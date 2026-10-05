defmodule Workstation.CLI.Core do
  @moduledoc """
  In-process core evaluation path — the CLI's only front end.

  Without `--input`, the evaluated catalog is the native live envelope
  (`Workstation.Core.Catalog.live/1`): the declared package registry with
  asset bodies inlined, host = the running platform, destinations re-rooted
  to the evaluated home. With `--input <path>` the envelope is read from
  the file instead (offline golden replay); evaluation is then fully
  offline and file-driven, which is what the golden parity tests rely on —
  tests never compose the live catalog.

  Parity anchors (kept byte-identical across the whole recorded matrix,
  tests/goldens/<profile>):

    * plan body — the recorded `plan.json` projection, as proven by
      `Workstation.Core.GoldenReplayTest`; the projection below produces
      exactly those bytes (nil fields dropped, empty maps kept as maps,
      modes as four-digit octal strings).
    * patches / diff records — `Workstation.Core.Changesets`, fed the same
      entry view the recorded changesets consume (string-keyed entries
      carrying `bytes`/`source_name`, not the dropped-fields golden view).
    * target states — lstat no-follow per planned target, `absent` /
      `link -> dest` / `type mode-octal`.

  State-root bracketing: the core reads journal state through
  `Workstation.Core.EngineState.home/0` (`WORKSTATION_HOME`). This module
  brackets that variable around core evaluation and restores the previous
  value, so an evaluation always sees exactly the selected `--home` and
  never the operator's real state root. The bracket is process-global and
  brief.
  """

  alias Workstation.CLI.Output
  alias Workstation.Core.{Catalog, Changesets, Digest, EngineState, Graph, Journal, Source}

  @engine_name "workstation"

  @type error :: {:error, {:core, String.t()}} | {:error, {:engine, term()}}

  @doc """
  Evaluate one command through the Elixir core. Returns `{:ok, wire}` with
  the hard-cut `Workstation.CLI.Output` schema for the command, or an error
  tagged `{:core, reason}` (bad envelope, conflict, invariant — the
  caller's conflict-or-precondition exit) or `{:engine, reason}` (native
  catalog collection failure — the caller's backend-or-engine exit).
  """
  @spec evaluate(atom(), String.t(), keyword()) :: {:ok, map()} | error()
  def evaluate(command, home, opts) when command in [:status, :plan, :diff] do
    expanded = Path.expand(home)

    with {:ok, input} <- load_input(opts[:input], expanded) do
      bracket(expanded, fn ->
        case command do
          :status -> status(expanded, input)
          :plan -> plan(expanded, input)
          :diff -> diff(input)
        end
      end)
    end
  end

  ## input collection

  # The evaluated input is either the live native catalog (no --input) or a
  # decoded golden envelope read from --input (offline replay).
  defp load_input(nil, home) do
    {:ok, {:native, Catalog.live(home)}}
  rescue
    # Collection failures are engine failures, not core evaluation failures:
    # a missing engine checkout or an empty package asset is an integrity
    # problem in the engine source, not a bad user envelope.
    error in [ArgumentError] -> {:error, {:engine, Exception.message(error)}}
  end

  defp load_input(input_path, _home) when is_binary(input_path) do
    path = Path.expand(input_path)

    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      {:ok, {:file, decoded}}
    else
      {:error, %Jason.DecodeError{} = reason} ->
        {:error, {:core, "invalid input envelope #{path}: #{Exception.message(reason)}"}}

      {:error, reason} ->
        {:error, {:core, "cannot read input envelope #{path}: #{inspect(reason)}"}}
    end
  end

  ## state-root bracket

  defp bracket(home, fun) do
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    try do
      fun.()
    rescue
      error -> {:error, {:core, Exception.message(error)}}
    after
      restore_state_root(previous)
    end
  end

  defp restore_state_root(nil), do: System.delete_env("WORKSTATION_HOME")
  defp restore_state_root(previous), do: System.put_env("WORKSTATION_HOME", previous)

  ## pipelines

  defp replay({:file, input}), do: compose(Catalog.load(input))

  defp replay({:native, catalog}), do: compose(catalog)

  defp compose(catalog) do
    graph =
      Graph.order(%{
        host: catalog.host,
        specifications: catalog.packages
      })

    {:ok, catalog, graph, Source.plan(%{graph: graph})}
  end

  defp plan(home, input) do
    with {:ok, catalog, _graph, core_plan} <- replay(input) do
      view = entry_view(core_plan)

      # The changeset builders mirror post-decode Lua shapes and keep
      # explicit nil map values; a nil field does not exist on the wire, so
      # the emitted patches are pruned (the canonical encoder drops nothing
      # and fails closed on nil).
      patches = sweep(Changesets.plan_patches(view, nil))
      states = target_states(home, core_plan)

      {:ok,
       Output.plan(
         core_plan.generation,
         sweep(project_plan(catalog, core_plan)),
         sweep(core_plan.manifest),
         patches,
         states
       )}
    end
  end

  defp status(home, input) do
    with {:ok, catalog, graph, _core_plan} <- replay(input) do
      packages =
        Enum.map(catalog.packages, fn package ->
          %{"id" => package.id, "requires" => package.requires}
          |> maybe_put("supported_hosts", Map.get(package, :supported_hosts))
        end)

      journal = journal_record()

      {:ok,
       Output.status(
         @engine_name,
         "elixir",
         home,
         catalog.host,
         packages,
         Enum.map(graph.ordered, &Map.get(&1, :id)),
         journal
       )}
    end
  end

  defp diff(input) do
    with {:ok, _catalog, _graph, core_plan} <- replay(input) do
      # A nil baseline resolves to the verified journal baseline inside the
      # bracket, mirroring the Lua reporter's diff payload (which also lets
      # changesets() pick up the verified baseline).
      records = sweep(Changesets.changesets(entry_view(core_plan), nil))
      {:ok, Output.diff(core_plan.generation, records)}
    end
  end

  # Prune nil map values recursively: the changeset builders mirror
  # post-decode Lua shapes (nil == absent field), and the canonical encoder
  # fails closed on nil instead of dropping the key.
  defp sweep(value) when is_map(value) do
    value
    |> Enum.reject(fn {_key, inner} -> is_nil(inner) end)
    |> Map.new(fn {key, inner} -> {key, sweep(inner)} end)
  end

  defp sweep(value) when is_list(value), do: Enum.map(value, &sweep/1)
  defp sweep(value), do: value

  ## parity views

  # String-keyed superset view of one plan entry: everything the Lua-shaped
  # Changesets functions read (bytes/source_name included — the golden view
  # deliberately drops them, so patches and diff records get their own view
  # instead of reshaping the parity-locked plan body).
  defp entry_view(core_plan) do
    entries =
      Enum.map(core_plan.entries, fn entry ->
        %{
          "owner" => entry.owner,
          "attribution" => entry.attribution,
          "provider" => Map.get(entry, :provider),
          "operation" => Map.get(entry, :operation),
          "target" => Map.get(entry, :target),
          "source_name" => entry.source_name,
          "type" => Map.get(entry, :type),
          "mode" => Map.get(entry, :mode),
          "bytes" => Map.get(entry, :bytes),
          "link" => Map.get(entry, :link),
          "shared" => Map.get(entry, :shared),
          "fingerprint" => Map.get(entry, :fingerprint)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
      end)

    # The .chezmoiremove aggregate in Changesets reads remove_file whenever a
    # journal baseline exists (real hosts, unlike fresh sandbox journals,)
    # so the entry view must carry it: Source.plan always sets a binary body
    # (Policy.remove_file), and a missing key would fail closed as "plan
    # remove_file must be a string" on every journaled home.
    %{"entries" => entries, "remove_file" => core_plan.remove_file}
  end

  # The recorded view of the plan (proven byte-identical by
  # Workstation.Core.GoldenReplayTest): a nil field is an absent key, an
  # explicit JSON null stays null, and entry modes are four-digit octal
  # strings. Profile and host come from the catalog envelope, never from the
  # plan struct (the core plan does not carry the envelope identity).
  #
  # One recorded exception to the nil-drops rule: `mode` is ALWAYS present
  # in the entry view — golden.lua kept an explicit vim.NIL when the entry
  # has no mode, so the port must emit :null, not drop the key. Dropping it
  # silently diverges from the recorded bytes on profiles whose entries can
  # be mode-less (caught by the b8 old-vs-new harness on full-home/theme
  # after the per-profile golden test missed it: the test carried its own
  # projection copy, so only a production-vs-golden comparison catches drift
  # here).
  defp project_plan(catalog, core_plan) do
    entries =
      core_plan.entries
      |> Enum.map(fn entry ->
        %{
          "name" => entry.source_name,
          "target" => entry.target,
          "operation" => entry.operation,
          "type" => entry.type,
          "mode" =>
            if(Map.get(entry, :mode), do: octal(Map.get(entry, :mode)), else: :null),
          "attribution" => entry.attribution,
          "bytes_sha256" =>
            case Map.get(entry, :bytes) do
              nil -> nil
              bytes -> Digest.sha256(bytes)
            end,
          "fingerprint" => Map.get(entry, :fingerprint),
          "link" => Map.get(entry, :link),
          "exact" => Map.get(entry, :exact),
          "template" => Map.get(entry, :template)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
      end)
      |> Enum.sort_by(& &1["name"])

    %{
      "profile" => catalog.profile,
      "host" => catalog.host,
      "journal_revision" => core_plan.journal_revision,
      # The recorded explicit null: a fresh journal has no baseline, and the
      # golden body keeps the key with a JSON null (:null — a literal nil
      # would make the canonical encoder drop the key).
      "baseline_generation" => core_plan.baseline_generation || :null,
      "entries" => entries,
      "removals" =>
        Enum.map(core_plan.removals, fn removal ->
          %{"owner" => removal.owner, "target" => removal.target}
        end),
      "unsupported_reversals" =>
        Enum.map(core_plan.unsupported_reversals, fn reversal ->
          %{"owner" => reversal.owner, "target" => reversal.target}
        end),
      # The recorded view is Lua-shaped: an empty journal object is a JSON
      # array in the goldens (a Lua table cannot distinguish the two), so the
      # wire carries [] exactly like the engine's projection.
      "fragments_journal" =>
        if(core_plan.fragments_journal == %{}, do: [], else: core_plan.fragments_journal),
      "composed_profile" =>
        core_plan.profile && Enum.map(core_plan.profile, fn item -> %{"id" => item[:id]} end),
      "data" =>
        core_plan.data && %{"owner" => core_plan.data.owner, "bytes" => core_plan.data.bytes},
      "remove_file" => core_plan.remove_file
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # changesets.lua describe_target_state, evaluated at this application
  # boundary: the plan itself never probes the filesystem (replay purity),
  # so the CLI owns the lstat and reports the actual pre-plan target state.
  defp target_states(home, core_plan) do
    targets = Enum.map(core_plan.entries, & &1.target) ++ Enum.map(core_plan.removals, & &1.target)
    Map.new(targets, fn target -> {target, describe_target_state(EngineState.join_home(home, target))} end)
  end

  defp describe_target_state(path) do
    case EngineState.lstat(path) do
      nil ->
        "absent"

      %{type: "symlink"} ->
        case :file.read_link(path) do
          {:ok, dest} -> "link -> " <> to_string(dest)
          {:error, _reason} -> "link"
        end

      %{type: type, mode: mode} ->
        "#{type} #{Integer.to_string(mode, 8)}"
    end
  end

  defp octal(mode), do: mode |> Integer.to_string(8) |> String.pad_leading(4, "0")

  # The engine repairs the state root to 0700 on every journal access
  # (state.lua guarded_directory chmods the existing final component — the
  # runtime-root creation in paths.lua deliberately leaves it at 0755 until
  # the first apply). The CLI mirrors that repair at its application boundary
  # before the fail-closed read; a symlinked or foreign-owned component is
  # never chmod'ed here and still fails closed through EngineState.verify_tree!/2.
  defp journal_record do
    state_root = EngineState.state_root()

    case EngineState.lstat(state_root) do
      %{type: "directory", uid: uid} ->
        # Guard cannot call uid/0 (remote call): compare in the body.
        if uid == EngineState.uid(), do: File.chmod!(state_root, 0o700)

      _other ->
        :ok
    end

    Journal.applied(state_root)
  end

  # Canonical JSON drops nil map values (a Lua nil field does not exist), so
  # optional wire fields are omitted rather than emitted as nulls.
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
