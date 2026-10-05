defmodule Workstation.Core.GoldenGenerateTest do
  @moduledoc """
  The Elixir golden generator is the canonical re-record path; this anchor
  proves the native engine still regenerates the committed tests/goldens
  tree byte for byte — the same drift assertion the retired Lua-side suite
  (`tests/goldens.test.lua`, deleted with the Lua generator) once ran
  against the Lua generator. No cross-process check is needed here:
  `CanonicalJSON` is deterministic and carries no encoder seeding. A drift
  is an engine or envelope change: re-record deliberately via
  `mix workstation.goldens` after review — never by editing goldens.
  """

  use ExUnit.Case, async: false

  @goldens_root Path.expand("../../../../../tests/goldens", __DIR__)

  test "the native engine regenerates the committed golden tree byte for byte" do
    generated = Workstation.Core.Golden.generate() |> Map.new()

    recorded =
      @goldens_root |> File.ls!() |> Enum.reject(&String.starts_with?(&1, ".")) |> Enum.sort()

    # The recording order is the generator's contract (Golden.profiles/0);
    # the committed set is compared as a set so directory order can never
    # mask a missing or extra profile.
    assert generated |> Map.keys() |> Enum.sort() == recorded

    for {profile, files} <- generated do
      assert MapSet.new(Map.keys(files)) == MapSet.new(committed_files(profile)),
             "file set differs for profile #{profile}"

      for {relative, bytes} <- files do
        assert bytes == File.read!(Path.join([@goldens_root, profile, relative])),
               "golden drift in #{profile}/#{relative}"
      end
    end
  end

  test "generation.txt addresses the exact manifest bytes" do
    for {profile, files} <- Workstation.Core.Golden.generate() do
      assert files["expected/generation.txt"] ==
               Workstation.Core.Digest.sha256(files["expected/manifest.json"]) <> "\n",
             "generation does not address the manifest bytes for profile #{profile}"
    end
  end

  defp committed_files(profile) do
    root = Path.join(@goldens_root, profile)
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
