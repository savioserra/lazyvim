defmodule Workstation.Daemon.Capabilities.UpdateCheck do
  @moduledoc """
  Update-availability capability: serves `update.check` — the daemon-side
  passive check that answers whether the install repo is behind its origin
  (`Workstation.Daemon.UpdateCheck`, TTL-cached). READ-ONLY by contract:
  ls-remote never touches the working tree, so the check can run while any
  op is in flight without taking a lock.

  The repo resolution is opted in: the daemon boot enables the check
  (`Application.put_env(:daemon, :update_check, true)`, with optional
  `:update_check_repo` pin); a tree booted without the opt-in answers
  `"unknown"` instead of ever making an unplanned network query. Unknown
  is the silent verdict — clients treat it as no-news.
  """

  use Workstation.Daemon.Capability

  alias Workstation.Daemon.UpdateCheck

  @empty_schema Zoi.object(%{}, unrecognized_keys: :error)

  @impl true
  def ops, do: ["update.check"]

  @impl true
  def schema("update.check"), do: @empty_schema

  @impl true
  def handle("update.check", _params, _ctx) do
    {:ok, UpdateCheck.check_cached()}
  end

  @impl true
  def domains, do: []

  @impl true
  def children, do: [UpdateCheck]
end
