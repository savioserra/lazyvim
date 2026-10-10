defmodule Workstation.Core.Packages.ReaderTest do
  @moduledoc """
  The data-manifest reader's rejection contract: the schema pin, the field
  vocabulary, the tree-law id match and the contribution dispatch — every
  failure names the manifest path or the package.
  """

  use ExUnit.Case, async: true

  alias Workstation.Core.Packages.Reader

  # The tree law checks the id against the manifest's directory name, so
  # each fixture lives in a temp dir named for its id (unique per test,
  # async-safe).
  defp read_spec(id, manifest) do
    dir = Path.join([System.tmp_dir!(), "workstation-reader-test", id])
    path = Path.join(dir, "manifest.json")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Reader.spec!(path, manifest)
  end

  test "a minimal manifest denormalizes to the native spec shape" do
    spec =
      read_spec("minimal", %{
        "schema" => 1,
        "id" => "minimal",
        "foundation" => "foundation/base",
        "contributes" => []
      })

    assert spec == %{
             id: "minimal",
             foundation: "foundation/base",
             requires: [],
             supported_hosts: nil,
             contributes: []
           }
  end

  test "an integer ordering knob is rejected with the ban message" do
    assert_raise ArgumentError, ~r/integer ordering fields are banned/, fn ->
      read_spec("ordered", %{"schema" => 1, "id" => "ordered", "foundation" => "f", "order" => 3})
    end
  end

  test "unknown fields, a wrong schema and a non-object fail closed" do
    assert_raise ArgumentError, ~r/unknown manifest fields: \["nope"\]/, fn ->
      read_spec("unknown", %{"schema" => 1, "id" => "unknown", "foundation" => "f", "nope" => 1})
    end

    assert_raise ArgumentError, ~r/manifest schema must be 1, got: 2/, fn ->
      read_spec("schema", %{"schema" => 2, "id" => "schema", "foundation" => "f"})
    end

    assert_raise ArgumentError, ~r/manifest must be an object/, fn ->
      read_spec("array", [%{"schema" => 1}])
    end
  end

  test "the id must match the package directory (the tree law)" do
    assert_raise ArgumentError, ~r/package directory is named for its id/, fn ->
      read_spec("misnamed", %{"schema" => 1, "id" => "other", "foundation" => "f"})
    end
  end

  test "an unknown provider fails closed naming the package" do
    assert_raise ArgumentError, ~r/ghost contribution names unknown provider "nope"/, fn ->
      read_spec("ghost", %{
        "schema" => 1,
        "id" => "ghost",
        "foundation" => "f",
        "contributes" => [%{"provider" => "nope", "spec" => %{}}]
      })
    end
  end

  test "a git pin denormalizes through the discovered provider contract" do
    commit = String.duplicate("a", 40)

    spec =
      read_spec("pinned", %{
        "schema" => 1,
        "id" => "pinned",
        "foundation" => "f",
        "contributes" => [
          %{
            "provider" => "git",
            "spec" => %{"url" => "https://example.com/x", "commit" => commit, "target" => ".x/checkout"}
          }
        ]
      })

    assert [%{provider: "git", spec: pin}] = spec.contributes
    assert pin.id == "git"
    assert pin.url == "https://example.com/x"
    assert pin.commit == commit
    assert pin.target == ".x/checkout"
    assert is_binary(pin.fingerprint)
  end

  test "a chezmoi asset reference stays a package-relative reference" do
    spec =
      read_spec("asset", %{
        "schema" => 1,
        "id" => "asset",
        "foundation" => "f",
        "contributes" => [
          %{
            "provider" => "chezmoi",
            "spec" => %{"target" => ".config/x", "kind" => "file", "asset" => "files/.config/x"}
          }
        ]
      })

    assert [%{provider: "chezmoi", spec: recipe}] = spec.contributes
    assert recipe.kind == :file
    assert recipe.asset == "files/.config/x"
    assert recipe.content == nil
  end

  test "the tree walk serves the checkout's data manifests" do
    assert {path, spec} = Enum.find(Reader.specs(), fn {_path, spec} -> spec.id == "nunchux" end)
    assert path =~ "workstation/packages/terminal/nunchux/manifest.json"
    assert spec.requires == ["foundation", "theme"]
  end
end
