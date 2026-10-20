defmodule Workstation.Core.Update.BootstrapTest do
  @moduledoc """
  The bootstrap step against offline fixtures: a pre-seeded runtime cache
  (the shell's cache-hit path) and `file://` backend downloads behind the
  fixture-only `allow_file_urls` opt — every integrity check the bootstrap
  contract enforces, exercised without any external network.

  Not covered offline (documented residual): the https runtime download
  itself, whose URL validation pins it to the real GitHub release path; the
  corrupt-cache refusal is pinned through the same discard-and-refetch code
  via the corrupt RUNTIME cache entry (the honest https failure follows).

  The EXDEV fallback (a filesystem that cannot rename the installed tree —
  an overlayfs lower layer, e.g. a docker-committed container) is exercised
  by stubbing the activation renames through the fixture-only `rename` opt:
  the fallback must land the install, and a failed activation must roll the
  COPIED tree back with its modes and links intact.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.Update.Bootstrap

  @fixture_version "0.0.0"
  @nvim_banner "NVIM v#{@fixture_version}"

  setup do
    base = Path.join(System.tmp_dir!(), "c2-bootstrap-#{System.unique_integer([:positive])}")
    home = Path.join(base, "home")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous,
        do: System.put_env("WORKSTATION_HOME", previous),
        else: System.delete_env("WORKSTATION_HOME")

      File.rm_rf!(base)
    end)

    %{base: base, home: home}
  end

  ## pins! derivation matrix (pure versions.json derivation)

  test "pins! derives the platform pin from versions.json", %{base: base} do
    %{root: root} = engine_fixture(base)

    pin = Bootstrap.pins!(root, Bootstrap.platform())
    assert pin["version"] == @fixture_version
    assert pin["url"] == github_url(Bootstrap.platform())
    assert byte_size(pin["digest"]) == 64 and Regex.match?(~r/\A[0-9a-f]+\z/, pin["digest"])

    # The derivation yields exactly the two supported platforms.
    both = Bootstrap.pins!(root)
    assert MapSet.new(Map.keys(both)) == MapSet.new(["linux_x86_64", "darwin_arm64"])
    assert both["linux_x86_64"]["asset"] == "linux_x86_64"
    assert both["darwin_arm64"]["asset"] == "darwin_arm64"
    assert both["darwin_arm64"]["version"] == @fixture_version
  end

  test "pins! refuses derivations that fail any record validation", %{base: base} do
    good_digest = String.duplicate("ab", 32)
    good_url = github_url("linux_x86_64")

    cases = [
      # version outside digits/dots
      {"invalid runtime version", %{"neovim" => "0..0-alpha"}},
      # half-bumped source: the URL template is still pinned to the OLD
      # version — the exact rot the derivation refuses at run time
      {"invalid runtime URL", %{"neovim" => "0.0.1"}},
      # URL outside the pinned release path
      {"invalid runtime URL",
       %{"neovim_linux_x86_64_url" => "https://evil.example/nvim-1.0.tar.gz"}},
      # digest not 64 lowercase hex / short digest
      {"invalid manifest record", %{"neovim_linux_x86_64_sha256" => "NOTAHASH"}},
      {"invalid manifest record", %{"neovim_linux_x86_64_sha256" => String.duplicate("ab", 31)}},
      # a missing pin field / a non-string pin field
      {"missing or invalid neovim pin field", %{"neovim_darwin_arm64_url" => :drop}},
      {"missing or invalid neovim pin field", %{"neovim" => 5}},
      # an extra platform the derivation does not consume
      {"unexpected neovim pin field", %{"neovim_windows_x86_64_url" => good_url}},
      {"unexpected neovim pin field", %{"neovim_windows_x86_64_sha256" => good_digest}}
    ]

    for {expected, overrides} <- cases do
      root = pin_versions_fixture(base, overrides)

      assert_raise ArgumentError, ~r/#{expected}/, fn ->
        Bootstrap.pins!(root, "linux_x86_64")
      end
    end
  end

  ## full run (offline: runtime cache pre-seeded, backend over file://)

  test "run installs runtime, backend and launcher from verified artifacts", %{
    base: base,
    home: home
  } do
    fixture = engine_fixture(base)
    seed_runtime_cache!(home, fixture)

    result = Bootstrap.run(engine_root: fixture.root, home: home, allow_file_urls: true)

    assert {:ok,
            %{
              "step" => "bootstrap",
              "status" => "ok",
              "runtime" => @fixture_version,
              "chezmoi" => "1.2.3"
            }} = result

    # Runtime: installed, executable, and the version check ran the STAGED
    # binary (the banner only passes if the extracted tree is what ran).
    nvim = Path.join([home, ".local", "opt", "nvim", "bin", "nvim"])
    assert {banner, 0} = System.cmd(nvim, [])
    assert String.trim_trailing(banner) == @nvim_banner
    assert Bitwise.band(File.stat!(nvim).mode, 0o111) != 0

    # Backend: the pinned inner file, mode 0755, at the argv contract path.
    chezmoi = Path.join([home, ".local", "opt", "chezmoi", "bin", "chezmoi"])
    assert File.read!(chezmoi) == "#!/bin/sh\necho chezmoi-fixture\n"
    assert Bitwise.band(File.stat!(chezmoi).mode, 0o755) == 0o755

    # Launcher: the canonical symlink to the engine checkout's launcher.
    {:ok, link} = File.read_link(Path.join([home, ".local", "bin", "workstation"]))
    assert link == Workstation.Core.Update.realpath(Path.join(fixture.root, "bin/workstation"))

    # Caches: both artifacts cached under their own digest.
    assert File.regular?(
             Path.join([home, ".cache", "workstation", "bootstrap", fixture.runtime_digest])
           )

    assert [_one] = File.ls!(Path.join([home, ".cache", "workstation", "downloads"]))

    # No lock or staging debris survives a successful run.
    refute File.exists?(Path.join([home, ".local", "opt", ".nvim-bootstrap-lock"]))

    # Idempotent: a second run over installed state succeeds.
    assert {:ok, %{"status" => "ok"}} =
             Bootstrap.run(engine_root: fixture.root, home: home, allow_file_urls: true)
  end

  test "a corrupt runtime cache entry is discarded, never trusted", %{base: base, home: home} do
    fixture = engine_fixture(base)
    seed_runtime_cache!(home, fixture)

    File.write!(
      Path.join([home, ".cache", "workstation", "bootstrap", fixture.runtime_digest]),
      "corrupt bytes"
    )

    # The https-only runtime download cannot run in this sandbox; what this
    # pins is the DISCARD: the corrupt entry is gone before the honest
    # download failure follows (no fixture can serve that URL).
    assert_raise ArgumentError, ~r/runtime download failed/, fn ->
      Bootstrap.run(engine_root: fixture.root, home: home)
    end

    refute File.exists?(
             Path.join([home, ".cache", "workstation", "bootstrap", fixture.runtime_digest])
           )

    assert File.regular?(fixture.runtime_archive)
  end

  test "a backend download whose bytes do not hash to the pin is refused", %{
    base: base,
    home: home
  } do
    fixture = engine_fixture(base)
    seed_runtime_cache!(home, fixture)
    File.write!(fixture.chezmoi_archive, "not the pinned bytes")

    assert_raise ArgumentError, ~r/provision checksum mismatch/, fn ->
      Bootstrap.run(engine_root: fixture.root, home: home, allow_file_urls: true)
    end

    refute File.exists?(Path.join([home, ".local", "opt", "chezmoi", "bin", "chezmoi"]))
  end

  test "a runtime archive with a traversing member is refused before extraction", %{
    base: base,
    home: home
  } do
    fixture = engine_fixture(base, runtime_archive: tar_fixture!([{"../evil.txt", "evil\n"}]))
    seed_runtime_cache!(home, fixture)

    assert_raise ArgumentError, ~r/unsafe archive member/, fn ->
      Bootstrap.run(engine_root: fixture.root, home: home)
    end

    refute File.exists?(Path.join([home, ".local", "opt", "nvim"]))
  end

  test "a runtime tree without bin/nvim, or with a wrong version banner, is refused", %{
    base: base,
    home: home
  } do
    # no bin/nvim at all
    fixture =
      engine_fixture(base, runtime_archive: tar_fixture!([{"fixture/README", "nothing here\n"}]))

    seed_runtime_cache!(home, fixture)

    assert_raise ArgumentError, ~r/lacks executable bin\/nvim/, fn ->
      Bootstrap.run(engine_root: fixture.root, home: home)
    end

    # bin/nvim that reports the wrong version
    fixture =
      engine_fixture(base,
        runtime_archive: tar_fixture!([{"fixture/bin/nvim", "#!/bin/sh\necho 'NVIM v9.9.9'\n"}])
      )

    seed_runtime_cache!(home, fixture)

    assert_raise ArgumentError, ~r/runtime version mismatch/, fn ->
      Bootstrap.run(engine_root: fixture.root, home: home)
    end
  end

  test "a legacy owner-less lock is never stolen (operator recovery)", %{base: base, home: home} do
    fixture = engine_fixture(base)
    seed_runtime_cache!(home, fixture)
    lock = Path.join([home, ".local", "opt", ".nvim-bootstrap-lock"])
    File.mkdir_p!(lock)

    assert_raise ArgumentError, ~r/runtime installer locked/, fn ->
      Bootstrap.run(engine_root: fixture.root, home: home, lock_retries: 1, lock_wait_ms: 1)
    end

    # The held lock is intact — recovery is the operator inspecting it.
    assert File.dir?(lock)
  end

  test "a lock held by a live owner is never stolen", %{base: base, home: home} do
    fixture = engine_fixture(base)
    seed_runtime_cache!(home, fixture)
    lock = Path.join([home, ".local", "opt", ".nvim-bootstrap-lock"])
    File.mkdir_p!(lock)
    {:ok, hostname} = :inet.gethostname()

    File.write!(
      Path.join(lock, "owner"),
      "#{hostname}|#{:os.getpid()}|#{System.system_time(:millisecond)}"
    )

    assert_raise ArgumentError, ~r/runtime installer locked/, fn ->
      Bootstrap.run(engine_root: fixture.root, home: home, lock_retries: 1, lock_wait_ms: 1)
    end

    assert File.dir?(lock)
  end

  test "a foreign-host lock is never stolen", %{base: base, home: home} do
    fixture = engine_fixture(base)
    seed_runtime_cache!(home, fixture)
    lock = Path.join([home, ".local", "opt", ".nvim-bootstrap-lock"])
    File.mkdir_p!(lock)
    File.write!(Path.join(lock, "owner"), "some-other-host|1|#{System.system_time(:millisecond)}")

    assert_raise ArgumentError, ~r/runtime installer locked/, fn ->
      Bootstrap.run(engine_root: fixture.root, home: home, lock_retries: 1, lock_wait_ms: 1)
    end

    assert File.dir?(lock)
  end

  test "a stale-owned lock is debris: stolen once, the install proceeds", %{
    base: base,
    home: home
  } do
    fixture = engine_fixture(base)
    seed_runtime_cache!(home, fixture)
    lock = Path.join([home, ".local", "opt", ".nvim-bootstrap-lock"])
    File.mkdir_p!(lock)

    # A pid that is guaranteed dead and reaped: the shell printed its own
    # pid and exited before System.cmd returned.
    {out, 0} = System.cmd("sh", ["-c", "echo $$"], stderr_to_stdout: true)
    dead_pid = String.trim(out)
    {:ok, hostname} = :inet.gethostname()

    File.write!(
      Path.join(lock, "owner"),
      "#{hostname}|#{dead_pid}|#{System.system_time(:millisecond)}"
    )

    assert {:ok, %{"status" => "ok"}} =
             Bootstrap.run(engine_root: fixture.root, home: home, allow_file_urls: true)

    # The steal left no debris: the renamed lock is gone, the fresh one was
    # cleaned up by the successful install.
    refute File.exists?(lock)
    assert Path.wildcard(Path.join([home, ".local", "opt", ".nvim-bootstrap-lock.stale-*"])) == []
  end

  ## distro prerequisite precheck (docs/tools.md, probed before provisioning)

  test "a host missing two tools refuses once, naming both and the install command, provisioning nothing",
       %{base: base, home: home} do
    fixture = engine_fixture(base)
    seed_runtime_cache!(home, fixture)

    stub = fn
      "xz" -> nil
      "unzip" -> nil
      other -> System.find_executable(other)
    end

    error =
      assert_raise ArgumentError, fn ->
        Bootstrap.run(
          engine_root: fixture.root,
          home: home,
          allow_file_urls: true,
          find_executable: stub
        )
      end

    message = Exception.message(error)
    assert message =~ ~r/host tool\(s\) `xz`, `unzip`/
    assert message =~ "apt install git curl xz-utils unzip"

    # The refusal came BEFORE any provisioning: no runtime tree, no backend,
    # no launcher, no lock debris — the lifecycle cycle is not wasted.
    refute File.exists?(Path.join([home, ".local", "opt", "nvim"]))
    refute File.exists?(Path.join([home, ".local", "opt", "chezmoi"]))
    refute File.exists?(Path.join([home, ".local", "bin", "workstation"]))
    refute File.exists?(Path.join([home, ".local", "opt", ".nvim-bootstrap-lock"]))
  end

  test "a single missing tool is named alone; the recorded install command stays the whole set",
       %{base: base, home: home} do
    fixture = engine_fixture(base)
    seed_runtime_cache!(home, fixture)

    stub = fn
      "xz" -> nil
      other -> System.find_executable(other)
    end

    error =
      assert_raise ArgumentError, fn ->
        Bootstrap.run(engine_root: fixture.root, home: home, find_executable: stub)
      end

    message = Exception.message(error)
    assert message =~ "`xz`"
    refute message =~ "`unzip`"
    assert message =~ "apt install git curl xz-utils unzip"
  end

  test "the doc resolves through the repository layout (payload root, doc one level up)",
       %{base: base, home: home} do
    fixture = engine_fixture(base, docs: :parent)
    seed_runtime_cache!(home, fixture)

    assert {:ok, %{"status" => "ok"}} =
             Bootstrap.run(engine_root: fixture.root, home: home, allow_file_urls: true)
  end

  test "a checkout without docs/tools.md anywhere refuses before provisioning",
       %{base: base, home: home} do
    fixture = engine_fixture(base, docs: :none)

    assert_raise ArgumentError, ~r/no docs\/tools\.md beside the engine checkout/, fn ->
      Bootstrap.run(engine_root: fixture.root, home: home)
    end

    refute File.exists?(Path.join([home, ".local", "opt", "nvim"]))
  end

  test "a malformed prereqs doc refuses the bootstrap with the specific defect",
       %{base: base, home: home} do
    cases = [
      {"no workstation-distro-prereqs block", "Only prose here, never a block.\n"},
      {"exactly one is required",
       "```workstation-distro-prereqs\ngit:git\n```\n\n```workstation-distro-prereqs\ncurl:curl\n```\n"},
      {"malformed workstation-distro-prereqs entry in docs/tools.md: git git",
       "```workstation-distro-prereqs\ngit git\n```\n"},
      {"the workstation-distro-prereqs block in docs/tools.md is empty",
       "```workstation-distro-prereqs\n# only a comment\n```\n"},
      {"duplicate distro prerequisite package: git",
       "```workstation-distro-prereqs\ngit:git\ngit:git\n```\n"},
      {"duplicate distro prerequisite binary: git",
       "```workstation-distro-prereqs\ngit:git\ngit2:git\n```\n"},
      {"unterminated workstation-distro-prereqs block",
       "```workstation-distro-prereqs\ngit:git\n"}
    ]

    for {expected, doc} <- cases do
      fixture = engine_fixture(base)
      File.write!(Path.join(fixture.root, "docs/tools.md"), doc)

      error =
        assert_raise ArgumentError, ~r/#{Regex.escape(expected)}/, fn ->
          Bootstrap.run(engine_root: fixture.root, home: home)
        end

      assert Exception.message(error) =~ "bootstrap:"
    end
  end

  ## the EXDEV fallback (stubbed activation renames)

  test "an EXDEV move-aside falls back to a copy and the install still proceeds", %{
    base: base,
    home: home
  } do
    fixture = engine_fixture(base)
    seed_runtime_cache!(home, fixture)

    # The first run installs the tree the second run must replace; the
    # second run's move-aside of that tree is what a lower-layer filesystem
    # (docker-committed container) answers with EXDEV.
    assert {:ok, %{"status" => "ok"}} =
             Bootstrap.run(engine_root: fixture.root, home: home, allow_file_urls: true)

    installed = installed_path(home)
    backup = backup_path(home)

    stub = fn
      ^installed, ^backup -> {:error, :exdev}
      source, destination -> File.rename(source, destination)
    end

    assert {:ok, %{"status" => "ok", "runtime" => @fixture_version}} =
             Bootstrap.run(
               engine_root: fixture.root,
               home: home,
               allow_file_urls: true,
               rename: stub
             )

    # The replacement is live and runnable, and the fallback left no lock
    # or staging debris anywhere under opt.
    assert {banner, 0} = System.cmd(Path.join([installed, "bin", "nvim"]), [])
    assert String.trim_trailing(banner) == @nvim_banner
    assert Path.wildcard(Path.join(opt_dir(home), ".nvim-bootstrap-lock*")) == []
  end

  test "the EXDEV fallback keeps the lock discipline: a failed activation rolls the copied tree back",
       %{
         base: base,
         home: home
       } do
    fixture = engine_fixture(base)
    seed_runtime_cache!(home, fixture)

    assert {:ok, %{"status" => "ok"}} =
             Bootstrap.run(engine_root: fixture.root, home: home, allow_file_urls: true)

    # Age the installed tree with state the fixture archive does not carry:
    # a marker, a relative symlink and a private mode. If the fallback
    # re-extracted the archive instead of copying THIS tree, every assert
    # below would fail (755, no marker, no link).
    installed = installed_path(home)
    backup = backup_path(home)
    stage = stage_path(home)
    File.mkdir_p!(Path.join(installed, "share"))
    File.write!(Path.join([installed, "share", "old-marker"]), "previous tree\n")
    File.ln_s!("nvim", Path.join([installed, "bin", "nvim-link"]))
    File.chmod!(Path.join([installed, "bin", "nvim"]), 0o700)

    stub = fn
      ^installed, ^backup -> {:error, :exdev}
      ^stage, ^installed -> {:error, :eio}
      source, destination -> File.rename(source, destination)
    end

    assert_raise File.RenameError, ~r/could not rename/, fn ->
      Bootstrap.run(engine_root: fixture.root, home: home, allow_file_urls: true, rename: stub)
    end

    # The ORIGINAL tree is back in place — the copy captured it faithfully:
    # marker bytes, the relative link and the private mode all survived.
    assert File.read!(Path.join([installed, "share", "old-marker"])) == "previous tree\n"
    assert {:ok, "nvim"} = File.read_link(Path.join([installed, "bin", "nvim-link"]))
    assert Bitwise.band(File.stat!(Path.join([installed, "bin", "nvim"])).mode, 0o777) == 0o700
    assert {banner, 0} = System.cmd(Path.join([installed, "bin", "nvim"]), [])
    assert String.trim_trailing(banner) == @nvim_banner

    # Lock discipline held: the lock — with its staging sibling inside — is
    # gone, so a crash mid-copy could never have published a half-populated
    # `previous`.
    assert Path.wildcard(Path.join(opt_dir(home), ".nvim-bootstrap-lock*")) == []
  end

  test "a non-EXDEV move-aside refusal keeps the rename error and the installed tree", %{
    base: base,
    home: home
  } do
    fixture = engine_fixture(base)
    seed_runtime_cache!(home, fixture)

    assert {:ok, %{"status" => "ok"}} =
             Bootstrap.run(engine_root: fixture.root, home: home, allow_file_urls: true)

    installed = installed_path(home)
    backup = backup_path(home)

    stub = fn
      ^installed, ^backup -> {:error, :eperm}
      source, destination -> File.rename(source, destination)
    end

    assert_raise File.RenameError,
                 ~r/could not rename from .*opt\/nvim.* to .*previous.*: not owner/,
                 fn ->
                   Bootstrap.run(
                     engine_root: fixture.root,
                     home: home,
                     allow_file_urls: true,
                     rename: stub
                   )
                 end

    # Untouched: the installed tree is exactly what the first run laid
    # down, and no fallback copy ever started.
    assert File.read!(Path.join([installed, "bin", "nvim"])) ==
             "#!/bin/sh\necho 'NVIM v#{@fixture_version}'\n"

    assert Path.wildcard(Path.join(opt_dir(home), "*"))
           |> Enum.map(&Path.basename/1)
           |> Enum.sort() == ["chezmoi", "nvim"]
  end

  test "a conflicting launcher path is refused, never replaced", %{base: base, home: home} do
    fixture = engine_fixture(base)
    seed_runtime_cache!(home, fixture)
    launcher = Path.join([home, ".local", "bin", "workstation"])
    File.mkdir_p!(Path.dirname(launcher))
    File.write!(launcher, "someone else's launcher\n")

    assert_raise ArgumentError, ~r/refusing conflicting launcher/, fn ->
      Bootstrap.run(engine_root: fixture.root, home: home, allow_file_urls: true)
    end

    assert File.read!(launcher) == "someone else's launcher\n"
  end

  ## fixtures

  # An engine checkout fixture: payload markers and a versions.json carrying
  # BOTH the derived runtime pins (https/github-shaped URLs, never fetched —
  # the cache is seeded) and the backend file:// fixture record. The
  # distro-prerequisite doc ships beside the payload like the real layouts
  # do: `docs: :root` (self-contained checkout, the default), `docs: :parent`
  # (the repository layout — the doc one level above the payload root) or
  # `docs: :none` (a stripped payload with no doc anywhere).
  defp engine_fixture(base, opts \\ []) do
    root = Path.join(base, "engine")
    fixture_dir = Path.join(base, "fixtures")
    File.mkdir_p!(Path.join(root, "bin"))
    File.mkdir_p!(fixture_dir)

    case Keyword.get(opts, :docs, :root) do
      :root ->
        File.mkdir_p!(Path.join(root, "docs"))
        File.write!(Path.join(root, "docs/tools.md"), distro_doc())

      :parent ->
        File.mkdir_p!(Path.join(base, "docs"))
        File.write!(Path.join(base, "docs/tools.md"), distro_doc())

      :none ->
        :ok
    end

    File.write!(Path.join(root, "bin/workstation"), "#!/bin/sh\necho launcher-fixture\n")
    File.chmod!(Path.join(root, "bin/workstation"), 0o755)

    %{archive: runtime_archive, digest: runtime_digest} =
      Keyword.get_lazy(opts, :runtime_archive, fn -> runtime_fixture_archive!(base) end)

    %{archive: chezmoi_archive, digest: chezmoi_digest} = chezmoi_fixture_archive!(fixture_dir)

    versions =
      Jason.encode!(%{
        "neovim" => @fixture_version,
        "neovim_linux_x86_64_url" => github_url("linux_x86_64"),
        "neovim_linux_x86_64_sha256" => runtime_digest,
        "neovim_darwin_arm64_url" => github_url("darwin_arm64"),
        "neovim_darwin_arm64_sha256" => runtime_digest,
        "chezmoi" => "1.2.3",
        "chezmoi_linux_x86_64_url" => "file://#{chezmoi_archive}",
        "chezmoi_linux_x86_64_sha256" => chezmoi_digest,
        "chezmoi_darwin_arm64_url" => "file://#{chezmoi_archive}",
        "chezmoi_darwin_arm64_sha256" => chezmoi_digest
      })

    File.write!(Path.join(root, "versions.json"), versions)

    %{
      root: root,
      runtime_archive: runtime_archive,
      runtime_digest: runtime_digest,
      chezmoi_archive: chezmoi_archive
    }
  end

  # The canonical docs/tools.md prereqs block (the source the engine
  # parses); the malformed-doc cases rewrite this file in place.
  defp distro_doc do
    """
    Tool inventory prose.

    ```workstation-distro-prereqs
    # <distro package>:<binary probed on PATH>
    git:git
    curl:curl
    xz-utils:xz
    unzip:unzip
    ```

    More prose.
    """
  end

  # A minimal versions.json fixture for the derivation-refusal matrix: the
  # valid base record set with per-case overrides (:drop removes a field).
  defp pin_versions_fixture(base, overrides) do
    root = Path.join(base, "pins-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    versions =
      Map.merge(
        %{
          "neovim" => @fixture_version,
          "neovim_linux_x86_64_url" => github_url("linux_x86_64"),
          "neovim_linux_x86_64_sha256" => String.duplicate("ab", 32),
          "neovim_darwin_arm64_url" => github_url("darwin_arm64"),
          "neovim_darwin_arm64_sha256" => String.duplicate("cd", 32)
        },
        overrides
      )
      |> Map.reject(fn {_key, value} -> value == :drop end)

    File.write!(Path.join(root, "versions.json"), Jason.encode!(versions))
    root
  end

  defp github_url(asset),
    do:
      "https://github.com/neovim/neovim/releases/download/v#{@fixture_version}/nvim-#{asset}.tar.gz"

  # A tar.gz whose extraction yields bin/nvim printing the fixture banner.
  defp runtime_fixture_archive!(base),
    do: tar_fixture!([{"fixture/bin/nvim", "#!/bin/sh\necho '#{@nvim_banner}'\n"}], base: base)

  defp chezmoi_fixture_archive!(dir),
    do: tar_fixture!([{"chezmoi", "#!/bin/sh\necho chezmoi-fixture\n"}], dir: dir)

  # Seed the runtime cache so the https download path never runs in tests.
  defp seed_runtime_cache!(home, fixture) do
    cache = Path.join([home, ".cache", "workstation", "bootstrap"])
    File.mkdir_p!(cache)
    File.cp!(fixture.runtime_archive, Path.join(cache, fixture.runtime_digest))
    :ok
  end

  # The bootstrap's lock/replace layout under `<home>/.local/opt` — the
  # paths the EXDEV stubs pattern-match on.
  defp opt_dir(home), do: Path.join([home, ".local", "opt"])
  defp installed_path(home), do: Path.join(opt_dir(home), "nvim")
  defp lock_path(home), do: Path.join(opt_dir(home), ".nvim-bootstrap-lock")
  defp stage_path(home), do: Path.join(lock_path(home), "stage")
  defp backup_path(home), do: Path.join(lock_path(home), "previous")

  # Archives are built as DETERMINISTIC IN-MEMORY bytes (fixed ustar
  # headers, mtime 0) and written once, then hashed from the same bytes the
  # writer used. This is deliberate: under ExUnit's rapid create/delete
  # cycles this sandbox's /tmp has served stale page-cache bytes for a
  # just-tarred file, so any "create with tar, then read back and hash"
  # fixture can disagree with itself; in-memory bytes cannot.
  defp tar_fixture!(entries, opts \\ []) do
    bytes = entries |> Enum.map(fn {name, body} -> ustar(name, body) end) |> IO.iodata_to_binary()
    archive = :zlib.gzip(bytes)

    dir = Keyword.get(opts, :dir) || Keyword.get(opts, :base) || System.tmp_dir!()

    unless is_binary(dir), do: raise(ArgumentError, "tar fixture needs a directory")

    File.mkdir_p!(dir)
    path = Path.join(dir, "fixture-#{System.unique_integer([:positive])}.tar.gz")
    File.write!(path, archive)
    %{archive: path, digest: Workstation.Core.EngineState.sha256(archive)}
  end

  defp ustar(name, body) do
    if byte_size(name) > 100, do: raise(ArgumentError, "fixture member name too long")
    size = byte_size(body)

    head =
      pad(name, 100) <>
        "0000755 " <>
        "0000000 " <>
        "0000000 " <>
        (IO.iodata_to_binary(Integer.to_string(size, 8) |> String.pad_leading(11, "0")) <> " ") <>
        "00000000000 "

    tail =
      "0" <>
        :binary.copy(<<0>>, 100) <>
        "ustar " <>
        "00" <>
        :binary.copy(<<0>>, 32) <>
        :binary.copy(<<0>>, 32) <>
        :binary.copy(<<0>>, 8) <>
        :binary.copy(<<0>>, 8) <>
        :binary.copy(<<0>>, 155) <>
        :binary.copy(<<0>>, 12)

    # The checksum is the byte sum of the header with the checksum field
    # itself filled with eight spaces (the POSIX ustar rule).
    checksum =
      (head <> "        " <> tail)
      |> :binary.bin_to_list()
      |> Enum.sum()

    header =
      head <>
        IO.iodata_to_binary(Integer.to_string(checksum, 8) |> String.pad_leading(6, "0")) <>
        "  " <> tail

    padded = body <> :binary.copy(<<0>>, 512 - rem(byte_size(body), 512))
    header <> padded
  end

  defp pad(string, width) do
    string <> :binary.copy(<<0>>, width - byte_size(string))
  end
end
