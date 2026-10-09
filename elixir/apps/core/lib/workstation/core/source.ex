defmodule Workstation.Core.Source do
  @moduledoc """
  The source assembler: composition root of the deterministic engine plan.

  The composition root that interprets validated recipes through the
  explicitly registered providers, composes domain outputs before chezmoi
  source generation, detects ownership/path/attribute conflicts and produces
  the deterministic plan shared by diff, apply and plan previews. Core stays
  domain-neutral; this module owns the registry.

  Replay purity: the golden contract records a fresh journal and no
  filesystem, so `plan/1` performs no I/O. Journal-based retirement
  reconciliation is journal-driven only; on-disk presence probing stays an
  application-boundary concern so a replay is a pure function of its input
  and the recorded generation ids stay machine-independent.
  """

  alias Workstation.Core.Digest
  alias Workstation.Core.Source.Chezmoi
  alias Workstation.Core.Source.Download
  alias Workstation.Core.Source.Manifest
  alias Workstation.Core.Source.Shell

  # Domain-generic providers are wired directly into the assembler; their
  # wire ids live in the backend modules (`Chezmoi.provider_id/0`,
  # `Shell.provider_id/0`). Capability-specific providers are NOT listed
  # here — they are discovered through the `Workstation.Core.Source.Provider`
  # contract, so the assembler never names a capability.
  defp generic_providers do
    %{
      Chezmoi.provider_id() => true,
      Chezmoi.data_provider_id() => true,
      Shell.provider_id() => true,
      Download.provider_id() => true
    }
  end

  @engine_state_target ".local/state/workstation"

  defstruct entries: [],
            removals: [],
            declared_removals: [],
            unsupported_reversals: [],
            profile: nil,
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

  @type t :: %__MODULE__{
          entries: [entry()],
          removals: [removal()],
          declared_removals: [removal()],
          unsupported_reversals: [removal()],
          profile: [map()] | nil,
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
    data = extract_data_envelope(collected)
    capability = compose_capability_profiles(collected)
    collected = collected ++ Enum.map(capability, &elem(&1, 0))
    profile = capability_profiles(capability)
    downloads = compose_downloads(collected)
    # The golden replay always records against a fresh journal: applied_record
    # is nil, so no fragments are recorded and no retirements are reconciled.
    journal = nil
    ancestors = build_ancestors(collected)
    {shell_entries, fragments_journal} = compose_shell_entries(collected, journal, ancestors)
    {entries, removals} = build_entries(collected, ancestors)
    entries = Enum.sort_by(entries ++ shell_entries, & &1.source_name)
    {entries, _by_target} = detect_conflicts(entries, removals)
    # reconcile/2 with a fresh journal yields no retirements and no
    # unsupported reversals: nothing was ever applied, so nothing can retire.
    # Every declared removal literal is still validated: an ambiguous glob or
    # traversal is invalid regardless of current presence.
    Enum.each(removals, &validate_removal_literal(&1.target))

    # Active filtering with a fresh journal: a removal is active only when the
    # journal recorded it or the target is present in the destination home;
    # the pure core replay performs no filesystem probing, and a fresh journal
    # records nothing, so no declared removal can be active. The declared set
    # travels verbatim in `declared_removals` so the one production
    # composition boundary (`Workstation.Core.Plan.composed_plan/2` through
    # `activate_removals/3`) can activate it where journal and home are both
    # readable.
    declared_removals = removals
    removals = []

    remove_additions = Enum.map(removals, & &1.target)

    # The complete final removal list — policy tombstones included — is
    # revalidated against active ownership: static aggregation gets no bypass.
    Enum.each(entries, fn entry ->
      Enum.each(removals, fn removal ->
        encompasses(removal.target, entry.target) &&
          fail("final removal #{removal.target} overlaps owned target #{entry.target}")
      end)
    end)

    # Downloaded artifacts own their targets exclusively: a chezmoi entry or
    # a declared removal reaching the same path is a composition conflict,
    # checked before the plan exists so replay fails loudly.
    check_download_conflicts(downloads, entries, declared_removals)

    plan = %__MODULE__{
      entries: entries,
      removals: removals,
      declared_removals: declared_removals,
      unsupported_reversals: [],
      profile: profile,
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

  @doc """
  Stamp the plan with the journal baseline it was composed against (the Lua
  anchor's changeset baseline: applied revision + generation read at plan
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
  one production composition — `Workstation.Core.Plan.composed_plan/2` —
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
        encompasses(removal.target, entry.target) &&
          fail("final removal #{removal.target} overlaps owned target #{entry.target}")
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

  defp pinned_files(plan) do
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
  provider. Exposed separately from `plan/1` because the Lua engine writes
  it into the caller's context rather than into the plan view.
  """
  def composed_profile(plan), do: plan.profile

  # --- collection ---

  defp collect(ordered) do
    Enum.flat_map(ordered, fn specification ->
      Enum.map(Map.get(specification, :contributes) || [], fn recipe ->
        known_provider?(recipe.provider) ||
          fail("#{specification.id} declares unknown provider #{recipe.provider}")

        %{owner: specification.id, provider: recipe.provider, spec: recipe.spec}
      end)
    end)
  end

  defp known_provider?(provider) do
    Map.has_key?(generic_providers(), provider) or
      match?({:ok, _module}, Workstation.Core.Source.Provider.Discover.lookup(provider))
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
    Workstation.Core.Source.Provider.Discover.by_id()
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

  # --- download composition ---

  # Pinned artifacts are validated at composition: every record is a
  # validated recipe and the plan carries the derived fingerprint and the
  # staged descriptor name. The fetch itself never happens at plan time —
  # the pure pipeline performs no I/O.
  defp compose_downloads(collected) do
    collected
    |> Enum.filter(&(&1.provider == Download.provider_id()))
    |> Enum.map(fn record ->
      spec = record.spec
      :ok = Download.validate(spec)

      %{
        owner: record.owner,
        target: spec.target,
        url: spec.url,
        version: spec.version,
        sha256: spec.sha256,
        fingerprint: Download.fingerprint(spec),
        source_name: Download.pin_source_name(spec)
      }
    end)
    |> Enum.reduce({[], MapSet.new()}, fn download, {downloads, seen} ->
      if MapSet.member?(seen, download.target) do
        fail("duplicate download target #{download.target}: one artifact target may have only one owner")
      end

      {downloads ++ [download], MapSet.put(seen, download.target)}
    end)
    |> elem(0)
  end

  defp check_download_conflicts(downloads, entries, removals) do
    Enum.each(downloads, fn download ->
      Enum.each(entries, fn entry ->
        overlapping =
          download.target == entry.target or encompasses(download.target, entry.target) or
            encompasses(entry.target, download.target)

        overlapping &&
          fail(
            "download target #{download.target} overlaps owned target #{entry.target} " <>
              "(#{Enum.join(entry.attribution, ",")})"
          )
      end)

      Enum.each(removals, fn removal ->
        not encompasses(removal.target, download.target) ||
          fail("declared removal #{removal.target} overlaps download target #{download.target}")
      end)
    end)
  end

  defp build_ancestors(collected) do
    Enum.reduce(collected, %{}, fn record, ancestors ->
      if record.provider == Chezmoi.provider_id() and record.spec.kind == :directory do
        :ok = Chezmoi.validate_spec(record.spec)

        existing = Map.get(ancestors, record.spec.target)

        if existing != nil and (existing.exact != record.spec.exact or existing.private != record.spec.private) do
          fail("incompatible directory attributes for #{record.spec.target}")
        end

        Map.put(ancestors, record.spec.target, %{exact: record.spec.exact, private: record.spec.private})
      else
        ancestors
      end
    end)
  end

  # --- shell composition ---

  # Group shell fragments per shared target in collection order; explicit
  # fragment order keys plus graph-order tie-breaking keep output stable.
  # One marker on one target can only ever have one owning fragment id.
  defp desired_fragments(collected) do
    collected
    |> Enum.filter(&(&1.provider == Shell.provider_id()))
    |> Enum.with_index(1)
    |> Enum.reduce({%{}, 0}, fn {record, sequence}, {grouped, _} ->
      :ok = Shell.validate_spec(record.spec)
      assert_not_engine_state(record.spec.target)
      target = record.spec.target

      group =
        Map.get_lazy(grouped, target, fn -> %{target: target, fragments: [], owners: []} end)

      fragment = %{
        id: record.spec.fragment.id,
        marker: record.spec.fragment.marker,
        body: record.spec.fragment.body,
        order: record.spec.fragment.order,
        owner: record.owner,
        sequence: sequence
      }

      group = %{
        target: target,
        fragments: group.fragments ++ [fragment],
        owners: group.owners ++ [record.owner]
      }

      {Map.put(grouped, target, group), sequence}
    end)
    |> elem(0)
    |> Enum.map(fn {target, group} ->
      fragments =
        Enum.sort_by(group.fragments, fn fragment -> {fragment.order, fragment.sequence} end)

      ids = MapSet.new(Enum.map(fragments, & &1.id))

      if MapSet.size(ids) != length(fragments) do
        fail("duplicate shell fragment id on #{target}")
      end

      seen =
        Enum.reduce(fragments, MapSet.new(), fn fragment, seen ->
          if MapSet.member?(seen, fragment.marker) do
            fail(
              "duplicate shell marker #{fragment.marker} on #{target} is owned by both " <>
                "an earlier fragment and #{fragment.id}"
            )
          end

          MapSet.put(seen, fragment.marker)
        end)

      _ = seen

      {target, %{group | fragments: fragments}}
    end)
    |> Map.new()
  end

  defp compose_shell_entries(collected, journal, ancestors) do
    grouped = desired_fragments(collected)

    # Targets whose every recorded fragment disappeared still need one final
    # recomposition so their exact known blocks are removed; leftover managed
    # shell lines are not inert and stopping source management is not removal.
    grouped =
      case journal && journal.fragments do
        nil -> grouped
        recorded -> Enum.reduce(recorded, grouped, fn {target, applied}, acc ->
          if Map.has_key?(acc, target) or applied == [] do
            acc
          else
            Map.put(acc, target, %{target: target, fragments: [], owners: []})
          end
        end)
      end

    Enum.map_reduce(grouped, %{}, fn {target, group}, fragments_journal ->
      recorded = (journal && journal.fragments && Map.get(journal.fragments, target)) || %{}
      {program, _ids} = Shell.compose(target, group.fragments, recorded)

      recipe =
        Chezmoi.recipe(%{target: target, kind: :modify, executable: true, content: program})

      entry = %{
        owner: "shell",
        provider: Chezmoi.provider_id(),
        operation: "modify",
        target: target,
        source_name: Chezmoi.source_name(recipe, ancestors),
        type: "modify",
        mode: Chezmoi.entry_mode(recipe),
        bytes: program,
        shared: true,
        attribution: group.owners,
        fragments: group.fragments
      }

      # Journal records mirror source.lua's internal fragment records exactly:
      # {id, marker, body, order, owner, sequence} with sequence the 1-based
      # position of the shell record in collection order (string keys — the
      # journal is a recorded-state parity anchor, encoded canonically).
      fragments_journal =
        if group.fragments != [] do
          journal_records =
            Enum.map(group.fragments, fn fragment ->
              %{
                "id" => fragment.id,
                "marker" => fragment.marker,
                "body" => fragment.body,
                "order" => fragment.order,
                "owner" => fragment.owner,
                "sequence" => fragment.sequence
              }
            end)

          Map.put(fragments_journal, target, journal_records)
        else
          fragments_journal
        end

      {entry, fragments_journal}
    end)
  end

  # --- chezmoi entries ---

  defp build_entries(collected, ancestors) do
    collected
    |> Enum.filter(&(&1.provider == Chezmoi.provider_id()))
    |> Enum.map_reduce([], fn record, removals ->
      :ok = Chezmoi.validate_spec(record.spec)
      assert_not_engine_state(record.spec.target)

      case build_entry(record, ancestors) do
        {{:removal, target, owner}, _acc} ->
          {nil, removals ++ [%{target: target, owner: owner}]}

        {entry, _acc} ->
          {entry, removals}
      end
    end)
    |> then(fn {entries, removals} -> {Enum.reject(entries, &is_nil/1), removals} end)
  end

  defp build_entry(record, ancestors) do
    spec = record.spec

    if spec.kind == :remove do
      # Explicit removals have no source name; they become .chezmoiremove
      # entries carried by the policy body.
      {{:removal, spec.target, record.owner}, []}
    else
      # Every generated regular source file must carry real bytes: a nil body
      # must never silently publish an empty program or payload.
      bytes =
        cond do
          spec.kind == :symlink -> spec.to
          spec.kind == :directory -> nil
          true -> spec.content
        end

      unless spec.kind == :symlink or spec.kind == :directory or bytes != nil do
        fail("backend file recipe produced no source bytes for #{spec.target}")
      end

      type =
        cond do
          spec.kind == :symlink -> "link"
          spec.kind == :modify -> "modify"
          true -> Atom.to_string(spec.kind)
        end

      entry = %{
        owner: record.owner,
        provider: Chezmoi.provider_id(),
        operation: Atom.to_string(spec.kind),
        target: spec.target,
        source_name: Chezmoi.source_name(spec, ancestors),
        type: type,
        mode: Chezmoi.entry_mode(spec),
        bytes: bytes,
        link: if(spec.kind == :symlink, do: spec.to),
        exact: spec.exact,
        template: spec.template,
        attribution: attribution(record),
        fingerprint: fingerprint(spec, type, bytes)
      }

      {entry, []}
    end
  end

  defp attribution(record), do: Map.get(record, :attribution) || [record.owner]

  # Fingerprints are content addresses: the encode is canonical (bytewise key
  # order) so two processes derive the identical id for identical content.
  defp fingerprint(spec, type, bytes) do
    fields =
      [
        {"target", spec.target},
        {"operation", Atom.to_string(spec.kind)},
        {"type", type},
        {"mode", Chezmoi.entry_mode(spec)},
        {"bytes", bytes && Digest.sha256(bytes)},
        {"link", if(spec.kind == :symlink, do: spec.to)}
      ]
      |> Enum.reject(fn {_key, value} -> value == nil end)
      |> Map.new()

    Digest.sha256(Workstation.Core.CanonicalJSON.encode(fields))
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

        not encompasses(entry.target, @engine_state_target) ||
          fail("exact directory #{entry.target} encompasses engine-private state")

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
      assert_not_engine_state(removal.target)
      not encompasses(removal.target, @engine_state_target) ||
        fail("removal of #{removal.target} encompasses engine-private state")

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

  # --- removal literals ---

  # Validate one final removal literal: engine-private state is never touched,
  # active ownership is never overlapped, and chezmoi interprets
  # .chezmoiremove entries as glob patterns, so one literal owned target must
  # not be able to expand into several removals.
  defp validate_removal_literal(target) do
    is_binary(target) and target != "" || fail("invalid removal entry")
    not String.match?(target, ~r/[\x00-\x1f\x7f]/) ||
      fail("removal entry must not contain control characters or newlines: #{target}")

    not String.match?(target, ~r/[*?\[\]]/) ||
      fail("removal entry contains glob metacharacters the backend would expand: #{target}")

    not String.starts_with?(target, "/") && not Regex.match?(~r/\.\.($|\/)/, target) ||
      fail("removal entry must be a literal relative path")

    not is_within(target, @engine_state_target) && not encompasses(target, @engine_state_target) ||
      fail("removal entry would touch engine-private state: #{target}")

    :ok
  end

  # --- path helpers (parity with source.lua is_within/encompasses) ---

  defp is_within(target, ancestor) do
    target == ancestor or String.starts_with?(target, ancestor <> "/")
  end
  defp encompasses(ancestor, target), do: is_within(target, ancestor)

  defp assert_not_engine_state(target) do
    not is_within(target, @engine_state_target) ||
      fail("recipe target overlaps engine-private state: #{target}")
  end

  defp fail(message), do: raise(ArgumentError, message)
end
