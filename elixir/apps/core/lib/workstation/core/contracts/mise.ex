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
    binary, so activated shells resolve the engine mise through PATH. The
    installer's first-acquisition copy of the same pinned bytes is absorbed
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
  alias Workstation.Core.Contracts.Download
  alias Workstation.Core.Digest
  alias Workstation.Core.EngineState
  alias Workstation.Core.Source.Paths

  @engine_state_target ".local/state/workstation"
  @data_dir_target @engine_state_target <> "/mise"
  @config_target ".config/mise/config.toml"
  @config_source_name "mise/config.toml"
  @path_link_target ".local/bin/mise"
  @absorbed_conf_d ".config/mise/conf.d/workstation-bootstrap.toml"
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
        overlaps?(target, download.target) &&
          Paths.invalid!("mise target #{target} overlaps download target #{download.target}")
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

  @doc """
  Execute one effect at the apply boundary. `ctx` carries `:home`, `:plan`
  and the optional `:mise` runner (a `(executable, args, env) -> {output,
  exit_code}` injection for tests; production runs the pinned binary).
  """
  @impl Workstation.Core.Contracts.Contract
  @spec run_effect(map(), map()) :: :ok
  def run_effect(effect, ctx) do
    home = ctx.home

    case effect.kind do
      :configure -> configure(home, effect)
      :link -> ensure_path_link(home, effect, ctx)
      :install -> install(home, effect, ctx)
      other -> raise(ArgumentError, "unknown mise effect kind #{inspect(other)}")
    end

    :ok
  end

  @doc """
  The applied-target ownership claims, computed from the ACTUAL home after
  the fold: the config must carry exactly the composed bytes, the link must
  point exactly at the pinned binary, and the tool state must resolve every
  declared pin through mise — an effect that did not produce exactly its
  declared outcome raises instead of recording.
  """
  @impl Workstation.Core.Contracts.Contract
  @spec fingerprint(map(), map()) :: map()
  def fingerprint(%{kind: :configure} = effect, ctx) do
    bytes = config_bytes(%{tools: effect.tools, owners: effect.owners})
    live = claim_file!(ctx.home, @config_target, Digest.sha256(bytes))

    %{@config_target =>
        Map.merge(live, %{
          "owner" => "mise",
          "operation" => "configure",
          "source_fingerprint" => effect.fingerprint
        })}
  end

  def fingerprint(%{kind: :link} = effect, ctx) do
    desired = link_value(effect.mise_version)
    live = EngineState.target_fingerprint(ctx.home, @path_link_target)

    unless is_map(live) and live["type"] == "link" and live["link"] == desired do
      raise ArgumentError,
            "apply did not produce the mise PATH link #{@path_link_target} -> #{desired}"
    end

    %{@path_link_target =>
        Map.merge(live, %{
          "owner" => "mise",
          "operation" => "link",
          "source_fingerprint" => effect.fingerprint
        })}
  end

  def fingerprint(%{kind: :install} = effect, ctx) do
    mise = Path.join(ctx.home, effect.mise_target)

    case EngineState.lstat(mise) do
      %{type: "file"} -> :ok
      nil -> raise(ArgumentError, "apply did not produce the pinned mise binary #{effect.mise_target}")
      %{type: other} -> raise(ArgumentError, "the pinned mise binary #{effect.mise_target} exists as #{other}")
    end

    Enum.each(effect.tools, fn tool -> probe_tool!(tool, mise, ctx.home) end)

    live = EngineState.target_fingerprint(ctx.home, @data_dir_target)

    unless is_map(live) and live["type"] == "directory" do
      raise(ArgumentError, "apply did not produce the mise tool state #{@data_dir_target}")
    end

    %{@data_dir_target =>
       %{
         "type" => "mise",
         "mise" => effect.mise_target,
         "mise_version" => effect.mise_version,
         "tools" => Enum.map(effect.tools, &tool_fields/1),
         "owner" => "mise",
         "operation" => "install",
         "source_fingerprint" => effect.fingerprint
       }}
  end

  @doc """
  The verify seam: a `mise`-typed journal record re-checks, through mise
  itself, that every recorded tool still resolves at its pinned version on
  the ACTUAL home; anything else is :unclaimed (the default file-fingerprint
  verification takes it). A missing pinned binary or a version that no
  longer resolves fails closed — a changed version under an unchanged record
  is drift, never silently accepted. Tests inject a runner through
  `ctx["mise_runner"]`.
  """
  @impl Workstation.Core.Contracts.Contract
  @spec verify_record(map(), map()) :: :ok | :unclaimed
  def verify_record(%{"type" => "mise", "mise" => mise_target, "tools" => tools} = _record, ctx)
      when is_binary(mise_target) and is_list(tools) do
    home = fetch_string(ctx, "home")

    mise = Path.join(home, mise_target)

    case EngineState.lstat(mise) do
      %{type: "file"} -> :ok
      nil -> raise(ArgumentError, "verify: the pinned mise binary #{mise_target} is gone")
      %{type: other} -> raise(ArgumentError, "verify: the pinned mise binary #{mise_target} exists as #{other}")
    end

    Enum.each(tools, fn tool ->
      record_tool = %{
        name: fetch_string(tool, "name"),
        version: fetch_string(tool, "version"),
        backend: Map.get(tool, "backend")
      }

      runner = ctx["mise_runner"] || (&default_runner/3)
      probe_tool!(record_tool, mise, home, runner)
    end)

    :ok
  end

  def verify_record(%{"type" => "mise"}, _ctx) do
    raise(ArgumentError, "verify: mise record without its binary path and tools; the record is corruption")
  end

  def verify_record(_record, _ctx), do: :unclaimed

  # --- effect mechanics ---

  # The composed managed config: written atomically, idempotent on identical
  # bytes, and the installer's first-acquisition conf.d fragment is absorbed
  # here — the exact namespaced path only, and only as a regular file;
  # anything else refuses instead of being deleted blind.
  defp configure(home, effect) do
    bytes = config_bytes(%{tools: effect.tools, owners: effect.owners})
    path = Path.join(home, @config_target)

    case File.read(path) do
      {:ok, ^bytes} ->
        :ok

      {:ok, _other} ->
        write_atomic!(path, bytes)

      {:error, :enoent} ->
        write_atomic!(path, bytes)

      {:error, reason} ->
        raise(ArgumentError, "mise config target #{@config_target} is unreadable: #{inspect(reason)}")
    end

    absorbed = Path.join(home, @absorbed_conf_d)

    case EngineState.lstat(absorbed) do
      nil -> :ok
      %{type: "file"} -> File.rm!(absorbed)

      %{type: other} ->
        raise(ArgumentError,
          "the installer activation fragment #{@absorbed_conf_d} exists as #{other}; " <>
            "inspect it and resolve it explicitly"
        )
    end

    :ok
  end

  # The PATH entry: a symlink into the pinned binary, converged on every
  # apply. A regular file already at the target is the installer's
  # first-acquisition copy exactly when its bytes match the download pin —
  # proven ownership is absorbed; anything else refuses.
  defp ensure_path_link(home, effect, ctx) do
    desired = link_value(effect.mise_version)
    path = Path.join(home, @path_link_target)

    case EngineState.lstat(path) do
      nil ->
        make_link!(path, desired)

      %{type: "link"} ->
        File.read_link(path) == {:ok, desired} || make_link!(path, desired)

      %{type: "file"} ->
        pinned_sha = pinned_sha256!(effect, ctx)

        Digest.sha256(File.read!(path)) == pinned_sha ||
          raise(ArgumentError,
            "#{@path_link_target} exists and is not the first-acquisition copy of the pinned mise " <>
              "(sha256 mismatch with #{effect.mise_target}); inspect it and remove it explicitly"
          )

        File.rm!(path)
        make_link!(path, desired)

      %{type: other} ->
        raise(ArgumentError, "#{@path_link_target} exists as #{other}; refusing to replace it")
    end

    :ok
  end

  # The pinned install: one `mise install` invocation carrying every
  # declared pin (mise resolves backend dependencies itself), then a
  # resolution probe per tool — the effect's own proof that the exact pins
  # landed, through mise, never through directory layout.
  defp install(home, effect, ctx) do
    mise = pinned_mise!(home, effect.mise_target)
    runner = ctx[:mise] || (&default_runner/3)

    args = ["install"] ++ Enum.map(effect.tools, &tool_spec/1)
    {out, code} = runner.(mise, args, mise_env(home))

    code == 0 ||
      raise(ArgumentError, "mise install failed (exit #{code}): #{String.trim_trailing(out)}")

    Enum.each(effect.tools, fn tool -> probe_tool!(tool, mise, home, runner) end)

    :ok
  end

  defp probe_tool!(tool, mise, home, runner \\ &default_runner/3) do
    {out, code} = runner.(mise, ["where", tool_spec(tool)], mise_env(home))

    code == 0 ||
      raise(ArgumentError,
        "mise tool #{Map.fetch!(tool, :name)} does not resolve at the pinned version " <>
          "#{Map.fetch!(tool, :version)} (exit #{code}): #{String.trim_trailing(out)}"
      )

    :ok
  end

  defp pinned_mise!(home, mise_target) do
    mise = Path.join(home, mise_target)

    case EngineState.lstat(mise) do
      %{type: "file"} ->
        mise

      nil ->
        raise(ArgumentError,
          "the pinned mise binary #{mise_target} is absent; the pinned download must apply first"
        )

      %{type: other} ->
        raise(ArgumentError, "the pinned mise binary #{mise_target} exists as #{other}")
    end
  end

  # The absorption proof: the executing host's pinned sha256, resolved
  # through the download contract from the plan's pin (the plan is on the
  # effect context; replay never runs effects).
  defp pinned_sha256!(effect, ctx) do
    plan = Map.get(ctx || %{}, :plan)
    downloads = (plan && Map.get(plan, :downloads)) || []

    download =
      Enum.find(downloads, &(&1.target == effect.mise_target)) ||
        raise(ArgumentError, "the plan carries no download pin for #{effect.mise_target}")

    Download.resolve(download).sha256
  end

  defp make_link!(path, desired) do
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
    File.ln_s!(desired, path)
    :ok
  end

  defp link_value(mise_version), do: "../opt/mise/#{mise_version}/bin/mise"

  defp write_atomic!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    staged = Path.join(Path.dirname(path), ".mise-config-#{:os.getpid()}-#{System.system_time(:native)}")
    File.write!(staged, bytes)
    File.chmod!(staged, 0o644)

    case File.rename(staged, path) do
      :ok -> :ok
      {:error, reason} -> raise(ArgumentError, "mise config write failed for #{path}: #{inspect(reason)}")
    end
  end

  # The mise subprocess environment: the target home is HOME, tool state is
  # pinned under the engine state root, and the managed config dir is the
  # composed document's directory. Non-interactive: prompts are failures.
  defp mise_env(home) do
    %{
      "HOME" => home,
      "WORKSTATION_HOME" => home,
      "MISE_DATA_DIR" => Path.join(home, @data_dir_target),
      "MISE_CONFIG_DIR" => Path.join(home, Path.dirname(@config_target)),
      "MISE_YES" => "1"
    }
  end

  defp default_runner(exe, args, env) do
    System.cmd(exe, args, env: env, stderr_to_stdout: true)
  rescue
    reason -> raise(ArgumentError, "mise execution failed: #{inspect(reason)}")
  end

  # The mise CLI names a backend tool by its backend identity alone (the
  # installer's own invocation shape): `aqua:tmux/tmux-builds@3.7c`. The
  # short name is the display alias, never part of the tool argument.
  defp tool_spec(tool) do
    backend = Map.get(tool, :backend)
    version = Map.fetch!(tool, :version)

    if backend do
      "#{backend}@#{version}"
    else
      "#{Map.fetch!(tool, :name)}@#{version}"
    end
  end

  defp tool_fields(tool) do
    fields = %{"name" => Map.fetch!(tool, :name), "version" => Map.fetch!(tool, :version)}
    backend = Map.get(tool, :backend)
    (backend && Map.put(fields, "backend", backend)) || fields
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
    |> Enum.filter(&String.starts_with?(&1.target, ".local/opt/mise/"))
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

  defp fetch_string(map, key) when is_map(map) do
    value = Map.get(map, key)
    is_binary(value) and value != "" || raise(ArgumentError, "mise record field #{inspect(key)} is missing")
    value
  end

  defp claim_file!(home, target, sha256) do
    live = EngineState.target_fingerprint(home, target)

    unless is_map(live) and live["type"] == "file" and live["sha256"] == sha256 do
      raise(ArgumentError, "apply did not produce the managed mise config #{target} with the composed bytes")
    end

    live
  end

  defp overlaps?(target, other) do
    target == other or Paths.encompasses?(target, other) or Paths.encompasses?(other, target)
  end
end
