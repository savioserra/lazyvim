defmodule Workstation.Core.DownloadTest do
  @moduledoc """
  The pinned-artifact contract: recipe validation, plan integration
  (pins content-addressed into the generation, exclusive target ownership),
  fail-closed install (checksum mismatch installs nothing, a mismatched
  existing target is never overwritten, a matching target is an idempotent
  no-op that skips the fetch), the archive form (traversal-checked,
  single-rooted, strip-one-root exact-tree installs gated by the declared
  probe — idempotent through the probe, refused overwrite on version drift,
  a claim and a verify seam that re-probe the actual tree) and the
  apply-boundary journal integration.
  """

  use ExUnit.Case, async: false

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


  require Record

  alias Workstation.Core.{Digest, Graph, Source}
  alias Workstation.Backends.Chezmoi
  alias Workstation.Core.Contracts.Download

  # The archive form's declared probe (shared by the round-trip pins):
  # the exec shape, argv[0] a tree-relative member.
  @probe %{argv: ["bin/go", "version"], output: "go version go{V}"}

  # Both redirected-TLS host names are served by ONE endpoint on the
  # loopback with a wildcard-only (*.download.test) cert; the in-VM inet_db
  # host table resolves them (the tests never touch /etc/hosts).
  @download_test_hosts [~c"redirect.download.test", ~c"asset.download.test"]

  setup do
    home = unique_home("workstation-download")
    File.mkdir_p!(home)
    System.put_env("WORKSTATION_HOME", home)

    %{home: home}
  end

  # The redirected-TLS tests share ONE VM-global resolver state: the tests
  # never touch /etc/hosts, the in-VM inet_db host table resolves their two
  # .download.test names, and the module restores the previous lookup order
  # (and clears the loaded trust store) once, after all tests — per-test
  # on_exit callbacks can overlap the next test, so global restore belongs
  # at module scope only.
  setup_all do
    old_lookup = :inet_db.res_option(:lookup)
    :inet_db.set_lookup([:file, :native])
    :inet_db.add_host({127, 0, 0, 1}, @download_test_hosts)

    on_exit(fn ->
      :public_key.cacerts_clear()
      :inet_db.del_host({127, 0, 0, 1})
      :inet_db.set_lookup(old_lookup)
    end)

    :ok
  end

  describe "recipe validation" do
    test "accepts a well-formed pin" do
      spec = recipe()
      assert spec.url == "https://example.invalid/artifacts/tool/1.0.0/tool"
      assert spec.target == ".local/bin/tool"
    end

    test "rejects non-https urls, bad checksums, unsafe targets and missing fields" do
      assert_raise ArgumentError, ~r/must be https/, fn -> recipe(url: "http://example.invalid/tool") end

      assert_raise ArgumentError, ~r/64 lowercase hex/, fn ->
        recipe(sha256: String.upcase(sha_a()))
      end

      assert_raise ArgumentError, ~r/64 lowercase hex/, fn -> recipe(sha256: "abc") end

      assert_raise ArgumentError, ~r/relative path inside the home/, fn -> recipe(target: "/usr/local/bin/tool") end

      assert_raise ArgumentError, ~r/relative path inside the home/, fn ->
        recipe(target: ".local/../escape/tool")
      end

      assert_raise ArgumentError, ~r/literal path/, fn -> recipe(target: ".local/bin/*") end

      assert_raise ArgumentError, ~r/engine-private state/, fn ->
        recipe(target: ".local/state/workstation/tool")
      end

      assert_raise ArgumentError, ~r/requires sha256/, fn -> recipe(sha256: nil) end
    end
  end

  describe "plan integration" do
    test "download pins are content-addressed into the manifest and generation" do
      plan = plan_with_downloads()
      assert length(plan.downloads) == 2

      names = Enum.map(plan.manifest, & &1["name"])
      assert Enum.any?(names, &String.starts_with?(&1, "download/"))

      download = hd(plan.downloads)
      descriptor = Enum.find(plan.manifest, &(&1["name"] == download.source_name))
      assert descriptor
      assert descriptor["type"] == "file"
      assert Jason.decode!(Download.pin_bytes(download))["sha256"] == download.sha256

      # Changing any pin field changes the generation id.
      changed = plan_with_downloads(sha_a: sha_b())
      assert changed.generation != plan.generation
    end

    test "a download target owned by a chezmoi entry is a composition conflict" do
      package = %{
        id: "clashing",
        requires: [],
        contributes: [
          %{provider: "download", spec: recipe(target: ".local/bin/tool")},
          %{provider: "chezmoi", spec: Chezmoi.recipe(%{target: ".local/bin/tool", kind: :file, content: "x"})}
        ]
      }

      assert_raise ArgumentError, ~r/overlaps owned target/, fn -> plan_for([package]) end
    end

    test "two downloads of one target are a duplicate conflict" do
      package = %{
        id: "dup",
        requires: [],
        contributes: [
          %{provider: "download", spec: recipe(target: ".local/bin/tool")},
          %{provider: "download", spec: recipe(target: ".local/bin/tool", sha256: sha_b())}
        ]
      }

      assert_raise ArgumentError, ~r/duplicate download target/, fn -> plan_for([package]) end
    end

    test "a declared removal reaching a download target is a conflict" do
      package = %{
        id: "remover",
        requires: [],
        contributes: [
          %{provider: "download", spec: recipe(target: ".local/bin/tool")},
          %{provider: "chezmoi", spec: Chezmoi.recipe(%{target: ".local/bin/tool", kind: :remove})}
        ]
      }

      assert_raise ArgumentError, ~r/overlaps download target/, fn -> plan_for([package]) end
    end
  end

  describe "per-platform dispatch" do
    test "a dispatched pin declares per-platform assets and validates them" do
      spec = dispatched_recipe()

      assert spec.assets == %{
               "linux_x86_64" => %{url: "https://example.invalid/tool-linux", sha256: sha_a()},
               "darwin_arm64" => %{url: "https://example.invalid/tool-darwin", sha256: sha_b()}
             }

      assert spec.url == nil and spec.sha256 == nil
      :ok = Download.validate(spec)
    end

    test "unknown platform tags and malformed assets fail closed" do
      assert_raise ArgumentError, ~r/unknown platform tag "linux-amd64"/, fn ->
        Download.recipe(%{
          version: "1.0.0",
          target: ".local/bin/tool",
          assets: %{"linux-amd64" => %{url: "https://example.invalid/x", sha256: sha_a()}}
        })
      end

      assert_raise ArgumentError, ~r/download recipe requires sha256/, fn ->
        Download.recipe(%{
          version: "1.0.0",
          target: ".local/bin/tool",
          assets: %{"linux_x86_64" => %{url: "https://example.invalid/x"}}
        })
      end

      assert_raise ArgumentError, ~r/must be a table with url and sha256/, fn ->
        Download.recipe(%{
          version: "1.0.0",
          target: ".local/bin/tool",
          assets: %{"linux_x86_64" => "not-a-table"}
        })
      end

      assert_raise ArgumentError, ~r/download assets must be a non-empty table/, fn ->
        Download.recipe(%{version: "1.0.0", target: ".local/bin/tool", assets: %{}})
      end
    end

    test "resolve picks the executing host's asset through the contract" do
      spec = dispatched_recipe()
      resolved = Download.resolve(spec, "linux_x86_64")

      assert resolved.url == "https://example.invalid/tool-linux"
      assert resolved.sha256 == sha_a()

      assert_raise ArgumentError, ~r/declares no asset for darwin_x86_64/, fn ->
        Download.resolve(spec, "darwin_x86_64")
      end
    end

    test "a direct pin resolves to itself" do
      resolved = Download.resolve(recipe())
      assert resolved.url == "https://example.invalid/artifacts/tool/1.0.0/tool"
      assert resolved.sha256 == sha_a()
    end

    test "the pin descriptor carries every platform's provenance, machine-independently" do
      spec = dispatched_recipe()
      descriptor = Download.pin_bytes(spec)

      assert descriptor =~ "tool-linux"
      assert descriptor =~ "tool-darwin"
      refute descriptor =~ "linux_x86_64\"}"

      # The fingerprint (and so the generation id) changes when ANY
      # platform's pin changes.
      other =
        Download.recipe(%{
          version: "1.0.0",
          target: ".local/bin/tool",
          assets: %{
            "linux_x86_64" => %{url: "https://example.invalid/tool-linux", sha256: sha_a()},
            "darwin_arm64" => %{url: "https://example.invalid/tool-darwin", sha256: sha_a()}
          }
        })

      refute Download.fingerprint(spec) == Download.fingerprint(other)
    end

    test "the dispatched spec survives the recorded-envelope round trip" do
      spec = dispatched_recipe()

      recorded = %{
        "version" => "1.0.0",
        "target" => ".local/bin/tool",
        "assets" => %{
          "linux_x86_64" => %{"url" => "https://example.invalid/tool-linux", "sha256" => sha_a()},
          "darwin_arm64" => %{"url" => "https://example.invalid/tool-darwin", "sha256" => sha_b()}
        }
      }

      assert Download.from_recorded(recorded) == spec
    end

    test "plan effects carry the declared assets unresolved" do
      spec = dispatched_recipe()

      package = %{
        id: "tooling",
        requires: [],
        contributes: [%{provider: Download.provider_id(), spec: spec}]
      }

      plan = plan_for([package])
      [effect] = Download.plan_effect(plan, %{})

      assert effect.target == ".local/bin/tool"
      assert effect.assets["linux_x86_64"].url == "https://example.invalid/tool-linux"
      refute Map.has_key?(effect, :url)
      refute Map.has_key?(effect, :sha256)
    end
  end

  describe "golden envelope round-trip" do
    test "a recorded download spec denormalizes to the native recipe" do
      spec =
        Download.from_recorded(%{
          "url" => "https://example.invalid/artifacts/tool/1.0.0/tool",
          "version" => "1.0.0",
          "sha256" => sha_a(),
          "target" => ".local/bin/tool"
        })

      assert spec == recipe()
    end

    test "a recorded archive spec denormalizes to the native archive recipe" do
      recorded = %{
        "archive" => "tar.gz",
        "probe" => %{"argv" => ["bin/go", "version"], "output" => "go version go{V}"},
        "url" => "https://example.invalid/artifacts/tool/1.0.0/tool.tar.gz",
        "version" => "1.0.0",
        "sha256" => sha_a(),
        "target" => ".local/opt/tool"
      }

      assert Download.from_recorded(recorded) ==
               Download.recipe(%{
                 archive: "tar.gz",
                 probe: %{argv: ["bin/go", "version"], output: "go version go{V}"},
                 url: "https://example.invalid/artifacts/tool/1.0.0/tool.tar.gz",
                 version: "1.0.0",
                 sha256: sha_a(),
                 target: ".local/opt/tool"
               })

      assert_raise ArgumentError, ~r/download archive pin requires a probe/, fn ->
        Download.from_recorded(Map.delete(recorded, "probe"))
      end
    end
  end

  describe "archive layouts" do
    test "recipe validation: layouts, target tables and the content probe" do
      base = %{url: "https://example.invalid/x.tar.gz", version: "1.0.0", sha256: sha_a(), target: ".local/opt/x", archive: "tar.gz", probe: @probe}

      assert_raise ArgumentError, ~r/layout must be one of release, flat/, fn ->
        Download.recipe(Map.put(base, :layout, "rootless"))
      end

      assert_raise ArgumentError, ~r/layout requires an archive pin/, fn ->
        Download.recipe(%{url: "https://example.invalid/x", version: "1.0.0", sha256: sha_a(), target: ".local/bin/x", layout: "flat"})
      end

      assert_raise ArgumentError, ~r/both target and targets/, fn ->
        Download.recipe(%{version: "1.0.0", target: ".local/x", targets: %{"linux_x86_64" => ".local/y"}})
      end

      assert_raise ArgumentError, ~r/unknown platform tag "linux-amd64"/, fn ->
        Download.recipe(%{version: "1.0.0", targets: %{"linux-amd64" => ".local/y"}})
      end

      assert_raise ArgumentError, ~r/download recipe requires target/, fn ->
        Download.recipe(%{version: "1.0.0"})
      end

      assert_raise ArgumentError, ~r/one shape per probe/, fn ->
        Download.recipe(
          Map.merge(base, %{probe: %{argv: ["x", "--version"], output: "{V}", member: "x", sha256: sha_a()}})
        )
      end

      assert_raise ArgumentError, ~r/64 lowercase hex/, fn ->
        Download.recipe(Map.merge(base, %{probe: %{member: "x", sha256: "ZZ"}}))
      end

      assert_raise ArgumentError, ~r/relative member/, fn ->
        Download.recipe(Map.merge(base, %{probe: %{member: "../escape", sha256: sha_a()}}))
      end

      # The content probe validates and carries through the struct.
      spec = Download.recipe(Map.merge(base, %{probe: %{member: "nvm.sh", sha256: sha_a()}, layout: "release"}))
      assert spec.probe == %{member: "nvm.sh", sha256: sha_a()}
      assert spec.layout == "release"
    end
  end

  describe "per-platform targets" do
    test "resolve returns the executing host's declared target" do
      spec =
        Download.recipe(%{
          version: "3.5.0",
          targets: %{"linux_x86_64" => ".local/share/fonts/f", "darwin_arm64" => "Library/Fonts/f"},
          assets: %{
            "linux_x86_64" => %{url: "https://example.invalid/f-linux", sha256: sha_a()},
            "darwin_arm64" => %{url: "https://example.invalid/f-darwin", sha256: sha_b()}
          }
        })

      assert Download.resolve(spec, "linux_x86_64") == %{
               url: "https://example.invalid/f-linux",
               sha256: sha_a(),
               target: ".local/share/fonts/f"
             }

      assert Download.resolve(spec, "darwin_arm64").target == "Library/Fonts/f"
    end

    test "dispatched targets ride the plan effect and the pending anchor verbatim" do
      package = %{
        id: "fonts",
        requires: [],
        contributes: [
          %{
            provider: "download",
            spec:
              Download.recipe(%{
                version: "3.5.0",
                targets: %{"linux_x86_64" => ".local/share/fonts/f", "darwin_arm64" => "Library/Fonts/f"},
                assets: %{
                  "linux_x86_64" => %{url: "https://example.invalid/f", sha256: sha_a()},
                  "darwin_arm64" => %{url: "https://example.invalid/f", sha256: sha_a()}
                },
                archive: "tar.xz",
                layout: "flat",
                probe: %{member: "f.ttf", sha256: sha_a()}
              })
          }
        ]
      }

      plan = plan_for([package])
      assert [pin] = plan.downloads
      assert pin.target == nil
      assert pin.targets == %{"linux_x86_64" => ".local/share/fonts/f", "darwin_arm64" => "Library/Fonts/f"}

      [effect] = Download.plan_effect(plan, %{})
      assert effect.target == nil
      assert effect.targets == pin.targets
      assert effect.archive == "tar.xz" and effect.layout == "flat"
    end

    test "a declared per-platform target overlapping an owned entry is a composition conflict" do
      fonts = %{
        id: "fonts",
        requires: [],
        contributes: [
          %{
            provider: "download",
            spec:
              Download.recipe(%{
                version: "3.5.0",
                targets: %{"linux_x86_64" => ".config/owned", "darwin_arm64" => "Library/Fonts/f"},
                assets: %{
                  "linux_x86_64" => %{url: "https://example.invalid/f", sha256: sha_a()},
                  "darwin_arm64" => %{url: "https://example.invalid/f", sha256: sha_a()}
                },
                archive: "tar.xz",
                probe: %{member: "f.ttf", sha256: sha_a()}
              })
          }
        ]
      }

      owner = %{
        id: "owner",
        requires: [],
        contributes: [
          %{provider: "chezmoi", spec: Chezmoi.recipe(%{target: ".config/owned/keep", kind: :file, content: "x"})}
        ]
      }

      assert_raise ArgumentError, ~r/overlaps owned target/, fn -> plan_for([fonts, owner]) end
    end

    test "the recorded envelope round-trips layout, targets and the content probe" do
      recorded = %{
        "version" => "3.5.0",
        "targets" => %{"linux_x86_64" => ".local/share/fonts/f", "darwin_arm64" => "Library/Fonts/f"},
        "assets" => %{
          "linux_x86_64" => %{"url" => "https://example.invalid/f", "sha256" => sha_a()},
          "darwin_arm64" => %{"url" => "https://example.invalid/f", "sha256" => sha_a()}
        },
        "archive" => "tar.xz",
        "layout" => "flat",
        "probe" => %{"member" => "f.ttf", "sha256" => sha_a()}
      }

      spec = Download.from_recorded(recorded)
      assert spec.targets == %{"linux_x86_64" => ".local/share/fonts/f", "darwin_arm64" => "Library/Fonts/f"}
      assert spec.layout == "flat"
      assert spec.probe == %{member: "f.ttf", sha256: sha_a()}
      :ok = Download.validate(spec)

      # The descriptor stays machine-independent and drops nil fields.
      descriptor = Jason.decode!(Download.pin_bytes(spec))
      assert descriptor["targets"] == recorded["targets"]
      assert descriptor["layout"] == "flat"
      refute Map.has_key?(descriptor, "target")
    end
  end

  defp dispatched_recipe(overrides \\ %{}), do: Download.recipe(dispatched_attrs(overrides))

  defp dispatched_attrs(overrides) do
    Map.merge(
      %{
        version: "1.0.0",
        target: ".local/bin/tool",
        assets: %{
          "linux_x86_64" => %{url: "https://example.invalid/tool-linux", sha256: sha_a()},
          "darwin_arm64" => %{url: "https://example.invalid/tool-darwin", sha256: sha_b()}
        }
      },
      overrides
    )
  end

  defp recipe(overrides \\ []) do
    Download.recipe(%{
      url: Keyword.get(overrides, :url, "https://example.invalid/artifacts/tool/1.0.0/tool"),
      version: Keyword.get(overrides, :version, "1.0.0"),
      sha256: Keyword.get(overrides, :sha256, sha_a()),
      target: Keyword.get(overrides, :target, ".local/bin/tool")
    })
  end

  defp payload_bytes, do: "#!/usr/bin/env sh\nexit 0\n"

  # The pinned checksum of the test payload: recipes under these tests pin
  # exactly the bytes their injected fetch returns.
  defp sha_a, do: Digest.sha256(payload_bytes())

  defp sha_b, do: Digest.sha256("#!/usr/bin/env sh\nexit 1\n")

  defp plan_for(packages) do
    graph = Graph.order(%{host: "linux", specifications: packages})
    Source.plan(%{graph: graph})
  end

  defp plan_with_downloads(overrides \\ []) do
    sha_a = Keyword.get(overrides, :sha_a, sha_a())

    package = %{
      id: "tooling",
      requires: [],
      contributes: [
        %{provider: "download", spec: recipe(sha256: sha_a, target: "tools/downloaded/tool")},
        %{
          provider: "download",
          spec:
            recipe(
              url: "https://example.invalid/artifacts/other/2.0.0/other",
              version: "2.0.0",
              sha256: sha_b(),
              target: "tools/downloaded/other"
            )
        }
      ]
    }

    plan_for([package])
  end

end
