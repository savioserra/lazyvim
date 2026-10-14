defmodule Workstation.Core.Update.Pull do
  @moduledoc """
  The `pull` step: fetch the upstream of the engine-owned checkout and move
  it forward — the checked fast-forward (`git -C repo_root pull --ff-only`)
  of `docs/capabilities.md` ("Checked pull --ff-only").

  It is spelled fetch + `merge --ff-only`, never `reset --hard`: a pull that
  rewrote the checkout would destroy uncommitted owner work in the engine
  source tree, so a diverged checkout must ABORT the update instead of being
  reset. `GIT_TERMINAL_PROMPT=0` keeps a network fetch from ever hanging the
  daemon on a credential prompt, and the git config is pinned to /dev/null
  exactly like the collector bridge — the operator's ambient git
  configuration must not be able to redirect what an update pulls.

  This is the one network-bound step; sandbox tests run it against a local
  fixture repository only.
  """

  @doc """
  Fast-forward the engine checkout to its upstream. Returns
  `{:ok, %{"step" => "pull", "status" => "ok", "head" => sha}}`; raises
  `ArgumentError` when the checkout is not a git repository, the fetch
  fails, or the upstream is not a fast-forward of the local head.
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) when is_list(opts) do
    root = Workstation.Core.Update.engine_root(opts)
    repo = repo_root!(root)

    git!(repo, ["fetch", "--quiet"], "git fetch failed")

    case git(repo, ["merge", "--ff-only", "FETCH_HEAD"]) do
      {_, 0} ->
        {:ok, %{"step" => "pull", "status" => "ok", "head" => head!(repo)}}

      {out, _code} ->
        raise ArgumentError,
              "pull: upstream is not a fast-forward of the local checkout; refusing to reset a diverged engine source (checked pull --ff-only): " <>
                String.trim_trailing(out)
      end
  end

  # `git rev-parse --show-toplevel` both proves the checkout IS a repository
  # (honest failure before any fetch) and resolves the repo root when the
  # engine payload sits in a subdirectory of it.
  defp repo_root!(root) do
    case git(root, ["rev-parse", "--show-toplevel"]) do
      {out, 0} -> String.trim_trailing(out)
      {_out, _code} -> raise ArgumentError, "pull: #{root} is not a git repository checkout"
    end
  end

  defp head!(repo) do
    {:ok, out} = git!(repo, ["rev-parse", "HEAD"], "git rev-parse failed")
    String.trim_trailing(out)
  end

  defp git!(repo, args, label) do
    case git(repo, args) do
      {out, 0} -> {:ok, out}
      {out, code} -> raise ArgumentError, "#{label} (exit #{code}): #{String.trim_trailing(out)}"
    end
  end

  defp git(repo, args) do
    System.cmd("git", ["-C", repo | args],
      stderr_to_stdout: true,
      env: [
        # Same config isolation as the sanitized collector bridge: no ambient
        # git configuration may influence what an update pulls.
        {"GIT_CONFIG_NOSYSTEM", "1"},
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_CONFIG_SYSTEM", "/dev/null"},
        # A daemon step must never block on an interactive credential prompt.
        {"GIT_TERMINAL_PROMPT", "0"}
      ]
    )
  end
end
