defmodule Workstation.Daemon.Capabilities.Theme do
  @moduledoc """
  Theme capability: serves `theme.resolve` and owns the `"theme"` pubsub
  domain.

  Resolution logic is pure and lives in `Workstation.Core.Theme`; this
  module is the thin daemon shell — schema on the way in, resolved palette
  on the way out, one best-effort `Workstation.Daemon.Overlay.pub/2` event
  on success so domain subscribers can follow theme changes.
  """

  use Workstation.Daemon.Capability

  alias Workstation.Core.Theme
  alias Workstation.Daemon.Overlay

  @domain "theme"
  @op "theme.resolve"

  @resolve_params_schema Zoi.object(
                           %{
                             "appearance" => Zoi.enum(["dark", "light"]),
                             "overlays" =>
                               Zoi.array(
                                 Zoi.object(
                                   %{
                                     "from" => Zoi.string(min_length: 1),
                                     "set" => Zoi.map(Zoi.string(), Zoi.string())
                                   },
                                   unrecognized_keys: :error
                                 )
                               )
                           },
                           unrecognized_keys: :error
                         )

  @impl true
  def ops, do: [@op]

  @impl true
  def schema(@op), do: @resolve_params_schema

  @impl true
  def domains, do: [@domain]

  @impl true
  def handle(@op, params, _ctx) do
    case Theme.resolve(params) do
      {:ok, theme} = ok ->
        Overlay.pub(@domain, {:theme_resolved, theme})
        ok

      {:error, _reason} = refusal ->
        refusal
    end
  end
end
