defmodule Workstation.Core.Contracts.Download do
  @moduledoc """
  The pinned-artifact source contract: a thing that declares a pinned
  artifact (url + version + sha256 + target) into the home.

  Layer: contract. The contract law: a pin declares exactly its pinned
  bytes, or exactly the tree a checksum-gated archive carries — nothing
  else is ever declared (implementor policy: implementations are the
  engine's own contract modules; discovery finds them by behaviour
  conformance).

  The plan stays pure: a download recipe contributes a validated pin whose
  descriptor is content-addressed into the plan manifest, so the generation
  id changes whenever a pin changes and the generation directory carries the
  machine-readable pin provenance. Execution retired with the engine's
  write plane — the nix substrate's workstation-switch drivers own the
  fetch and the install. This module's face is the declared program:
  validation, per-platform resolution, the pin fingerprint/descriptor, and
  the plan's typed effects. Recipe constructors raise `ArgumentError` with
  anchored messages, exactly like the other source contracts.

  Per-platform dispatch is resolved THROUGH the contract, never by ad-hoc
  conditionals in consumers: a spec either pins ONE artifact directly
  (`url` + `sha256`) or declares `assets` keyed by platform tag —
  `%{"linux_x86_64" => %{url: ..., sha256: ...}, "darwin_arm64" => %{...}}` —
  and `resolve/2` resolves the asking host's tag (`platform/0`; the tag
  vocabulary is the bootstrap pins manifest's). The declared assets travel
  verbatim through the plan, the fingerprint and the recorded envelope — a
  pin change on ANY platform changes the generation, and a recorded plan
  stays machine-independent.

  ## The archive form

  A pin may declare `archive: "tar.gz"`, `"tar.xz"` or `"zip"`: the pinned
  artifact is then a release ARCHIVE installed as an exact tree — the
  checksum gate applies to the archive bytes, and the declared `probe`
  (data, below) is what proves an activated tree is the pinned tool. An
  archive target is a directory inside the home.

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
      the 1Password `op`/`op.sig` pair, the Nerd Font ttf set).

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

  ## Per-platform targets

  A pin installs at ONE target path; like its assets, that path may be
  platform-specific: a spec declares either `target` (one literal) or
  `targets` keyed by the platform tag vocabulary (`%{"linux_x86_64" =>
  ".local/share/fonts/...", "darwin_arm64" => "Library/Fonts/..."}`). The
  declared targets travel verbatim through the plan — `resolve/2` resolves
  the asking host's own — so a recorded plan stays machine-independent.
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
