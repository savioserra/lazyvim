defmodule Workstation.Core.Contracts.Download do
  @moduledoc """
  The pinned-artifact source contract: a thing that fetches a pinned
  artifact (url + version + sha256 + target) into the home.

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
  """

  alias Workstation.Core.{CanonicalJSON, Digest}

  @engine_state_target ".local/state/workstation"

  @enforce_keys [:version, :target]
  defstruct [:url, :version, :sha256, :target, :assets]

  @typedoc "One platform's pinned asset: an https url and its checksum."
  @type asset :: %{required(:url) => String.t(), required(:sha256) => String.t()}

  @type t :: %__MODULE__{
          url: String.t() | nil,
          version: String.t(),
          sha256: String.t() | nil,
          target: String.t(),
          assets: %{optional(String.t()) => asset()} | nil
        }

  @platform_tags ~w(linux_x86_64 darwin_arm64)

  @doc "The wire provider id for pinned-artifact contributions."
  @spec provider_id() :: String.t()
  def provider_id, do: "download"

  @doc """
  Build one validated download recipe. Raises `ArgumentError` on any
  invalid field: the url must be https (the supply-chain posture of a
  checksummed fetch), the sha256 must be 64 lowercase hex digits, the
  version a non-empty string, and the target a safe relative literal path
  that never touches engine-private state.
  """
  @spec recipe(map()) :: t()
  def recipe(attrs) when is_map(attrs) do
    version = fetch_field(attrs, :version)
    target = fetch_field(attrs, :target)
    validate_version(version)
    validate_target(target)

    if attrs[:assets] != nil or attrs["assets"] != nil do
      %__MODULE__{version: version, target: target, assets: recipe_assets(attrs)}
    else
      url = fetch_field(attrs, :url)
      sha256 = fetch_field(attrs, :sha256)
      validate_url(url)
      validate_sha256(sha256)
      %__MODULE__{url: url, version: version, sha256: sha256, target: target}
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
  host). A direct pin resolves to itself; a dispatched spec fails closed
  with the declared tags named when the platform has no asset.
  """
  @spec resolve(t() | map(), String.t()) :: %{url: String.t(), sha256: String.t()}
  def resolve(spec, platform \\ platform()) do
    case field(spec, :assets) do
      nil ->
        %{url: field(spec, :url), sha256: field(spec, :sha256)}

      assets ->
        case Map.fetch(assets, platform) do
          {:ok, asset} -> %{url: asset.url, sha256: asset.sha256}
          :error ->
            raise ArgumentError,
                  "download target #{field(spec, :target)} declares no asset for #{platform} " <>
                    "(declared: #{Enum.join(Map.keys(assets), ", ")})"
        end
    end
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
    if Map.get(spec, "assets") != nil do
      recipe(%{version: Map.get(spec, "version"), target: Map.get(spec, "target"), assets: Map.get(spec, "assets")})
    else
      recipe(%{
        url: Map.get(spec, "url"),
        version: Map.get(spec, "version"),
        sha256: Map.get(spec, "sha256"),
        target: Map.get(spec, "target")
      })
    end
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
    validate_target(field(spec, :target))

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

      # The declared shape travels verbatim (assets stay unresolved): the
      # executing host resolves at the apply boundary, so a recorded plan
      # stays machine-independent.
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
  def fingerprint(effect, ctx) do
    fingerprint = Workstation.Core.EngineState.target_fingerprint(ctx.home, effect.target)
    resolved = resolve(effect)

    unless fingerprint,
      do: raise(ArgumentError, "apply did not produce download target " <> effect.target)

    unless fingerprint["sha256"] == resolved.sha256 do
      raise ArgumentError,
            "applied download " <> effect.target <> " does not carry the pinned checksum " <>
              "(" <> fingerprint["sha256"] <> " != " <> resolved.sha256 <> ")"
    end

    %{effect.target =>
       Map.merge(fingerprint, %{
         "owner" => effect.owner,
         "operation" => "download",
         "source_fingerprint" => effect.fingerprint
       })}
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

  Idempotent: a target already carrying the pinned content answers
  `{:ok, :already_installed}` without fetching. Fail-closed: downloaded
  bytes that do not match the pinned sha256 raise and install nothing, and
  an existing target with different content is never overwritten. The file
  is staged under a temporary name in the target directory and renamed into
  place, so an interrupted install can never leave a half-written artifact.
  """
  @spec install(t() | map(), String.t(), keyword()) :: {:ok, :installed} | {:ok, :already_installed}
  def install(spec, home, opts \\ []) when is_binary(home) and home != "" do
    # Per-platform dispatch resolves HERE — the apply boundary — through the
    # contract, never in the caller.
    resolved = resolve(spec)
    fetch = Keyword.get(opts, :fetch) || (&http_fetch/1)
    path = Path.join(home, field(spec, :target))

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
        bytes = fetch.(resolved.url)
        install_verified(field(spec, :target), resolved, path, bytes)

      {:error, reason} ->
        raise ArgumentError, "download target #{field(spec, :target)} is unreadable: #{inspect(reason)}"
    end
  end

  defp install_verified(target, resolved, path, bytes) when is_binary(bytes) do
    actual = Digest.sha256(bytes)

    unless actual == resolved.sha256 do
      raise ArgumentError,
            "downloaded artifact #{resolved.url} failed the pinned checksum: " <>
              "expected #{resolved.sha256}, got #{actual}; nothing was installed"
    end

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

  @doc "The default fetch: one HTTPS GET returning the response body."
  @spec http_fetch(String.t()) :: binary()
  def http_fetch(url) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    request = {String.to_charlist(url), []}
    http_options = [ssl: [verify: :verify_peer, cacerts: cacerts(), depth: 3]]

    case :httpc.request(:get, request, http_options, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} -> body
      {:ok, {{_version, status, reason}, _headers, _body}} -> raise ArgumentError, "download fetch for #{url} failed: HTTP #{status} #{reason}"
      {:error, reason} -> raise ArgumentError, "download fetch for #{url} failed: #{inspect(reason)}"
    end
  end

  # Resolved at runtime through apply/3: the compiler has no compile-time
  # view of the Erlang distribution's public_key app, and the call stays
  # fail-closed -- a missing trust store raises, it never disables checks.
  defp cacerts, do: apply(:public_key, :cacerts_get, [])

  # --- validation ---

  defp pin_fields(spec) do
    base = %{"target" => field(spec, :target), "version" => field(spec, :version)}

    case field(spec, :assets) do
      nil ->
        Map.merge(base, %{"sha256" => field(spec, :sha256), "url" => field(spec, :url)})

      assets ->
        # The declared assets travel verbatim: the pin descriptor is
        # machine-independent (a recorded generation pins EVERY platform's
        # provenance), and the resolution happens only at the apply boundary.
        Map.put(base, "assets", Map.new(assets, fn {tag, asset} -> {tag, %{"sha256" => asset.sha256, "url" => asset.url}} end))
    end
  end

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
