defmodule Workstation.Core.Contracts.Mise do
  @moduledoc """
  The mise tool contract: packages declare mise-managed tools (short name +
  exact version + optional backend), and this contract composes one managed
  global tool set, provisions it through the engine-owned mise binary, and
  records the result so drift is detected.

  Layer: contract. The contract law: the engine names no tool source — mise
  tools are engine vocabulary published through discovery, and packages
  declare pins as data against the kind, never as recipe code (implementor
  policy: this engine module is the mise kind's only implementor, on the
  apply-time handshake; the recorded-envelope reader dispatches declarations
  here through the same discovery).

  The contract is the ONE writer of the mise footprint, and every piece of
  it is owned on a declared surface:

  * the mise BINARY itself is not a recipe here — a download-contract
    contribution (pinned per-platform url/version/sha256) into the
    engine-owned opt root at `.local/opt/mise/<version>/bin/mise` provides
    the executable, and this contract refuses to run without exactly that
    one pin (composition fails when tools are declared without it);
  * `.local/bin/mise` is a contract-maintained symlink into the pinned
    binary — the interactive PATH convenience, never load-bearing for
    activation: the managed shell fragment resolves the pinned binary by
    absolute path (the launcher when it carries this exact link shape,
    else the sole opt-root pin, else a silent no-op), so hosts with a
    distro mise earlier on PATH can never bind a foreign mise to the
    engine's managed data and config. The installer's first-acquisition
    copy of the same pinned bytes is absorbed
    by content proof (its sha256 must equal the download pin's); anything
    else refuses instead of being replaced;
  * `.config/mise/config.toml` is the composed global managed set — one
    deterministic document built from every package's declared tools. It
    replaces the retired payload the language package used to ship, and at
    apply time it absorbs the installer's namespaced conf.d activation
    fragment (the exact `workstation-bootstrap.toml` path is deleted; both
    writers must never coexist). The composed bytes are pinned into the
    generation (a tool-pin change moves the generation id), the same
    provenance law the download descriptors follow;
  * a tool declaration may carry an optional platform scope
    (`platforms: ["linux"]` — default: every supported host; the scope
    vocabulary is the graph's host names, closed and validated at the
    declaration). Composition filters the declared set against the RUNNING
    host — the resolved graph's host — before the merge law, so a tool
    scoped away on this host contributes nothing (not to the composed
    config, not to the owners, not to the installs) and per-host
    alternative pins never conflict with each other; a catalog whose every
    tool is scoped away composes nil and the contract contributes nothing
    on that host, exactly like no declarations. The terminal tools are
    linux-scoped: on macOS tmux/btop stay host prerequisites (brew), not
    contract effects;
  * tool state lives under the engine state root, pinned through
    `MISE_DATA_DIR=<home>/.local/state/workstation/mise` on every mise
    subprocess (the env name this mise generation honors; the historical
    MISE_DATA_HOME is not read for resolution). The state is claimed as a
    first-class journal target, so a later apply verifies it like any other
    owned effect.

  Verification resolves tools THROUGH mise (`mise where <tool>@<version>`)
  and never through storage-layout assumptions: backend-qualified and
  short-name slugs may legitimately coexist in the installs tree, and
  identity is the (backend, version) resolution, not a directory name.
  Declared versions are EXACT pins — the engine's desired state is one
  version, the way a git pin is one commit; a prefix like a major.minor is
  not a pin and fails the resolution probe instead of silently tracking a
  moving tag.

  Fail-closed posture, matching the pinned-clone and pinned-download
  contracts: one tool may carry only one pinned version across all
  declaring packages, targets this contract owns may not overlap any entry,
  removal or download, and every effect verifies its actual outcome before
  the claim is recorded.
  """

  @behaviour Workstation.Core.Contracts.Contract

  alias Workstation.Core.CanonicalJSON
  alias Workstation.Core.Digest
  alias Workstation.Core.Source.Paths

  @engine_state_target ".local/state/workstation"
  @data_dir_target @engine_state_target <> "/mise"
  @config_target ".config/mise/config.toml"
  @config_source_name "mise/config.toml"
  @path_link_target ".local/bin/mise"
  @mise_pin_regex ~r{\A\.local/opt/mise/([^/]+)/bin/mise\z}
  @tool_name_regex ~r/\A[a-z0-9][a-z0-9._-]*\z/
  @tool_version_regex ~r/\A[0-9A-Za-z][0-9A-Za-z._+-]*\z/
  @backend_regex ~r/\A[a-z0-9]+:[A-Za-z0-9][A-Za-z0-9._\/-]*\z/
  # The platform-scope vocabulary: the graph's host names (`Catalog.host`).
  # Closed and validated at the declaration, so a typo'd scope is a
  # declaration error, never a silently-never-matching pin.
  @host_scopes ~w(linux darwin)

  @doc "The wire provider id for managed-tool declarations."
  @spec provider_id() :: String.t()
  def provider_id, do: "mise"

  @doc "The wire contract id of managed-tool effects (matches the provider id)."
  @impl Workstation.Core.Contracts.Contract
  @spec id() :: String.t()
  def id, do: provider_id()

  @doc "The home-relative targets this contract owns, in effect order."
  @spec owned_targets() :: [String.t()]
  def owned_targets, do: [@config_target, @path_link_target, @data_dir_target]

  @doc "The owned targets of one plan's tool set (none when the plan declares none)."
  @spec owned_targets_for(map() | nil) :: [String.t()]
  def owned_targets_for(nil), do: []
  def owned_targets_for(_mise), do: owned_targets()

  @doc """
  Validate one declared spec: exactly a non-empty `tools` list, each tool
  carrying a lowercase short name, a non-empty exact version, an
  optional `<prefix>:<path>` backend and an optional `platforms` scope
  (a non-empty list of supported host names). Raises `ArgumentError` on the
  first invalid field.
  """
  @impl Workstation.Core.Contracts.Contract
  @spec validate_spec(term()) :: :ok
  def validate_spec(spec) when is_map(spec) do
    tools = Map.get(spec, :tools) || Map.get(spec, "tools")

    is_list(tools) and tools != [] ||
      raise(ArgumentError, "mise recipe requires a non-empty tools list")

    Enum.each(tools, &validate_tool/1)

    unknown = Map.keys(spec) -- [:tools, "tools"]
    unknown == [] || raise(ArgumentError, "mise recipe has unknown fields: #{inspect(unknown)}")

    :ok
  end

  def validate_spec(other), do: raise(ArgumentError, "mise recipe must be a map, got: #{inspect(other)}")

  @doc """
  Denormalize one recorded-envelope spec (string-keyed golden or manifest
  bytes) back to the validated atom-keyed declared shape, so replay compares
  equal to native declarations. Raises `ArgumentError` with the declaring
  package named.
  """
  @impl Workstation.Core.Contracts.Contract
  @spec from_recorded(map(), map()) :: map()
  def from_recorded(spec, ctx) when is_map(spec) do
    tools = Map.get(spec, "tools")

    unless is_list(tools), do: raise(ArgumentError, "mise recipe requires a tools list")

    tools =
      Enum.map(tools, fn tool ->
        unless is_map(tool), do: raise(ArgumentError, "mise tool entries must be tables")

        tool =
          %{
            name: tool_string(tool, "name"),
            version: tool_string(tool, "version")
          }
          |> put_backend(Map.get(tool, "backend"))
          |> put_platforms(Map.get(tool, "platforms"))

        validate_tool(tool)
        tool
      end)

    spec = %{tools: tools}
    :ok = validate_spec(spec)
    spec
  rescue
    e in [ArgumentError] ->
      raise ArgumentError,
            "golden input has an invalid mise recipe for #{Map.get(ctx, :package_id)}: #{Exception.message(e)}"
  end

  def from_recorded(other, _ctx),
    do: raise(ArgumentError, "mise recipe must be a table, got: #{inspect(other)}")

  @doc """
  Compose the collected declarations (graph-ordered records contributed
  under this provider id) into the plan's managed tool set for the RUNNING
  host: platform-scoped tools (`platforms:` on a declaration) outside the
  host are skipped before the merge law — a scoped pin never conflicts with
  a peer host's alternative, a record whose every tool is skipped drops out
  (its id leaves the owners), and a catalog whose every tool is scoped away
  composes nil, the contract contributes nothing on that host exactly like
  no declarations. What survives composes as before: the deduplicated,
  deterministically sorted tool pins, the owning package ids, the
  content-addressed fingerprint, and the resolved engine mise pin. A
  catalog that still declares tools without exactly one opt-root mise pin
  fails here, at plan time. A catalog without declarations composes nil —
  the contract contributes nothing.
  """
  @spec compose_tools([map()], [map()], String.t()) :: map() | nil
  def compose_tools(collected, downloads, host) when is_binary(host) and host != "" do
    collected
    |> Enum.filter(&(&1.provider == provider_id()))
    |> Enum.map(fn record ->
      tools = Enum.filter(record.spec.tools, &scoped_to?(&1, host))
      %{record | spec: Map.put(record.spec, :tools, tools)}
    end)
    |> Enum.reject(&(&1.spec.tools == []))
    |> case do
      [] ->
        nil

      records ->
        tools = merge_tools(records)
        pin = mise_pin(downloads)

        %{
          tools: tools,
          owners: records |> Enum.map(& &1.owner) |> Enum.sort() |> Enum.uniq(),
          fingerprint: fingerprint_tools(tools),
          mise_target: pin.target,
          mise_version: pin.version
        }
    end
  end

  # The scope law: a tool without platforms is universal; a scoped tool
  # contributes only on a host its scope names. Scopes are validated at the
  # declaration against the closed host vocabulary, so membership here is
  # total — nothing to guess at composition time.
  defp scoped_to?(%{platforms: platforms}, host) when is_list(platforms), do: host in platforms
  defp scoped_to?(_tool, _host), do: true

  @doc "The tool-set fingerprint: content address over the exact pinned set."
  @spec fingerprint_tools([map()]) :: String.t()
  def fingerprint_tools(tools) do
    Digest.sha256(CanonicalJSON.encode(%{"tools" => Enum.map(tools, &tool_fields/1)}))
  end

  defp tool_fields(tool) do
    fields = %{"name" => Map.fetch!(tool, :name), "version" => Map.fetch!(tool, :version)}
    backend = Map.get(tool, :backend)
    (backend && Map.put(fields, "backend", backend)) || fields
  end

  @doc """
  The composed managed-config bytes: one deterministic document, header
  attribution first, then the `[tools]` table in the composed (sorted) order.
  Backend-qualified keys are quoted; bare short names stay bare.
  """
  @spec config_bytes(map()) :: String.t()
  def config_bytes(mise) do
    lines = [
      "# Managed by the workstation engine; do not edit deployed state by hand.",
      "# The engine mise contract composes this global tool set from the",
      "# packages' declared pins (declared by: " <> Enum.join(mise.owners, ", ") <> ").",
      "# Tool state lives under the engine state root (MISE_DATA_DIR).",
      "",
      "[tools]"
    ]

    body = Enum.map(mise.tools, &toml_entry/1)
    Enum.join(lines ++ body, "\n") <> "\n"
  end

  @doc "The generation-directory name of the managed-config pinned descriptor."
  @spec config_source_name() :: String.t()
  def config_source_name, do: @config_source_name

  @doc """
  The staged-generation pinned files of one composed tool set: the managed
  config bytes, so the generation id moves whenever a tool pin moves.
  """
  @spec pinned_files(map() | nil) :: [{String.t(), String.t()}]
  def pinned_files(nil), do: []
  def pinned_files(mise), do: [{@config_source_name, config_bytes(mise)}]

  # The same conflict law as the pinned downloads: a contract-owned target
  # may not overlap any owned entry, declared removal or download pin, in
  # either direction, so replay fails loudly before a plan exists.
  @doc false
  @spec check_conflicts(map() | nil, [map()], [map()], [map()]) :: :ok
  def check_conflicts(nil, _entries, _removals, _downloads), do: :ok

  def check_conflicts(mise, entries, removals, downloads) do
    Enum.each(owned_targets_for(mise), fn target ->
      Enum.each(entries, fn entry ->
        overlaps?(target, entry.target) &&
          Paths.invalid!(
            "mise target #{target} overlaps owned target #{entry.target} " <>
              "(#{Enum.join(entry.attribution || [entry.owner], ",")})"
          )
      end)

      Enum.each(removals, fn removal ->
        Paths.encompasses?(removal.target, target) &&
          Paths.invalid!("declared removal #{removal.target} overlaps mise target #{target}")
      end)

      Enum.each(downloads, fn download ->
        # A dispatched pin (per-platform targets) checks every destination
        # it declares; a literal pin checks its own.
        declared =
          case Map.get(download, :targets) do
            nil -> [download.target]
            targets -> Map.values(targets)
          end

        Enum.each(declared, fn dl_target ->
          overlaps?(target, dl_target) &&
            Paths.invalid!("mise target #{target} overlaps download target #{dl_target}")
        end)
      end)
    end)
  end

  # --- the effect contract ---

  # One typed effect per owned surface, all phase :target: the composed
  # config lands first, then the PATH link, then the tool installs (the fold
  # sorts by {phase, contract, target}, and the target names order these
  # three deterministically).
  @impl Workstation.Core.Contracts.Contract
  @spec plan_effect(term(), map()) :: [map()]
  def plan_effect(plan, _ctx) do
    case Map.get(plan, :mise) do
      nil ->
        []

      mise ->
        [
          %{
            contract: id(),
            kind: :configure,
            phase: :target,
            target: @config_target,
            tools: mise.tools,
            owners: mise.owners,
            fingerprint: mise.fingerprint
          },
          %{
            contract: id(),
            kind: :link,
            phase: :target,
            target: @path_link_target,
            mise_target: mise.mise_target,
            mise_version: mise.mise_version,
            fingerprint: mise.fingerprint
          },
          %{
            contract: id(),
            kind: :install,
            phase: :target,
            target: @data_dir_target,
            tools: mise.tools,
            mise_target: mise.mise_target,
            mise_version: mise.mise_version,
            fingerprint: mise.fingerprint
          }
        ]
    end
  end

  # --- composition helpers ---

  defp merge_tools(records) do
    records
    |> Enum.flat_map(fn record ->
      Enum.map(record.spec.tools, &Map.put(&1, :owner, record.owner))
    end)
    |> Enum.reduce({[], %{}}, fn tool, {tools, seen} ->
      key = {tool.name, Map.get(tool, :backend)}

      case Map.get(seen, key) do
        nil ->
          {tools ++ [tool], Map.put(seen, key, tool)}

        %{version: version} ->
          version == tool.version ||
            raise(ArgumentError,
              "mise tool #{tool.name} is declared twice with diverging versions " <>
                "(#{version} vs #{tool.version}); one tool may carry only one pinned version"
            )

          {tools, seen}
      end
    end)
    |> elem(0)
    |> Enum.sort_by(&{&1.name, Map.get(&1, :backend) || ""})
  end

  # The engine mise pin: exactly one download under the engine-owned opt
  # subtree, shaped `.local/opt/mise/<version>/bin/mise` — the layout law of
  # the subtree this contract owns.
  defp mise_pin(downloads) do
    downloads
    |> Enum.filter(&(is_binary(&1.target) and String.starts_with?(&1.target, ".local/opt/mise/")))
    |> case do
      [pin] ->
        case Regex.run(@mise_pin_regex, pin.target) do
          [_all, version] -> %{target: pin.target, version: version}

          nil ->
            raise(ArgumentError,
              "the mise download pin target must be .local/opt/mise/<version>/bin/mise, got: #{pin.target}"
            )
        end

      [] ->
        raise(ArgumentError,
          "packages declare mise tools, but no pinned download provides the mise binary at " <>
            ".local/opt/mise/<version>/bin/mise; the engine-owned base package owns that pin"
        )

      many ->
        raise(ArgumentError,
          "multiple download pins under .local/opt/mise/ (#{Enum.map_join(many, ", ", & &1.target)}); " <>
            "exactly one mise binary pin may exist"
        )
    end
  end

  defp toml_entry(tool) do
    # The managed key IS the tool identity: a backend tool carries its
    # backend-qualified name alone (the installer's conf.d shape), a core
    # tool its short name.
    backend = Map.get(tool, :backend)
    key = backend || tool.name
    key = if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, key), do: key, else: "\"" <> key <> "\""
    key <> " = \"" <> tool.version <> "\""
  end

  # --- validation helpers ---

  defp validate_tool(tool) when is_map(tool) do
    name = field(tool, :name)
    version = field(tool, :version)

    Regex.match?(@tool_name_regex, name) ||
      raise(ArgumentError, "mise tool name must be a lowercase short name (a-z, 0-9, dot, dash), got: #{name}")

    Regex.match?(@tool_version_regex, version) ||
      raise(ArgumentError, "mise tool #{name} version must be an exact pin (digits, letters, dot, dash, plus), got: #{version}")

    backend = Map.get(tool, :backend) || Map.get(tool, "backend")

    if backend do
      Regex.match?(@backend_regex, backend) ||
        raise(ArgumentError, "mise tool #{name} backend must be <prefix>:<path>, got: #{backend}")
    end

    platforms = Map.get(tool, :platforms) || Map.get(tool, "platforms")

    if platforms do
      is_list(platforms) and platforms != [] ||
        raise(ArgumentError, "mise tool #{name} platforms must be a non-empty list of host names")

      Enum.each(platforms, fn host ->
        host in @host_scopes ||
          raise(ArgumentError,
            "mise tool #{name} platform scope must be one of #{Enum.join(@host_scopes, ", ")}, got: #{inspect(host)}"
          )
      end)
    end

    unknown =
      Map.keys(tool) --
        [:name, :version, :backend, :platforms, "name", "version", "backend", "platforms"]

    unknown == [] || raise(ArgumentError, "mise tool #{name} has unknown fields: #{inspect(unknown)}")

    :ok
  end

  defp validate_tool(other), do: raise(ArgumentError, "mise tool entries must be tables, got: #{inspect(other)}")

  defp put_backend(tool, nil), do: tool
  defp put_backend(tool, backend), do: Map.put(tool, :backend, backend)

  defp put_platforms(tool, nil), do: tool
  defp put_platforms(tool, platforms), do: Map.put(tool, :platforms, platforms)

  defp field(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
    is_binary(value) and value != "" || raise(ArgumentError, "mise tool requires #{key}")
    value
  end

  defp tool_string(map, key) do
    value = Map.get(map, key)
    is_binary(value) and value != "" || raise(ArgumentError, "mise tool requires #{key}")
    value
  end

  defp overlaps?(target, other) do
    target == other or Paths.encompasses?(target, other) or Paths.encompasses?(other, target)
  end
end
