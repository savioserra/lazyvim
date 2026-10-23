defmodule Workstation.Core.Packages.ReaderTest do
  @moduledoc """
  The data-manifest reader's rejection contract: the schema pin, the field
  vocabulary, the tree-law id match and the contribution dispatch — every
  failure names the manifest path or the package.
  """

  use ExUnit.Case, async: true

  # Fixture homes are cross-VM collision-proof (the full note lives in
  # apps/daemon/test/workstation/daemon/generation_test.exs): the boot
  # millisecond in base36 never repeats across `mix test` VM instances the
  # way the restarted `System.unique_integer/1` sequence does, and the
  # within-VM base36 tail keeps concurrent async draws (or two calls inside
  # one test) from sharing a millisecond. Any same-named leftover is swept
  # before use and the home is removed on exit.
  defp unique_home(prefix) do
    token =
      Integer.to_string(:os.system_time(:millisecond), 36) <>
        Integer.to_string(System.unique_integer([:positive]), 36)

    home = Path.join(System.tmp_dir!(), "#{prefix}-#{token}")

    File.rm_rf!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    home
  end


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

  # The $embed_assets sentinel resolves package assets through the ENGINE
  # package tree (package_asset!/2 keys on the declared package id), so
  # these fixtures declare the nvim id: a unique per-test parent keeps the
  # runs async-safe, and the `nvim` leaf satisfies the tree law. No fixture
  # files are written; the real package payloads serve as the bodies.
  defp read_nvim_spec(manifest) do
    # File.rm/1 can never remove a DIRECTORY: the old per-test child was
    # leaked verbatim by every run and re-drawn (integer restart) by the
    # next VM. The helper token keeps the child cross-VM unique; sweep and
    # rm_rf! own it end to end. (The shared parent stays: concurrent async
    # tests nest under it, and it holds only empty dirs between runs.)
    embed = Path.basename(unique_home("nvim-embed"))

    dir =
      Path.join([
        System.tmp_dir!(),
        "workstation-reader-test",
        embed,
        "nvim"
      ])

    path = Path.join(dir, "manifest.json")
    File.rm_rf!(Path.dirname(dir))
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(Path.dirname(dir)) end)
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

  test "an ordering knob anywhere in a contribution is rejected, at any depth" do
    assert_raise ArgumentError, ~r/declares "order" inside nested's contribution.*integer.*ordering fields are banned/s, fn ->
      read_spec("nested", %{
        "schema" => 1,
        "id" => "nested",
        "foundation" => "f",
        "contributes" => [
          %{
            "provider" => "shell",
            "spec" => %{
              "target" => ".zshrc",
              "fragment" => %{"id" => "x", "marker" => "# m", "body" => "b", "order" => 3}
            }
          }
        ]
      })
    end

    assert_raise ArgumentError, ~r/declares "position"/, fn ->
      read_spec("nested2", %{
        "schema" => 1,
        "id" => "nested2",
        "foundation" => "f",
        "contributes" => [
          %{"provider" => "nvim-profile", "spec" => %{"position" => 20, "entry" => %{"id" => "x"}}}
        ]
      })
    end
  end

  test "the engine-rendered sentinel expands to the theme envelope" do
    spec =
      read_spec("rendered", %{
        "schema" => 1,
        "id" => "rendered",
        "foundation" => "f",
        "contributes" => [
          %{"provider" => "chezmoi-data", "spec" => %{"content" => %{"$theme_data" => true}}}
        ]
      })

    assert [%{provider: "chezmoi-data", spec: %{content: content}}] = spec.contributes
    assert is_binary(content) and content != ""
    assert content =~ "Generated by the workstation theme capability"
  end

  test "the embed sentinel composes the modify program from declared assets" do
    spec =
      read_nvim_spec(%{
        "schema" => 1,
        "id" => "nvim",
        "foundation" => "f",
        "contributes" => [
          %{
            "provider" => "chezmoi",
            "spec" => %{
              "target" => ".config/nvim/lazy-lock.json",
              "kind" => "modify",
              "executable" => true,
              "content" => %{
                "$embed_assets" => %{
                  "template" => "files/modify/lazy-lock.json.sh",
                  "embed" => "files/.config/nvim/lazy-lock.json",
                  "marker" => "__WORKSTATION_ENGINE_PINS__"
                }
              }
            }
          }
        ]
      })

    assert [%{provider: "chezmoi", spec: recipe}] = spec.contributes
    template = template_fixture()
    pins = pins_fixture()

    # The exact compiled-arm semantics: first-occurrence substitution of the
    # body at the marker, no sentinel bytes left behind.
    assert recipe.content == String.replace(template, "__WORKSTATION_ENGINE_PINS__", pins)
    refute recipe.content =~ "__WORKSTATION_ENGINE_PINS__"
  end

  test "the embed sentinel fails closed on an unknown descriptor field" do
    assert_raise ArgumentError, ~r/render descriptor has unknown fields: \["nope"\]/, fn ->
      read_nvim_spec(%{
        "schema" => 1,
        "id" => "nvim",
        "foundation" => "foundation/editor",
        "contributes" => [
          %{
            "provider" => "chezmoi",
            "spec" => %{
              "target" => ".x",
              "kind" => "modify",
              "content" => %{
                "$embed_assets" => %{
                  "template" => "files/modify/lazy-lock.json.sh",
                  "embed" => "files/.config/nvim/lazy-lock.json",
                  "marker" => "__WORKSTATION_ENGINE_PINS__",
                  "nope" => true
                }
              }
            }
          }
        ]
      })
    end
  end

  test "the embed sentinel fails closed on a body that is not a JSON object" do
    assert_raise ArgumentError, ~r/files\/\.config\/nvim\/stylua\.toml asset is not a JSON object/, fn ->
      read_nvim_spec(%{
        "schema" => 1,
        "id" => "nvim",
        "foundation" => "foundation/editor",
        "contributes" => [
          %{
            "provider" => "chezmoi",
            "spec" => %{
              "target" => ".x",
              "kind" => "modify",
              "content" => %{
                "$embed_assets" => %{
                  "template" => "files/modify/lazy-lock.json.sh",
                  "embed" => "files/.config/nvim/stylua.toml",
                  "marker" => "__WORKSTATION_ENGINE_PINS__"
                }
              }
            }
          }
        ]
      })
    end
  end

  test "the embed sentinel fails closed when the template carries no marker" do
    assert_raise ArgumentError,
                 ~r/files\/modify\/lazy-lock.json.sh asset carries no __MISSING__ marker/,
                 fn ->
                   read_nvim_spec(%{
                     "schema" => 1,
                     "id" => "nvim",
                     "foundation" => "foundation/editor",
                     "contributes" => [
                       %{
                         "provider" => "chezmoi",
                         "spec" => %{
                           "target" => ".x",
                           "kind" => "modify",
                           "content" => %{
                             "$embed_assets" => %{
                               "template" => "files/modify/lazy-lock.json.sh",
                               "embed" => "files/.config/nvim/lazy-lock.json",
                               "marker" => "__MISSING__"
                             }
                           }
                         }
                       }
                     ]
                   })
                 end
  end

  # The real nvim assets serve as the sentinel's fixture: the production
  # template (single marker) and the production pins (a JSON object) —
  # read-only, no fixture files written.
  defp template_fixture do
    nvim_asset("files/modify/lazy-lock.json.sh")
  end

  defp pins_fixture do
    nvim_asset("files/.config/nvim/lazy-lock.json")
  end

  defp nvim_asset(relative) do
    path =
      Path.expand("../../../../../../", __DIR__)
      |> Path.join("workstation/packages/editor/nvim")
      |> Path.join(relative)

    File.read!(path)
  end

  test "the tree walk serves the checkout's data manifests" do
    assert {path, spec} = Enum.find(Reader.specs(), fn {_path, spec} -> spec.id == "elixir" end)
    assert path =~ "workstation/packages/languages/elixir/manifest.json"
    assert spec.foundation == "foundation/runtime"
  end
end
