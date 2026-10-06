defmodule Workstation.Daemon.ProtocolTest do
  use ExUnit.Case, async: true

  alias Workstation.Daemon.Protocol

  # --- framing ---------------------------------------------------------------

  describe "frame framing" do
    test "encode_frame prefixes a 4-byte unsigned big-endian length" do
      frame = Protocol.encode_frame("{}")
      # The prefix counts the JSON body only (2 bytes), never itself.
      assert <<2::unsigned-big-integer-size(32), "{}"::binary>> = frame
      assert byte_size(frame) == 6
    end

    test "header_length_ok?/1 enforces the request cap exactly" do
      refute Protocol.header_length_ok?(0)
      assert Protocol.header_length_ok?(1)
      assert Protocol.header_length_ok?(Protocol.max_request_bytes())
      refute Protocol.header_length_ok?(Protocol.max_request_bytes() + 1)
    end

    test "encode_frame/1 refuses payloads above the request cap" do
      assert_raise ArgumentError, ~r/cap/, fn ->
        Protocol.encode_frame(String.duplicate("x", Protocol.max_request_bytes() + 1))
      end
    end
  end

  # --- caps --------------------------------------------------------------

  describe "response caps" do
    test "encode_result/2 frames results within the response cap" do
      assert {:ok, frame} = Protocol.encode_result(1, %{"ok" => true})
      <<len::unsigned-big-integer-size(32), _rest::binary>> = frame
      assert len == byte_size(frame) - 4
    end

    test "encode_result/2 refuses results above the response cap without truncating" do
      oversized = %{"blob" => String.duplicate("x", Protocol.max_response_bytes())}

      assert {:error, {:response_too_large, bytes}} = Protocol.encode_result(1, oversized)
      assert bytes > Protocol.max_response_bytes()
    end
  end

  # --- handshake -----------------------------------------------------------

  describe "hello handshake" do
    test "capabilities advertise the protocol, version, ops, domains and caps" do
      caps = Protocol.capabilities()

      # The literal payload is the published wire contract; CapabilitiesTest
      # pins only its derivation — this pin is what breaks when the published
      # surface changes.
      assert caps["protocol"] == "workstation.daemon/1"
      assert caps["version"] == 1
      # The served op set is derived from the capability registry, not
      # hardcoded here; hello is the handshake op, the rest are capabilities.
      assert caps["ops"] == [
               "apply.run",
               "bootstrap.run",
               "daemon.stop",
               "diff.run",
               "hello",
               "plan.run",
               "pull.run",
               "status.run",
               "sync.run",
               "theme.resolve",
               "update.check",
               "update.run",
               "verify.run"
             ]
      # The pinned-home advertisement: the client's --home honesty check
      # compares its resolved destination against exactly this field.
      assert is_binary(caps["home"])

      # Domains come from the capabilities that register them.
      assert caps["domains"] == ["theme"]
      assert caps["caps"]["max_request_bytes"] == 1_048_576
      assert caps["caps"]["max_response_bytes"] == 16_777_216
      assert caps["caps"]["frame_timeout_ms"] == 5_000
      assert caps["caps"]["max_depth"] == 32
    end

    test "version_mismatch?/1 only fires on a different protocol name" do
      refute Protocol.version_mismatch?(%{"protocol" => "workstation.daemon/1"})
      assert Protocol.version_mismatch?(%{"protocol" => "workstation.daemon/0"})
      # A client that sends no protocol is tolerated (bare ping hello).
      refute Protocol.version_mismatch?(%{})
    end

    test "hello params are strict" do
      assert {:ok, %{"protocol" => "workstation.daemon/1"}} =
               Protocol.decode_hello_params(%{"protocol" => "workstation.daemon/1"})

      assert {:error, {"invalid_params", _}} = Protocol.decode_hello_params(%{"protocol" => 1})
      assert {:error, {"invalid_params", _}} = Protocol.decode_hello_params(%{"extra" => true})

      # An envelope without params decodes as empty and fails the handshake
      # schema on the missing protocol announcement.
      assert {:error, {"invalid_params", _}} = Protocol.decode_params("hello", nil)
    end
  end

  # --- request envelope ------------------------------------------------------

  describe "decode_request/1" do
    test "round-trips a valid request" do
      body = ~s({"v":1,"id":"a","op":"hello","params":{"protocol":"workstation.daemon/1"}})

      assert {:ok, %{"v" => 1, "id" => "a", "op" => "hello", "params" => %{"protocol" => "workstation.daemon/1"}}} =
               Protocol.decode_request(body)
    end

    test "hello without the protocol announcement is invalid_params (handshake cannot be verified)" do
      body = ~s({"v":1,"id":2,"op":"hello"})
      assert {:error, {"invalid_params", _}} = Protocol.decode_request(body)
    end

    test "rejects non-JSON bodies" do
      assert {:error, {"bad_json", _}} = Protocol.decode_request("this is not json")
    end

    test "rejects unknown top-level fields (strict envelope)" do
      body = ~s({"v":1,"id":"a","op":"hello","extra":"x"})
      assert {:error, {"bad_request", _}} = Protocol.decode_request(body)
    end

    test "rejects a version other than 1" do
      body = ~s({"v":2,"id":"a","op":"hello"})
      assert {:error, {"bad_request", _}} = Protocol.decode_request(body)
    end

    test "rejects unknown ops" do
      body = ~s({"v":1,"id":"a","op":"apply.everything"})
      assert {:error, {"unknown_op", _}} = Protocol.decode_request(body)
    end

    test "rejects depth violations before schema validation" do
      deep = Enum.reduce(1..40, 1, fn _, acc -> %{"n" => acc} end)
      body = Jason.encode!(%{"v" => 1, "id" => "a", "op" => "hello", "params" => %{"protocol" => deep}})
      assert {:error, {"bad_request", message}} = Protocol.decode_request(body)
      assert message =~ "nesting"
    end

    test "shallow type violations are schema errors, not depth errors" do
      body = Jason.encode!(%{"v" => 1, "id" => "a", "op" => "hello", "params" => %{"protocol" => 5}})
      assert {:error, {"invalid_params", _}} = Protocol.decode_request(body)
    end
  end

  describe "capability param schemas (decode_params/2)" do
    test "accepts a shape-valid overlay patch" do
      params = %{"appearance" => "dark", "overlays" => [%{"from" => "brand", "set" => %{"accent" => "#ff0000"}}]}
      assert {:ok, _} = Protocol.decode_params("theme.resolve", params)
    end

    test "rejects unknown fields on any level" do
      top = %{"appearance" => "dark", "overlays" => [], "extra" => 1}
      assert {:error, {"invalid_params", _}} = Protocol.decode_params("theme.resolve", top)

      overlay = %{"from" => "brand", "set" => %{}, "extra" => 1}
      assert {:error, {"invalid_params", _}} = Protocol.decode_params("theme.resolve", %{"appearance" => "dark", "overlays" => [overlay]})
    end

    test "rejects a non-enum appearance at the schema level" do
      params = %{"appearance" => "system", "overlays" => []}
      assert {:error, {"invalid_params", _}} = Protocol.decode_params("theme.resolve", params)
    end

    test "served ops without params are refused; unknown ops refuse with unknown_op" do
      assert {:error, {"invalid_params", message}} = Protocol.decode_params("theme.resolve", nil)
      assert message =~ "requires params"

      assert {:error, {"unknown_op", _}} = Protocol.decode_params("apply.everything", %{})
    end

    test "lifecycle schemas stay strict through the capability registry" do
      assert {:ok, %{"step" => "verify"}} = Protocol.decode_params("update.run", %{"step" => "verify"})
      assert {:error, {"invalid_params", _}} = Protocol.decode_params("update.run", %{"step" => "deploy"})

      assert {:ok, %{"generation" => "g1"}} =
               Protocol.decode_params("apply.run", %{"generation" => "g1", "entries" => []})

      assert {:error, {"invalid_params", _}} = Protocol.decode_params("apply.run", %{"generation" => ""})
    end
  end
end
