defmodule Workstation.Core.Theme do
  @moduledoc """
  Pure theme overlay resolution.

  Base palettes come from `Workstation.Core.Theme.Tokens`; client overlays
  patch roles in explicit array order, later patches winning per role.
  Validation is envelope-wide: one bad appearance, unknown role or malformed
  hex value rejects the entire request, never silently partially applies.

  This module is daemon-agnostic; the daemon capability
  (`Workstation.Daemon.Capabilities.Theme`) is a thin shell around it and
  publishes resolved themes on the `"theme"` pubsub domain.
  """

  alias Workstation.Core.Theme.Tokens

  @appearance ["dark", "light"]

  # Roles overlays may patch: the full palette surface. Slot-only roles
  # (terminal named slots) are not overridable with concrete hex values.
  # String-keyed: JSON object keys arrive as binaries.
  @settable_roles ["accent", "ok", "warn", "err", "chrome", "text", "bg", "muted"]

  @typedoc "Resolved theme: the appearance plus its full role-to-hex palette."
  @type resolved :: %{String.t() => term()}

  @doc "Appearances accepted for overlay resolution."
  @spec appearances() :: [String.t()]
  def appearances, do: @appearance

  @doc "Roles an overlay patch may set."
  @spec settable_roles() :: [String.t()]
  def settable_roles, do: @settable_roles

  @doc """
  Resolve one theme-overlay request onto the base palette.

  Params (validated upstream by the daemon schema, re-checked here because
  this is the contract's only enforcement point):

    * `appearance` — `"dark"` or `"light"` (base palette selector)
    * `overlays` — ordered `[%{"from" => name, "set" => %{role => "#rrggbb"}}]`
  """
  @spec resolve(%{String.t() => term()}) :: {:ok, resolved()} | {:error, {String.t(), String.t()}}
  def resolve(%{"appearance" => appearance, "overlays" => overlays})
      when appearance in @appearance and is_list(overlays) do
    with :ok <- validate_overlays(overlays) do
      {:ok, apply_overlays(appearance, overlays)}
    end
  end

  def resolve(%{"appearance" => appearance, "overlays" => _overlays})
      when appearance in @appearance do
    {:error, {"invalid_params", "overlays must be a list"}}
  end

  def resolve(%{"appearance" => appearance}) when appearance in @appearance do
    {:ok, apply_overlays(appearance, [])}
  end

  def resolve(%{"appearance" => appearance}) do
    {:error, {"invalid_params", "unknown appearance: #{inspect(appearance)}"}}
  end

  def resolve(_other) do
    {:error, {"invalid_params", "theme resolve requires appearance and overlays"}}
  end

  defp apply_overlays(appearance, overlays) do
    base = base_palette(appearance)

    colors =
      Enum.reduce(overlays, base, fn overlay, acc ->
        Map.merge(acc, string_keys(overlay["set"]))
      end)

    %{"appearance" => appearance, "colors" => colors}
  end

  defp base_palette(appearance) do
    Tokens.palette(appearance)
    |> Map.new(fn {role, hex} -> {Atom.to_string(role), hex} end)
  end

  defp string_keys(set) when is_map(set) do
    Map.new(set, fn {key, value} -> {to_string(key), value} end)
  end

  defp validate_overlays(overlays) do
    overlays
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {overlay, index}, :ok ->
      case validate_overlay(overlay, index) do
        :ok -> {:cont, :ok}
        {:error, _code, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, code, message} -> {:error, {code, message}}
    end
  end

  defp validate_overlay(%{"set" => set}, _index) when is_map(set) do
    Enum.find_value(set, :ok, fn {role, hex} ->
      cond do
        role not in @settable_roles ->
          {:error, "invalid_params", "overlay sets unknown role: #{inspect(role)}"}

        not valid_hex?(hex) ->
          {:error, "invalid_params", "overlay role #{role} must be #rrggbb, got: #{inspect(hex)}"}

        true ->
          nil
      end
    end)
  end

  defp valid_hex?(hex) when is_binary(hex), do: hex =~ ~r/\A#[0-9a-fA-F]{6}\z/
  defp valid_hex?(_other), do: false
end
