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
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(base)
    end)

    %{base: base, home: home}
  end

  ## pins! validation matrix (pure manifest reading)

  test "pins! returns the platform pin for a valid manifest", %{base: base} do
    %{root: root} = engine_fixture(base)

    pin = Bootstrap.pins!(root, Bootstrap.platform())
    assert pin["version"] == @fixture_version
    assert pin["url"] == "https://github.com/neovim/neovim/releases/download/v#{@fixture_version}/nvim-#{Bootstrap.platform()}.tar.gz"
    assert byte_size(pin["digest"]) == 64 and Regex.match?(~r/\A[0-9a-f]+\z/, pin["digest"])
  end

  test "pins! refuses a stale manifest binding", %{base: base} do
    %{root: root} = engine_fixture(base, bind: :wrong)

    assert_raise ArgumentError, ~r/manifest is stale/, fn ->
      Bootstrap.pins!(root, Bootstrap.platform())
    end
  end

  test "pins! refuses malformed manifests", %{base: base} do
    good_digest = String.duplicate("ab", 32)
    good_url = github_url("linux_x86_64")
    other_url = github_url("darwin_arm64")
    other_digest = String.duplicate("cd", 32)
    header = "versions-sha256|#{Workstation.Core.EngineState.sha256("{}")}"

    cases = [
      # wrong record count (missing darwin record)
      {"invalid manifest header", "#{header}\nlinux_x86_64|0.0.0|#{good_url}|#{good_digest}\n"},
      # version outside digits/dots
      {"invalid runtime version", "#{header}\nlinux_x86_64|0..0-alpha|#{good_url}|#{good_digest}\ndarwin_arm64|0.0.0|#{other_url}|#{other_digest}\n"},
      # URL outside the pinned release path
      {"invalid runtime URL", "#{header}\nlinux_x86_64|0.0.0|https://evil.example/nvim-1.0.tar.gz|#{good_digest}\ndarwin_arm64|0.0.0|#{other_url}|#{other_digest}\n"},
      # digest not 64 lowercase hex
      {"invalid manifest record", "#{header}\nlinux_x86_64|0.0.0|#{good_url}|NOTAHASH\ndarwin_arm64|0.0.0|#{other_url}|#{other_digest}\n"},
      # extra field in a record
      {"invalid manifest record", "#{header}\nlinux_x86_64|0.0.0|#{good_url}|#{good_digest}|extra\ndarwin_arm64|0.0.0|#{other_url}|#{other_digest}\n"},
      # a trailing fourth record
      {"invalid manifest header", "#{header}\nlinux_x86_64|0.0.0|#{good_url}|#{good_digest}\ndarwin_arm64|0.0.0|#{other_url}|#{other_digest}\nwindows_x86|0.0.0|#{good_url}|#{good_digest}\n"}
    ]

    for {expected, records} <- cases do
      root = pins_fixture(base, "#{records}")

      assert_raise ArgumentError, ~r/#{expected}/, fn ->
        Bootstrap.pins!(root, "linux_x86_64")
      end
    end
  end

  test "pins! refuses a malformed header shape even with well-formed records", %{base: base} do
    good_digest = String.duplicate("ab", 32)
    root = pins_fixture(base, "versions-sha256:#{good_digest}\n")

    assert_raise ArgumentError, ~r/invalid manifest header/, fn ->
      Bootstrap.pins!(root, "linux_x86_64")
    end
  end

  ## full run (offline: runtime cache pre-seeded, backend over file://)

  test "run installs runtime, backend and launcher from verified artifacts", %{base: base, home: home} do
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
    assert File.regular?(Path.join([home, ".cache", "workstation", "bootstrap", fixture.runtime_digest]))
    assert [_one] = File.ls!(Path.join([home, ".cache", "workstation", "downloads"]))

    # No lock or staging debris survives a successful run.
    refute File.exists?(Path.join([home, ".local", "opt", ".nvim-bootstrap-lock"]))

    # Idempotent: a second run over installed state succeeds.
    assert {:ok, %{"status" => "ok"}} = Bootstrap.run(engine_root: fixture.root, home: home, allow_file_urls: true)
  end

  test "a corrupt runtime cache entry is discarded, never trusted", %{base: base, home: home} do
    fixture = engine_fixture(base)
    seed_runtime_cache!(home, fixture)
    File.write!(Path.join([home, ".cache", "workstation", "bootstrap", fixture.runtime_digest]), "corrupt bytes")

    # The https-only runtime download cannot run in this sandbox; what this
    # pins is the DISCARD: the corrupt entry is gone before the honest
    # download failure follows (no fixture can serve that URL).
    assert_raise ArgumentError, ~r/runtime download failed/, fn ->
      Bootstrap.run(engine_root: fixture.root, home: home)
    end

    refute File.exists?(Path.join([home, ".cache", "workstation", "bootstrap", fixture.runtime_digest]))
    assert File.regular?(fixture.runtime_archive)
  end

  test "a backend download whose bytes do not hash to the pin is refused", %{base: base, home: home} do
    fixture = engine_fixture(base)
    seed_runtime_cache!(home, fixture)
    File.write!(fixture.chezmoi_archive, "not the pinned bytes")

    assert_raise ArgumentError, ~r/provision checksum mismatch/, fn ->
      Bootstrap.run(engine_root: fixture.root, home: home, allow_file_urls: true)
    end

    refute File.exists?(Path.join([home, ".local", "opt", "chezmoi", "bin", "chezmoi"]))
  end

  test "a runtime archive with a traversing member is refused before extraction", %{base: base, home: home} do
    fixture = engine_fixture(base, runtime_archive: tar_fixture!([{"../evil.txt", "evil\n"}]))
    seed_runtime_cache!(home, fixture)

    assert_raise ArgumentError, ~r/unsafe archive member/, fn ->
      Bootstrap.run(engine_root: fixture.root, home: home)
    end

    refute File.exists?(Path.join([home, ".local", "opt", "nvim"]))
  end

  test "a runtime tree without bin/nvim, or with a wrong version banner, is refused", %{base: base, home: home} do
    # no bin/nvim at all
    fixture = engine_fixture(base, runtime_archive: tar_fixture!([{"fixture/README", "nothing here\n"}]))
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

  test "the runtime installer lock is never stolen", %{base: base, home: home} do
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

  # An engine checkout fixture: payload markers, a versions.json whose hash
  # the pins bind, and a pins manifest for the runtime archive. The runtime
  # record's URL is https/github-shaped but NEVER fetched in tests (the
  # cache is seeded); the backend record carries the file:// fixture.
  defp engine_fixture(base, opts \\ []) do
    root = Path.join(base, "engine")
    fixture_dir = Path.join(base, "fixtures")
    File.mkdir_p!(Path.join(root, "bootstrap"))
    File.mkdir_p!(Path.join(root, "bin"))
    File.mkdir_p!(fixture_dir)

    File.write!(Path.join(root, "bin/workstation"), "#!/bin/sh\necho launcher-fixture\n")
    File.chmod!(Path.join(root, "bin/workstation"), 0o755)

    %{archive: runtime_archive, digest: runtime_digest} =
      Keyword.get_lazy(opts, :runtime_archive, fn -> runtime_fixture_archive!(base) end)
    %{archive: chezmoi_archive, digest: chezmoi_digest} = chezmoi_fixture_archive!(fixture_dir)

    versions =
      Jason.encode!(%{
        "chezmoi" => "1.2.3",
        "chezmoi_linux_x86_64_url" => "file://#{chezmoi_archive}",
        "chezmoi_linux_x86_64_sha256" => chezmoi_digest,
        "chezmoi_darwin_arm64_url" => "file://#{chezmoi_archive}",
        "chezmoi_darwin_arm64_sha256" => chezmoi_digest
      })

    File.write!(Path.join(root, "versions.json"), versions)

    binding = if opts[:bind] == :wrong, do: String.duplicate("00", 32), else: Workstation.Core.EngineState.sha256(versions)

    File.write!(
      Path.join(root, "bootstrap/bootstrap.pins"),
      "versions-sha256|#{binding}\nlinux_x86_64|#{@fixture_version}|#{github_url("linux_x86_64")}|#{runtime_digest}\n" <>
        "darwin_arm64|#{@fixture_version}|#{github_url("darwin_arm64")}|#{String.duplicate("cd", 32)}\n"
    )

    %{
      root: root,
      runtime_archive: runtime_archive,
      runtime_digest: runtime_digest,
      chezmoi_archive: chezmoi_archive
    }
  end

  defp pins_fixture(base, records) do
    root = Path.join(base, "pins-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "bootstrap"))
    File.write!(Path.join(root, "versions.json"), "{}")
    File.write!(Path.join(root, "bootstrap/bootstrap.pins"), records)
    root
  end

  defp github_url(asset), do: "https://github.com/neovim/neovim/releases/download/v#{@fixture_version}/nvim-#{asset}.tar.gz"

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

    header = head <> IO.iodata_to_binary(Integer.to_string(checksum, 8) |> String.pad_leading(6, "0")) <> "  " <> tail
    padded = body <> :binary.copy(<<0>>, 512 - rem(byte_size(body), 512))
    header <> padded
  end

  defp pad(string, width) do
    string <> :binary.copy(<<0>>, width - byte_size(string))
  end
end
