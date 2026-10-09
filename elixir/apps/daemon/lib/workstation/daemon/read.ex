defmodule Workstation.Daemon.Read do
  @moduledoc """
  The daemon-side read engine: `status`, `plan`, and `diff` evaluation
  behind the wire ops `status.run`, `plan.run`, `diff.run`.

  This is the single source of the read-side wire assembly (moved here from
  the CLI in the engine client/server refactor): the CLI daemon client
  routes every read verb through the daemon and renders the returned wire
  unchanged, so the daemon is the one place that composes the live catalog
  and reads journal state. The CLI keeps one in-process path — `--input`
  golden replay — which is offline by definition (it substitutes a recorded
  envelope for the live catalog and touches no daemon state) and delegates
  to this module with `input: {:file, envelope}` so both paths produce
  identical bytes.

  Without `input`, the evaluated catalog is the native live envelope
  (`Workstation.Core.Catalog.live/1`): the declared package registry with
  asset bodies inlined, host = the running platform, destinations re-rooted
  to the evaluated home. The daemon always serves its own pinned home (the
  home it booted with); ops carry no home parameter.

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
  brackets that variable around evaluation and restores the previous value,
  so an evaluation always sees exactly the selected home and never the
  ambient environment. The bracket is process-global and brief.
  """

  alias Workstation.Core.{Catalog, Changesets, Digest, EngineState, Journal}
  alias Workstation.Pipeline

  @engine_name "workstation"

  @status_schema "workstation.status.v1"
  @plan_schema "workstation.plan.v1"
  @diff_schema "workstation.diff.v1"

  @doc "Schema identifier of the hard-cut status wire."
  def status_schema, do: @status_schema

  @doc "Schema identifier of the hard-cut plan wire."
  def plan_schema, do: @plan_schema

  @doc "Schema identifier of the hard-cut diff wire."
  def diff_schema, do: @diff_schema

  @type input :: {:native, term()} | {:file, map()}

  @type error :: {:error, {:core, String.t()}} | {:error, {:engine, String.t()}}

  @doc """
  Evaluate one read command for `home`. Returns `{:ok, wire}` with the
  hard-cut schema for the command, or an error tagged `{:core, reason}`
  (bad envelope, conflict, invariant — the client's conflict-or-precondition
  exit) or `{:engine, reason}` (native catalog collection failure — the
  client's backend-or-engine exit).
  """
  @spec evaluate(atom(), String.t(), keyword()) :: {:ok, map()} | error()
  def evaluate(command, home, opts) when command in [:status, :plan, :diff] and is_list(opts) do
    expanded = Path.expand(home)

    with {:ok, input} <- load_input(opts[:input], expanded) do
      bracket(expanded, fn ->
        # A verb is a pipeline prefix: status runs to resolve (catalog +
        # graph), plan/diff to compose, and the mutation path continues the
        # same list through verify under the apply lock.
        run =
          Pipeline.run(
            %Pipeline.Run{input: input, mode: :read, home: expanded},
            Pipeline.verb_depth(command)
          )

        case command do
          :status -> status(expanded, run)
          :plan -> plan(expanded, run)
          :diff -> diff(run)
        end
      end)
    end
  end

  @doc """
  Build the status wire. `packages` are the collected envelope packages
  (id/requires/supported_hosts verbatim), `graph_order` the resolved
  package ids, `journal` the applied record or nil when nothing was ever
  applied, `taxonomy` the live catalog's package -> foundation declaration
  (descriptive metadata only; it never enters envelopes or plan bytes).
  """
  @spec status(String.t(), String.t(), String.t(), String.t(), [map()], [String.t()], map() | nil, %{
          String.t() => String.t()
        }) :: map()
  def status(engine_name, mode, destination, platform, packages, graph_order, journal, taxonomy) do
    %{
      "schema" => @status_schema,
      "engine" => %{"name" => engine_name, "version" => engine_version(), "mode" => mode},
      "destination" => destination,
      "platform" => platform,
      "packages" => packages,
      "graph_order" => graph_order,
      "taxonomy" => taxonomy,
      # Explicit null token: the canonical encoder drops literal nils, but
      # the status schema keeps journal present as JSON null when nothing
      # was ever applied.
      "journal" => (journal && journal_wire(journal)) || :null
    }
  end

  @doc """
  Build the plan wire. `plan_body` must already be the golden-verbatim
  projected view, `manifest` the plan manifest verbatim; `patches` and
  `target_states` are the b5 additions (changeset patches and the probed
  target states of every planned target).
  """
  @spec plan(String.t(), map(), [map()], [map()], map()) :: map()
  def plan(generation, plan_body, manifest, patches, target_states) do
    %{
      "schema" => @plan_schema,
      "generation" => generation,
      "plan" => plan_body,
      "manifest" => manifest,
      "patches" => patches,
      "target_states" => target_states
    }
  end

  @doc """
  Build the diff wire: `backend_diff` is the structured change-set record
  list verbatim (the records the goldens pin).
  `generation` is the desired generation the records were computed against.
  """
  @spec diff(String.t(), [map()]) :: map()
  def diff(generation, backend_diff) do
    %{
      "schema" => @diff_schema,
      "generation" => generation,
      "backend_diff" => backend_diff
    }
  end

  ## input collection

  # The evaluated input is either the live native catalog (the daemon's
  # default) or a decoded golden envelope (`input: {:file, envelope}` — the
  # CLI's offline replay path).
  defp load_input(nil, home) do
    {:ok, {:native, Catalog.live(home)}}
  rescue
    # Collection failures are engine failures, not core evaluation failures:
    # a missing engine checkout or an empty package asset is an integrity
    # problem in the engine source, not a bad user envelope.
    error in [ArgumentError] -> {:error, {:engine, Exception.message(error)}}
  end

  defp load_input({:file, decoded}, _home) when is_map(decoded), do: {:ok, {:file, decoded}}

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

  defp plan(home, run) do
    view = entry_view(run.plan)

    # The changeset builders keep explicit nil map values for their baseline
    # logic; a nil field does not exist on the wire, so
    # the emitted patches are pruned (the canonical encoder drops nothing
    # and fails closed on nil).
    patches = sweep(Changesets.plan_patches(view, nil))
    states = target_states(home, run.plan)

    {:ok,
     plan(
       run.plan.generation,
       sweep(project_plan(run.catalog, run.plan)),
       sweep(run.plan.manifest),
       patches,
       states
     )}
  end

  defp status(home, run) do
    packages =
      Enum.map(run.catalog.packages, fn package ->
        %{"id" => package.id, "requires" => package.requires}
        |> maybe_put("supported_hosts", Map.get(package, :supported_hosts))
      end)

    journal = journal_record()

    {:ok,
     status(
       @engine_name,
       "elixir",
       home,
       run.catalog.host,
       packages,
       Enum.map(run.graph.ordered, &Map.get(&1, :id)),
       journal,
       Catalog.Packages.taxonomy()
     )}
  end

  defp diff(run) do
    # A nil baseline resolves to the verified journal baseline inside the
    # bracket (which also lets changesets() pick up the verified baseline).
    records = sweep(Changesets.changesets(entry_view(run.plan), nil))
    {:ok, diff(run.plan.generation, records)}
  end

  # Prune nil map values recursively: on the wire nil == absent field, and
  # the canonical encoder fails closed on nil instead of dropping the key.
  defp sweep(value) when is_map(value) do
    value
    |> Enum.reject(fn {_key, inner} -> is_nil(inner) end)
    |> Map.new(fn {key, inner} -> {key, sweep(inner)} end)
  end

  defp sweep(value) when is_list(value), do: Enum.map(value, &sweep/1)
  defp sweep(value), do: value

  ## parity views

  # String-keyed superset view of one plan entry: everything the Changesets
  # functions read (bytes/source_name included — the golden view
  # deliberately drops them, so patches and diff records get their own view
  # instead of reshaping the recorded plan body).
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
  # in the entry view — the recorded envelope keeps an explicit null when
  # the entry has no mode, so the projection must emit :null, not drop the
  # key. Dropping it
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
      # The recorded envelope format has no distinct empty object: an empty
      # journal object is a JSON array in the goldens, so the
      # wire carries [] exactly like the engine's projection.
      "fragments_journal" =>
        if(core_plan.fragments_journal == %{}, do: [], else: core_plan.fragments_journal),
      "composed_profile" =>
        core_plan.profile && Enum.map(core_plan.profile, fn item -> %{"id" => item[:id]} end),
      "data" =>
        core_plan.data && %{"owner" => core_plan.data.owner, "bytes" => core_plan.data.bytes},
      "remove_file" => core_plan.remove_file,
      # The resolved package context (compose-stage, static layer) and the
      # typed mutation program the apply fold runs, in fold order: the live
      # wire declares both exactly like the recorded plan does.
      "context" => context_view(core_plan.context),
      "effects" => effects_view(core_plan)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # The resolved package context: per-package, dependency-scoped views —
  # the live wire declares them exactly like the recorded plan does. An
  # empty context is an ABSENT key (the recorded empty-object encodes as a
  # JSON array — the same empty-table quirk every other section dodges by
  # nil-dropping).
  defp context_view(context) do
    case context do
      m when m == %{} ->
        nil

      context ->
        Map.new(context, fn {package, keys} ->
          {package,
           Map.new(keys, fn {key, entry} ->
             {key, %{"schema" => entry.schema, "value" => entry.value}}
           end)}
        end)
    end
  end

  # One wire record per typed effect (contract, kind, ordering fields);
  # nil fields are absent keys like everywhere else on the wire.
  defp effects_view(plan) do
    Enum.map(Pipeline.effects(plan), fn effect ->
      %{
        "contract" => effect.contract,
        "kind" => to_string(effect.kind),
        "target" => effect[:target],
        "owner" => effect[:owner],
        "url" => effect[:url],
        "version" => effect[:version],
        "sha256" => effect[:sha256],
        "commit" => effect[:commit],
        "fingerprint" => effect[:fingerprint],
        "attribution" => effect[:attribution],
        "generation" => effect[:generation]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  # Target-state report, evaluated at this application
  # boundary: the plan itself never probes the filesystem (replay purity),
  # so the daemon owns the lstat and reports the actual pre-plan target
  # state.
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
  # (the write path chmods the existing final component —
  # runtime-root creation deliberately leaves it at 0755 until
  # the first apply). The daemon mirrors that repair at its application
  # boundary before the fail-closed read; a symlinked or foreign-owned
  # component is never chmod'ed here and still fails closed through
  # EngineState.verify_tree!/2.
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

  # On the wire a nil field does not exist: optional wire fields are omitted
  # rather than emitted as nulls.
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # The engine version is the release's CLI application version; outside a
  # release (dev/test) the placeholder keeps the schema total.
  defp engine_version, do: to_string(Application.spec(:cli, :vsn) || "0.0.0")

  defp journal_wire(journal) do
    %{"generation" => journal["generation"], "revision" => journal["revision"]}
    |> maybe_put("at", journal["at"])
  end
end
