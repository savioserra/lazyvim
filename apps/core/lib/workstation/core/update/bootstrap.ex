defmodule Workstation.Core.Update.Bootstrap do
  @moduledoc """
  The `bootstrap` step: verified pinned runtime, backend and public
  launcher.

  The integrity semantics are strict, and so is the host precheck:

  * the distro prerequisite set is verified BEFORE anything is provisioned.
    The set is read from the checkout's `docs/tools.md` — the
    `workstation-distro-prereqs` block, the same source the installer cites
    (never a second hand-copied list) — parsed strict (exactly one block,
    `<distro package>:<PATH binary>` entries, no duplicates), each binary
    probed on PATH, and the missing set refuses the bootstrap ONCE, naming
    every missing tool plus the distro install command (the d43604df
    aggregate shape: fix the whole set, re-run once — never one wasted
    lifecycle cycle per tool). The apply-time extraction refusal stays as
    the fail-closed backstop.
  * the runtime pins are DERIVED from the checkout's `versions.json` — the
    single source of truth (the retired `bootstrap.pins` manifest was fully
    derivable data whose hand regeneration rotted twice). The derivation is
    strict: exactly the two supported platforms, the `neovim` version
    digits/dots only, each platform's URL pinned to the pinned version's
    GitHub release path with a restricted character set after `{V}`
    substitution, 64-hex digests, and no `neovim_*` field outside the ones
    the derivation consumes. A versions.json that fails any check refuses
    the bootstrap instead of downloading from it. The release refresh hands
    the derived records to the shell installer as env (`NEOVIM_VERSION`,
    `NEOVIM_<PLAT>_URL`, `NEOVIM_<PLAT>_SHA256`), so a fresh machine and a
    daemon-driven refresh validate the same derivation; versions.json
    itself is checkout source whose integrity rides the git checkout.
  * artifacts are hash-checked on EVERY use and cached under their digest
    (`<home>/.cache/workstation/bootstrap/<digest>` for the runtime,
    `<home>/.cache/workstation/downloads/<sha256>` for the backend); a
    cached file whose bytes no longer hash to its own name is discarded,
    never trusted.
  * archives are member-checked before extraction (no empty, absolute or
    `..`-traversing names), extracted into a private staging directory, and
    activated by sibling rename with the previous tree kept as backup until
    activation commits — an interrupted installer can never leave a
    half-installed runtime in place of a working one. A filesystem that
    cannot rename the installed tree (EXDEV: an overlayfs lower layer, e.g.
    a docker-committed container's `<home>/.local/opt/nvim`) moves the old
    tree aside by copy instead: `cp -a` into a staging sibling inside the
    lock dir, flush best effort, then the same-directory rename commits
    `previous` in one atomic step before the source is removed. The
    activation renames are injectable (the `rename` opt — a 2-arity fun in
    the same fixture/test-only class as `allow_file_urls`, never a
    production argument) so the EXDEV branch is exercisable on a plain
    single-filesystem host.
  * the whole runtime install (download included, the shell's
    `$lock/download` staging) is serialized through a mkdir lock
    (`<home>/.local/opt/.nvim-bootstrap-lock`, bounded retries), because two
    concurrent bootstraps renaming `<home>/.local/opt/nvim` is exactly the
    race the lock exists to prevent. The lock carries its owner (host, pid,
    since): a lock whose owner is provably dead ON THIS HOST (the shared
    `/proc`-stat judge, `Workstation.Core.ProcessState` — a zombie owner is
    exited, so a defunct installer under a non-reaping pid 1 never reads as
    alive) is debris from
    an interrupted installer — the R2 refresh deadlock, where one stale lock
    stalled every later update — and is stolen exactly once per acquisition
    (atomic rename first, contents re-checked immediately before it).
    A legacy owner-less lock and a foreign-host lock are never stolen: an
    exhausted wait is still an honest failure naming the lock.
  * the public launcher is published only as the canonical matching symlink;
    a conflicting path is refused ("inspect and move it aside explicitly"),
    never replaced.

  The backend artifact covers the one call shape the bootstrap verb
  needs (`tar` archive, single `chezmoi` inner file, mode 0755); the general
  provision archive machinery (zip, overlay trees, exact manifests) lands
  when a lane needs it.

  Downloads use the pinned https-only curl contract; `allow_file_urls: true`
  re-opens `file://` for LOCAL FIXTURE tests only, never in production runs.
  """

  @lock_retries 60
  @lock_wait_ms 1_000

  @doc "Platform pin name, mirroring the launcher's `uname` mapping."
  @spec platform() :: String.t()
  def platform do
    case :os.type() do
      {:unix, :linux} ->
        if x86_64?(),
          do: "linux_x86_64",
          else: raise(ArgumentError, "bootstrap: unsupported platform: linux/#{arch()}")

      {:unix, :darwin} ->
        if arm64?(),
          do: "darwin_arm64",
          else: raise(ArgumentError, "bootstrap: unsupported platform: darwin/#{arch()}")

      _other ->
        raise ArgumentError,
              "bootstrap: supported hosts are Linux x86_64 (including WSL) and Darwin arm64"
    end
  end

  @doc """
  Run the full bootstrap step against the target home: pinned runtime,
  pinned backend, public launcher. Returns
  `{:ok, %{"step" => "bootstrap", "status" => "ok", "runtime" => version,
  "chezmoi" => version}}`; raises `ArgumentError` on any missing host
  distro prerequisite, integrity, download or activation failure.
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) when is_list(opts) do
    root = Workstation.Core.Update.engine_root(opts)
    home = Keyword.get(opts, :home) || Workstation.Core.EngineState.home()

    # Before ANY provisioning: a missing host tool must refuse before the
    # first download, extraction or launcher write — the 2026-10-19 WSL2
    # incident walked pull → bootstrap "ok" and died at apply.
    verify_distro_tools!(root, opts)

    pin = pins!(root, platform())

    runtime_version = install_runtime(home, pin, opts)
    chezmoi_version = install_backend(root, home, opts)
    install_launcher(root, home)

    {:ok,
     %{
       "step" => "bootstrap",
       "status" => "ok",
       "runtime" => runtime_version,
       "chezmoi" => chezmoi_version
     }}
  end

  ## Distro prerequisite precheck (docs/tools.md is the machine-readable source)

  # The doc lives beside the payload: `<root>/docs/tools.md` for a
  # self-contained checkout, `<root>/../docs/tools.md` for the repository
  # layout (the payload partition is `workstation/`).
  @doc_prereq_block "workstation-distro-prereqs"
  @doc_prereq_entry ~r|\A([a-z0-9][a-z0-9+.-]*):([a-z0-9][a-z0-9._+-]*)\z|

  # The `find_executable` opt is a 1-arity fun in the same fixture/test-only
  # class as `rename` and `allow_file_urls`, never a production argument.
  defp verify_distro_tools!(root, opts) do
    find_executable = Keyword.get(opts, :find_executable, &System.find_executable/1)
    tools = distro_tools!(doc_tools_path!(root))

    missing =
      Enum.filter(tools, fn {_package, binary} -> not is_binary(find_executable.(binary)) end)

    case missing do
      [] -> :ok
      missing -> raise(ArgumentError, missing_tools_message(missing, tools))
    end
  end

  defp doc_tools_path!(root) do
    candidates = [
      Path.join(root, "docs/tools.md"),
      Path.expand(Path.join(root, "../docs/tools.md"))
    ]

    case Enum.find(candidates, &File.regular?/1) do
      nil ->
        raise ArgumentError,
              "bootstrap: no docs/tools.md beside the engine checkout " <>
                "(looked at #{Enum.join(candidates, ", ")}); " <>
                "the distro prerequisite set cannot be verified"

      path ->
        path
    end
  end

  # The doc is parsed with the derivation's own strictness: exactly one
  # block, and inside it only comments, blank lines and `<package>:<binary>`
  # entries — a doc edited into a shape the engine cannot trust refuses the
  # bootstrap instead of provisioning from it.
  defp distro_tools!(doc_path) do
    {state, entries, blocks} =
      doc_path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reduce({:out, [], 0}, &scan_prereq_line!/2)

    case {state, blocks, entries} do
      {:in, _, _} ->
        raise ArgumentError,
              "bootstrap: unterminated #{@doc_prereq_block} block in docs/tools.md"

      {_, 0, _} ->
        raise ArgumentError,
              "bootstrap: docs/tools.md carries no #{@doc_prereq_block} block; " <>
                "the distro prerequisite set cannot be verified"

      {_, blocks, _} when blocks > 1 ->
        raise ArgumentError,
              "bootstrap: #{blocks} #{@doc_prereq_block} blocks in docs/tools.md; " <>
                "exactly one is required"

      {_, 1, []} ->
        raise ArgumentError,
              "bootstrap: the #{@doc_prereq_block} block in docs/tools.md is empty"

      {_, 1, entries} ->
        refuse_duplicates!(entries)
        Enum.reverse(entries)
    end
  end

  # Outside the block only the exact opening fence matters; inside, a bare
  # closing fence ends it and every other line must parse — a stray fence
  # with another info string is a malformed entry, never a nested block.
  defp scan_prereq_line!(line, {:out, entries, blocks}) do
    if String.trim_trailing(line) == "```#{@doc_prereq_block}",
      do: {:in, entries, blocks},
      else: {:out, entries, blocks}
  end

  defp scan_prereq_line!(line, {:in, entries, blocks}) do
    condensed = String.trim(line)

    cond do
      condensed == "```" ->
        {:out, entries, blocks + 1}

      condensed == "" or String.starts_with?(condensed, "#") ->
        {:in, entries, blocks}

      true ->
        case Regex.run(@doc_prereq_entry, condensed) do
          [_, package, binary] ->
            {:in, [{package, binary} | entries], blocks}

          nil ->
            raise ArgumentError,
                  "bootstrap: malformed #{@doc_prereq_block} entry in docs/tools.md: #{condensed}"
        end
    end
  end

  defp refuse_duplicates!(entries) do
    packages = Enum.map(entries, &elem(&1, 0))
    binaries = Enum.map(entries, &elem(&1, 1))

    case {packages -- Enum.uniq(packages), binaries -- Enum.uniq(binaries)} do
      {[], []} ->
        :ok

      {[package | _], _} ->
        raise ArgumentError, "bootstrap: duplicate distro prerequisite package: #{package}"

      {_, [binary | _]} ->
        raise ArgumentError, "bootstrap: duplicate distro prerequisite binary: #{binary}"
    end
  end

  # One refusal, the full missing set, and the distro install command the
  # docs record — derived from the parsed package list, never hand-copied
  # here (the d43604df aggregate shape).
  defp missing_tools_message(missing, tools) do
    named =
      missing
      |> Enum.map(fn {_package, binary} -> "`#{binary}`" end)
      |> Enum.join(", ")

    base =
      "bootstrap requires the host tool(s) #{named} " <>
        "(the distro prerequisite set — docs/tools.md); " <>
        "install the missing tool(s) and re-run"

    case :os.type() do
      {:unix, :linux} ->
        base <> ": apt install " <> Enum.map_join(tools, " ", &elem(&1, 0))

      _other ->
        base <> "; see docs/tools.md for the platform prerequisites"
    end
  end

  ## Pins derivation (versions.json is the single source of truth)

  # Fixed platform set: the derivation yields exactly these two records, so
  # an unknown or duplicated platform cannot enter a bootstrap.
  @platforms ["linux_x86_64", "darwin_arm64"]

  @doc """
  Derive the runtime pins from the checkout's `versions.json`: the `neovim`
  version plus each platform's `{V}`-substituted GitHub release URL and
  SHA-256. Returns `%{"linux_x86_64" => record, "darwin_arm64" => record}`
  with records `{"asset", "version", "url", "digest"}`; raises
  `ArgumentError` on any validation failure.
  """
  @spec pins!(String.t()) :: %{String.t() => %{String.t() => String.t()}}
  def pins!(root) do
    versions = versions!(root)
    version = pin_field!(versions, "neovim")

    unless version != "" and Regex.match?(~r/\A[0-9.]+\z/, version),
      do: raise(ArgumentError, "bootstrap: invalid runtime version")

    records =
      Map.new(@platforms, fn asset ->
        url = versions |> pin_field!("neovim_#{asset}_url") |> String.replace("{V}", version)
        digest = pin_field!(versions, "neovim_#{asset}_sha256")
        {asset, validate_record!(asset, version, url, digest)}
      end)

    # No extra fields: every neovim-prefixed key must be one the derivation
    # consumed. A future platform or field added to versions.json without
    # extending this derivation is a loud refusal, never a silently ignored
    # pin the installer would never see.
    expected =
      MapSet.new([
        "neovim" | Enum.flat_map(@platforms, &["neovim_#{&1}_url", "neovim_#{&1}_sha256"])
      ])

    extras =
      versions
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "neovim"))
      |> MapSet.new()
      |> MapSet.difference(expected)
      |> MapSet.to_list()
      |> Enum.sort()

    case extras do
      [] ->
        records

      extras ->
        raise ArgumentError,
              "bootstrap: unexpected neovim pin field(s): #{Enum.join(extras, ", ")}"
    end
  end

  @doc false
  @spec pins!(String.t(), String.t()) :: %{String.t() => String.t()}
  def pins!(root, platform) do
    case pins!(root) do
      %{^platform => pin} -> pin
      _other -> raise ArgumentError, "bootstrap: no pin for platform #{platform}"
    end
  end

  defp pin_field!(versions, field) do
    case Map.fetch(versions, field) do
      {:ok, value} when is_binary(value) -> value
      _other -> raise ArgumentError, "bootstrap: missing or invalid neovim pin field: #{field}"
    end
  end

  # Field validation mirrors the shell installer's record checks field by
  # field; the version check ran in pins!/1 before the {V} substitution, so
  # the URL prefix is bound to an already-validated pinned version.
  defp validate_record!(asset, version, url, digest) do
    unless String.starts_with?(
             url,
             "https://github.com/neovim/neovim/releases/download/v#{version}/nvim-"
           ) and
             String.ends_with?(url, ".tar.gz") and
             Regex.match?(~r/\A[a-zA-Z0-9.\/:_-]+\z/, url),
           do: raise(ArgumentError, "bootstrap: invalid runtime URL")

    unless valid_hash?(digest), do: raise(ArgumentError, "bootstrap: invalid manifest record")

    %{"asset" => asset, "version" => version, "url" => url, "digest" => digest}
  end

  ## Runtime install (install-runtime.sh semantics)

  defp install_runtime(home, pin, opts) do
    parent = Path.join([home, ".local", "opt"])
    cache = Path.join([home, ".cache", "workstation", "bootstrap"])
    File.mkdir_p!(parent)
    File.mkdir_p!(cache)

    lock = Path.join(parent, ".nvim-bootstrap-lock")
    retries = Keyword.get(opts, :lock_retries, @lock_retries)
    wait = Keyword.get(opts, :lock_wait_ms, @lock_wait_ms)

    unless acquire_lock(lock, retries, wait),
      do:
        raise(
          ArgumentError,
          "bootstrap: runtime installer locked at #{lock} (check for an interrupted installer)"
        )

    stage = Path.join(lock, "stage")
    backup = Path.join(lock, "previous")

    try do
      # The archive is hash-checked and (when missing or corrupt) downloaded
      # INSIDE the lock — the shell's download staging is `$lock/download`,
      # so a crashed download never leaves debris in the cache and the
      # rename into it is single-atomic.
      archive = cached_archive(cache, pin, lock, opts)
      extract_runtime!(archive, stage)
      verify_runtime!(stage, pin)
      activate_runtime!(parent, stage, backup, opts)
      pin["version"]
    after
      File.rm_rf!(lock)
    end
  end

  # Cache under the digest: a present-but-corrupt archive (or a symlink in
  # its place) is removed and refetched, exactly like the shell's check.
  defp cached_archive(cache, pin, lock, opts) do
    archive = Path.join(cache, pin["digest"])

    fresh? =
      case File.lstat(archive) do
        {:ok, %{type: :regular}} ->
          Workstation.Core.EngineState.sha256(File.read!(archive)) == pin["digest"]

        _other ->
          false
      end

    if fresh? do
      archive
    else
      File.rm(archive)
      download_runtime(cache, pin, lock, opts)
      archive
    end
  end

  defp download_runtime(cache, pin, lock, opts) do
    partial = Path.join(lock, "download")

    try do
      curl!(pin["url"], partial, Keyword.get(opts, :allow_file_urls, false), "runtime")

      unless Workstation.Core.EngineState.sha256(File.read!(partial)) == pin["digest"],
        do: raise(ArgumentError, "bootstrap: runtime checksum mismatch")

      File.rename!(partial, Path.join(cache, pin["digest"]))
    after
      File.rm(partial)
    end
  end

  defp curl!(url, partial, allow_file_urls, artifact) do
    proto = if allow_file_urls, do: "=https,file", else: "=https"

    case System.cmd(
           "curl",
           [
             "--proto",
             proto,
             "--proto-redir",
             "=https",
             "-fSL",
             "--retry",
             "3",
             "-o",
             partial,
             url
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {out, code} ->
        raise ArgumentError,
              "bootstrap: #{artifact} download failed (exit #{code}): #{String.trim_trailing(out)}"
    end
  end

  # Reject traversal before extraction; release archives have one owned
  # root and extract with exactly one component stripped.
  defp extract_runtime!(archive, stage) do
    {members, 0} = System.cmd("tar", ["-tf", archive], stderr_to_stdout: true)
    Enum.each(String.split(members, "\n", trim: true), &safe_member!/1)

    File.mkdir!(stage)

    case System.cmd("tar", ["-xf", archive, "-C", stage, "--strip-components=1"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {out, code} ->
        raise ArgumentError,
              "bootstrap: runtime extraction failed (exit #{code}): #{String.trim_trailing(out)}"
    end
  end

  defp safe_member!(name) do
    traversal? =
      name == "" or String.starts_with?(name, "/") or name == ".." or
        String.starts_with?(name, "../") or
        String.contains?(name, "/../") or String.ends_with?(name, "/..")

    unless not traversal?, do: raise(ArgumentError, "bootstrap: unsafe archive member")
  end

  defp verify_runtime!(stage, pin) do
    nvim = Path.join(stage, "bin/nvim")

    unless regular_executable?(nvim),
      do: raise(ArgumentError, "bootstrap: runtime archive lacks executable bin/nvim")

    {out, 0} = System.cmd(nvim, ["--version"], stderr_to_stdout: true)
    first = out |> String.split("\n", trim: true) |> List.first("")

    unless first == "NVIM v" <> pin["version"],
      do: raise(ArgumentError, "bootstrap: runtime version mismatch (#{first})")
  end

  # Sibling renames; the previous tree is restored when activation failed
  # and the new tree is not in place (the shell's exit trap). The renames
  # go through the injectable `rename` opt (production: `File.rename/2`),
  # and a filesystem that refuses to rename the installed tree — EXDEV,
  # an overlayfs lower layer — falls back to the copy-based move-aside.
  defp activate_runtime!(parent, stage, backup, opts) do
    rename = Keyword.get(opts, :rename, &File.rename/2)
    installed = Path.join(parent, "nvim")
    had_installed? = File.exists?(installed)

    if had_installed? do
      case rename.(installed, backup) do
        :ok ->
          :ok

        # Overlayfs lower layer (any container whose opt/nvim sits in an
        # image layer, e.g. after docker commit): the tree cannot be
        # renamed, only copied. The lock discipline survives through the
        # staging-then-commit move-aside below; every other refusal keeps
        # the exact `File.rename!/2` error shape.
        {:error, :exdev} ->
          copy_installed_aside!(installed, backup)

        {:error, reason} ->
          raise File.RenameError,
            reason: reason,
            action: "rename",
            source: installed,
            destination: backup
      end
    end

    try do
      rename_bang!(rename, stage, installed)
    rescue
      error ->
        if had_installed? and not File.exists?(installed),
          do: rename_bang!(rename, backup, installed)

        reraise error, __STACKTRACE__
    end
  end

  # `File.rename!/2` over the injectable rename fun, raising the exact
  # bang's error shape (the fun returns `{:error, reason}` tuples).
  defp rename_bang!(rename, source, destination) do
    case rename.(source, destination) do
      :ok ->
        :ok

      {:error, reason} ->
        raise File.RenameError,
          reason: reason,
          action: "rename",
          source: source,
          destination: destination
    end
  end

  # The EXDEV fallback: a POSIX-safe equivalent of the move-aside rename.
  # `cp -a` the installed tree into a STAGING sibling inside the lock dir
  # (modes, links and times preserved), flush it best effort, and commit
  # the backup with a rename INSIDE the lock dir — atomic, so a crash
  # mid-copy can never leave `previous` half-populated — before the source
  # goes away.
  defp copy_installed_aside!(installed, backup) do
    staged = backup <> ".staging-" <> Integer.to_string(System.unique_integer([:positive]))

    case System.cmd("cp", ["-a", installed, staged], stderr_to_stdout: true) do
      {_, 0} ->
        flush_tree_best_effort(staged)
        File.rename!(staged, backup)
        File.rm_rf!(installed)

      {out, code} ->
        File.rm_rf(staged)

        raise ArgumentError,
              "bootstrap: runtime backup copy failed (exit #{code}): #{String.trim_trailing(out)}"
    end
  end

  # The copied backup's crash window closes only when its bytes reach the
  # disk, so walk the tree and flush every regular file — best effort: the
  # fallback runs on exactly the filesystems where a flush can be refused,
  # and the backup is rollback convenience, never worth failing the
  # install over.
  defp flush_tree_best_effort(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, children} -> Enum.each(children, &flush_tree_best_effort(Path.join(path, &1)))
          {:error, _reason} -> :ok
        end

      {:ok, %{type: :regular}} ->
        File.open(path, [:raw, :read], &:file.sync/1)
        :ok

      _other ->
        :ok
    end
  end

  ## Backend artifact (the `ensure_backend` call shape)

  defp install_backend(root, home, opts) do
    versions = versions!(root)
    version = Map.fetch!(versions, "chezmoi")
    asset = platform()
    url = versions |> Map.fetch!("chezmoi_#{asset}_url") |> String.replace("{V}", version)
    digest = Map.fetch!(versions, "chezmoi_#{asset}_sha256")
    valid_hash?(digest) || raise(ArgumentError, "bootstrap: invalid SHA256 pin for chezmoi")
    https_url?(url, opts) || raise(ArgumentError, "bootstrap: HTTPS URL required for chezmoi")

    archive = cached_download(home, url, digest, opts)
    bin_dir = Path.join([home, ".local", "opt", "chezmoi", "bin"])
    File.mkdir_p!(bin_dir)
    staging = sibling(bin_dir)
    dest = Path.join(bin_dir, "chezmoi")

    try do
      {members, 0} = System.cmd("tar", ["-tf", archive], stderr_to_stdout: true)
      Enum.each(String.split(members, "\n", trim: true), &safe_member!/1)

      File.mkdir!(staging)

      case System.cmd("tar", ["-xf", archive, "-C", staging], stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {out, code} ->
          raise ArgumentError,
                "bootstrap: backend extraction failed (exit #{code}): #{String.trim_trailing(out)}"
      end

      inner = Path.join(staging, "chezmoi")

      unless regular_executable_after_chmod?(inner),
        do: raise(ArgumentError, "bootstrap: archive member must be a regular file")

      File.chmod!(inner, 0o755)
      activate!(dest, inner)
    after
      File.rm_rf!(staging)
    end

    version
  end

  # versions.json is checkout source (not guarded home state): strict decode
  # so a malformed pin set is a loud failure, never a partial download.
  defp versions!(root) do
    case root
         |> then(&Path.join(&1, "versions.json"))
         |> File.read!()
         |> Workstation.Core.EngineState.decode_json() do
      {:ok, %{} = versions} when map_size(versions) > 0 -> versions
      _other -> raise ArgumentError, "bootstrap: malformed versions.json"
    end
  end

  defp https_url?(url, opts) do
    String.starts_with?(url, "https://") or
      (Keyword.get(opts, :allow_file_urls, false) and String.starts_with?(url, "file://"))
  end

  # The provision download cache: digest-keyed, re-verified on every use,
  # partials invisible until the bytes hash to their name.
  defp cached_download(home, url, digest, opts) do
    cache = Path.join([home, ".cache", "workstation", "downloads"])
    File.mkdir_p!(cache)
    cached = Path.join(cache, digest)

    fresh? =
      case File.lstat(cached) do
        {:ok, %{type: :regular}} ->
          Workstation.Core.EngineState.sha256(File.read!(cached)) == digest

        _other ->
          false
      end

    unless fresh? do
      File.rm(cached)
      partial = sibling(cached)

      try do
        curl!(url, partial, Keyword.get(opts, :allow_file_urls, false), "provision")

        unless Workstation.Core.EngineState.sha256(File.read!(partial)) == digest,
          do: raise(ArgumentError, "bootstrap: provision checksum mismatch: #{url}")

        File.rename!(partial, cached)
      after
        File.rm(partial)
      end
    end

    cached
  end

  # The provision activation: rename the destination aside, rename the
  # staged tree in, roll the destination back when activation failed.
  defp activate!(dest, content) do
    retired = sibling(dest)
    had_dest? = File.exists?(dest)

    if had_dest?, do: File.rename!(dest, retired)

    try do
      File.rename!(content, dest)
      File.rm_rf!(retired)
    rescue
      error ->
        if had_dest? and not File.exists?(dest), do: File.rename!(retired, dest)
        reraise error, __STACKTRACE__
    end
  end

  ## Public launcher (install into `~/.local/bin`)

  defp install_launcher(root, home) do
    target = Workstation.Core.Update.realpath(Path.join(root, "bin/workstation"))
    directory = Path.join([home, ".local", "bin"])
    launcher = Path.join(directory, "workstation")
    File.mkdir_p!(directory)

    conflict =
      "bootstrap: refusing conflicting launcher at #{launcher}; inspect and move it aside explicitly"

    case File.lstat(launcher) do
      {:error, :enoent} ->
        case File.ln_s(target, launcher) do
          :ok ->
            :ok

          {:error, reason} ->
            raise ArgumentError,
                  "bootstrap: cannot publish launcher at #{launcher}: #{inspect(reason)}"
        end

      {:ok, %{type: :symlink}} ->
        case File.read_link(launcher) do
          {:ok, ^target} -> :ok
          _other -> raise ArgumentError, conflict
        end

      {:ok, _other} ->
        raise ArgumentError, conflict

      {:error, reason} ->
        raise ArgumentError,
              "bootstrap: cannot inspect launcher at #{launcher}: #{inspect(reason)}"
    end
  end

  ## internals

  defp acquire_lock(lock, retries, wait, steals \\ 1) do
    case File.mkdir(lock) do
      :ok ->
        write_owner(lock)
        true

      {:error, :eexist} ->
        cond do
          # One steal per acquisition: a lock whose recorded owner is
          # provably dead on this host is debris (the R2 refresh deadlock),
          # not a held lock. The re-check inside steal_lock/1 closes the
          # lost-race window on a fresh live owner.
          steals > 0 and stale?(lock) ->
            steal_lock(lock)
            acquire_lock(lock, retries, wait, steals - 1)

          retries > 0 ->
            Process.sleep(wait)
            acquire_lock(lock, retries - 1, wait, steals)

          true ->
            false
        end

      {:error, reason} ->
        raise ArgumentError,
              "bootstrap: cannot create runtime installer lock at #{lock}: #{inspect(reason)}"
    end
  end

  # The owner line: "<hostname>|<os pid>|<epoch ms>". A legacy lock (no
  # owner file) and a foreign-host lock are unknowable or not ours to
  # judge — never stolen.
  defp write_owner(lock) do
    File.write(
      Path.join(lock, "owner"),
      "#{hostname()}|#{:os.getpid()}|#{System.system_time(:millisecond)}"
    )
  end

  defp read_owner(lock) do
    case File.read(Path.join(lock, "owner")) do
      {:ok, line} ->
        case String.split(String.trim_trailing(line), "|") do
          [host, pid, since] -> {:ok, [host, pid, since]}
          _other -> :error
        end

      {:error, _reason} ->
        :error
    end
  end

  defp stale?(lock) do
    case read_owner(lock) do
      {:ok, owner} -> stale_owner?(owner)
      :error -> false
    end
  end

  defp stale_owner?([host, pid, _since]), do: host == hostname() and not pid_alive?(pid)
  defp stale_owner?(_other), do: false

  # The atomic steal: rename first (a lost race — someone else stole it, or
  # a fresh live owner appeared — fails the rename or leaves the check
  # catching it), then delete the renamed debris.
  defp steal_lock(lock) do
    with {:ok, owner} <- read_owner(lock),
         true <- stale_owner?(owner),
         dead = lock <> ".stale-" <> Integer.to_string(System.unique_integer([:positive])),
         :ok <- File.rename(lock, dead) do
      File.rm_rf!(dead)
    else
      _other -> :ok
    end
  end

  # The staleness judge is the shared liveness verdict
  # (`Workstation.Core.ProcessState`), the same "provably dead ON THIS HOST"
  # verdict the apply lock's takeover uses: the `/proc/<pid>/stat` state
  # character decides and a zombie owner is EXITED — the kernel's own proof
  # the installer exited. (Under a pid 1 that never reaps the defunct entry
  # outlives the death, and the old `/proc` existence probe read it as alive,
  # refusing every steal: the R2 refresh deadlock's own shape.) Fail-closed
  # is intact: an unclear probe — unreadable stat, inconclusive `kill -0`, a
  # non-numeric pid — reads ALIVE, so a corrupt owner record is operator
  # recovery, never a stolen lock.
  defp pid_alive?(pid), do: Workstation.Core.ProcessState.alive?(pid)

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  # Staging siblings live next to their destination, on the same filesystem,
  # so the final rename is atomic.
  defp sibling(dest), do: "#{dest}.bootstrap-#{System.unique_integer([:positive])}"

  defp regular_executable?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  # The backend member's executability is SET here (mode 0755); the check is
  # only that the staged entry is a plain regular file at all.
  defp regular_executable_after_chmod?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> true
      _other -> false
    end
  end

  defp valid_hash?(value),
    do: is_binary(value) and byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp arch, do: to_string(:erlang.system_info(:system_architecture))
  defp x86_64?, do: String.contains?(arch(), "x86_64")
  defp arm64?, do: String.contains?(arch(), "aarch64") or String.contains?(arch(), "arm64")
end
