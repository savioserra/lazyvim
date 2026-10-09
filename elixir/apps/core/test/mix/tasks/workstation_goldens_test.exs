defmodule Workstation.Core.WorkstationGoldensTaskTest do
  @moduledoc """
  The `mix workstation.goldens` invocation contract: recording into an
  explicit root must reproduce the committed goldens byte-for-byte — the
  re-record path an operator runs after a reviewed engine change has to be
  a byte no-op on a consistent tree, otherwise "re-record deliberately"
  would silently rewrite unrelated bytes.
  """

  use ExUnit.Case, async: false

  # apps/core/test/mix/tasks -> repo root is six levels up.
  @repo_root Path.expand("../../../../../..", __DIR__)
  @goldens_root Path.join(@repo_root, "tests/goldens")

  # The recorded profiles are the golden contract itself (same stance as
  # the replay anchor): a missing or extra profile here is a deliberate
  # re-recording decision, never a side effect.
  @profiles ["conflicts", "context", "download", "full-home", "git", "minimal", "nvim-profile", "shell-order", "theme"]

  test "recording into an explicit root reproduces the committed goldens byte for byte" do
    tmp_root = Path.join(System.tmp_dir!(), "ws-goldens-task-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_root)

    on_exit(fn -> File.rm_rf!(tmp_root) end)

    Mix.Task.rerun("workstation.goldens", [tmp_root])

    assert Enum.sort(File.ls!(tmp_root)) == @profiles,
           "the task must record exactly the golden profiles"

    for profile <- @profiles do
      assert dir_tree(tmp_root <> "/" <> profile) == dir_tree(@goldens_root <> "/" <> profile),
             "file set differs for profile #{profile}"

      for relative <- dir_tree(Path.join(tmp_root, profile)) do
        assert File.read!(Path.join([tmp_root, profile, relative])) ==
                 File.read!(Path.join([@goldens_root, profile, relative])),
               "recorded bytes differ from the committed goldens in #{profile}/#{relative}"
      end
    end
  end

  defp dir_tree(root) do
    walk(root, root) |> Enum.sort()
  end

  defp walk(root, dir) do
    Enum.flat_map(File.ls!(dir), fn name ->
      path = Path.join(dir, name)

      if File.dir?(path) do
        walk(root, path)
      else
        [Path.relative_to(path, root)]
      end
    end)
  end
end
