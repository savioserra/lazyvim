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
  """

  alias Workstation.Core.{CanonicalJSON, Digest}

  @engine_state_target ".local/state/workstation"

  @enforce_keys [:url, :version, :sha256, :target]
  defstruct [:url, :version, :sha256, :target]

  @type t :: %__MODULE__{
          url: String.t(),
          version: String.t(),
          sha256: String.t(),
          target: String.t()
        }

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
    url = fetch_field(attrs, :url)
    version = fetch_field(attrs, :version)
    sha256 = fetch_field(attrs, :sha256)
    target = fetch_field(attrs, :target)

    validate_url(url)
    validate_version(version)
    validate_sha256(sha256)
    validate_target(target)

    %__MODULE__{url: url, version: version, sha256: sha256, target: target}
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
      target: Map.get(spec, "target")
    })
  end

  def from_recorded(other),
    do: raise(ArgumentError, "download recipe must be a table, got: #{inspect(other)}")

  @doc """
  Validate one download recipe (the struct or any field map); raises
  `ArgumentError` on the first invalid field. Composition calls this on
  every collected download record.
  """
  @spec validate(map()) :: :ok
  def validate(%__MODULE__{} = spec) do
    validate_url(field(spec, :url))
    validate_version(field(spec, :version))
    validate_sha256(field(spec, :sha256))
    validate_target(field(spec, :target))
    :ok
  end

  def validate(other),
    do: raise(ArgumentError, "download recipe must be a validated struct, got: #{inspect(other)}")

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
  pinned sha256, so two pins of one artifact share one descriptor path.
  """
  @spec pin_source_name(map()) :: String.t()
  def pin_source_name(spec), do: "download/" <> String.slice(field(spec, :sha256), 0, 16) <> ".pin.json"

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
    fetch = Keyword.get(opts, :fetch) || (&http_fetch/1)
    path = Path.join(home, field(spec, :target))

    case File.read(path) do
      {:ok, content} ->
        if Digest.sha256(content) == field(spec, :sha256) do
          {:ok, :already_installed}
        else
          raise ArgumentError,
                "download target #{field(spec, :target)} exists with different content " <>
                  "(sha256 #{Digest.sha256(content)}, expected #{field(spec, :sha256)}); " <>
                  "refusing to overwrite a mismatched artifact"
        end

      {:error, :enoent} ->
        bytes = fetch.(field(spec, :url))
        install_verified(spec, path, bytes)

      {:error, reason} ->
        raise ArgumentError, "download target #{field(spec, :target)} is unreadable: #{inspect(reason)}"
    end
  end

  defp install_verified(spec, path, bytes) when is_binary(bytes) do
    actual = Digest.sha256(bytes)

    unless actual == field(spec, :sha256) do
      raise ArgumentError,
            "downloaded artifact #{field(spec, :url)} failed the pinned checksum: " <>
              "expected #{field(spec, :sha256)}, got #{actual}; nothing was installed"
    end

    directory = Path.dirname(path)
    File.mkdir_p!(directory)
    staged = Path.join(directory, ".download-#{:os.getpid()}-#{System.system_time(:native)}")
    File.write!(staged, bytes)
    File.chmod!(staged, 0o755)

    case File.rename(staged, path) do
      :ok -> {:ok, :installed}
      {:error, reason} -> raise ArgumentError, "download install failed for #{field(spec, :target)}: #{inspect(reason)}"
    end
  end

  defp install_verified(spec, _path, other) do
    raise ArgumentError, "download fetch for #{field(spec, :url)} returned non-binary: #{inspect(other)}"
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

  defp pin_fields(spec),
    do: %{
      "sha256" => field(spec, :sha256),
      "target" => field(spec, :target),
      "url" => field(spec, :url),
      "version" => field(spec, :version)
    }

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
