defmodule Workstation.Daemon.Generation do
  @moduledoc """
  Layer: kernel. The kernel law: this module names no package, no backend and no
  consumer -- it speaks only contracts and shapes (docs/architecture.md,
  "Module hierarchy & moduledoc conventions").
  The daemon's release-generation identity — the rendezvous gate that keeps
  a node from serving code it cannot prove is the installed release.

  Why: the 2026-10-19 aurora incident. `workstation update` rebuilt the
  installed release while a daemon node was spawning/booting against the
  same tree, and the node went on serving corrupt evaluations for EVERY
  read verb and the apply step — a spec-shape error that did not exist in
  the served tree — until the operator killed the beam by pid. Nothing in
  the handshake proved the node and the installed release were the same
  code; the pinned-home check proved the home, never the generation.

  The contract, fail-closed at both ends of the wire:

  * at BOOT the listener pins this node's generation — the `.built-from`
    stamp beside its own release root (`:code.root_dir()`), falling back to
    the root path when unstamped (dev/mix runs), the same identity spelling
    as `Workstation.Daemon.Lifecycle.release_identity/1`. A node whose own
    root CARRIES a stamp that differs from the installed release's stamp
    (`<home>/.local/opt/workstation/.built-from`) is provably not the
    installed generation and the boot refuses before the state socket ever
    binds — a known-stale node never serves.
  * at EVERY HELLO (rendezvous) the session re-reads the installed stamp
    and compares it against the pinned generation. A mismatch means the
    release changed (or landed) under this node: the hello is refused with
    the `stale_generation` code and the daemon schedules its own graceful
    stop (`Workstation.Daemon.Shutdown`), so the client's ensure-daemon
    respawns a clean node from the fully staged installed release. The
    incident's every-verb-fails-until-TERM state is exactly what this gate
    turns into a one-op refusal plus an automatic respawn.
  * the hello capabilities carry the pinned generation (`"release"`), and
    the CLIENT (`Workstation.CLI.DaemonClient`, ensure path only) verifies
    the advertisement against its own read of the installed stamp — an
    independent second reader, so a daemon-side read failure or a
    protocol-aged daemon cannot silence the gate. Liveness probes and
    control paths deliberately skip the check: `workstation daemon stop`
    must reach a stale generation to stop it, and the pre-replace
    liveness probe must see it to wait for it.

  Decidability: the verdict is `:undecided` whenever the installed stamp
  is absent or unreadable (a fresh machine, a dev home, a torn read) — the
  engine cannot decide, so it serves and says so in the capabilities. The
  rendezvous gate still fires the moment a READABLE installed stamp
  disagrees with the pinned generation: a node that cannot prove it serves
  the installed release does not serve it. Test trees boot with sandboxed
  homes and no installed stamp, so they are `:undecided` and unaffected.
  """

  alias Workstation.Core.EngineState
  alias Workstation.Daemon.Lifecycle

  @own_key {__MODULE__, :own}

  # The installed release root: the same path the update lifecycle's
  # refresh installs to and the launcher shim execs from — the release the
  # daemon must prove it serves (`Workstation.Daemon.Lifecycle.installed_release_root/1`).
  @installed_release_root ~w(.local opt workstation)

  @typedoc """
  The rendezvous verdict for a pinned generation against the installed
  release: `:fresh` (readable stamp, equal), `{:stale, own, installed}`
  (readable stamp, differs — refuse and respawn), `:undecided` (no
  readable installed stamp — the engine cannot decide).
  """
  @type verdict :: :fresh | {:stale, String.t(), String.t()} | :undecided

  @doc """
  Pin the calling node's generation, once, at listener boot. `opts[:own]`
  forces the identity (tests); otherwise it is read beside `opts[:own_root]`,
  the `:daemon, :generation_root` app env (the test seam for "this node
  booted from a foreign release root"), or the node's own release root.
  Returns the pinned value.
  """
  @spec pin(keyword()) :: String.t()
  def pin(opts) when is_list(opts) do
    own = opts[:own] || Lifecycle.release_identity(own_root(opts))
    :persistent_term.put(@own_key, own)
    own
  end

  @doc """
  The calling node's pinned generation (listener-boot pin), or the identity
  of its own release root when nothing was pinned (in-VM callers, unit
  tests). The advertised `release` capability is always this value.
  """
  @spec own() :: String.t()
  def own do
    case :persistent_term.get(@own_key, nil) do
      nil -> Lifecycle.release_identity(own_root([]))
      own -> own
    end
  end

  @doc "Path of the installed release's `.built-from` stamp for `home`."
  @spec stamp_path(String.t()) :: String.t()
  def stamp_path(home) when is_binary(home) do
    Path.join([home | @installed_release_root] ++ [".built-from"])
  end

  @doc """
  The installed release's stamp for `home`: `{:ok, stamp}` when the stamp
  file is readable, `:none` when it cannot be read (absent, unreadable,
  torn) — the undecided case, never a guess.
  """
  @spec installed(String.t()) :: {:ok, String.t()} | :none
  def installed(home) when is_binary(home) do
    case File.read(stamp_path(home)) do
      {:ok, raw} -> {:ok, String.trim_trailing(raw)}
      {:error, _reason} -> :none
    end
  end

  @doc """
  The boot verdict: whether this node may bind the state socket at all.
  Strictly decidable — it fires only when BOTH the node's own root and the
  installed release carry readable stamps and they differ, the one
  combination that PROVES the node is not the installed generation. A
  node without its own stamp (dev/mix run) is undecided here: it is judged
  at the rendezvous instead, where serving actually happens.
  """
  @spec boot_verdict(String.t(), String.t()) ::
          :fresh | {:stale, String.t(), String.t()} | :undecided
  def boot_verdict(home, own_root) when is_binary(home) and is_binary(own_root) do
    own_stamp = read_stamp(own_root)
    installed_stamp = installed(home)

    with {:ok, own} <- own_stamp,
         {:ok, installed} <- installed_stamp do
      decide(own, installed)
    else
      :none -> :undecided
    end
  end

  @doc """
  The rendezvous verdict for `generation` (the caller's pinned generation —
  `own/0` in production) against the installed release serving `home`.
  This is the per-hello check: a readable installed stamp that differs
  from the pinned generation is a node the release changed under.
  """
  @spec verdict(String.t(), String.t()) :: verdict()
  def verdict(home, generation) when is_binary(home) do
    case installed(home) do
      {:ok, installed_stamp} -> decide(generation, installed_stamp)
      :none -> :undecided
    end
  end

  @doc "The rendezvous verdict against the daemon's pinned home (production form)."
  @spec verdict() :: verdict()
  def verdict, do: verdict(EngineState.home(), own())

  @doc """
  The one refusal wording for both wire ends (the daemon's `stale_generation`
  hello error and the client's ensure refusal): names both generations and
  the recovery, because the operator-facing message IS the contract.
  """
  @spec refusal_message(String.t(), String.t()) :: String.t()
  def refusal_message(own, installed) do
    "daemon is serving generation #{inspect(own)} but the installed release is " <>
      "#{inspect(installed)}; the daemon must be stopped so the client spawns " <>
      "the installed generation (`workstation daemon stop`, or re-run the verb — " <>
      "a refused daemon stops itself)"
  end

  @doc false
  @spec own_root(keyword()) :: String.t()
  def own_root(opts) when is_list(opts) do
    opts[:own_root] || Application.get_env(:daemon, :generation_root) ||
      :code.root_dir() |> to_string()
  end

  @doc "Clear the pinned generation (tests; a real daemon never unpins)."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@own_key)
    :ok
  end

  defp decide(own, installed) when own == installed, do: :fresh
  defp decide(own, installed), do: {:stale, own, installed}

  defp read_stamp(root) do
    case File.read(Path.join([root, ".built-from"])) do
      {:ok, raw} -> {:ok, String.trim_trailing(raw)}
      {:error, _reason} -> :none
    end
  end
end
