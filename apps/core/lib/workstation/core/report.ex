defmodule Workstation.Core.Report do
  @moduledoc """
  Layer: kernel. The kernel law: this module names no package, no backend and
  no consumer — it reads the substrate's declared-state report and hands it
  to the read plane as validated data.

  The report is the engine's ONLY declared-state source: the flake's fold
  over the co-located capability modules (`flake.evalReport` — nix/report.nix),
  baked into the release by `nix/engine.nix`, so release and declared state
  ship from one flake snapshot and the daemon's reads are coherent by
  construction.

  Resolution: `WORKSTATION_REPORT` (a path — tests and dev) wins; else the
  release-relative `share/workstation/eval-report.json` (the release root is
  two levels above the `:cli` app's lib dir). An absent or malformed report
  is an engine failure (`ArgumentError`) — reads fail closed, never guess.

  Shape validation is structural (the fold's integrity assertions are the
  nix side; this side refuses to serve a report it cannot trust): counts,
  capabilityOrder, the accounting rows (id/foundation + list-valued
  surfaces), fragmentOrder and the target lists. The decoded report and its
  digest are cached per node (`:persistent_term`) — a release carries
  exactly one report per generation; tests override the cache with
  `put/2`-style seams through the env path instead.
  """

  @report_relative Path.join(["share", "workstation", "eval-report.json"])

  @type report :: map()

  @doc """
  The running platform's host name — the vocabulary the status wire serves
  ("linux" / "darwin"). Unsupported platforms fail closed instead of
  silently describing a host outside the support set.
  """
  @spec platform() :: String.t()
  def platform do
    case :os.type() do
      {:unix, :linux} -> "linux"
      {:unix, :darwin} -> "darwin"
      other -> raise ArgumentError, "unsupported platform: #{inspect(other)}"
    end
  end

  @doc "The resolved report path (the env override wins over the release bake)."
  @spec path() :: String.t()
  def path do
    case System.get_env("WORKSTATION_REPORT") do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _other -> release_report_path()
    end
  end

  @doc "The report bytes (read through the resolved path, fail-closed)."
  @spec bytes() :: String.t()
  def bytes do
    p = path()

    case File.read(p) do
      {:ok, bytes} when bytes != "" ->
        bytes

      {:ok, ""} ->
        raise ArgumentError, "the declared-state report is empty: #{p}"

      {:error, reason} ->
        raise ArgumentError,
              "no declared-state report at #{p} (#{inspect(reason)}) — the release bakes it " <>
                "at share/workstation/eval-report.json; dev and tests set WORKSTATION_REPORT"
    end
  end

  @doc """
  The decoded, structurally-validated report, cached per node. The digest
  (lowercase hex sha256 of the raw bytes — `digest/0`) is the plan
  generation: the declared state's content address.
  """
  @spec decoded() :: report()
  def decoded do
    {_raw, report, _digest} = cached()
    report
  end

  @doc "Lowercase hex sha256 of the report bytes — the plan generation id."
  @spec digest() :: String.t()
  def digest do
    {_raw, _report, digest} = cached()
    digest
  end

  @doc "Test/dev seam: force the cached report (and its digest) to explicit bytes."
  @spec put(String.t()) :: :ok
  def put(raw) when is_binary(raw) do
    report = decode!(raw)
    :persistent_term.put({__MODULE__, :report}, {raw, report, Workstation.Core.EngineState.sha256(raw)})
    :ok
  end

  @doc "Test seam: drop the cached report (the next read resolves afresh)."
  @spec clear() :: :ok
  def clear do
    :persistent_term.erase({__MODULE__, :report})
    :ok
  end

  defp cached do
    case :persistent_term.get({__MODULE__, :report}, :missing) do
      :missing ->
        raw = bytes()
        report = decode!(raw)
        entry = {raw, report, Workstation.Core.EngineState.sha256(raw)}
        :persistent_term.put({__MODULE__, :report}, entry)
        entry

      entry ->
        entry
    end
  end

  ## --- decoding + structural validation (fail-closed) ---

  defp decode!(raw) do
    case Workstation.Core.JSON.decode(raw) do
      {:ok, decoded} when is_map(decoded) ->
        validate!(decoded)
        decoded

      {:ok, _other} ->
        raise ArgumentError, "the declared-state report must be an object"

      {:error, :malformed} ->
        raise ArgumentError, "the declared-state report is not valid JSON"
    end
  end

  defp validate!(report) do
    list!(report, "fileTargetNames")
    list!(report, "claimTargets")
    list!(report, "capabilityOrder")
    list!(report, "fragmentOrder")
    is_map(report["counts"]) ||
      raise ArgumentError, "the declared-state report carries no counts object"

    Enum.each(report["capabilityOrder"], fn id ->
      is_binary(id) and id != "" ||
        raise ArgumentError, "capabilityOrder entries must be non-empty strings"
    end)

    Enum.each(report["fragmentOrder"], fn row ->
      is_map(row) and is_binary(row["target"]) and is_list(row["fragments"]) ||
        raise ArgumentError,
                "fragmentOrder rows must be {target, fragments} objects"
    end)

    list!(report, "accounting")

    Enum.each(report["accounting"], fn row ->
      is_map(row) or raise ArgumentError, "accounting rows must be objects"
      is_binary(row["id"]) or raise ArgumentError, "accounting rows must carry an id"
      is_binary(row["foundation"]) or raise ArgumentError, "accounting rows must carry a foundation"

      Enum.each(["fileTargets", "claimTargets", "fragments", "retire"], fn field ->
        is_list(row[field]) ||
          raise ArgumentError, "accounting row #{row["id"]} carries no #{field} list"
      end)
    end)

    :ok
  end

  defp list!(report, field) do
    is_list(report[field]) ||
      raise ArgumentError, "the declared-state report carries no #{field} list"
  end

  defp release_report_path do
    case :code.lib_dir(:cli) do
      {:error, _reason} ->
        raise ArgumentError,
              "no :cli application in the code path — the report resolves relative to " <>
                "the release layout; set WORKSTATION_REPORT for dev and tests"

      lib_dir ->
        lib_dir |> to_string() |> Path.join("../../#{@report_relative}") |> Path.expand()
    end
  end
end
