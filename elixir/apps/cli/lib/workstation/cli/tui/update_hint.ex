defmodule Workstation.CLI.TUI.UpdateHint do
  @moduledoc """
  The passive update-availability indicator (supervisor-directed engine
  scope): the daemon's `update.check` op — a read-only `git ls-remote`
  against the install repo's origin, TTL-cached daemon-side — is consulted
  asynchronously on screen open and after a completed update chain, never
  blocking render and never spinning.

  The verdict only ever SURFACES when the branch is behind its remote
  (an accent footer row and the `[u]` shortcut) and stays SILENT on
  `up_to_date` and `unknown`: offline must look like no-news, never like
  a nag. Every failure of the check itself folds to silence here — the
  daemon already answered `"unknown"` for no-origin, no-git, offline and
  timeout, and this module additionally treats transport errors as
  no-news.
  """

  @typedoc "The surfaced verdict: the two short shas the footer shows."
  @type hint :: %{required(String.t()) => String.t()}

  @doc """
  Fold one `update.check` executor result to the surfaced hint (or `nil`).
  Only `"behind"` surfaces; `up_to_date`, `unknown` and errors are silent.
  """
  @spec fold({:ok, map()} | {:error, term()}) :: hint() | nil
  def fold({:ok, %{"status" => "behind", "local" => local, "remote" => remote}})
      when is_binary(local) and is_binary(remote) do
    %{"local" => local, "remote" => remote}
  end

  def fold(_up_to_date_or_unknown_or_error), do: nil

  @doc "The footer text for a surfaced hint (the locked wording)."
  @spec text(hint()) :: String.t()
  def text(%{"local" => local, "remote" => remote}) do
    "↑ update available (#{local} → #{remote}) — [u] update"
  end
end
