defmodule Workstation.Core.DownloadTest do
  @moduledoc """
  The pinned-artifact contract: recipe validation, plan integration
  (pins content-addressed into the generation, exclusive target ownership),
  fail-closed install (checksum mismatch installs nothing, a mismatched
  existing target is never overwritten, a matching target is an idempotent
  no-op that skips the fetch), the archive form (traversal-checked,
  single-rooted, strip-one-root exact-tree installs gated by the declared
  probe — idempotent through the probe, refused overwrite on version drift,
  a claim and a verify seam that re-probe the actual tree) and the
  apply-boundary journal integration.
  """

  use ExUnit.Case, async: false

  # Fixture homes are cross-VM collision-proof (the full note lives in
  # apps/daemon/test/workstation/daemon/generation_test.exs): the boot
  # millisecond in base36 never repeats across `mix test` VM instances the
  # way the restarted `System.unique_integer/1` sequence does, and the
  # within-VM base36 tail keeps concurrent async draws (or two calls inside
  # one test) from sharing a millisecond. Any same-named leftover is swept
  # before use and the home is removed on exit.
  defp unique_home(prefix) do
    token =
      Integer.to_string(:os.system_time(:millisecond), 36) <>
        Integer.to_string(System.unique_integer([:positive]), 36)

    home = Path.join(System.tmp_dir!(), "#{prefix}-#{token}")

    File.rm_rf!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    home
  end


  require Record
  import Bitwise

  alias Workstation.Core.{Digest, EngineState, Graph, Journal, Source}
  alias Workstation.Pipeline
  alias Workstation.Backends.Chezmoi
  alias Workstation.Core.Contracts.Download

  # Both redirected-TLS host names are served by ONE endpoint on the
  # loopback with a wildcard-only (*.download.test) cert; the in-VM inet_db
  # host table resolves them (the tests never touch /etc/hosts).
  @download_test_hosts [~c"redirect.download.test", ~c"asset.download.test"]

  setup do
    home = unique_home("workstation-download")
    File.mkdir_p!(home)
    System.put_env("WORKSTATION_HOME", home)

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

    test "a stale pending anchor on bootstrap-provisioned surface reconciles through the apply", %{home: home} do
      # The 2026-10-19 convergence catch-22: an interrupted attempt's anchor
      # listed engine-provisioned surface (a pinned download) that no backend
      # entry ever declares. The next generation desires exactly that
      # surface, so the anchor must not wedge the apply — the fold
      # re-produces the target (byte-identical already: an idempotent
      # no-op), the claim records ownership, and the anchor retires. The
      # next successful apply is what clears the evidence.
      install_fake_chezmoi(home)
      {:ok, bytes} = fetch_payload()

      stale = String.duplicate("79", 32)

      Journal.write_pending(home, %{
        "generation" => stale,
        "at" => System.system_time(:second),
        "pid" => :os.getpid(),
        "entries" => 0,
        "targets" => ["tools/downloaded/tool"]
      })

      # The interrupted attempt's own write: byte-identical to the pin.
      path = Path.join(home, "tools/downloaded/tool")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)

      fetch = fn url ->
        if String.contains?(url, "/other/"), do: "#!/usr/bin/env sh\nexit 1\n", else: bytes
      end

      plan = plan_with_downloads()
      assert Pipeline.execute(plan, %{"home" => home, "fetch" => fetch}) == plan.generation

      # The plan's own claim owns the formerly stray target.
      record = Journal.applied(Path.join([home | EngineState.state_components()]))
      assert record["targets"]["tools/downloaded/tool"]["operation"] == "download"

      # The anchor retired with the run — renamed, never deleted. Both the
      # stale record and the run's own anchor are preserved there.
      state_root = Path.join([home | EngineState.state_components()])
      assert Journal.pending(state_root) == []
      names = File.ls!(Path.join([state_root, "journal", "retired"]))
      assert stale <> ".json" in names and plan.generation <> ".json" in names
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

      home = unique_home("workstation-dispatch")
      File.mkdir_p!(home)

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

    test "a recorded archive spec denormalizes to the native archive recipe" do
      recorded = %{
        "archive" => "tar.gz",
        "probe" => %{"argv" => ["bin/go", "version"], "output" => "go version go{V}"},
        "url" => "https://example.invalid/artifacts/tool/1.0.0/tool.tar.gz",
        "version" => "1.0.0",
        "sha256" => sha_a(),
        "target" => ".local/opt/tool"
      }

      assert Download.from_recorded(recorded) ==
               Download.recipe(%{
                 archive: "tar.gz",
                 probe: %{argv: ["bin/go", "version"], output: "go version go{V}"},
                 url: "https://example.invalid/artifacts/tool/1.0.0/tool.tar.gz",
                 version: "1.0.0",
                 sha256: sha_a(),
                 target: ".local/opt/tool"
               })

      assert_raise ArgumentError, ~r/download archive pin requires a probe/, fn ->
        Download.from_recorded(Map.delete(recorded, "probe"))
      end
    end
  end

  describe "archive form" do
    @probe %{argv: ["bin/go", "version"], output: "go version go{V}"}
    @fixture_banner "go version go1.27.1 linux/amd64"

    test "recipe validation holds the archive vocabulary" do
      spec = Download.recipe(%{url: "https://example.invalid/go.tar.gz", version: "1.27.1", sha256: sha_a(), target: ".local/opt/go", archive: "tar.gz", probe: @probe})
      assert spec.archive == "tar.gz"
      assert spec.probe == @probe
      :ok = Download.validate(spec)

      assert_raise ArgumentError, ~r/download archive must be one of tar\.gz, tar\.xz, zip/, fn ->
        Download.recipe(%{url: "https://example.invalid/go.tar.bz2", version: "1.27.1", sha256: sha_a(), target: ".local/opt/go", archive: "tar.bz2", probe: @probe})
      end

      assert_raise ArgumentError, ~r/download probe requires an archive pin/, fn ->
        Download.recipe(%{url: "https://example.invalid/tool", version: "1.0.0", sha256: sha_a(), target: ".local/bin/tool", probe: @probe})
      end

      assert_raise ArgumentError, ~r/download archive pin requires a probe/, fn ->
        Download.recipe(%{url: "https://example.invalid/go.tar.gz", version: "1.27.1", sha256: sha_a(), target: ".local/opt/go", archive: "tar.gz"})
      end

      assert_raise ArgumentError, ~r/must be a relative member/, fn ->
        Download.recipe(%{url: "https://example.invalid/go.tar.gz", version: "1.27.1", sha256: sha_a(), target: ".local/opt/go", archive: "tar.gz", probe: %{argv: ["../outside/go", "version"], output: "go version go{V}"}})
      end

      assert_raise ArgumentError, ~r/exactly the \{V\} version template/, fn ->
        Download.recipe(%{url: "https://example.invalid/go.tar.gz", version: "1.27.1", sha256: sha_a(), target: ".local/opt/go", archive: "tar.gz", probe: %{argv: ["bin/go", "version"], output: "go version"}})
      end

      assert_raise ArgumentError, ~r/exactly the \{V\} version template/, fn ->
        Download.recipe(%{url: "https://example.invalid/go.tar.gz", version: "1.27.1", sha256: sha_a(), target: ".local/opt/go", archive: "tar.gz", probe: %{argv: ["bin/go", "version"], output: "{V} go version {V}"}})
      end

      # The pin's content address changes when the archive form joins it.
      file_pin = Download.recipe(%{url: "https://example.invalid/go.tar.gz", version: "1.27.1", sha256: sha_a(), target: ".local/opt/go"})
      refute Download.fingerprint(file_pin) == Download.fingerprint(spec)

      descriptor = Jason.decode!(Download.pin_bytes(spec))
      assert descriptor["archive"] == "tar.gz"
      assert descriptor["probe"] == %{"argv" => ["bin/go", "version"], "output" => "go version go{V}"}
    end

    test "installs the exact tree probe-verified, then is an idempotent no-op without a fetch" do
      home = fresh_home()
      {bytes, digest} = tree_fixture(@fixture_banner)
      spec = archive_recipe(sha256: digest)
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      fetch = fn _url ->
        Agent.update(calls, &(&1 + 1))
        bytes
      end

      assert {:ok, :installed} = Download.install(spec, home, fetch: fetch)

      tree = Path.join(home, ".local/opt/go")
      assert File.read!(Path.join(tree, "VERSION")) == "go-1.27.1\n"
      assert mode_of(Path.join(tree, "bin/go")) == 0o755
      # Nothing else at the target: the staging directory is gone.
      assert Enum.sort(File.ls!(Path.dirname(tree))) == ["go"]

      assert {:ok, :already_installed} = Download.install(spec, home, fetch: fetch)
      assert Agent.get(calls, & &1) == 1, "a tree already carrying the pinned tool must not refetch"
    end

    test "a checksum mismatch installs nothing and leaves no staging debris" do
      home = fresh_home()
      spec = archive_recipe()

      assert_raise ArgumentError, ~r/failed the pinned checksum/, fn ->
        Download.install(spec, home, fetch: fn _url -> "not the archive" end)
      end

      refute File.exists?(Path.join(home, ".local/opt/go"))
      # The staging debris is swept with the staging directory itself.
      assert File.ls!(Path.join(home, ".local/opt")) == []
    end

    test "a traversal member refuses before extraction" do
      home = fresh_home()
      {bytes, digest} = tree_fixture(@fixture_banner, extra: {"../evil.txt", "escaped"})
      spec = archive_recipe(sha256: digest)

      assert_raise ArgumentError, ~r/unsafe archive member/, fn ->
        Download.install(spec, home, fetch: fn _url -> bytes end)
      end

      refute File.exists?(Path.join(home, ".local/opt/go"))
      refute File.exists?(Path.join(home, "evil.txt"))
      assert File.ls!(Path.join(home, ".local/opt")) == []
    end

    test "a multi-root archive refuses" do
      home = fresh_home()
      {bytes, digest} = tree_fixture(@fixture_banner, extra: {"other/file.txt", "second root"})
      spec = archive_recipe(sha256: digest)

      assert_raise ArgumentError, ~r/exactly one root directory/, fn ->
        Download.install(spec, home, fetch: fn _url -> bytes end)
      end

      refute File.exists?(Path.join(home, ".local/opt/go"))
    end

    test "a staged tree failing the probe never activates" do
      home = fresh_home()
      {bytes, digest} = tree_fixture("go version go1.99.0 linux/amd64")
      spec = archive_recipe(sha256: digest)

      assert_raise ArgumentError, ~r/does not carry the pinned tool/, fn ->
        Download.install(spec, home, fetch: fn _url -> bytes end)
      end

      refute File.exists?(Path.join(home, ".local/opt/go"))
    end

    test "an existing tree reporting a prefix-trapped version is never overwritten" do
      home = fresh_home()
      {bytes, digest} = tree_fixture("go version go1.27.10 linux/amd64")

      # The pin reads 1.27.1; the tree's banner says go1.27.10 — a prefix of
      # the pinned template but a different tool.
      spec = archive_recipe(sha256: digest, version: "1.27.1")
      File.mkdir_p!(Path.join(home, ".local/opt/go/bin"))
      File.write!(Path.join(home, ".local/opt/go/bin/go"), "#!/bin/sh\necho 'go version go1.27.10 linux/amd64'\n")
      File.chmod!(Path.join(home, ".local/opt/go/bin/go"), 0o755)

      assert_raise ArgumentError, ~r/refusing to overwrite — inspect and remove the tree explicitly/, fn ->
        Download.install(spec, home, fetch: fn _url -> raise("a mismatched tree must fail before any fetch") end)
      end

      assert File.read!(Path.join(home, ".local/opt/go/bin/go")) == "#!/bin/sh\necho 'go version go1.27.10 linux/amd64'\n"
    end

    test "an existing non-directory at an archive target is refused" do
      home = fresh_home()
      {bytes, digest} = tree_fixture(@fixture_banner)
      spec = archive_recipe(sha256: digest)
      File.mkdir_p!(Path.dirname(Path.join(home, ".local/opt/go")))
      File.write!(Path.join(home, ".local/opt/go"), "someone else's file")

      assert_raise ArgumentError, ~r/exists as file; refusing to replace/, fn ->
        Download.install(spec, home, fetch: fn _url -> bytes end)
      end
    end

    test "the applied claim re-probes the actual tree and records the archive record" do
      home = fresh_home()
      {bytes, digest} = tree_fixture(@fixture_banner)
      spec = archive_recipe(sha256: digest)

      assert {:ok, :installed} = Download.install(spec, home, fetch: fn _url -> bytes end)

      effect = %{
        contract: "download",
        kind: :install,
        phase: :target,
        owner: "go",
        target: ".local/opt/go",
        version: "1.27.1",
        archive: "tar.gz",
        probe: @probe,
        url: "https://example.invalid/go.tar.gz",
        sha256: digest,
        fingerprint: "pinfp"
      }

      record = Map.fetch!(Download.fingerprint(effect, %{home: home}), ".local/opt/go")
      assert record["type"] == "download-archive"
      assert record["version"] == "1.27.1"
      assert record["archive_sha256"] == digest
      assert record["owner"] == "go"
      assert record["probe"] == %{"argv" => ["bin/go", "version"], "output" => "go version go{V}"}

      # A missing tree is a failed claim, never a recorded one.
      File.rm_rf!(Path.join(home, ".local/opt/go"))

      assert_raise ArgumentError, ~r/apply did not produce download target/, fn ->
        Download.fingerprint(effect, %{home: home})
      end
    end

    test "the verify seam re-probes the recorded tree and refuses drift" do
      home = fresh_home()
      {bytes, digest} = tree_fixture(@fixture_banner)
      spec = archive_recipe(sha256: digest)
      {:ok, :installed} = Download.install(spec, home, fetch: fn _url -> bytes end)

      # The record UNDER TEST is the WRITER's own output round-tripped —
      # the shape verify actually receives from the journal, not a
      # hand-built lookalike (the target-key gap shipped exactly here).
      effect = %{
        contract: "download",
        kind: :install,
        phase: :target,
        owner: "go",
        target: ".local/opt/go",
        version: "1.27.1",
        archive: "tar.gz",
        probe: @probe,
        url: "https://example.invalid/go.tar.gz",
        sha256: digest,
        fingerprint: "pinfp"
      }

      record = Map.fetch!(Download.fingerprint(effect, %{home: home}), ".local/opt/go")
      assert Map.fetch!(record, "target") == ".local/opt/go"

      assert Download.verify_record(record, %{"home" => home}) == :ok

      # Tool drift: the probe member no longer reports the pinned version.
      File.write!(Path.join(home, ".local/opt/go/bin/go"), "#!/bin/sh\necho 'go version go1.99.0 linux/amd64'\n")
      File.chmod!(Path.join(home, ".local/opt/go/bin/go"), 0o755)

      assert_raise ArgumentError, ~r/does not carry the pinned tool/, fn ->
        Download.verify_record(record, %{"home" => home})
      end

      # A gone tree is a failed verify.
      File.rm_rf!(Path.join(home, ".local/opt/go"))

      assert_raise ArgumentError, ~r/verify: download target .* is gone/, fn ->
        Download.verify_record(record, %{"home" => home})
      end

      # Everything else stays :unclaimed for the default verification.
      assert Download.verify_record(%{"type" => "file"}, %{"home" => home}) == :unclaimed
    end

    test "a symlinked probe member (python3 -> python3.14 shape) probes through the link" do
      home = fresh_home()
      {bytes, digest} = symlink_tree_fixture(@fixture_banner)
      spec = archive_recipe(sha256: digest)

      assert {:ok, :installed} = Download.install(spec, home, fetch: fn _url -> bytes end)

      record = %{
        "type" => "download-archive",
        "target" => ".local/opt/go",
        "version" => "1.27.1",
        "probe" => %{"argv" => ["bin/go", "version"], "output" => "go version go{V}"}
      }

      assert Download.verify_record(record, %{"home" => home}) == :ok

      # A dangling link is a loud failure, never a silent pass.
      File.rm_rf!(Path.join(home, ".local/opt/go/bin/go.real"))

      assert_raise ArgumentError, ~r/lacks the probe member/, fn ->
        Download.verify_record(record, %{"home" => home})
      end
    end

    test "apply installs the pinned archive tree, records the archive claim, and re-apply is an idempotent no-op", %{home: home} do
      install_fake_chezmoi(home)
      {bytes, digest} = tree_fixture(@fixture_banner)

      package = %{
        id: "archiver",
        requires: [],
        contributes: [%{provider: "download", spec: archive_recipe(sha256: digest, target: "tools/archived/tool")}]
      }

      plan = plan_for([package])
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      fetch = fn _url ->
        Agent.update(calls, &(&1 + 1))
        bytes
      end

      assert Pipeline.execute(plan, %{"home" => home, "fetch" => fetch}) == plan.generation
      assert String.contains?(File.read!(Path.join(home, "tools/archived/tool/bin/go")), @fixture_banner)
      assert Agent.get(calls, & &1) == 1

      state_root = Path.join([home | EngineState.state_components()])
      record = Map.fetch!(Journal.applied(state_root)["targets"], "tools/archived/tool")
      assert record["type"] == "download-archive"
      assert record["owner"] == "archiver"
      assert record["archive_sha256"] == digest

      # Re-apply: the tree already carries the pinned tool, so no more fetches.
      assert Pipeline.execute(plan, %{"home" => home, "fetch" => fetch}) == plan.generation
      assert Agent.get(calls, & &1) == 1
      assert Journal.applied(state_root)["revision"] == 2
    end

    test "plan effects and composition carry the declared archive fields" do
      spec = archive_recipe(sha256: sha_a())

      go = %{
        id: "go",
        requires: [],
        contributes: [
          %{provider: Download.provider_id(), spec: spec},
          %{provider: "chezmoi", spec: Chezmoi.recipe(%{target: ".local/bin/go", kind: :symlink, to: "../opt/go/bin/go"})}
        ]
      }

      plan = plan_for([go])
      [effect] = Download.plan_effect(plan, %{})
      assert effect.archive == "tar.gz"
      assert effect.probe == @probe
      assert effect.target == ".local/opt/go"

      # An owned entry INSIDE the archive target is a composition conflict.
      squatter = %{
        id: "squatter",
        requires: [],
        contributes: [
          %{provider: "chezmoi", spec: Chezmoi.recipe(%{target: ".local/opt/go/bin/squatter", kind: :file, content: "x"})}
        ]
      }

      assert_raise ArgumentError, ~r/overlaps/, fn -> plan_for([go, squatter]) end
    end
  end

  describe "archive layouts" do
    test "a lone root file is the installed tree (the single-binary release shape)" do
      {bytes, digest} = single_file_fixture("fzf", "#!/bin/sh\necho '0.74.2 (3337be9d)'\n")

      spec =
        archive_recipe(version: "0.74.2", sha256: digest, target: ".local/opt/fzf", probe: %{argv: ["fzf", "--version"], output: "{V}"})

      home = fresh_home()

      assert {:ok, :installed} = Download.install(spec, home, fetch: fn _url -> bytes end)
      assert File.read!(Path.join([home, ".local/opt/fzf/fzf"])) == "#!/bin/sh\necho '0.74.2 (3337be9d)'\n"

      # Idempotent: the probe passes on the existing tree, no fetch happens.
      assert {:ok, :already_installed} = Download.install(spec, home, fetch: fn _url -> flunk("must not fetch") end)
    end

    test "the flat layout extracts top-level members as they are (the bare-release shape)" do
      {bytes, digest} =
        flat_tar_fixture([
          {"lazygit", "#!/bin/sh\necho 'version=0.63.1, os=linux'\n"},
          {"LICENSE", "MIT\n"},
          {"README.md", "lazygit\n"}
        ])

      spec =
        Download.recipe(%{
          url: "https://example.invalid/artifacts/lazygit/0.63.1/lazygit.tar.gz",
          version: "0.63.1",
          sha256: digest,
          target: ".local/opt/lazygit",
          archive: "tar.gz",
          layout: "flat",
          probe: %{argv: ["lazygit", "--version"], output: "version={V},"}
        })

      home = fresh_home()
      assert {:ok, :installed} = Download.install(spec, home, fetch: fn _url -> bytes end)
      tree = Path.join(home, ".local/opt/lazygit")

      assert File.read!(Path.join(tree, "LICENSE")) == "MIT\n"
      assert File.read!(Path.join(tree, "README.md")) == "lazygit\n"
      assert File.read!(Path.join(tree, "lazygit")) =~ "version=0.63.1"
    end

    test "the flat layout through a zip archive installs the exact members" do
      script = "#!/bin/sh\necho '2.39.0'\n"
      bytes = zip_fixture([{"op", script, 0o100755}, {"op.sig", "signature\n", 0o100644}])
      digest = Digest.sha256(bytes)

      spec =
        Download.recipe(%{
          url: "https://example.invalid/artifacts/op/2.39.0/op.zip",
          version: "2.39.0",
          sha256: digest,
          target: ".local/opt/op",
          archive: "zip",
          layout: "flat",
          probe: %{argv: ["op", "--version"], output: "{V}"}
        })

      home = fresh_home()
      assert {:ok, :installed} = Download.install(spec, home, fetch: fn _url -> bytes end)
      assert File.read!(Path.join([home, ".local/opt/op/op.sig"])) == "signature\n"

      # The exec bit rides the zip's external attributes — the probe gate
      # requires it.
      %{mode: mode} = Workstation.Core.EngineState.lstat(Path.join([home, ".local/opt/op/op"]))
      assert Bitwise.band(mode, 0o111) != 0
    end

    test "a tar.xz flat layout proves a data tree through the content probe" do
      ttf = :binary.copy("font-bytes-", 100) <> "regular"
      {bytes, digest} = tar_xz_fixture([{"JetMonoNerdFont-Regular.ttf", ttf}, {"JetMonoNerdFont-Bold.ttf", "bold\n"}])

      spec =
        Download.recipe(%{
          url: "https://example.invalid/artifacts/font/3.5.0/JetBrainsMono.tar.xz",
          version: "3.5.0",
          sha256: digest,
          target: ".local/share/fonts/JetMonoNerdFont",
          archive: "tar.xz",
          layout: "flat",
          probe: %{member: "JetMonoNerdFont-Regular.ttf", sha256: Digest.sha256(ttf)}
        })

      home = fresh_home()
      assert {:ok, :installed} = Download.install(spec, home, fetch: fn _url -> bytes end)
      assert File.read!(Path.join([home, ".local/share/fonts/JetMonoNerdFont/JetMonoNerdFont-Bold.ttf"])) == "bold\n"

      # The applied claim: a download-archive record whose content probe
      # verify re-runs against the actual tree.
      record = %{
        "type" => "download-archive",
        "target" => ".local/share/fonts/JetMonoNerdFont",
        "version" => "3.5.0",
        "probe" => %{"member" => "JetMonoNerdFont-Regular.ttf", "sha256" => Digest.sha256(ttf)}
      }

      assert :ok = Download.verify_record(record, %{"home" => home})

      diverged = put_in(record, ["probe", "sha256"], String.duplicate("0", 64))
      assert_raise ArgumentError, ~r/does not carry the pinned member/, fn ->
        Download.verify_record(diverged, %{"home" => home})
      end
    end

    test "the release layout still demands one root and rejects stray siblings" do
      {bytes, digest} = tree_fixture("unused", extra: [{"go/VERSION", "x\n"}, {"STRAY", "sibling\n"}])

      assert_raise ArgumentError, ~r/exactly one root directory/, fn ->
        Download.install(archive_recipe(sha256: digest), fresh_home(), fetch: fn _url -> bytes end)
      end

      {multi, multi_digest} = single_file_fixture_pair([{"a", "a\n"}, {"b", "b\n"}])

      assert_raise ArgumentError, ~r/exactly one root directory/, fn ->
        Download.install(archive_recipe(sha256: multi_digest), fresh_home(), fetch: fn _url -> multi end)
      end
    end

    test "a zip pin under the release layout fails closed instead of pretending to strip" do
      bytes = zip_fixture([{"tool/tool", "x\n", 0o100755}])

      assert_raise ArgumentError, ~r/no root directory to strip/, fn ->
        Download.install(
          Download.recipe(%{
            url: "https://example.invalid/artifacts/tool/1.0.0/tool.zip",
            version: "1.0.0",
            sha256: Digest.sha256(bytes),
            target: ".local/opt/tool",
            archive: "zip",
            probe: %{argv: ["tool", "--version"], output: "{V}"}
          }),
          fresh_home(),
          fetch: fn _url -> bytes end
        )
      end
    end

    test "recipe validation: layouts, target tables and the content probe" do
      base = %{url: "https://example.invalid/x.tar.gz", version: "1.0.0", sha256: sha_a(), target: ".local/opt/x", archive: "tar.gz", probe: @probe}

      assert_raise ArgumentError, ~r/layout must be one of release, flat/, fn ->
        Download.recipe(Map.put(base, :layout, "rootless"))
      end

      assert_raise ArgumentError, ~r/layout requires an archive pin/, fn ->
        Download.recipe(%{url: "https://example.invalid/x", version: "1.0.0", sha256: sha_a(), target: ".local/bin/x", layout: "flat"})
      end

      assert_raise ArgumentError, ~r/both target and targets/, fn ->
        Download.recipe(%{version: "1.0.0", target: ".local/x", targets: %{"linux_x86_64" => ".local/y"}})
      end

      assert_raise ArgumentError, ~r/unknown platform tag "linux-amd64"/, fn ->
        Download.recipe(%{version: "1.0.0", targets: %{"linux-amd64" => ".local/y"}})
      end

      assert_raise ArgumentError, ~r/download recipe requires target/, fn ->
        Download.recipe(%{version: "1.0.0"})
      end

      assert_raise ArgumentError, ~r/one shape per probe/, fn ->
        Download.recipe(
          Map.merge(base, %{probe: %{argv: ["x", "--version"], output: "{V}", member: "x", sha256: sha_a()}})
        )
      end

      assert_raise ArgumentError, ~r/64 lowercase hex/, fn ->
        Download.recipe(Map.merge(base, %{probe: %{member: "x", sha256: "ZZ"}}))
      end

      assert_raise ArgumentError, ~r/relative member/, fn ->
        Download.recipe(Map.merge(base, %{probe: %{member: "../escape", sha256: sha_a()}}))
      end

      # The content probe validates and carries through the struct.
      spec = Download.recipe(Map.merge(base, %{probe: %{member: "nvm.sh", sha256: sha_a()}, layout: "release"}))
      assert spec.probe == %{member: "nvm.sh", sha256: sha_a()}
      assert spec.layout == "release"
    end
  end

  describe "per-platform targets" do
    test "resolve returns the executing host's declared target" do
      spec =
        Download.recipe(%{
          version: "3.5.0",
          targets: %{"linux_x86_64" => ".local/share/fonts/f", "darwin_arm64" => "Library/Fonts/f"},
          assets: %{
            "linux_x86_64" => %{url: "https://example.invalid/f-linux", sha256: sha_a()},
            "darwin_arm64" => %{url: "https://example.invalid/f-darwin", sha256: sha_b()}
          }
        })

      assert Download.resolve(spec, "linux_x86_64") == %{
               url: "https://example.invalid/f-linux",
               sha256: sha_a(),
               target: ".local/share/fonts/f"
             }

      assert Download.resolve(spec, "darwin_arm64").target == "Library/Fonts/f"
    end

    test "an archive install lands at the resolved platform target" do
      {bytes, digest} = single_file_fixture("tool", "#!/bin/sh\necho '1.0.0'\n")

      spec =
        Download.recipe(%{
          version: "1.0.0",
          url: "https://example.invalid/artifacts/tool/1.0.0/tool.tar.gz",
          sha256: digest,
          targets: %{"linux_x86_64" => ".local/opt/tool-linux", "darwin_arm64" => ".local/opt/tool-darwin"},
          archive: "tar.gz",
          probe: %{argv: ["tool", "--version"], output: "{V}"}
        })

      home = fresh_home()
      assert {:ok, :installed} = Download.install(spec, home, fetch: fn _url -> bytes end)
      assert File.exists?(Path.join([home, ".local/opt/tool-linux/tool"]))
      refute File.exists?(Path.join([home, ".local/opt/tool-darwin"]))
    end

    test "dispatched targets ride the plan effect and the pending anchor verbatim" do
      package = %{
        id: "fonts",
        requires: [],
        contributes: [
          %{
            provider: "download",
            spec:
              Download.recipe(%{
                version: "3.5.0",
                targets: %{"linux_x86_64" => ".local/share/fonts/f", "darwin_arm64" => "Library/Fonts/f"},
                assets: %{
                  "linux_x86_64" => %{url: "https://example.invalid/f", sha256: sha_a()},
                  "darwin_arm64" => %{url: "https://example.invalid/f", sha256: sha_a()}
                },
                archive: "tar.xz",
                layout: "flat",
                probe: %{member: "f.ttf", sha256: sha_a()}
              })
          }
        ]
      }

      plan = plan_for([package])
      assert [pin] = plan.downloads
      assert pin.target == nil
      assert pin.targets == %{"linux_x86_64" => ".local/share/fonts/f", "darwin_arm64" => "Library/Fonts/f"}

      [effect] = Download.plan_effect(plan, %{})
      assert effect.target == nil
      assert effect.targets == pin.targets
      assert effect.archive == "tar.xz" and effect.layout == "flat"
    end

    test "a declared per-platform target overlapping an owned entry is a composition conflict" do
      fonts = %{
        id: "fonts",
        requires: [],
        contributes: [
          %{
            provider: "download",
            spec:
              Download.recipe(%{
                version: "3.5.0",
                targets: %{"linux_x86_64" => ".config/owned", "darwin_arm64" => "Library/Fonts/f"},
                assets: %{
                  "linux_x86_64" => %{url: "https://example.invalid/f", sha256: sha_a()},
                  "darwin_arm64" => %{url: "https://example.invalid/f", sha256: sha_a()}
                },
                archive: "tar.xz",
                probe: %{member: "f.ttf", sha256: sha_a()}
              })
          }
        ]
      }

      owner = %{
        id: "owner",
        requires: [],
        contributes: [
          %{provider: "chezmoi", spec: Chezmoi.recipe(%{target: ".config/owned/keep", kind: :file, content: "x"})}
        ]
      }

      assert_raise ArgumentError, ~r/overlaps owned target/, fn -> plan_for([fonts, owner]) end
    end

    test "the recorded envelope round-trips layout, targets and the content probe" do
      recorded = %{
        "version" => "3.5.0",
        "targets" => %{"linux_x86_64" => ".local/share/fonts/f", "darwin_arm64" => "Library/Fonts/f"},
        "assets" => %{
          "linux_x86_64" => %{"url" => "https://example.invalid/f", "sha256" => sha_a()},
          "darwin_arm64" => %{"url" => "https://example.invalid/f", "sha256" => sha_a()}
        },
        "archive" => "tar.xz",
        "layout" => "flat",
        "probe" => %{"member" => "f.ttf", "sha256" => sha_a()}
      }

      spec = Download.from_recorded(recorded)
      assert spec.targets == %{"linux_x86_64" => ".local/share/fonts/f", "darwin_arm64" => "Library/Fonts/f"}
      assert spec.layout == "flat"
      assert spec.probe == %{member: "f.ttf", sha256: sha_a()}
      :ok = Download.validate(spec)

      # The descriptor stays machine-independent and drops nil fields.
      descriptor = Jason.decode!(Download.pin_bytes(spec))
      assert descriptor["targets"] == recorded["targets"]
      assert descriptor["layout"] == "flat"
      refute Map.has_key?(descriptor, "target")
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

  # The archive form's fixture pin; the sha256 must pin exactly the bytes
  # the injected fetch returns, so tests build the recipe from the fixture's
  # own digest.
  defp archive_recipe(overrides \\ []) do
    Download.recipe(%{
      url: "https://example.invalid/artifacts/go/1.27.1/go.tar.gz",
      version: Keyword.get(overrides, :version, "1.27.1"),
      sha256: Keyword.get(overrides, :sha256, sha_a()),
      target: Keyword.get(overrides, :target, ".local/opt/go"),
      archive: "tar.gz",
      probe: Keyword.get(overrides, :probe, @probe)
    })
  end

  # A tar.gz carrying ONE top-level file: the single-binary release shape
  # (fzf, rainfrog). Deterministic in-memory ustar bytes, like tree_fixture.
  defp single_file_fixture(name, body), do: single_file_fixture_pair([{name, body}])

  defp single_file_fixture_pair(entries) do
    bytes =
      entries
      |> Enum.map(fn {name, body} -> ustar(name, body) end)
      |> IO.iodata_to_binary()
      |> :zlib.gzip()

    {bytes, Digest.sha256(bytes)}
  end

  # A tar.gz whose members live at the top level with no owning root: the
  # bare-release shape (lazygit, op).
  defp flat_tar_fixture(entries), do: single_file_fixture_pair(entries)

  # The same ustar stream compressed as tar.xz (the font shape) — xz is one
  # of the apply-time extraction tools this layout's pins require, so the
  # fixture rides the same host tool the apply path uses.
  defp tar_xz_fixture(entries) do
    ustar_stream =
      entries
      |> Enum.map(fn {name, body} -> ustar(name, body) end)
      |> IO.iodata_to_binary()

    dir = unique_home("workstation-fixture")
    File.mkdir_p!(dir)
    tar_path = Path.join(dir, "fixture.tar")
    xz_path = tar_path <> ".xz"

    File.write!(tar_path, ustar_stream)
    {_, 0} = System.cmd("xz", ["-z", "-0", "-f", tar_path], stderr_to_stdout: true)
    bytes = File.read!(xz_path)
    File.rm_rf!(dir)
    {bytes, Digest.sha256(bytes)}
  end

  # A minimal STORED (method 0) zip archive, built in memory: local file
  # headers, central directory, end-of-central-directory. The external
  # attributes carry the unix mode so Info-ZIP unzip restores the exec bit
  # exactly like the real release archives do.
  defp zip_fixture(entries) do
    dos_time = 0
    dos_date = (2026 - 1980) <<< 9 ||| 1 <<< 5 ||| 1

    {_mapped, {locals_rev, centrals_rev, _end_offset}} =
      Enum.map_reduce(entries, {[], [], 0}, fn {name, body, mode}, {locals, centrals, offset} ->
        crc = :erlang.crc32(body)
        name_bytes = IO.iodata_to_binary(name)

        local = [
          <<0x04034B50::little-32, 20::little-16, 0::little-16, 0::little-16, dos_time::little-16,
            dos_date::little-16, crc::little-32, byte_size(body)::little-32, byte_size(body)::little-32,
            byte_size(name_bytes)::little-16, 0::little-16, name_bytes::binary, body::binary>>
        ]

        central = [
          <<0x02014B50::little-32, (3 <<< 8 ||| 20)::little-16, 20::little-16, 0::little-16, 0::little-16,
            dos_time::little-16, dos_date::little-16, crc::little-32, byte_size(body)::little-32,
            byte_size(body)::little-32, byte_size(name_bytes)::little-16, 0::little-16, 0::little-16,
            0::little-16, 0::little-16, mode <<< 16::little-32, offset::little-32, name_bytes::binary>>
          | centrals
        ]

        {local, {[local | locals], central, offset + IO.iodata_length(local)}}
      end)

    local_bytes = locals_rev |> Enum.reverse() |> IO.iodata_to_binary()
    central_bytes = centrals_rev |> Enum.reverse() |> IO.iodata_to_binary()
    count = length(entries)

    eocd = <<
      0x06054B50::little-32, 0::little-16, 0::little-16, count::little-16, count::little-16,
      byte_size(central_bytes)::little-32, byte_size(local_bytes)::little-32, 0::little-16
    >>

    IO.iodata_to_binary([local_bytes, central_bytes, eocd])
  end

  # A tar.gz whose extraction yields an exact tree: `go/VERSION`, and
  # `go/bin/go` a probe script printing the given banner. Archives are built
  # as DETERMINISTIC IN-MEMORY ustar bytes (fixed headers, the same
  # construction the bootstrap fixtures use), so the digest under test is
  # the digest of the bytes the fetch returns — never a re-read of a
  # just-tarred file.
  defp tree_fixture(banner, opts \\ []) do
    base = [
      {"go/VERSION", "go-1.27.1\n"},
      {"go/bin/go", "#!/bin/sh\necho '#{banner}'\n"}
    ]

    entries = base ++ List.wrap(Keyword.get(opts, :extra))

    bytes =
      entries
      |> Enum.map(fn {name, body} -> ustar(name, body) end)
      |> IO.iodata_to_binary()
      |> :zlib.gzip()

    {bytes, Digest.sha256(bytes)}
  end

  # One ustar member: 512-byte header (mode 0755) + body padded to 512.
  defp ustar(name, body) do
    if byte_size(name) > 100, do: raise(ArgumentError, "fixture member name too long")
    size = byte_size(body)

    head =
      pad(name, 100) <>
        "0000755\u0000" <>
        "0000000\u0000" <>
        "0000000\u0000" <>
        (IO.iodata_to_binary(Integer.to_string(size, 8) |> String.pad_leading(11, "0")) <> "\u0000") <>
        "00000000000\u0000"

    tail =
      "0" <>
        :binary.copy(<<0>>, 100) <>
        "ustar\u0000" <>
        "00" <>
        :binary.copy(<<0>>, 32) <>
        :binary.copy(<<0>>, 32) <>
        :binary.copy(<<0>>, 8) <>
        :binary.copy(<<0>>, 8) <>
        :binary.copy(<<0>>, 155) <>
        :binary.copy(<<0>>, 12)

    header = ustar_header(head, tail)
    padded = body <> :binary.copy(<<0>>, 512 - rem(byte_size(body), 512))
    header <> padded
  end

  # The python3 -> python3.14 shape: a symlink probe member. Typeflag 2, the
  # target in the linkname field, zero size.
  defp ustar_symlink(name, linkname) do
    if byte_size(name) > 100 or byte_size(linkname) > 100,
      do: raise(ArgumentError, "fixture member name too long")

    head =
      pad(name, 100) <>
        "0000777\u0000" <>
        "0000000\u0000" <>
        "0000000\u0000" <>
        "00000000000\u0000" <>
        "00000000000\u0000"

    tail =
      "2" <>
        pad(linkname, 100) <>
        "ustar\u0000" <>
        "00" <>
        :binary.copy(<<0>>, 32) <>
        :binary.copy(<<0>>, 32) <>
        :binary.copy(<<0>>, 8) <>
        :binary.copy(<<0>>, 8) <>
        :binary.copy(<<0>>, 155) <>
        :binary.copy(<<0>>, 12)

    ustar_header(head, tail)
  end

  defp ustar_header(head, tail) do
    # The checksum is the byte sum of the header with the checksum field
    # itself filled with eight spaces (the POSIX ustar rule).
    checksum =
      (head <> "        " <> tail)
      |> :binary.bin_to_list()
      |> Enum.sum()

    head <> IO.iodata_to_binary(Integer.to_string(checksum, 8) |> String.pad_leading(6, "0")) <> "\u0000 " <> tail
  end

  # The release layout with the probe member a SYMLINK to a real script —
  # the python-build-standalone install_only layout (bin/python3 ->
  # python3.14) that broke the exec probe on symlink-blind lstat.
  defp symlink_tree_fixture(banner) do
    entries = [
      ustar("go/VERSION", "go-1.27.1\n"),
      ustar("go/bin/go.real", "#!/bin/sh\necho '#{banner}'\n"),
      ustar_symlink("go/bin/go", "go.real")
    ]

    bytes =
      entries
      |> IO.iodata_to_binary()
      |> :zlib.gzip()

    {bytes, Digest.sha256(bytes)}
  end

  defp pad(string, width), do: string <> :binary.copy(<<0>>, width - byte_size(string))

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
    home = unique_home("workstation-download-unit")
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
    root_pem = unique_home("workstation-test-root") <> ".pem"

    File.write!(root_pem, :public_key.pem_encode([{:Certificate, root_der, :not_encrypted}]))
    :ok = :public_key.cacerts_load(root_pem)

    server = spawn_link(fn -> accept_loop(listen, port, mode, payload) end)

    on_exit(fn ->
      Process.exit(server, :kill)
      File.rm(root_pem)
    end)

    %{port: port, cacerts: [root_der]}
  end

  defp accept_loop(listen, port, mode, payload, backoff \\ 0) do
    case :ssl.transport_accept(listen) do
      {:ok, sock} ->
        # One handler per connection: a hop's handshake must never queue
        # behind the previous hop's close.
        spawn(fn -> serve_connection(sock, port, mode, payload) end)
        accept_loop(listen, port, mode, payload)

      {:error, reason} when reason in [:emfile, :enfile, :temporarily_unavailable] and backoff < 50 ->
        # Under a loaded test VM the listener can transiently refuse an
        # accept (fd pressure from the parallel suite). Dying here would
        # close every later hop and turn a load spike into a flake; re-arm
        # with a bounded backoff instead.
        Process.sleep(5)
        accept_loop(listen, port, mode, payload, backoff + 5)

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
