defmodule Workstation.Core.Source do
  @moduledoc """
  The source assembler: composition root of the deterministic engine plan.

  The composition root that interprets validated recipes through the
  discovered providers, composes domain outputs before chezmoi
  source generation, detects ownership/path/attribute conflicts and produces
  the deterministic plan shared by diff, apply and plan previews. Core stays
  domain-neutral; this module owns the composition surface, and every
  provider on it is discovered, never registered.

  Replay purity: the golden contract records a fresh journal and no
  filesystem, so `plan/1` performs no I/O. Journal-based retirement
  reconciliation is journal-driven only; on-disk presence probing stays an
  application-boundary concern so a replay is a pure function of its input
  and the recorded generation ids stay machine-independent.
  """

  alias Workstation.Backends.Chezmoi
  alias Workstation.Core.Contracts.Download
  alias Workstation.Core.Digest
  alias Workstation.Core.Source.{Downloads, Entries, Manifest, Paths, Removals, Shell}

  # Domain-generic providers are wired directly into the assembler, but
  # the assembler names no provider id: the effect-contract surface
  # (`Workstation.Core.Contracts.Contract.Discover`) publishes the
  # domain-generic ids, and capability-specific providers are discovered
  # through the `Workstation.Core.Contracts.Provider` contract — a new
  # provider plugs in with zero edits to the assembler.

  defstruct entries: [],
            removals: [],
            declared_removals: [],
            unsupported_reversals: [],
            profile: nil,
            context: %{},
            fragments_journal: %{},
            remove_file: nil,
            journal_revision: 0,
            baseline_generation: nil,
            data: nil,
            downloads: [],
            manifest: [],
            generation: nil

  @type entry :: %{
          optional(:owner) => String.t(),
          optional(:provider) => String.t(),
          optional(:operation) => String.t(),
          optional(:target) => String.t(),
          optional(:source_name) => String.t(),
          optional(:type) => String.t(),
          optional(:mode) => non_neg_integer() | nil,
          optional(:bytes) => String.t() | nil,
          optional(:link) => String.t() | nil,
          optional(:exact) => boolean() | nil,
          optional(:template) => boolean() | nil,
          optional(:attribution) => [String.t()],
          optional(:fingerprint) => String.t(),
          optional(:shared) => boolean(),
          optional(:fragments) => [map()]
        }

  @type removal :: %{required(:target) => String.t(), required(:owner) => String.t()}

  @type context_view :: %{
          optional(String.t()) => %{
            required(:key) => String.t(),
            required(:schema) => pos_integer(),
            required(:value) => term()
          }
        }

  @type t :: %__MODULE__{
          entries: [entry()],
          removals: [removal()],
          declared_removals: [removal()],
          unsupported_reversals: [removal()],
          profile: [map()] | nil,
          context: %{optional(String.t()) => context_view()},
          fragments_journal: %{optional(String.t()) => [map()]},
          remove_file: String.t() | nil,
          journal_revision: non_neg_integer(),
          baseline_generation: String.t() | nil,
          data: %{required(:owner) => String.t(), required(:bytes) => String.t()} | nil,
          downloads: [map()],
          manifest: [map()],
          generation: String.t() | nil
        }

  @spec sha256(binary()) :: String.t()
  def sha256(data), do: Digest.sha256(data)

  @doc """
  Build the validated source plan for one resolved graph. Reads no journal,
  no package assets and no target metadata; performs no mutation.
  """
  @spec plan(%{required(:graph) => Workstation.Core.Graph.t()}) :: t()
  def plan(%{graph: graph}) do
    collected = collect(graph.ordered)
    context = resolve_context(graph.ordered)
    data = extract_data_envelope(collected)
    capability = compose_capability_profiles(collected)
    collected = collected ++ Enum.map(capability, &elem(&1, 0))
    profile = capability_profiles(capability)
    downloads = Downloads.compose(collected)
    # The golden replay always records against a fresh journal: applied_record
    # is nil, so no fragments are recorded and no retirements are reconciled.
    journal = nil
    ancestors = Entries.build_ancestors(collected)
    {shell_entries, fragments_journal} = Shell.compose_shell_entries(collected, journal, ancestors)
    {entries, removals} = Entries.build_entries(collected, ancestors)
    entries = Enum.sort_by(entries ++ shell_entries, & &1.source_name)
    {entries, _by_target} = detect_conflicts(entries, removals)
    # reconcile/2 with a fresh journal yields no retirements and no
    # unsupported reversals: nothing was ever applied, so nothing can retire.
    # Every declared removal literal is still validated: an ambiguous glob or
    # traversal is invalid regardless of current presence.
    Enum.each(removals, &Removals.validate_literal!(&1.target))

    # Active filtering with a fresh journal: a removal is active only when the
    # journal recorded it or the target is present in the destination home;
    # the pure core replay performs no filesystem probing, and a fresh journal
    # records nothing, so no declared removal can be active. The declared set
    # travels verbatim in `declared_removals` so the one production
    # composition boundary (`Workstation.Pipeline.composed_plan/2` through
    # `activate_removals/3`) can activate it where journal and home are both
    # readable.
    declared_removals = removals
    removals = []

    remove_additions = Enum.map(removals, & &1.target)

    # The complete final removal list — policy tombstones included — is
    # revalidated against active ownership: static aggregation gets no bypass.
    Enum.each(entries, fn entry ->
      Enum.each(removals, fn removal ->
        Paths.encompasses?(removal.target, entry.target) &&
          Paths.invalid!("final removal #{removal.target} overlaps owned target #{entry.target}")
      end)
    end)

    # Downloaded artifacts own their targets exclusively: a chezmoi entry or
    # a declared removal reaching the same path is a composition conflict,
    # checked before the plan exists so replay fails loudly.
    Downloads.check_conflicts(downloads, entries, declared_removals)

    plan = %__MODULE__{
      entries: entries,
      removals: removals,
      declared_removals: declared_removals,
      unsupported_reversals: [],
      profile: profile,
      context: context,
      fragments_journal: fragments_journal,
      remove_file: Workstation.Core.Policy.remove_file(remove_additions),
      journal_revision: 0,
      baseline_generation: nil,
      data: data,
      downloads: downloads
    }

    manifest = Manifest.build(plan.entries, pinned_files(plan))
    generation = Digest.sha256(Workstation.Core.CanonicalJSON.encode(manifest))
    %__MODULE__{plan | manifest: manifest, generation: generation}
  end

  # --- the package-context fold (compose-stage, static layer) ---

  # ONE topological pass over the resolver's order — dependencies fold
  # before dependents (cycles are already rejected upstream), ties resolve
  # by the graph's deterministic id sort. Each package's view contains ONLY
  # the keys it declared (least knowledge — the world context never leaks);
  # each consumed key's schema range must cover the exported schema.
  # Exports are declared pure data (Catalog.Spec validates the purity at the
  # declaration), so the fold is a pure function of (manifests, order):
  # same manifests + same graph => byte-identical context. Effect results
  # (the dynamic layer) flow only through the interpret fold's run_effect
  # returns and can never reach this fold — different stage, different
  # channel, no shared state.
  defp resolve_context(ordered) do
    {views, _world} =
      Enum.map_reduce(ordered, %{}, fn spec, world ->
        view =
          (Map.get(spec, :context_requires) || [])
          |> Enum.map(fn req ->
            case Map.fetch(world, req.key) do
              {:ok, export} ->
                Workstation.Core.Catalog.Spec.schema_covered?(export.schema, req.schema) ||
                  fail(
                    "#{spec.id} context_requires #{req.key} schema #{inspect(req.schema)} does not cover " <>
                      "the exported schema #{export.schema}"
                  )

                {req.key, %{key: req.key, schema: export.schema, value: export.value}}

              :error ->
                fail(
                  "#{spec.id} context_requires #{req.key}, but no dependency exports that key — " <>
                    "the dependency must declare an export under its own capability"
                )
            end
          end)
          |> Map.new()

        world =
          Enum.reduce(Map.get(spec, :exports) || [], world, fn export, world ->
            Map.put(world, export.key, export)
          end)

        {view, world}
      end)

    ordered
    |> Enum.zip(views)
    |> Map.new(fn {spec, view} -> {spec.id, view} end)
    |> Enum.reject(fn {_id, view} -> map_size(view) == 0 end)
    |> Map.new()
  end

  @doc """
  Stamp the plan with the journal baseline it was composed against (the
  changeset baseline: applied revision + generation read at plan
  build time). `plan/1` stays pure — a pure core replay probes no
  filesystem, and a fresh journal records nothing — so real appliers call
  this at the composition boundary with the journal record read at build
  time. The in-lock precondition check then compares this stamp against the
  current journal: a journal that advanced past the build refuses the apply
  as stale, while re-applying the identical desired generation stays an
  idempotent no-op. Without the stamp every real apply on a journaled home
  would refuse against the hardcoded `journal_revision: 0` default.
  """
  @spec with_baseline(t(), map() | nil) :: t()
  def with_baseline(%__MODULE__{} = plan, journal) do
    %{plan |
      journal_revision: (journal && journal["revision"]) || 0,
      baseline_generation: journal && journal["generation"]
    }
  end

  @doc """
  Activate a pure plan's declared removals at a REAL composition boundary.

  `plan/1` probes no filesystem, so every declared removal it composes stays
  inactive and the declared set travels verbatim in `declared_removals`. The
  one production composition — `Workstation.Pipeline.composed_plan/2` —
  calls this with the journal record read at build time and the destination
  home: a declared removal is active exactly when the journal recorded the
  target or the target is present in the home. The active set rebuilds the
  `.chezmoiremove` body, the manifest and the generation id (a change the
  pure plan cannot see), so the tombstone is a real engine mutation and not
  validated-but-inert dead text.
  """
  @spec activate_removals(t(), map() | nil, String.t()) :: t()
  def activate_removals(%__MODULE__{declared_removals: declared} = plan, journal, home)
      when is_binary(home) and home != "" do
    recorded = (is_map(journal) && Map.get(journal, "targets")) || %{}

    active =
      Enum.filter(declared, fn removal ->
        Map.has_key?(recorded, removal.target) or home_target_present?(home, removal.target)
      end)

    # The same static rule `plan/1` enforces against the declared set — an
    # active removal must not overlap a target the same composition still
    # owns — re-checked here so this boundary helper stays safe on its own.
    Enum.each(plan.entries, fn entry ->
      Enum.each(active, fn removal ->
        Paths.encompasses?(removal.target, entry.target) &&
          Paths.invalid!("final removal #{removal.target} overlaps owned target #{entry.target}")
      end)
    end)

    plan = %{plan | removals: active, remove_file: Workstation.Core.Policy.remove_file(Enum.map(active, & &1.target))}
    manifest = Manifest.build(plan.entries, pinned_files(plan))

    %{plan | manifest: manifest, generation: Digest.sha256(Workstation.Core.CanonicalJSON.encode(manifest))}
  end

  # Presence probing is lstat-shaped on purpose: a stale symlink still marks
  # a target as present even when it points nowhere. lstat does not follow
  # the link, so one guarded call answers for files, directories and
  # symlinks alike; failures mean absent, never skipped.
  defp home_target_present?(home, target) do
    match?({:ok, _stat}, File.lstat(Path.join(home, target)))
  end

  @doc """
  The pinned engine source-root bytes of one plan: the tombstone body, the
  optional data envelope and every download descriptor — manifest entries
  without being plan targets. The staged-generation writer reads this map;
  the names come from the backend module API and the download contract,
  never from a literal here.
  """
  @spec pinned_files(t()) :: [{String.t(), String.t()}]
  def pinned_files(plan) do
    # The source-root engine files (.chezmoiremove, the optional data
    # envelope) are manifest entries without being plan targets: they stage
    # with the generation and verify byte-for-byte, but never deploy into the
    # home. Download pins join them: each artifact's descriptor record is
    # content-addressed into the manifest, so the generation id changes
    # whenever a pin changes and the staged generation carries the provenance.
    base = [{Chezmoi.remove_filename(), plan.remove_file}]

    base =
      case plan.data do
        nil -> base
        data -> base ++ [{Chezmoi.data_filename(), data.bytes}]
      end

    base ++ Enum.map(plan.downloads, fn download -> {download.source_name, Download.pin_bytes(download)} end)
  end

  @doc """
  The composed capability profiles (ordered language entries, theme-derived
  surfaces, ...) for the plan, when any package contributed to a capability
  provider. Exposed separately from `plan/1` because it is a read-side
  projection, not part of the recorded plan body.
  """
  def composed_profile(plan), do: plan.profile

  # --- collection ---

  defp collect(ordered) do
    # ONE discovery pass per composition: the generic (effect-contract) id
    # set is derived once and the per-recipe check stays a map lookup —
    # discovery scans the whole code path, so it must never run per recipe.
    generic_ids = MapSet.new(Map.keys(Workstation.Core.Contracts.Contract.Discover.by_id()))

    Enum.flat_map(ordered, fn specification ->
      Enum.map(Map.get(specification, :contributes) || [], fn recipe ->
        known_provider?(recipe.provider, generic_ids) ||
          fail("#{specification.id} declares unknown provider #{recipe.provider}")

        %{owner: specification.id, provider: recipe.provider, spec: recipe.spec}
      end)
    end)
  end

  # A recipe provider is known when discovery finds an implementor: the
  # effect-contract surface publishes the domain-generic ids, and the
  # capability contract publishes the package-owned ones.
  defp known_provider?(provider, generic_ids) do
    MapSet.member?(generic_ids, provider) or
      match?({:ok, _module}, Workstation.Core.Contracts.Provider.Discover.lookup(provider))
  end

  # At most one package may declare the .chezmoidata.toml envelope: the
  # source-root name is shared engine state, not a composable target, so two
  # declarers could only fight over one file.
  defp extract_data_envelope(collected) do
    records = Enum.filter(collected, &(&1.provider == Chezmoi.data_provider_id()))

    case records do
      [] ->
        nil

      [record] ->
        content = record.spec.content
        %{owner: record.owner, bytes: content}

      _ ->
        fail("at most one package may declare the backend data envelope")
    end
  end

  # Capability-provider composition is fully contract-driven: for each
  # discovered provider id (deterministic module order — provider ids are
  # unique), hand it the collected intents in graph order and splice its
  # returned source record back into the collection. No capability is named
  # here; a package gains capability composition by implementing the
  # behaviour, never by editing this module.
  defp compose_capability_profiles(collected) do
    Workstation.Core.Contracts.Provider.Discover.by_id()
    |> Enum.sort_by(fn {id, _module} -> id end)
    |> Enum.flat_map(fn {id, module} ->
      intents =
        collected
        |> Enum.filter(&(&1.provider == id))
        |> Enum.map(&%{owner: &1.owner, spec: &1.spec})

      case intents do
        [] -> []
        _intents -> [module.compose(intents)]
      end
    end)
  end

  defp capability_profiles(capability) do
    case Enum.flat_map(capability, &elem(&1, 1)) do
      [] -> nil
      profiles -> profiles
    end
  end

  # --- conflicts ---

  defp directory_attributes(entry) do
    "#{entry.operation}|#{entry.mode || ""}|#{if entry.template, do: "tmpl", else: "plain"}|#{to_string(entry.exact)}"
  end

  defp detect_conflicts(entries, removals) do
    {by_target, merged} =
      Enum.reduce(entries, {%{}, []}, fn entry, {by_target, merged} ->
        case Map.get(by_target, entry.target) do
          nil ->
            {Map.put(by_target, entry.target, entry), merged ++ [entry]}

          existing ->
            # Only compatible shared-parent directory declarations may merge.
            unless entry.operation == "directory" and existing.operation == "directory" do
              fail(
                "duplicate exclusive target #{entry.target} owned by " <>
                  Enum.join(existing.attribution, ",") <> " and " <> Enum.join(entry.attribution, ",")
              )
            end

            unless directory_attributes(existing) == directory_attributes(entry) do
              fail("incompatible directory attributes for #{entry.target}")
            end

            # Merged attribution is a set of owners, recorded in one canonical
            # order: duplicated targets share an identical source name, whose
            # relative position after the by-name sort is unspecified, so the
            # merge must not leak that arbitrary order into the plan.
            owners = Enum.uniq(existing.attribution ++ entry.attribution) |> Enum.sort()
            existing = Map.put(existing, :attribution, owners)
            {Map.put(by_target, entry.target, existing), merged}
        end
      end)

    by_target
    |> Map.values()
    |> Enum.each(fn entry ->
      # Ancestor type conflicts: no leaf may be declared under a non-directory.
      walk_prefixes(entry.target, fn prefix ->
        case Map.get(by_target, prefix) do
          %{operation: operation} when operation != "directory" ->
            fail("#{prefix} is declared as #{operation} but also contains #{entry.target}")

          _ ->
            :ok
        end
      end)

      if Map.get(entry, :exact) == true do
        # Exact containers require a single explicit owner, may never
        # encompass engine-private state, and may only contain children of
        # that same owner: the backend prunes anything else inside them.
        unless length(entry.attribution) == 1 do
          fail("exact directory #{entry.target} requires exactly one owner")
        end

        not Paths.encompasses?(entry.target, Paths.engine_state_target()) ||
          Paths.invalid!("exact directory #{entry.target} encompasses engine-private state")

        owner = hd(entry.attribution)

        Enum.each(by_target, fn {other, other_entry} ->
          if other != entry.target and encompasses(entry.target, other) do
            unless hd(other_entry.attribution) == owner do
              fail(
                "exact directory #{entry.target} (owner #{owner}) contains cross-owner target #{other} " <>
                  "(owner #{hd(other_entry.attribution)})"
              )
            end
          end
        end)
      end
    end)

    # Native-name collisions: two different logical targets must never encode
    # to one source path, and an encoded ancestor must not collide with a
    # non-directory encoded entry.
    {by_name, _} =
      Enum.reduce(merged, {%{}, %{}}, fn entry, {by_name, seen} ->
        if Map.has_key?(by_name, entry.source_name) do
          existing = Map.fetch!(by_name, entry.source_name)

          fail(
            "native source name collision: #{existing.target} and #{entry.target} both encode to #{entry.source_name}"
          )
        end

        {Map.put(by_name, entry.source_name, entry), Map.put(seen, entry.source_name, true)}
      end)

    Enum.each(by_name, fn {name, _entry} ->
      walk_prefixes(name, fn prefix ->
        case Map.get(by_name, prefix) do
          %{type: declared_type} when declared_type != "directory" and declared_type != "modify" ->
            fail(
              "native source name #{prefix} is both a #{declared_type} and a required parent directory of #{name}"
            )

          _ ->
            :ok
        end
      end)
    end)

    Enum.each(removals, fn removal ->
      :ok = Paths.assert_not_engine_state!(removal.target)
      not Paths.encompasses?(removal.target, Paths.engine_state_target()) ||
        Paths.invalid!("removal of #{removal.target} encompasses engine-private state")

      Enum.each(by_target, fn {target, _entry} ->
        encompasses(removal.target, target) && fail("removal of #{removal.target} overlaps owned target #{target}")
      end)
    end)

    # Replace the plan's entry list with the merged one, keeping the merged
    # list position of each first declaration.
    entries = Enum.map(merged, &Map.get(by_target, &1.target, &1))
    {entries, by_target}
  end

  defp walk_prefixes(target, fun) do
    case String.contains?(target, "/") do
      false ->
        :ok

      true ->
        prefix = target |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
        fun.(prefix)
        walk_prefixes(prefix, fun)
    end
  end

  # The path algebra lives in `Workstation.Core.Source.Paths` (shared by the
  # data shapes); these thin aliases keep the conflict-law sentences on this
  # side dense and readable.
  defp encompasses(ancestor, target), do: Paths.encompasses?(ancestor, target)

  defp fail(message), do: Paths.invalid!(message)
end
