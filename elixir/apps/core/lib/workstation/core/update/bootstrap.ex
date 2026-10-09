defmodule Workstation.Core.Update.Bootstrap do
  @moduledoc """
  The `bootstrap` step: verified pinned runtime, backend and public
  launcher.

  Integrity is the step's whole point, so the semantics are strict:

  * `bootstrap.pins` is generated data with a fixed shape — the
    `versions-sha256|<hash>` header must equal the SHA-256 of the checkout's
    `versions.json`, exactly two platform records must follow in fixed order
    with validated fields (version digits/dots only, URL pinned to the
    pinned version's GitHub release path with a restricted character set,
    64-hex digest, no extra fields or trailing records). A manifest that
    fails any check refuses the bootstrap instead of downloading from it.
  * artifacts are hash-checked on EVERY use and cached under their digest
    (`<home>/.cache/workstation/bootstrap/<digest>` for the runtime,
    `<home>/.cache/workstation/downloads/<sha256>` for the backend); a
    cached file whose bytes no longer hash to its own name is discarded,
    never trusted.
  * archives are member-checked before extraction (no empty, absolute or
    `..`-traversing names), extracted into a private staging directory, and
    activated by sibling rename with the previous tree kept as backup until
    activation commits — an interrupted installer can never leave a
    half-installed runtime in place of a working one.
  * the whole runtime install (download included, the shell's
    `$lock/download` staging) is serialized through a mkdir lock
    (`<home>/.local/opt/.nvim-bootstrap-lock`, bounded retries), because two
    concurrent bootstraps renaming `<home>/.local/opt/nvim` is exactly the
    race the lock exists to prevent. The lock carries its owner (host, pid,
    since): a lock whose owner is provably dead ON THIS HOST is debris from
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
        if x86_64?(), do: "linux_x86_64", else: raise(ArgumentError, "bootstrap: unsupported platform: linux/#{arch()}")

      {:unix, :darwin} ->
        if arm64?(), do: "darwin_arm64", else: raise(ArgumentError, "bootstrap: unsupported platform: darwin/#{arch()}")

      _other ->
        raise ArgumentError, "bootstrap: supported hosts are Linux x86_64 (including WSL) and Darwin arm64"
    end
  end

  @doc """
  Run the full bootstrap step against the target home: pinned runtime,
  pinned backend, public launcher. Returns
  `{:ok, %{"step" => "bootstrap", "status" => "ok", "runtime" => version,
  "chezmoi" => version}}`; raises `ArgumentError` on any integrity,
  download or activation failure.
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) when is_list(opts) do
    root = Workstation.Core.Update.engine_root(opts)
    home = Keyword.get(opts, :home) || Workstation.Core.EngineState.home()
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

  ## Pins manifest reader

  @doc false
  @spec pins!(String.t(), String.t()) :: %{String.t() => String.t()}
  def pins!(root, platform) do
    records =
      case File.read!(Path.join(root, "bootstrap/bootstrap.pins")) |> String.split("\n", trim: true) do
        [header, linux, darwin] ->
          header!(header, Path.join(root, "versions.json"))
          [validate_record!("linux_x86_64", linux), validate_record!("darwin_arm64", darwin)]

        _other ->
          raise ArgumentError, "bootstrap: invalid manifest header"
      end

    case Enum.find(records, &(&1["asset"] == platform)) do
      nil -> raise ArgumentError, "bootstrap: no pin for platform #{platform}"
      pin -> pin
    end
  end

  # Fixed record order/count prohibit unknown/duplicate/missing platforms;
  # field validation mirrors the shell reader field by field.
  defp header!(header, versions_path) do
    binding = String.trim_leading(header, "versions-sha256|")

    unless header == "versions-sha256|" <> binding and valid_hash?(binding),
      do: raise(ArgumentError, "bootstrap: invalid manifest header")

    unless Workstation.Core.EngineState.sha256(File.read!(versions_path)) == binding,
      do: raise(ArgumentError, "bootstrap: bootstrap manifest is stale; regenerate from versions.json")
  end

  defp validate_record!(asset, record) do
    case String.split(record, "|", parts: 5) do
      [^asset, version, url, digest] ->
        unless version != "" and Regex.match?(~r/\A[0-9.]+\z/, version),
          do: raise(ArgumentError, "bootstrap: invalid runtime version")

        unless String.starts_with?(url, "https://github.com/neovim/neovim/releases/download/v#{version}/nvim-") and
                 String.ends_with?(url, ".tar.gz") and
                 Regex.match?(~r/\A[a-zA-Z0-9.\/:_-]+\z/, url),
               do: raise(ArgumentError, "bootstrap: invalid runtime URL")

        unless valid_hash?(digest), do: raise(ArgumentError, "bootstrap: invalid manifest record")

        %{"asset" => asset, "version" => version, "url" => url, "digest" => digest}

      _other ->
        raise ArgumentError, "bootstrap: invalid manifest record"
    end
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
      do: raise(ArgumentError, "bootstrap: runtime installer locked at #{lock} (check for an interrupted installer)")

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
      activate_runtime!(parent, stage, backup)
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
        {:ok, %{type: :regular}} -> Workstation.Core.EngineState.sha256(File.read!(archive)) == pin["digest"]
        _other -> false
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

    case System.cmd("curl", ["--proto", proto, "--proto-redir", "=https", "-fSL", "--retry", "3", "-o", partial, url],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {out, code} ->
        raise ArgumentError, "bootstrap: #{artifact} download failed (exit #{code}): #{String.trim_trailing(out)}"
    end
  end

  # Reject traversal before extraction; release archives have one owned
  # root and extract with exactly one component stripped.
  defp extract_runtime!(archive, stage) do
    {members, 0} = System.cmd("tar", ["-tf", archive], stderr_to_stdout: true)
    Enum.each(String.split(members, "\n", trim: true), &safe_member!/1)

    File.mkdir!(stage)

    case System.cmd("tar", ["-xf", archive, "-C", stage, "--strip-components=1"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {out, code} ->
        raise ArgumentError, "bootstrap: runtime extraction failed (exit #{code}): #{String.trim_trailing(out)}"
    end
  end

  defp safe_member!(name) do
    traversal? =
      name == "" or String.starts_with?(name, "/") or name == ".." or String.starts_with?(name, "../") or
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
  # and the new tree is not in place (the shell's exit trap).
  defp activate_runtime!(parent, stage, backup) do
    installed = Path.join(parent, "nvim")
    had_installed? = File.exists?(installed)

    if had_installed?, do: File.rename!(installed, backup)

    try do
      File.rename!(stage, installed)
    rescue
      error ->
        if had_installed? and not File.exists?(installed), do: File.rename!(backup, installed)
        reraise error, __STACKTRACE__
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
          raise ArgumentError, "bootstrap: backend extraction failed (exit #{code}): #{String.trim_trailing(out)}"
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
    case root |> then(&Path.join(&1, "versions.json")) |> File.read!() |> Workstation.Core.EngineState.decode_json() do
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
        {:ok, %{type: :regular}} -> Workstation.Core.EngineState.sha256(File.read!(cached)) == digest
        _other -> false
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
    conflict = "bootstrap: refusing conflicting launcher at #{launcher}; inspect and move it aside explicitly"

    case File.lstat(launcher) do
      {:error, :enoent} ->
        case File.ln_s(target, launcher) do
          :ok -> :ok
          {:error, reason} -> raise ArgumentError, "bootstrap: cannot publish launcher at #{launcher}: #{inspect(reason)}"
        end

      {:ok, %{type: :symlink}} ->
        case File.read_link(launcher) do
          {:ok, ^target} -> :ok
          _other -> raise ArgumentError, conflict
        end

      {:ok, _other} ->
        raise ArgumentError, conflict

      {:error, reason} ->
        raise ArgumentError, "bootstrap: cannot inspect launcher at #{launcher}: #{inspect(reason)}"
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
        raise ArgumentError, "bootstrap: cannot create runtime installer lock at #{lock}: #{inspect(reason)}"
    end
  end

  # The owner line: "<hostname>|<os pid>|<epoch ms>". A legacy lock (no
  # owner file) and a foreign-host lock are unknowable or not ours to
  # judge — never stolen.
  defp write_owner(lock) do
    File.write(Path.join(lock, "owner"), "#{hostname()}|#{:os.getpid()}|#{System.system_time(:millisecond)}")
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

  defp pid_alive?(pid) do
    case :os.type() do
      {:unix, :linux} -> File.exists?("/proc/" <> pid)
      _other -> match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
    end
  end

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

  defp valid_hash?(value), do: is_binary(value) and byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp arch, do: to_string(:erlang.system_info(:system_architecture))
  defp x86_64?, do: String.contains?(arch(), "x86_64")
  defp arm64?, do: String.contains?(arch(), "aarch64") or String.contains?(arch(), "arm64")
end
