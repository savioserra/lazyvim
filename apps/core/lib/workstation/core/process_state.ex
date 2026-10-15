defmodule Workstation.Core.ProcessState do
  @moduledoc """
  Layer: kernel. The kernel law: this module names no package, no backend and no
  consumer -- it speaks only contracts and shapes (docs/architecture.md,
  "Module hierarchy & moduledoc conventions").
  The engine's one OS-process liveness verdict: `alive?/1` decides whether the
  process behind an OS pid is still running. Every probe that must not read a
  dead process as alive shares it — the stop confirmations' exit ladders and
  the lock judges (the runtime installer lock's staleness steal and the apply
  lock's takeover), whose posture is explicit: an unclear probe reads ALIVE,
  because a takeover must be provable, never probable.

  Why the verdict is not bare `kill -0`: existence is not liveness. A process
  that exited but awaits reap — a zombie (`Z`) — still has a `/proc` entry and
  still answers `kill -0`, so under a pid 1 that never reaps (containers,
  chroots: the 2026-10-15 bare-box rehearsal) the defunct entry outlives the
  death indefinitely. The kernel itself says what the process is: the
  `/proc/<pid>/stat` STATE character decides, and `Z` is EXITED — a zombie
  cannot run code, so it cannot serve, hold a lock or be wedged; it is dead
  for every purpose any caller has. `kill -0` decides only where the stat is
  unreadable (no `/proc` on macOS, hidepid, a pid that vanished mid-read), and
  there an inconclusive exit status reads ALIVE: a probe that cannot decide
  never manufactures a death — the worst case is one honest refusal or one
  bounded extra wait, never a stolen lock or a false "stopped".
  """

  @doc """
  The liveness verdict for one OS pid: `true` while the process is running,
  `false` once it has exited — a zombie is exited, not alive. Anything the
  probe cannot decide reads ALIVE (fail closed): a non-positive or
  non-numeric pid names no provable process, an unreadable stat defers to
  `kill -0`, and an inconclusive `kill -0` status defers to alive.
  """
  @spec alive?(integer() | String.t()) :: boolean()
  def alive?(pid) when is_integer(pid) and pid > 0, do: pid |> Integer.to_string() |> alive?()

  # A non-positive pid names no process this engine could own a verdict on:
  # no proof of death exists, so the answer is alive.
  def alive?(pid) when is_integer(pid), do: true

  def alive?(pid) when is_binary(pid) do
    if pid?(pid) do
      case File.read("/proc/#{pid}/stat") do
        {:ok, stat} ->
          case stat_alive?(stat) do
            nil -> kill_zero_alive?(pid)
            alive? -> alive?
          end

        {:error, _reason} ->
          kill_zero_alive?(pid)
      end
    else
      # A non-numeric pid names no process at all; no proof of death exists,
      # so the verdict is alive (a lock judge refuses, a wait keeps waiting).
      true
    end
  end

  @doc """
  The `/proc/<pid>/stat` verdict behind `alive?/1`: `false` when the state
  character is `Z` — a zombie has exited and only awaits reap — `true` for
  any other parseable state, `nil` when the stat text cannot be parsed (the
  caller falls back to the existence-only `kill -0` probe). Public because
  the zombie branch IS the contract this module carries, and its on-host
  verification is a state string, not a live process: a healthy pid 1 reaps,
  so the defunct shape of the defect (state `Z`, ppid 1, forever) only
  exists where the defect bites.
  """
  @spec stat_alive?(String.t()) :: boolean() | nil
  def stat_alive?(stat) do
    case proc_stat_state(stat) do
      nil -> nil
      "Z" -> false
      _state -> true
    end
  end

  # stat is `pid (comm) state ppid ...`; comm is free text that may itself
  # contain spaces and parentheses, so the state character sits after the
  # LAST `)` — none of the fields that follow contain one.
  defp proc_stat_state(stat) do
    case :binary.matches(stat, ")") do
      [] ->
        nil

      matches ->
        {pos, 1} = List.last(matches)
        rest = binary_part(stat, pos + 1, byte_size(stat) - pos - 1)

        case String.trim_leading(rest) do
          <<state, _tail::binary>> when state in ?A..?Z or state in ?a..?z -> <<state>>
          _other -> nil
        end
    end
  end

  # The fallback: `kill -0` delivers no signal, existence only. Exit 0 means
  # the probe could address the process (alive); exit 1 is its ESRCH-class
  # "no such process" (dead); anything else is inconclusive and reads ALIVE —
  # an unclear probe must never manufacture a death.
  defp kill_zero_alive?(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_out, 0} -> true
      {_out, 1} -> false
      {_out, _other} -> true
    end
  end

  defp pid?(pid), do: Regex.match?(~r/\A[0-9]+\z/, pid)
end
