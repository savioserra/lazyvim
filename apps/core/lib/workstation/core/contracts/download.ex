defmodule Workstation.Core.Contracts.Download do
  @moduledoc """
  The pinned-artifact source contract: a thing that fetches a pinned
  artifact (url + version + sha256 + target) into the home.

  Layer: contract. The contract law: a pin installs exactly its pinned
  bytes, or exactly the tree a checksum-gated archive carries — nothing
  else is ever written (implementor policy: implementations are the
  engine's own contract modules; discovery finds them by behaviour
  conformance).

  The plan stays pure: a download recipe contributes a validated pin whose
  descriptor is content-addressed into the plan manifest, so the generation
  id changes whenever a pin changes and the generation directory carries the
  machine-readable pin provenance. Installation happens only at the apply
  boundary and is fail-closed both ways: the downloaded bytes must match the
  pinned sha256 (nothing is written otherwise) and an existing target with
  different content is never overwritten. A target already carrying the
  pinned content is an idempotent no-op — the fetch is skipped entirely.

  The fetch function is injected at the apply boundary (`:fetch` option);
  the default performs a real HTTPS GET. Recipe constructors raise
  `ArgumentError` with anchored messages, exactly like the other source
  contracts.

  Per-platform dispatch is resolved THROUGH the contract, never by ad-hoc
  conditionals in consumers: a spec either pins ONE artifact directly
  (`url` + `sha256`) or declares `assets` keyed by platform tag —
  `%{"linux_x86_64" => %{url: ..., sha256: ...}, "darwin_arm64" => %{...}}` —
  and the contract resolves the executing host's tag at the apply boundary
  (`resolve/2`, `platform/0`; the tag vocabulary is the bootstrap pins
  manifest's). The declared assets travel verbatim through the plan, the
  fingerprint and the recorded envelope — a pin change on ANY platform
  changes the generation, and a recorded plan stays machine-independent.

  ## The archive form

  A pin may declare `archive: "tar.gz"`, `"tar.xz"` or `"zip"`: the pinned
  artifact is then a release ARCHIVE installed as an exact tree — the sha256
  gate applies to the archive bytes, the archive's members are
  traversal-checked, extraction lands in a private staging directory beside
  the target, and the staged tree is activated by rename only after a
  declared probe proves it is the pinned tool. An archive target is a
  directory inside the home; the pipeline's caller-held apply lock is the
  install's serialization, and the staging discipline is the bootstrap's:
  debris staging siblings are swept at install start, and the tree is never
  partially visible at the target path.

  The declared `layout` names the archive's root discipline — the closed
  vocabulary:

    * `release` (the default): the archive carries exactly one root; a
      root DIRECTORY extracts with exactly one component stripped (the
      release-archive layout), and a lone root FILE is the installed tree
      itself (single-binary release archives: `fzf`, `tree-sitter`). A
      multi-root archive is a loud failure — merging unrelated top-level
      members into one target is never a silent act.
    * `flat`: the members live at the archive's top level with no owning
      root (upstream ships bare: lazygit's `LICENSE`/`README.md`/`lazygit`,
      the 1Password `op`/`op.sig` pair, the Nerd Font ttf set). Every
      member extracts into the staging root, none stripped, still
      traversal-checked — the freshness of the staging directory is what
      makes a rootless tree safe to activate.

  Formats ride the host's extraction tools (`tar` for tar.gz/tar.xz,
  `unzip` for zip); a missing tool is a named apply-time prerequisite
  error, never a silent fallback.

  The probe is the archive pin's honesty gate, declared as data so the
  contract stays domain-neutral. Two shapes — a tree proves it is the
  pinned tool through one of them, never both, never neither:

    * the exec probe `probe: %{argv: ["bin/tool", "version"], output: "tool
      version {V}"}` — argv[0] is a relative member of the installed tree,
      the remaining entries are literal arguments, and the first output line
      must match the template with `{V}` substituted by the pinned version
      (a token boundary: the next character is a space or end of line, so
      `1.27.1` never matches `1.27.10`);
    * the content probe `probe: %{member: "nvm.sh", sha256: "..."}"` — for
      trees that carry no executable at all (an nvm checkout, a font
      directory): the named relative member must be a regular file whose
      bytes hash to the declared digest, which pins the tree's identity as
      exactly as a version line does (the pinned archive is
      deterministic, so member digests are stable facts about the pin).

  A version line remains the probe of choice wherever the tool can speak;
  the content probe exists so data trees do not have to fake an executable.

  The probe drives all three lifecycle gates: an existing directory that
  does not carry the pinned tool refuses to be overwritten, the
  applied-target claim re-probes the actual tree before recording, and the
  verify seam (`verify_record/2`) re-probes the recorded tree on every
  verify.

  ## Per-platform targets

  A pin installs at ONE target path; like its assets, that path may be
  platform-specific: a spec declares either `target` (one literal) or
  `targets` keyed by the platform tag vocabulary (`%{"linux_x86_64" =>
  ".local/share/fonts/...", "darwin_arm64" => "Library/Fonts/..."}`). The
  declared targets travel verbatim through the plan — the executing host
  resolves its own at the apply boundary (`resolve/2`), so a recorded plan
  stays machine-independent and the journal claims the path that actually
  exists in the home.
  """

  alias Workstation.Core.{CanonicalJSON, Digest}

  @engine_state_target ".local/state/workstation"

  # The archive form's closed vocabulary: the supported archive formats and
  # root layouts. A new format or layout joins here or it does not exist.
  @archive_formats ~w(tar.gz tar.xz zip)
  @layouts ~w(release flat)

  @enforce_keys [:version]
  defstruct [:url, :version, :sha256, :target, :targets, :assets, :archive, :layout, :probe]

  @typedoc "One platform's pinned asset: an https url and its checksum."
  @type asset :: %{required(:url) => String.t(), required(:sha256) => String.t()}

  @typedoc """
  One platform's pinned target path (the mirror of `t:asset/0` for trees
  that land in a platform-specific directory).
  """
  @type platform_targets :: %{optional(String.t()) => String.t()}

  @typedoc """
  The archive form's installed-shape probe. The exec shape: argv[0] a
  relative member of the installed tree, literal arguments, and the
  first-line output template carrying exactly one `{V}` (substituted with
  the pinned version). The content shape: a relative member plus the exact
  sha256 its extracted bytes must carry.
  """
  @type probe ::
          %{required(:argv) => [String.t()], required(:output) => String.t()}
          | %{required(:member) => String.t(), required(:sha256) => String.t()}

  @type t :: %__MODULE__{
          url: String.t() | nil,
          version: String.t(),
          sha256: String.t() | nil,
          target: String.t() | nil,
          targets: platform_targets() | nil,
          assets: %{optional(String.t()) => asset()} | nil,
          archive: String.t() | nil,
          layout: String.t() | nil,
          probe: probe() | nil
        }

  @platform_tags ~w(linux_x86_64 darwin_arm64)

  # The redirect chain the default fetch follows itself, one TLS session per
  # hop: inets' autoredirect reuses a single flat ssl option set across hops,
  # which is exactly how a GitHub release fetch ends up TLS-ing to
  # release-assets.githubusercontent.com with github.com's identity.
  @max_redirects 5
  @redirect_statuses [301, 302, 303, 307, 308]

  # Transport-level errors one idempotent hop may absorb with a bounded
  # retry. :closed/:econnreset/:timeout are the classic async-close and
  # timeout shapes; :einval is the loaded-scheduler shape pinned by the
  # t_79669ce0 suite battery — the peer answers and closes cleanly, the
  # client still loses the response at the inet/ssl driver.
  @transient_connect_errors [:closed, :timeout, :econnreset, :einval]

  # Retries settle before each re-attempt so a scheduler/fd spike can drain;
  # the schedule is exponential (25ms before attempt 2, doubling to 200ms)
  # because the battery pinned back-to-back losses: bursts outlive any
  # single fixed gap. Bounded per hop and never counted as redirect hops.
  @max_hop_attempts 5
  @hop_retry_settle_ms [25, 50, 100, 200]

  @doc "The wire provider id for pinned-artifact contributions."
  @spec provider_id() :: String.t()
  def provider_id, do: "download"

  @doc """
  Build one validated download recipe. Raises `ArgumentError` on any
  invalid field: the url must be https (the supply-chain posture of a
  checksummed fetch), the sha256 must be 64 lowercase hex digits, the
  version a non-empty string, and the destination a safe relative literal
  path that never touches engine-private state — one `target` or a
  `targets` table keyed by platform tag, never both, never neither. An
  `archive` pin selects the archive form (the layout naming its root
  discipline) and REQUIRES a probe; a probe without an archive is
  rejected.
  """
  @spec recipe(map()) :: t()
  def recipe(attrs) when is_map(attrs) do
    version = fetch_field(attrs, :version)
    {target, targets} = destination(attrs)
    validate_version(version)

    case targets do
      nil -> validate_target(target)
      targets -> Enum.each(Map.values(targets), &validate_target/1)
    end

    archive = optional_field(attrs, :archive)

    archive == nil or archive in @archive_formats ||
      raise(ArgumentError,
            "download archive must be one of #{Enum.join(@archive_formats, ", ")}, got: #{archive}"
          )

    layout = optional_field(attrs, :layout)

    layout == nil or layout in @layouts ||
      raise(ArgumentError, "download layout must be one of #{Enum.join(@layouts, ", ")}, got: #{layout}")

    layout == nil or archive != nil ||
      raise(ArgumentError, "download layout requires an archive pin")

    probe = optional_probe(attrs, archive)

    spec =
      if attrs[:assets] != nil or attrs["assets"] != nil do
        %__MODULE__{version: version, target: target, targets: targets, assets: recipe_assets(attrs)}
      else
        url = fetch_field(attrs, :url)
        sha256 = fetch_field(attrs, :sha256)
        validate_url(url)
        validate_sha256(sha256)
        %__MODULE__{url: url, version: version, sha256: sha256, target: target, targets: targets}
      end

    %{spec | archive: archive, layout: layout, probe: probe}
  end

  # One destination per pin: a literal `target` or a `targets` table keyed
  # by KNOWN platform tag (a typo'd tag would silently never install).
  defp destination(attrs) do
    target = optional_field(attrs, :target)
    raw = attrs[:targets] || attrs["targets"]

    cond do
      target != nil and raw != nil ->
        raise ArgumentError, "download pin declares both target and targets — one destination per pin"

      raw == nil and target == nil ->
        raise ArgumentError, "download recipe requires target"

      raw == nil ->
        {target, nil}

      true ->
        unless is_map(raw) and raw != %{},
          do: raise(ArgumentError, "download targets must be a non-empty table keyed by platform tag")

        targets =
          Map.new(raw, fn {tag, path} ->
            tag = to_string(tag)

            tag in @platform_tags ||
              raise(ArgumentError,
                    "download targets declare unknown platform tag #{inspect(tag)} (known: #{Enum.join(@platform_tags, ", ")})"
                  )

            {tag, path}
          end)

        {nil, targets}
    end
  end

  # The archive form's declared probe: required exactly when the pin is an
  # archive, rejected otherwise — a probe is meaningless without a tree to
  # probe, and an archive without one could never prove what it installed.
  defp optional_probe(attrs, archive) do
    raw = attrs[:probe] || attrs["probe"]

    cond do
      raw == nil and archive == nil ->
        nil

      raw == nil ->
        raise ArgumentError, "download archive pin requires a probe"

      archive == nil ->
        raise ArgumentError, "download probe requires an archive pin"

      true ->
        validate_probe(raw, archive)
    end
  end

  # The probe's two shapes, never mixed: the exec shape (argv + output
  # template) and the content shape (member + sha256) — a tree proves it is
  # the pinned tool through one of them.
  defp validate_probe(probe, archive) when is_map(probe) do
    cond do
      exec_probe?(probe) and content_probe?(probe) ->
        raise ArgumentError,
              "download probe declares both the exec shape (argv/output) and the content shape " <>
                "(member/sha256) — one shape per probe"

      exec_probe?(probe) ->
        validate_exec_probe(probe, archive)

      content_probe?(probe) ->
        validate_content_probe(probe)

      true ->
        raise ArgumentError, "download probe must be a table with argv and output, got: #{inspect(probe)}"
    end
  end

  defp validate_probe(other, _archive),
    do: raise(ArgumentError, "download probe must be a table with argv and output, got: #{inspect(other)}")

  defp exec_probe?(probe), do: Map.get(probe, :argv) != nil or Map.get(probe, "argv") != nil
  defp content_probe?(probe), do: Map.get(probe, :member) != nil or Map.get(probe, "member") != nil

  defp validate_exec_probe(probe, archive) do
    argv = Map.get(probe, :argv) || Map.get(probe, "argv")
    output = Map.get(probe, :output) || Map.get(probe, "output")

    unless is_list(argv) and length(argv) in 1..8 and Enum.all?(argv, &is_binary/1) and
             Enum.all?(argv, &not String.match?(&1, ~r/[\x00-\x1f\x7f]/)) and
             Enum.all?(argv, &(&1 != "")),
      do: raise(ArgumentError, "download probe argv must be 1..8 non-empty literal strings")

    [executable | args] = argv
    validate_probe_member!(executable, archive)

    is_binary(output) and String.contains?(output, "{V}") or
      raise(ArgumentError, "download probe output must carry exactly the {V} version template")

    length(:binary.matches(output, "{V}")) == 1 ||
      raise(ArgumentError, "download probe output must carry exactly the {V} version template")

    not String.match?(output, ~r/[\x00-\x1f\x7f]/) ||
      raise(ArgumentError, "download probe output must not contain control characters")

    %{argv: [executable | args], output: output}
  end

  # The content probe: a relative regular-file member plus the exact digest
  # its extracted bytes must carry — the tree's identity without an
  # executable.
  defp validate_content_probe(probe) do
    member = Map.get(probe, :member) || Map.get(probe, "member")
    sha256 = Map.get(probe, :sha256) || Map.get(probe, "sha256")

    is_binary(member) or raise(ArgumentError, "download content probe requires member")
    is_binary(sha256) or raise(ArgumentError, "download content probe requires sha256")

    validate_sha256(sha256)
    validate_probe_member!(member, "content")

    %{member: member, sha256: sha256}
  end

  # argv[0] names a member INSIDE the installed tree: a relative literal
  # path, never absolute, never traversing — the probe must not be able to
  # point outside the tree the archive produced.
  defp validate_probe_member!(executable, archive) do
    outside? =
      String.starts_with?(executable, "/") or String.starts_with?(executable, "~") or
        Regex.match?(~r/(^|\/)\.\.(\/|$)/, executable) or String.match?(executable, ~r/[*?\[\]]/)

    outside? &&
      raise(ArgumentError,
            "download probe executable must be a relative member of the installed #{archive} tree: #{executable}"
          )

    :ok
  end

  defp optional_field(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      nil -> nil
      value when is_binary(value) and value != "" -> value
      other -> raise ArgumentError, "download #{key} must be a non-empty string, got: #{inspect(other)}"
    end
  end

  @doc "The platform tags the dispatch vocabulary knows."
  @spec platform_tags() :: [String.t()]
  def platform_tags, do: @platform_tags

  @doc """
  The executing host's platform tag — the same vocabulary the bootstrap
  pins manifest keys its records by, resolved from the running OS/arch and
  fail-closed on anything the launcher could not run anyway.
  """
  @spec platform() :: String.t()
  def platform do
    case :os.type() do
      {:unix, :linux} -> if arch?(~r/x86_64|amd64/), do: "linux_x86_64", else: fail_platform("linux")
      {:unix, :darwin} -> if arch?(~r/arm64|aarch64/), do: "darwin_arm64", else: fail_platform("darwin")
      other -> raise ArgumentError, "download: unsupported platform #{inspect(other)}"
    end
  end

  defp fail_platform(os), do: raise(ArgumentError, "download: unsupported platform #{os}/#{arch()}")

  defp arch, do: :erlang.system_info(:system_architecture) |> to_string()
  defp arch?(regex), do: arch() =~ regex

  @doc """
  Resolve one spec's effective pin for `platform` (default: the executing
  host): the pinned url, its checksum, and the destination path. A direct
  pin resolves to itself; a dispatched spec fails closed with the declared
  tags named when the platform has no asset or no target.
  """
  @spec resolve(t() | map(), String.t()) :: %{
          url: String.t(),
          sha256: String.t(),
          target: String.t() | nil
        }
  def resolve(spec, platform \\ platform()) do
    pinned_target = resolve_target(spec, platform)

    case field(spec, :assets) do
      nil ->
        %{url: field(spec, :url), sha256: field(spec, :sha256), target: pinned_target}

      assets ->
        case Map.fetch(assets, platform) do
          {:ok, asset} -> %{url: asset.url, sha256: asset.sha256, target: pinned_target}
          :error ->
            raise ArgumentError,
                  "download target #{label(spec)} declares no asset for #{platform} " <>
                    "(declared: #{Enum.join(Map.keys(assets), ", ")})"
        end
    end
  end

  # The executing host's destination: the literal target, or the platform's
  # row of the declared targets table — fail-closed with the tags named.
  defp resolve_target(spec, platform) do
    case field(spec, :targets) do
      nil ->
        field(spec, :target)

      targets ->
        case Map.fetch(targets, platform) do
          {:ok, target} -> target
          :error ->
            raise ArgumentError,
                  "download pin #{label(spec)} declares no target for #{platform} " <>
                    "(declared: #{Enum.join(Map.keys(targets), ", ")})"
        end
    end
  end

  # The pin's human label for errors: the single target, or the resolved
  # platform row when the pin dispatches its destination.
  defp label(spec) do
    field(spec, :target) || Map.get(field(spec, :targets) || %{}, platform()) || "pin"
  end

  # The dispatched form: `%{assets: %{tag => %{url, sha256}}}`. Every key
  # must be a KNOWN platform tag — a typo'd tag would silently never install
  # — and every asset a full https pin.
  defp recipe_assets(attrs) do
    raw = attrs[:assets] || attrs["assets"]

    unless is_map(raw) and raw != %{},
      do: raise(ArgumentError, "download assets must be a non-empty table keyed by platform tag")

    Map.new(raw, fn {tag, asset} ->
      tag = to_string(tag)

      tag in @platform_tags ||
        raise(ArgumentError, "download assets declare unknown platform tag #{inspect(tag)} (known: #{Enum.join(@platform_tags, ", ")})")

      unless is_map(asset),
        do: raise(ArgumentError, "download asset for #{tag} must be a table with url and sha256")

      url = fetch_field(asset, :url)
      sha256 = fetch_field(asset, :sha256)
      validate_url(url)
      validate_sha256(sha256)
      {tag, %{url: url, sha256: sha256}}
    end)
  end

  @doc """
  Denormalize one recorded-envelope spec (string-keyed golden bytes) back to
  the validated recipe struct, so replay compares equal to native
  declarations. Raises `ArgumentError` on invalid shape.
  """
  @spec from_recorded(map()) :: t()
  def from_recorded(spec) when is_map(spec) do
    recipe(%{
      url: Map.get(spec, "url"),
      version: Map.get(spec, "version"),
      sha256: Map.get(spec, "sha256"),
      target: Map.get(spec, "target"),
      targets: Map.get(spec, "targets"),
      assets: Map.get(spec, "assets"),
      archive: Map.get(spec, "archive"),
      layout: Map.get(spec, "layout"),
      probe: Map.get(spec, "probe")
    })
  end

  def from_recorded(other),
    do: raise(ArgumentError, "download recipe must be a table, got: #{inspect(other)}")

  # The recorded-envelope dispatch seam: the download shape is
  # self-contained (no assets, no home anchoring), so the context only
  # contributes the package id for error attribution.
  @spec from_recorded(map(), map()) :: t()
  def from_recorded(spec, ctx) when is_map(spec) do
    from_recorded(spec)
  rescue
    e in [ArgumentError] ->
      raise ArgumentError,
            "golden input has an invalid download recipe for #{ctx.package_id}: #{Exception.message(e)}"
  end

  def from_recorded(other, _ctx),
    do: raise(ArgumentError, "download recipe must be a table, got: #{inspect(other)}")

  @doc """
  Validate one download recipe (the struct or any field map); raises
  `ArgumentError` on the first invalid field. Composition calls this on
  every collected download record.
  """
  @spec validate(map()) :: :ok
  def validate(%__MODULE__{} = spec) do
    validate_version(field(spec, :version))

    case field(spec, :targets) do
      nil ->
        field(spec, :target) || raise(ArgumentError, "download recipe requires target")
        validate_target(field(spec, :target))

      targets ->
        field(spec, :target) &&
          raise(ArgumentError, "download pin declares both target and targets — one destination per pin")

        Enum.each(Map.values(targets), &validate_target/1)
    end

    archive = field(spec, :archive)

    archive == nil or archive in @archive_formats ||
      raise(ArgumentError, "download archive must be one of #{Enum.join(@archive_formats, ", ")}, got: #{archive}")

    layout = field(spec, :layout)

    layout == nil or layout in @layouts ||
      raise(ArgumentError, "download layout must be one of #{Enum.join(@layouts, ", ")}, got: #{layout}")

    layout == nil or archive != nil || raise(ArgumentError, "download layout requires an archive pin")

    case field(spec, :probe) do
      nil ->
        archive == nil || raise(ArgumentError, "download archive pin requires a probe")

      probe ->
        archive != nil || raise(ArgumentError, "download probe requires an archive pin")

        validate_probe(probe, archive)
    end

    case field(spec, :assets) do
      nil ->
        validate_url(field(spec, :url))
        validate_sha256(field(spec, :sha256))

      assets ->
        Enum.each(assets, fn {tag, asset} ->
          tag in @platform_tags ||
            raise(ArgumentError, "download assets declare unknown platform tag #{inspect(tag)}")

          validate_url(asset.url)
          validate_sha256(asset.sha256)
        end)
    end

    :ok
  end

  def validate(other),
    do: raise(ArgumentError, "download recipe must be a validated struct, got: #{inspect(other)}")

  # --- the effect contract ---

  # A discovered member of the effect-contract family: the pipeline's
  # interpret fold installs the pinned artifact BEFORE the staged generation
  # applies (the fetch is the only network-bound step, its checksum is
  # fail-closed, and a refused download must never leave a half-applied
  # generation behind — the pending record, which already carries the
  # download targets, is the recovery anchor).
  @behaviour Workstation.Core.Contracts.Contract

  @doc "The wire contract id of pinned-artifact installs."
  def id, do: provider_id()

  @doc "Validate one declared spec (the behaviour's spec entry point)."
  def validate_spec(spec), do: validate(spec)

  @doc "The plan's install effects: one typed effect per pinned artifact."
  def plan_effect(plan, _ctx) do
    Enum.map(plan.downloads, fn download ->
      base = %{
        contract: id(),
        kind: :install,
        phase: :target,
        owner: download.owner,
        target: download.target,
        version: download.version,
        fingerprint: download.fingerprint
      }

      # The declared shape travels verbatim (assets and per-platform targets
      # stay unresolved): the executing host resolves at the apply boundary,
      # so a recorded plan stays machine-independent. The archive form's
      # fields travel the same way — absent on every file pin.
      base =
        case download[:archive] do
          nil -> base
          archive -> Map.merge(base, %{archive: archive, layout: download[:layout], probe: download[:probe]})
        end

      base =
        case Map.get(download, :targets) do
          nil -> base
          targets -> base |> Map.put(:target, nil) |> Map.put(:targets, targets)
        end

      case Map.get(download, :assets) do
        nil -> Map.merge(base, %{url: Map.get(download, :url), sha256: Map.get(download, :sha256)})
        assets -> Map.put(base, :assets, assets)
      end
    end)
  end

  # The fetch function is injected through ctx (`:fetch`); production
  # fetches HTTPS.
  def run_effect(effect, ctx) do
    install(effect, ctx.home, fetch: ctx[:fetch])
    :ok
  end

  # Downloaded artifacts join the applied record as first-class owned
  # targets: the fingerprint is recomputed from the ACTUAL home and must
  # carry the pinned checksum -- an install that did not produce exactly the
  # pinned bytes is a hard failure, never recorded. (`fingerprint/1` above
  # is the pin's content address; this is the applied-target claim.)
  #
  # The archive form claims through the declared probe (the bootstrap's
  # runtime-verify semantic): the target directory must exist, the probe
  # member must be a regular executable, and the probe output must carry
  # the pinned version — the archive's own sha256 rides the record as
  # provenance, never as a claim about tree bytes. The record type routes
  # verify to `verify_record/2` instead of the default file fingerprint.
  def fingerprint(%{archive: archive} = effect, ctx) when archive != nil do
    target = resolve_target(effect, platform())
    tree = Path.join(ctx.home, target)

    case Workstation.Core.EngineState.lstat(tree) do
      %{type: "directory", mode: mode} ->
        run_probe!(tree, target, effect[:probe], effect.version)
        resolved = resolve(effect)

        %{target =>
           %{
             "type" => "download-archive",
             "target" => target,
             "mode" => mode,
             "version" => effect.version,
             "archive" => archive,
             "archive_sha256" => resolved.sha256,
             "probe" => string_probe(effect),
             "owner" => effect.owner,
             "operation" => "download",
             "source_fingerprint" => effect.fingerprint
           }}

      _other ->
        raise ArgumentError, "apply did not produce download target " <> target
    end
  end

  def fingerprint(effect, ctx) do
    target = resolve_target(effect, platform())
    fingerprint = Workstation.Core.EngineState.target_fingerprint(ctx.home, target)
    resolved = resolve(effect)

    unless fingerprint,
      do: raise(ArgumentError, "apply did not produce download target " <> target)

    unless fingerprint["sha256"] == resolved.sha256 do
      raise ArgumentError,
            "applied download " <> target <> " does not carry the pinned checksum " <>
              "(" <> fingerprint["sha256"] <> " != " <> resolved.sha256 <> ")"
    end

    %{target =>
       Map.merge(fingerprint, %{
         "owner" => effect.owner,
         "operation" => "download",
         "source_fingerprint" => effect.fingerprint
       })}
  end

  @doc """
  The verify seam: a `download-archive` journal record re-probes the actual
  tree through its own declared probe — the probe member must still be a
  regular executable and the output must still carry the recorded pinned
  version; anything else is :unclaimed (the default file-fingerprint
  verification takes it) or a failed verify, never silently accepted.
  """
  @spec verify_record(map(), map()) :: :ok | :unclaimed
  def verify_record(%{"type" => "download-archive", "probe" => probe, "version" => version} = record, ctx) do
    target = Map.fetch!(record, "target")
    tree = Path.join(ctx["home"], target)

    case Workstation.Core.EngineState.lstat(tree) do
      %{type: "directory"} ->
        run_probe!(tree, target, probe, version)
        :ok

      _other ->
        raise ArgumentError, "verify: download target #{target} is gone"
    end
  end

  def verify_record(%{"type" => "download-archive"}, _ctx) do
    raise ArgumentError, "verify: download-archive record is missing its probe or version"
  end

  def verify_record(_record, _ctx), do: :unclaimed

  # --- the archive probe ---

  # The probe dispatches on its declared shape: the exec probe runs the
  # declared argv against the tree — never a shell, the executable is a
  # resolved member path — and holds the recorded version against the first
  # output line at a token boundary; the content probe holds the declared
  # member's extracted bytes against the pinned digest.
  defp run_probe!(tree, target, probe, version) do
    fields = probe_fields(probe)

    case fields do
      %{argv: [executable | args], output: template} ->
        run_exec_probe!(tree, target, executable, args, template, version)

      %{member: member, sha256: sha256} ->
        run_content_probe!(tree, target, member, sha256)
    end
  end

  defp run_exec_probe!(tree, target, executable, args, template, version) do
    binary = Path.join(tree, executable)

    mode = probed_file_mode!(tree, binary, target, executable)

    Bitwise.band(mode, 0o111) != 0 ||
      raise ArgumentError, "download probe member #{executable} is not executable in tree #{target}"

    case System.cmd(binary, args, stderr_to_stdout: true) do
      {out, 0} ->
        first = out |> String.split("\n", trim: true) |> List.first("")

        probe_carries_version?(first, template, version) ||
          raise ArgumentError,
                "download tree #{target} does not carry the pinned tool " <>
                  "(#{executable} reported `#{first}`, expected the pinned version #{version})"

        :ok

      {out, code} ->
        raise ArgumentError,
              "download probe for #{target} failed (exit #{code}): #{String.trim_trailing(out)}"
    end
  end

  defp run_content_probe!(tree, target, member, sha256) do
    path = Path.join(tree, member)

    probed_file_mode!(tree, path, target, member)
    actual = path |> File.read!() |> Digest.sha256()

    actual == sha256 ||
      raise ArgumentError,
            "download tree #{target} does not carry the pinned member " <>
              "(#{member} hashes to #{actual}, expected #{sha256})"

    :ok
  end

  # The probe member may be a symlink to a regular file (python-build-
  # standalone ships bin/python3 -> python3.14): lstat sees the link, the
  # probe must judge the file it resolves to. A dangling link, a link out
  # of the tree, or a non-file is a loud "lacks the probe member", never a
  # silent pass. Link chains resolve hop by hop, bounded.
  @max_link_depth 8

  defp probed_file_mode!(tree, path, target, member) do
    probed_file_mode!(tree, path, target, member, @max_link_depth)
  end

  defp probed_file_mode!(_tree, _path, target, member, 0) do
    missing_probe_member!(target, member)
  end

  defp probed_file_mode!(tree, path, target, member, depth) do
    case Workstation.Core.EngineState.lstat(path) do
      %{type: "link"} ->
        case File.read_link(path) do
          {:ok, link} ->
            resolved = Path.expand(link, Path.dirname(path))
            in_tree? = String.starts_with?(resolved, tree <> "/") or resolved == tree

            case Workstation.Core.EngineState.lstat(resolved) do
              %{type: "file", mode: mode} when in_tree? -> mode
              _other when in_tree? -> probed_file_mode!(tree, resolved, target, member, depth - 1)
              _other -> missing_probe_member!(target, member)
            end

          {:error, _reason} ->
            missing_probe_member!(target, member)
        end

      %{type: "file", mode: mode} ->
        mode

      _other ->
        missing_probe_member!(target, member)
    end
  end

  defp missing_probe_member!(target, member) do
    raise ArgumentError, "download tree #{target} lacks the probe member #{member}"
  end

  # The probe field map travels atom-keyed (recipes, effects) and
  # string-keyed (journal records); both resolve here.
  defp probe_fields(probe) when is_map(probe) do
    argv = Map.get(probe, :argv) || Map.get(probe, "argv")
    output = Map.get(probe, :output) || Map.get(probe, "output")
    member = Map.get(probe, :member) || Map.get(probe, "member")
    sha256 = Map.get(probe, :sha256) || Map.get(probe, "sha256")

    cond do
      argv != nil and is_list(argv) ->
        unless is_binary(output),
          do: raise(ArgumentError, "download probe must declare argv and output")

        %{argv: argv, output: output}

      member != nil and is_binary(member) ->
        is_binary(sha256) or raise(ArgumentError, "download content probe requires sha256")

        %{member: member, sha256: sha256}

      true ->
        raise ArgumentError, "download probe must declare argv and output, or member and sha256"
    end
  end

  # Template match with a token boundary: `1.27.1` must never satisfy a
  # probe of a `1.27.10` tree.
  defp probe_carries_version?(line, template, version) do
    prefix = String.replace(template, "{V}", version)

    if String.starts_with?(line, prefix) do
      rest = String.slice(line, byte_size(prefix), byte_size(line))
      rest == "" or String.starts_with?(rest, " ")
    else
      false
    end
  end

  # The recorded probe, string-keyed per its shape — the journal record and
  # the pin descriptor carry it verbatim so verify can re-run it.
  defp string_probe(spec) do
    case probe_fields(field(spec, :probe)) do
      %{argv: argv, output: output} -> %{"argv" => argv, "output" => output}
      %{member: member, sha256: sha256} -> %{"member" => member, "sha256" => sha256}
    end
  end

  @doc """
  The pin fingerprint: content address over the exact pin fields. Two plans
  whose pins differ in any field produce different generations.
  """
  @spec fingerprint(map()) :: String.t()
  def fingerprint(spec) do
    Digest.sha256(CanonicalJSON.encode(pin_fields(spec)))
  end

  @doc """
  The staged pin descriptor: the machine-readable provenance record written
  into the generation directory, verified byte-for-byte with the generation.
  """
  @spec pin_bytes(map()) :: String.t()
  def pin_bytes(spec), do: CanonicalJSON.encode(pin_fields(spec))

  @doc """
  The generation-directory name of the pin descriptor: content-keyed by the
  pinned sha256 (direct pins) or by the pin fingerprint (dispatched pins —
  the descriptor carries every platform's provenance), so two pins of one
  artifact share one descriptor path.
  """
  @spec pin_source_name(map()) :: String.t()
  def pin_source_name(spec) do
    case field(spec, :assets) do
      nil -> "download/" <> String.slice(field(spec, :sha256), 0, 16) <> ".pin.json"
      _assets -> "download/" <> String.slice(fingerprint(spec), 0, 16) <> ".pin.json"
    end
  end

  @doc """
  Install the pinned artifact into `home` at the recipe target.

  File form: idempotent (a target already carrying the pinned content
  answers `{:ok, :already_installed}` without fetching), fail-closed
  (downloaded bytes that do not match the pinned sha256 raise and install
  nothing; an existing target with different content is never overwritten),
  staged (the file is written under a temporary name in the target
  directory and renamed into place, so an interrupted install can never
  leave a half-written artifact).

  Archive form (`archive:` pin): the pinned archive's bytes are
  checksum-gated before anything is extracted, the archive is
  traversal-checked, extracted per its declared layout into a private
  staging directory beside the target, the staged tree is proven by the
  declared probe, and one rename places the exact tree at the target. An
  existing directory answers `{:ok, :already_installed}` only when the
  probe carries the pinned version (no fetch); otherwise it is refused,
  never overwritten — inspect and remove it explicitly to re-install.
  Serialization is the pipeline's caller-held apply lock.
  """
  @spec install(t() | map(), String.t(), keyword()) :: {:ok, :installed} | {:ok, :already_installed}
  def install(spec, home, opts \\ []) when is_binary(home) and home != "" do
    # Per-platform dispatch (asset and target) resolves HERE — the apply
    # boundary — through the contract, never in the caller.
    resolved = resolve(spec)
    fetch = Keyword.get(opts, :fetch) || (&http_fetch/1)
    path = Path.join(home, resolved.target)

    case field(spec, :archive) do
      nil -> install_file(spec, resolved, fetch, path)
      archive -> install_archive(spec, archive, resolved, fetch, path)
    end
  end

  # The file form: byte equality at the target path.
  defp install_file(spec, resolved, fetch, path) do
    case File.read(path) do
      {:ok, content} ->
        if Digest.sha256(content) == resolved.sha256 do
          {:ok, :already_installed}
        else
          raise ArgumentError,
                "download target #{field(spec, :target)} exists with different content " <>
                  "(sha256 #{Digest.sha256(content)}, expected #{resolved.sha256}); " <>
                  "refusing to overwrite a mismatched artifact"
        end

      {:error, :enoent} ->
        install_verified(field(spec, :target), resolved, path, fetch.(resolved.url))

      {:error, reason} ->
        raise ArgumentError, "download target #{field(spec, :target)} is unreadable: #{inspect(reason)}"
    end
  end

  # The archive form: an exact tree at a directory target, gated by the
  # declared probe.
  defp install_archive(spec, archive, resolved, fetch, path) do
    case Workstation.Core.EngineState.lstat(path) do
      nil ->
        extract_and_activate(spec, archive, resolved, fetch, path)

      %{type: "directory"} ->
        try do
          run_probe!(path, resolved.target, field(spec, :probe), field(spec, :version))
          {:ok, :already_installed}
        rescue
          error in [ArgumentError] ->
            raise ArgumentError,
                  Exception.message(error) <>
                    "; refusing to overwrite — inspect and remove the tree explicitly to re-install"
        end

      %{type: other} ->
        raise ArgumentError, "download target #{resolved.target} exists as #{other}; refusing to replace it"
    end
  end

  # The bootstrap's staging discipline, minus the lock: debris staging
  # siblings swept, the archive bytes checksum-gated before anything is
  # extracted, the staged tree probe-verified, then one rename places the
  # exact tree at the never-before-present target. The pipeline's caller
  # holds the apply lock across the whole fold, so no second installer can
  # race the rename.
  defp extract_and_activate(spec, archive, resolved, fetch, path) do
    parent = Path.dirname(path)
    File.mkdir_p!(parent)
    basename = Path.basename(path)
    sweep_staging_debris!(parent, basename)

    staging =
      Path.join(parent, "." <> basename <> ".download-#{:os.getpid()}-#{System.system_time(:native)}")

    try do
      File.mkdir!(staging)
      archive_file = Path.join(staging, "download." <> archive)
      bytes = fetch.(resolved.url)
      verify_pinned_bytes!(resolved, bytes)
      File.write!(archive_file, bytes)
      extract_tree!(archive_file, staging, archive, field(spec, :layout))
      File.rm(archive_file)
      run_probe!(staging, resolved.target, field(spec, :probe), field(spec, :version))

      case File.rename(staging, path) do
        :ok -> {:ok, :installed}
        {:error, reason} -> raise ArgumentError, "download install failed for #{resolved.target}: #{inspect(reason)}"
      end
    after
      File.rm_rf!(staging)
    end
  end

  defp verify_pinned_bytes!(resolved, bytes) when is_binary(bytes) do
    actual = Digest.sha256(bytes)

    unless actual == resolved.sha256 do
      raise ArgumentError,
            "downloaded artifact #{resolved.url} failed the pinned checksum: " <>
              "expected #{resolved.sha256}, got #{actual}; nothing was installed"
    end

    :ok
  end

  defp verify_pinned_bytes!(_resolved, other) do
    raise ArgumentError, "download fetch returned non-binary: #{inspect(other)}"
  end

  defp install_verified(target, resolved, path, bytes) when is_binary(bytes) do
    verify_pinned_bytes!(resolved, bytes)

    directory = Path.dirname(path)
    File.mkdir_p!(directory)
    staged = Path.join(directory, ".download-#{:os.getpid()}-#{System.system_time(:native)}")
    File.write!(staged, bytes)
    File.chmod!(staged, 0o755)

    case File.rename(staged, path) do
      :ok -> {:ok, :installed}
      {:error, reason} -> raise ArgumentError, "download install failed for #{target}: #{inspect(reason)}"
    end
  end

  defp install_verified(target, _resolved, _path, other) do
    raise ArgumentError, "download fetch for #{target} returned non-binary: #{inspect(other)}"
  end

  @doc """
  The default fetch: one HTTPS GET returning the response body, with the
  redirect chain followed hop by hop.

  Every hop gets its own TLS session options: `server_name_indication` and
  the hostname-check reference id must name the host the connection actually
  talks to (a GitHub release pin redirects to a different host, e.g.
  `release-assets.githubusercontent.com`), and the peer cert is verified
  with `public_key.pkix_verify_hostname_match_fun(:https)` so single-label
  wildcard certs (`*.githubusercontent.com`) match per RFC 6125 — ssl's
  default hostname check is exact-match and fails such chains with
  `hostname_check_failed`. inets' own autoredirect carries one flat ssl
  option set across hops, so the fetch owns the chain: at most
  #{@max_redirects} redirects, never downgrading to plain http. A hop's GET
  is idempotent, so a transport-level loss is retried on a fresh connection
  (bounded #{@max_hop_attempts} attempts, short settle — retries never count
  as hops). The pinned sha256 of the FINAL body is verified by `install/3`
  exactly as before.
  """
  @spec http_fetch(String.t()) :: binary()
  def http_fetch(url) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    fetch_hop(url, cacerts(), 0)
  end

  defp fetch_hop(url, cacerts, hop, attempts_left \\ @max_hop_attempts)

  defp fetch_hop(url, cacerts, hop, attempts_left) when hop <= @max_redirects do
    request = {String.to_charlist(url), []}

    http_options = [
      ssl: [
        verify: :verify_peer,
        cacerts: cacerts,
        depth: 3,
        server_name_indication: connected_host(url),
        customize_hostname_check: [match_fun: hostname_match_fun()]
      ],
      autoredirect: false
    ]

    case :httpc.request(:get, request, http_options, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        body

      {:ok, {{_version, status, _reason}, headers, _body}} when status in @redirect_statuses ->
        fetch_hop(redirect_location(headers, url), cacerts, hop + 1)

      {:ok, {{_version, status, reason}, _headers, _body}} ->
        raise ArgumentError, "download fetch for #{url} failed: HTTP #{status} #{reason}"

      {:error, reason} when reason in @transient_connect_errors and attempts_left > 1 ->
        # A hop's GET is idempotent, so a transport-level loss is retried on
        # a fresh connection (RFC 7230 6.3.1: a client must recover from an
        # asynchronous close). Pinned under the loaded-suite battery: the
        # server answers and closes cleanly, the client still reads
        # :einval/:closed off the wire (inet/ssl driver race under scheduler
        # pressure) — ~5% of requests under load, in bursts: back-to-back
        # losses on one hop are common, so each retry settles exponentially
        # instead of racing the spike. Retries never count as redirect
        # hops; the pinned sha256 of the FINAL body stays the real gate.
        index = @max_hop_attempts - attempts_left
        Process.sleep(Enum.at(@hop_retry_settle_ms, index))
        fetch_hop(url, cacerts, hop, attempts_left - 1)

      {:error, reason} ->
        raise ArgumentError, "download fetch for #{url} failed: #{inspect(reason)}"
    end
  end

  defp fetch_hop(url, _cacerts, _hop, _attempts_left),
    do: raise(ArgumentError, "download fetch for #{url} failed: exceeded #{@max_redirects} redirects")

  # The SNI value and the hostname reference id are the CONNECTED host's
  # name — never a pre-resolved address or a previous hop's identity.
  defp connected_host(url) do
    case URI.parse(url).host do
      host when is_binary(host) and host != "" -> String.to_charlist(host)
      _ -> raise ArgumentError, "download fetch for #{url} failed: url has no hostname"
    end
  end

  defp redirect_location(headers, url) do
    location =
      Enum.find_value(headers, fn {name, value} ->
        String.downcase(to_string(name)) == "location" && to_string(value)
      end)

    location || raise ArgumentError, "download fetch for #{url} failed: redirect without a location"

    target = url |> URI.parse() |> URI.merge(location) |> URI.to_string()

    String.starts_with?(target, "https://") ||
      raise ArgumentError, "download fetch for #{url} refuses non-https redirect: #{target}"

    target
  end

  # Resolved at runtime through apply/3: the compiler has no compile-time
  # view of the Erlang distribution's public_key app, and the call stays
  # fail-closed -- a missing trust store raises, it never disables checks.
  defp cacerts, do: apply(:public_key, :cacerts_get, [])
  defp hostname_match_fun, do: apply(:public_key, :pkix_verify_hostname_match_fun, [:https])

  # --- archive extraction ---

  # Member-checked extraction under the declared layout: traversal is
  # rejected before anything extracts; `release` demands exactly one root —
  # a root directory strips one component (the release-archive layout), a
  # lone root file is the tree itself; `flat` takes the top-level members
  # as they are (the staging directory is always fresh, so a rootless tree
  # cannot merge into anything).
  defp extract_tree!(archive_file, staging, archive, layout) do
    names = list_members!(archive_file, archive)
    names != [] || raise(ArgumentError, "download archive carries no members")
    Enum.each(names, &safe_member!/1)

    case layout || "release" do
      "release" -> extract_release!(archive_file, staging, archive, names)
      "flat" -> extract_members!(archive_file, staging, archive, [])
      other -> raise(ArgumentError, "download layout must be one of #{Enum.join(@layouts, ", ")}, got: #{other}")
    end
  end

  # The release discipline: exactly one root. A root DIRECTORY extracts with
  # one component stripped; a lone root FILE is the tree itself. A
  # multi-root archive is a loud failure — merging unrelated top-level
  # members into one target is never a silent act.
  defp extract_release!(archive_file, staging, archive, names) do
    roots = MapSet.new(names, &root_of/1)

    MapSet.size(roots) == 1 ||
      raise(ArgumentError, "download archive must carry exactly one root directory (got: #{Enum.join(roots, ", ")})")

    # Directory members either end in the tar/zip listing's trailing slash or
    # carry a nested path — a member with neither is a lone root file, and
    # the tree is that file.
    if Enum.any?(names, &String.contains?(&1, "/")) do
      validate_layout_root!(root_of(hd(names)), names)
      extract_members!(archive_file, staging, archive, strip: 1)
    else
      extract_members!(archive_file, staging, archive, [])
    end
  end

  # Every member hangs under the one root: a stray top-level sibling would
  # survive the strip and pollute the target.
  defp validate_layout_root!(root, names) do
    Enum.each(names, fn name ->
      member = String.trim_trailing(name, "/")

      member == root or String.starts_with?(member, root <> "/") ||
        raise(ArgumentError, "download archive must carry exactly one root directory (got: #{root}, #{member})")
    end)

    :ok
  end

  # The extraction itself, per format: tar for the tarballs (with the
  # optional strip), unzip for zip archives (whose pins are always flat or
  # single-file — a zip with a root directory has no release layout until a
  # real pin needs one).
  defp extract_members!(archive_file, staging, archive, opts) do
    case archive do
      "tar.gz" -> tool_cmd!("tar", ["-xzf", archive_file, "-C", staging] ++ strip_args(opts), archive_file)
      "tar.xz" -> tool_cmd!("tar", ["-xJf", archive_file, "-C", staging] ++ strip_args(opts), archive_file)
      "zip" -> zip_extract!(archive_file, staging, opts)
      other -> raise(ArgumentError, "download archive must be one of #{Enum.join(@archive_formats, ", ")}, got: #{other}")
    end

    :ok
  end

  defp strip_args(opts) do
    case Keyword.get(opts, :strip) do
      nil -> []
      1 -> ["--strip-components=1"]
      other -> raise(ArgumentError, "download archive strip must be 1, got: #{inspect(other)}")
    end
  end

  defp zip_extract!(archive_file, staging, opts) do
    if Keyword.get(opts, :strip) do
      raise ArgumentError, "download zip archives carry no root directory to strip — declare the flat layout"
    end

    tool_cmd!("unzip", ["-q", "-o", archive_file, "-d", staging], archive_file)
  end

  # The member listing, per format — one name per line, directories with a
  # trailing slash (tar -t and unzip -Z1 both keep it).
  defp list_members!(archive_file, archive) do
    out =
      case archive do
        "tar.gz" -> tool_cmd!("tar", ["-tzf", archive_file], archive_file)
        "tar.xz" -> tool_cmd!("tar", ["-tJf", archive_file], archive_file)
        "zip" -> tool_cmd!("unzip", ["-Z1", archive_file], archive_file)
        other -> raise(ArgumentError, "download archive must be one of #{Enum.join(@archive_formats, ", ")}, got: #{other}")
      end

    String.split(out, "\n", trim: true)
  end

  # The apply-time extraction tools are named host prerequisites: tar for
  # the tarballs, unzip for zip. A missing tool is a loud, named failure —
  # never a silent fallback — and a failing extraction carries the tool's
  # own stderr.
  defp tool_cmd!(tool, args, archive_file) do
    case System.cmd(tool, args, stderr_to_stdout: true) do
      {out, 0} ->
        out

      {out, code} ->
        raise ArgumentError,
              "download archive extraction failed (exit #{code}): #{String.trim_trailing(out)}"
    end
  rescue
    e in [ErlangError] ->
      if match?(%ErlangError{original: :enoent}, e),
        do: missing_tool!(tool, archive_file),
        else: reraise(e, __STACKTRACE__)

    e in [File.Error] ->
      if match?(%File.Error{reason: :enoent}, e),
        do: missing_tool!(tool, archive_file),
        else: reraise(e, __STACKTRACE__)
  end

  defp missing_tool!(tool, archive_file) do
    raise ArgumentError,
          "download apply requires the host tool `#{tool}` (archive #{Path.basename(archive_file)}); " <>
            "install it and re-apply"
  end

  defp safe_member!(name) do
    traversal? =
      name == "" or String.starts_with?(name, "/") or name == ".." or String.starts_with?(name, "../") or
        String.contains?(name, "/../") or String.ends_with?(name, "/..")

    traversal? && raise(ArgumentError, "download: unsafe archive member")

    String.match?(name, ~r/[\x00]/) && raise(ArgumentError, "download: unsafe archive member")
    :ok
  end

  defp root_of(name), do: hd(String.split(name, "/", parts: 2))

  # Debris from an interrupted install: the caller holds the apply lock, so
  # no other installer can be mid-flight and any sibling matching this
  # target's staging prefix is removable (the bootstrap's lock-dir cleanup,
  # minus the lock).
  defp sweep_staging_debris!(parent, basename) do
    parent
    |> Path.join("." <> basename <> ".download-*")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf/1)

    :ok
  end

  # --- validation ---

  defp pin_fields(spec) do
    base = %{"target" => field(spec, :target), "version" => field(spec, :version)}

    base =
      case field(spec, :targets) do
        nil -> base
        targets -> Map.put(base, "targets", targets)
      end

    base =
      case field(spec, :archive) do
        nil -> base
        archive -> Map.merge(base, %{"archive" => archive, "layout" => field(spec, :layout), "probe" => string_probe(spec)})
      end

    # The declared shape travels verbatim: the pin descriptor is
    # machine-independent (a recorded generation pins EVERY platform's
    # provenance), and the resolution happens only at the apply boundary.
    case field(spec, :assets) do
      nil ->
        Map.merge(base, %{"sha256" => field(spec, :sha256), "url" => field(spec, :url)})

      assets ->
        Map.put(base, "assets", Map.new(assets, fn {tag, asset} -> {tag, %{"sha256" => asset.sha256, "url" => asset.url}} end))
    end
    |> drop_nil_fields()
  end

  defp drop_nil_fields(fields), do: fields |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp field(spec, key) when is_map(spec), do: Map.get(spec, key)

  defp fetch_field(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
    is_binary(value) and value != "" || raise(ArgumentError, "download recipe requires #{key}")
    value
  end

  defp validate_url(url) do
    String.starts_with?(url, "https://") ||
      raise(ArgumentError, "download url must be https (pinned supply chain), got: #{url}")
  end

  defp validate_version(version) do
    not String.match?(version, ~r/[\x00-\x1f\x7f]/) ||
      raise(ArgumentError, "download version must not contain control characters")
  end

  defp validate_sha256(sha256) do
    Regex.match?(~r/\A[0-9a-f]{64}\z/, sha256) ||
      raise(ArgumentError, "download sha256 must be 64 lowercase hex digits, got: #{sha256}")
  end

  defp validate_target(target) do
    not String.match?(target, ~r/[\x00-\x1f\x7f]/) ||
      raise(ArgumentError, "download target must not contain control characters: #{target}")

    not String.match?(target, ~r/[*?\[\]]/) ||
      raise(ArgumentError, "download target must be a literal path: #{target}")

    not String.starts_with?(target, "/") && not String.starts_with?(target, "~") &&
        not Regex.match?(~r/(\A|\/)\.\.?(\z|\/)/, target) ||
      raise(ArgumentError, "download target must be a relative path inside the home: #{target}")

    not is_within(target, @engine_state_target) && not encompasses(target, @engine_state_target) ||
      raise(ArgumentError, "download target overlaps engine-private state: #{target}")

    :ok
  end

  defp is_within(target, ancestor),
    do: target == ancestor or String.starts_with?(target, ancestor <> "/")

  defp encompasses(ancestor, target), do: is_within(target, ancestor)
end
