defmodule Workstation.Core.DownloadTest do
  @moduledoc """
  The pinned-artifact contract: recipe validation, plan integration
  (pins content-addressed into the generation, exclusive target ownership),
  fail-closed install (checksum mismatch installs nothing, a mismatched
  existing target is never overwritten, a matching target is an idempotent
  no-op that skips the fetch) and the apply-boundary journal integration.
  """

  use ExUnit.Case, async: false

  require Record

  alias Workstation.Core.{Digest, EngineState, Graph, Journal, Source}
  alias Workstation.Pipeline
  alias Workstation.Backends.Chezmoi
  alias Workstation.Core.Contracts.Download

  # Both redirected-TLS host names are served by ONE endpoint on the
  # loopback with a wildcard-only (*.download.test) cert; the in-VM inet_db
  # host table resolves them (the tests never touch /etc/hosts).
  @download_test_hosts [~c"redirect.download.test", ~c"asset.download.test"]

  setup do
    home = Path.join(System.tmp_dir!(), "workstation-download-#{:os.getpid()}-#{System.unique_integer([:positive])}")
    File.rm_rf!(home)
    File.mkdir_p!(home)
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home}
  end

  # The redirected-TLS tests share ONE VM-global resolver state: the tests
  # never touch /etc/hosts, the in-VM inet_db host table resolves their two
  # .download.test names, and the module restores the previous lookup order
  # (and clears the loaded trust store) once, after all tests — per-test
  # on_exit callbacks can overlap the next test, so global restore belongs
  # at module scope only.
  setup_all do
    old_lookup = :inet_db.res_option(:lookup)
    :inet_db.set_lookup([:file, :native])
    :inet_db.add_host({127, 0, 0, 1}, @download_test_hosts)

    on_exit(fn ->
      :public_key.cacerts_clear()
      :inet_db.del_host({127, 0, 0, 1})
      :inet_db.set_lookup(old_lookup)
    end)

    :ok
  end

  describe "recipe validation" do
    test "accepts a well-formed pin" do
      spec = recipe()
      assert spec.url == "https://example.invalid/artifacts/tool/1.0.0/tool"
      assert spec.target == ".local/bin/tool"
    end

    test "rejects non-https urls, bad checksums, unsafe targets and missing fields" do
      assert_raise ArgumentError, ~r/must be https/, fn -> recipe(url: "http://example.invalid/tool") end

      assert_raise ArgumentError, ~r/64 lowercase hex/, fn ->
        recipe(sha256: String.upcase(sha_a()))
      end

      assert_raise ArgumentError, ~r/64 lowercase hex/, fn -> recipe(sha256: "abc") end

      assert_raise ArgumentError, ~r/relative path inside the home/, fn -> recipe(target: "/usr/local/bin/tool") end

      assert_raise ArgumentError, ~r/relative path inside the home/, fn ->
        recipe(target: ".local/../escape/tool")
      end

      assert_raise ArgumentError, ~r/literal path/, fn -> recipe(target: ".local/bin/*") end

      assert_raise ArgumentError, ~r/engine-private state/, fn ->
        recipe(target: ".local/state/workstation/tool")
      end

      assert_raise ArgumentError, ~r/requires sha256/, fn -> recipe(sha256: nil) end
    end
  end

  describe "plan integration" do
    test "download pins are content-addressed into the manifest and generation" do
      plan = plan_with_downloads()
      assert length(plan.downloads) == 2

      names = Enum.map(plan.manifest, & &1["name"])
      assert Enum.any?(names, &String.starts_with?(&1, "download/"))

      download = hd(plan.downloads)
      descriptor = Enum.find(plan.manifest, &(&1["name"] == download.source_name))
      assert descriptor
      assert descriptor["type"] == "file"
      assert Jason.decode!(Download.pin_bytes(download))["sha256"] == download.sha256

      # Changing any pin field changes the generation id.
      changed = plan_with_downloads(sha_a: sha_b())
      assert changed.generation != plan.generation
    end

    test "a download target owned by a chezmoi entry is a composition conflict" do
      package = %{
        id: "clashing",
        requires: [],
        contributes: [
          %{provider: "download", spec: recipe(target: ".local/bin/tool")},
          %{provider: "chezmoi", spec: Chezmoi.recipe(%{target: ".local/bin/tool", kind: :file, content: "x"})}
        ]
      }

      assert_raise ArgumentError, ~r/overlaps owned target/, fn -> plan_for([package]) end
    end

    test "two downloads of one target are a duplicate conflict" do
      package = %{
        id: "dup",
        requires: [],
        contributes: [
          %{provider: "download", spec: recipe(target: ".local/bin/tool")},
          %{provider: "download", spec: recipe(target: ".local/bin/tool", sha256: sha_b())}
        ]
      }

      assert_raise ArgumentError, ~r/duplicate download target/, fn -> plan_for([package]) end
    end

    test "a declared removal reaching a download target is a conflict" do
      package = %{
        id: "remover",
        requires: [],
        contributes: [
          %{provider: "download", spec: recipe(target: ".local/bin/tool")},
          %{provider: "chezmoi", spec: Chezmoi.recipe(%{target: ".local/bin/tool", kind: :remove})}
        ]
      }

      assert_raise ArgumentError, ~r/overlaps download target/, fn -> plan_for([package]) end
    end
  end

  describe "install" do
    test "installs verified bytes executable, then skips the fetch on re-install" do
      home = fresh_home()
      spec = recipe()
      {:ok, bytes} = fetch_payload()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      fetch = fn _url ->
        Agent.update(calls, &(&1 + 1))
        bytes
      end

      assert {:ok, :installed} = Download.install(spec, home, fetch: fetch)
      path = Path.join(home, spec.target)
      assert File.read!(path) == bytes
      assert mode_of(path) == 0o755

      assert {:ok, :already_installed} = Download.install(spec, home, fetch: fetch)
      assert Agent.get(calls, & &1) == 1, "a matching target must be an idempotent no-op without a fetch"
    end

    test "checksum mismatch installs nothing (fail-closed)" do
      home = fresh_home()
      spec = recipe()

      assert_raise ArgumentError, ~r/failed the pinned checksum/, fn ->
        Download.install(spec, home, fetch: fn _url -> "not the pinned bytes" end)
      end

      refute File.exists?(Path.join(home, spec.target))
      # No staged leftovers either: the parent directory is never created.
      refute File.exists?(Path.dirname(Path.join(home, spec.target)))
    end

    test "an existing target with different content is never overwritten" do
      home = fresh_home()
      spec = recipe()
      path = Path.join(home, spec.target)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "someone else's binary")

      assert_raise ArgumentError, ~r/refusing to overwrite a mismatched artifact/, fn ->
        Download.install(spec, home, fetch: fn _url -> raise("a mismatched existing target must fail before any fetch") end)
      end

      assert File.read!(path) == "someone else's binary"
    end
  end

  describe "apply-boundary integration" do
    test "apply installs the pinned artifact, records ownership, and re-apply is an idempotent no-op", %{home: home} do
      install_fake_chezmoi(home)
      {:ok, bytes} = fetch_payload()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      fetch = fn url ->
        Agent.update(calls, &(&1 + 1))

        if String.contains?(url, "/other/") do
          "#!/usr/bin/env sh\nexit 1\n"
        else
          bytes
        end
      end

      plan = plan_with_downloads()
      assert Pipeline.execute(plan, %{"home" => home, "fetch" => fetch}) == plan.generation

      path = Path.join(home, "tools/downloaded/tool")
      assert File.read!(path) == bytes
      assert mode_of(path) == 0o755

      # Two artifacts, two fetches.
      assert Agent.get(calls, & &1) == 2

      record = Journal.applied(Path.join([home | EngineState.state_components()]))
      target_record = Map.fetch!(record["targets"], "tools/downloaded/tool")
      assert %{"owner" => "tooling", "operation" => "download"} = target_record
      assert target_record["sha256"] == sha_a()

      # Re-apply: every artifact already matches its pin, so no more fetches.
      assert Pipeline.execute(plan, %{"home" => home, "fetch" => fetch}) == plan.generation
      assert Agent.get(calls, & &1) == 2
      assert Journal.applied(Path.join([home | EngineState.state_components()]))["revision"] == 2
    end

    test "a refused download fails the whole apply fail-closed and leaves the pending anchor", %{home: home} do
      install_fake_chezmoi(home)
      plan = plan_with_downloads()

      assert_raise ArgumentError, ~r/failed the pinned checksum/, fn ->
        Pipeline.execute(plan, %{"home" => home, "fetch" => fn _url -> "tampered" end})
      end

      state_root = Path.join([home | EngineState.state_components()])
      assert Journal.applied(state_root) == nil
      pending = Journal.pending(state_root)
      assert [%{"targets" => targets}] = pending
      assert "tools/downloaded/tool" in targets
      refute File.exists?(Path.join(home, "tools/downloaded/tool"))
    end
  end

  describe "per-platform dispatch" do
    test "a dispatched pin declares per-platform assets and validates them" do
      spec = dispatched_recipe()

      assert spec.assets == %{
               "linux_x86_64" => %{url: "https://example.invalid/tool-linux", sha256: sha_a()},
               "darwin_arm64" => %{url: "https://example.invalid/tool-darwin", sha256: sha_b()}
             }

      assert spec.url == nil and spec.sha256 == nil
      :ok = Download.validate(spec)
    end

    test "unknown platform tags and malformed assets fail closed" do
      assert_raise ArgumentError, ~r/unknown platform tag "linux-amd64"/, fn ->
        Download.recipe(%{
          version: "1.0.0",
          target: ".local/bin/tool",
          assets: %{"linux-amd64" => %{url: "https://example.invalid/x", sha256: sha_a()}}
        })
      end

      assert_raise ArgumentError, ~r/download recipe requires sha256/, fn ->
        Download.recipe(%{
          version: "1.0.0",
          target: ".local/bin/tool",
          assets: %{"linux_x86_64" => %{url: "https://example.invalid/x"}}
        })
      end

      assert_raise ArgumentError, ~r/must be a table with url and sha256/, fn ->
        Download.recipe(%{
          version: "1.0.0",
          target: ".local/bin/tool",
          assets: %{"linux_x86_64" => "not-a-table"}
        })
      end

      assert_raise ArgumentError, ~r/download assets must be a non-empty table/, fn ->
        Download.recipe(%{version: "1.0.0", target: ".local/bin/tool", assets: %{}})
      end
    end

    test "resolve picks the executing host's asset through the contract" do
      spec = dispatched_recipe()
      resolved = Download.resolve(spec, "linux_x86_64")

      assert resolved.url == "https://example.invalid/tool-linux"
      assert resolved.sha256 == sha_a()

      assert_raise ArgumentError, ~r/declares no asset for darwin_x86_64/, fn ->
        Download.resolve(spec, "darwin_x86_64")
      end
    end

    test "a direct pin resolves to itself" do
      resolved = Download.resolve(recipe())
      assert resolved.url == "https://example.invalid/artifacts/tool/1.0.0/tool"
      assert resolved.sha256 == sha_a()
    end

    test "install resolves the executing host's asset (dispatch through the contract, not the caller)" do
      spec =
        dispatched_recipe(%{
          "linux_x86_64" => %{url: "https://example.invalid/tool-linux", sha256: sha_a()}
        })

      home = Path.join(System.tmp_dir!(), "workstation-dispatch-#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      on_exit(fn -> File.rm_rf!(home) end)

      assert {:ok, :installed} = Download.install(spec, home, fetch: fn url ->
               assert url == "https://example.invalid/tool-linux"
               payload_bytes()
             end)

      assert File.read!(Path.join(home, ".local/bin/tool")) == payload_bytes()
      assert {:ok, :already_installed} = Download.install(spec, home, fetch: fn _ -> flunk("refetched") end)
    end

    test "the pin descriptor carries every platform's provenance, machine-independently" do
      spec = dispatched_recipe()
      descriptor = Download.pin_bytes(spec)

      assert descriptor =~ "tool-linux"
      assert descriptor =~ "tool-darwin"
      refute descriptor =~ "linux_x86_64\"}"

      # The fingerprint (and so the generation id) changes when ANY
      # platform's pin changes.
      other =
        Download.recipe(%{
          version: "1.0.0",
          target: ".local/bin/tool",
          assets: %{
            "linux_x86_64" => %{url: "https://example.invalid/tool-linux", sha256: sha_a()},
            "darwin_arm64" => %{url: "https://example.invalid/tool-darwin", sha256: sha_a()}
          }
        })

      refute Download.fingerprint(spec) == Download.fingerprint(other)
    end

    test "the dispatched spec survives the recorded-envelope round trip" do
      spec = dispatched_recipe()

      recorded = %{
        "version" => "1.0.0",
        "target" => ".local/bin/tool",
        "assets" => %{
          "linux_x86_64" => %{"url" => "https://example.invalid/tool-linux", "sha256" => sha_a()},
          "darwin_arm64" => %{"url" => "https://example.invalid/tool-darwin", "sha256" => sha_b()}
        }
      }

      assert Download.from_recorded(recorded) == spec
    end

    test "plan effects carry the declared assets unresolved" do
      spec = dispatched_recipe()

      package = %{
        id: "tooling",
        requires: [],
        contributes: [%{provider: Download.provider_id(), spec: spec}]
      }

      plan = plan_for([package])
      [effect] = Download.plan_effect(plan, %{})

      assert effect.target == ".local/bin/tool"
      assert effect.assets["linux_x86_64"].url == "https://example.invalid/tool-linux"
      refute Map.has_key?(effect, :url)
      refute Map.has_key?(effect, :sha256)
    end
  end

  describe "golden envelope round-trip" do
    test "a recorded download spec denormalizes to the native recipe" do
      spec =
        Download.from_recorded(%{
          "url" => "https://example.invalid/artifacts/tool/1.0.0/tool",
          "version" => "1.0.0",
          "sha256" => sha_a(),
          "target" => ".local/bin/tool"
        })

      assert spec == recipe()
    end
  end

  describe "default fetch through redirected TLS" do
    # The GitHub release-asset regression shape: the first hop redirects to a
    # DIFFERENT host and every hop presents a WILDCARD-ONLY cert
    # (*.download.test). ssl's default hostname check is exact-match, so the
    # chain dies in hostname_check_failed unless the fetch verifies with
    # public_key.pkix_verify_hostname_match_fun(:https) and pins the SNI and
    # reference id to each hop's connected host.
    test "follows a cross-host redirect verified against a wildcard-only cert" do
      payload = "pinned-artifact-bytes-#{System.unique_integer()}"
      server = start_wildcard_tls_server(:cross_host, payload)

      assert Download.http_fetch("https://redirect.download.test:#{server.port}/artifact") == payload
    end

    test "caps the redirect chain instead of following forever" do
      server = start_wildcard_tls_server(:loop, "never reached")

      assert_raise ArgumentError, ~r/exceeded 5 redirects/, fn ->
        Download.http_fetch("https://redirect.download.test:#{server.port}/artifact")
      end
    end

    test "refuses a redirect that downgrades to plain http" do
      server = start_wildcard_tls_server(:downgrade, "never reached")

      assert_raise ArgumentError, ~r/refuses non-https redirect/, fn ->
        Download.http_fetch("https://redirect.download.test:#{server.port}/artifact")
      end
    end

    test "the wildcard-only cert really needs the https match fun: ssl's default check rejects it" do
      server = start_wildcard_tls_server(:cross_host, "unused")

      assert {:error, reason} =
               :ssl.connect(~c"asset.download.test", server.port,
                 verify: :verify_peer,
                 cacerts: server.cacerts,
                 depth: 3,
                 server_name_indication: ~c"asset.download.test"
               )

      assert inspect(reason) =~ "hostname_check_failed"
    end
  end

  # --- helpers ---

  defp dispatched_recipe(overrides \\ %{}), do: Download.recipe(dispatched_attrs(overrides))

  defp dispatched_attrs(overrides) do
    Map.merge(
      %{
        version: "1.0.0",
        target: ".local/bin/tool",
        assets: %{
          "linux_x86_64" => %{url: "https://example.invalid/tool-linux", sha256: sha_a()},
          "darwin_arm64" => %{url: "https://example.invalid/tool-darwin", sha256: sha_b()}
        }
      },
      overrides
    )
  end

  defp recipe(overrides \\ []) do
    Download.recipe(%{
      url: Keyword.get(overrides, :url, "https://example.invalid/artifacts/tool/1.0.0/tool"),
      version: Keyword.get(overrides, :version, "1.0.0"),
      sha256: Keyword.get(overrides, :sha256, sha_a()),
      target: Keyword.get(overrides, :target, ".local/bin/tool")
    })
  end

  defp payload_bytes, do: "#!/usr/bin/env sh\nexit 0\n"

  # The pinned checksum of the test payload: recipes under these tests pin
  # exactly the bytes their injected fetch returns.
  defp sha_a, do: Digest.sha256(payload_bytes())

  defp sha_b, do: Digest.sha256("#!/usr/bin/env sh\nexit 1\n")

  defp fetch_payload, do: {:ok, payload_bytes()}

  defp plan_for(packages) do
    graph = Graph.order(%{host: "linux", specifications: packages})
    Source.plan(%{graph: graph})
  end

  defp plan_with_downloads(overrides \\ []) do
    sha_a = Keyword.get(overrides, :sha_a, sha_a())

    package = %{
      id: "tooling",
      requires: [],
      contributes: [
        %{provider: "download", spec: recipe(sha256: sha_a, target: "tools/downloaded/tool")},
        %{
          provider: "download",
          spec:
            recipe(
              url: "https://example.invalid/artifacts/other/2.0.0/other",
              version: "2.0.0",
              sha256: sha_b(),
              target: "tools/downloaded/other"
            )
        }
      ]
    }

    plan_for([package])
  end

  defp fresh_home do
    home =
      Path.join(
        System.tmp_dir!(),
        "workstation-download-unit-#{:os.getpid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(home)
    File.mkdir_p!(home)
    home
  end

  defp install_fake_chezmoi(home) do
    path = Path.join([home, ".local", "opt", "chezmoi", "bin", "chezmoi"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh
exit 0
")
    File.chmod!(path, 0o755)
  end

  defp mode_of(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o777)
      _other -> nil
    end
  end

  # --- the redirected-TLS test server ---

  defp start_wildcard_tls_server(mode, payload) do
    {:ok, _} = Application.ensure_all_started(:ssl)
    %{cert: cert, key: key, cacerts: [root_der | _]} = wildcard_only_cert()

    {:ok, listen} = :ssl.listen(0, ip: {127, 0, 0, 1}, cert: cert, key: key)
    {:ok, {_address, port}} = :ssl.sockname(listen)

    # The fetch trusts what public_key has loaded, so this test's root
    # becomes the VM trust store for the test (setup_all clears it again
    # after the module).
    root_pem =
      Path.join(System.tmp_dir!(), "workstation-test-root-#{System.unique_integer([:positive])}.pem")

    File.write!(root_pem, :public_key.pem_encode([{:Certificate, root_der, :not_encrypted}]))
    :ok = :public_key.cacerts_load(root_pem)

    server = spawn_link(fn -> accept_loop(listen, port, mode, payload) end)

    on_exit(fn ->
      Process.exit(server, :kill)
      File.rm(root_pem)
    end)

    %{port: port, cacerts: [root_der]}
  end

  defp accept_loop(listen, port, mode, payload) do
    case :ssl.transport_accept(listen) do
      {:ok, sock} ->
        # One handler per connection: a hop's handshake must never queue
        # behind the previous hop's close.
        spawn(fn -> serve_connection(sock, port, mode, payload) end)
        accept_loop(listen, port, mode, payload)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve_connection(sock, port, mode, payload) do
    case :ssl.handshake(sock) do
      {:ok, tls} ->
        request = read_request(tls, "")
        :ssl.send(tls, response(request, port, mode, payload))
        :ssl.close(tls)

      {:error, _aborted} ->
        :ssl.close(sock)
    end
  end

  defp read_request(tls, buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {_start, _length} ->
        buffer

      :nomatch ->
        case :ssl.recv(tls, 0, 5_000) do
          {:ok, data} -> read_request(tls, buffer <> data)
          {:error, _reason} -> buffer
        end
    end
  end

  defp response(request, port, mode, payload) do
    case mode do
      :cross_host ->
        if String.contains?(request, "redirect.download.test") do
          redirect_response("https://asset.download.test:#{port}/artifact")
        else
          ok_response(payload)
        end

      :loop ->
        redirect_response("https://redirect.download.test:#{port}/artifact")

      :downgrade ->
        redirect_response("http://asset.download.test:#{port}/artifact")
    end
  end

  defp redirect_response(location) do
    "HTTP/1.1 302 Found\r\nlocation: #{location}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
  end

  defp ok_response(payload) do
    "HTTP/1.1 200 OK\r\ncontent-type: application/octet-stream\r\n" <>
      "content-length: #{byte_size(payload)}\r\nconnection: close\r\n\r\n" <> payload
  end

  # A root CA whose server cert carries exactly ONE wildcard SAN — the
  # RFC 6125 single-label shape (`*.download.test` matches
  # `asset.download.test` only with the https match fun). The RSA key and
  # sha256 digest mirror a real-world server cert: pkix_test_data's sha1
  # default makes the TLS 1.3 server refuse its own cert (never send a
  # sha1-signed chain), and ECDSA keys are irrelevant to what's under test.
  defp wildcard_only_cert do
    [cert: cert, key: key, cacerts: cacerts] =
      :public_key.pkix_test_data(%{
        root: [digest: :sha256],
        intermediates: [],
        peer: [
          key: {:rsa, 2048, 65_537},
          digest: :sha256,
          extensions: [wildcard_san_extension()]
        ]
      })

    %{cert: cert, key: key, cacerts: cacerts}
  end

  @extension_defaults Record.extract(:'Extension', from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  Record.defrecordp(:x509_extension, :"Extension", @extension_defaults)

  defp wildcard_san_extension do
    # extnID {2,5,29,17} is the OTP-PUB-KEY.hrl ?'id-ce-subjectAltName' OID.
    x509_extension(
      extnID: {2, 5, 29, 17},
      critical: false,
      extnValue: [{:dNSName, ~c"*.download.test"}]
    )
  end
end
