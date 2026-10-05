defmodule Workstation.Core.Golden do
  @moduledoc """
  The Elixir golden generator — the canonical re-record path for the
  `tests/goldens/<profile>/` trees (parity anchors:
  `workstation/lua/workstation/golden.lua` M.generate + M.normalize_input +
  M.project_plan, and `tests/goldens.test.lua`'s drift suite).

  Each profile records four files: `input.json` (the only replay input),
  `expected/plan.json`, `expected/manifest.json` and
  `expected/generation.txt` (the sha256 of the exact manifest bytes plus one
  newline). The recorded bytes must stay identical across generator runs and
  against the committed tree; `GoldenGenerateTest` re-runs the Lua suite's
  drift assertion against this engine (no cross-process check is needed
  here: `CanonicalJSON` is deterministic, there is no encoder seeding).

  Envelope rules (mirroring the Lua generator's header contract):

  * catalog profiles record the dependency closure of their seeds in catalog
    declaration order — `minimal` seeds `foundation`, `theme` seeds
    `theme`/`tmux`/`agent`, `full-home` records the complete catalog;
    `conflicts`, `shell-order` and `nvim-profile` are synthetic literal
    envelopes, validated by the engine at replay time;
  * declared spec fields are recorded verbatim, derived `components` are
    dropped (recipe constructors re-derive them at replay time), package
    asset bodies move into the top-level `assets` map under
    `"<package id>:<asset path>"`;
  * home-anchored symlink destinations are pinned at declaration time in the
    native catalog (`Catalog.canonical_home/0`, the recorder's own
    destination pinning), so normalization copies them verbatim — the same
    recorded bytes the Lua generator produces by rewriting live-home
    destinations;
  * nil struct fields are absent Lua keys and disappear from `input.json`,
    while empty lists stay present (`lazyvim_extras: []`) and an empty
    assets map encodes as `[]`.

  A golden drift is an engine or envelope change: it must be re-recorded
  deliberately (`mix workstation.goldens`) after review — never by editing
  the committed bytes. This module is the only generator since the c5
  retirement lane deleted the Lua generator (`golden.lua`); its recorded
  bytes remain the parity evidence this module must reproduce.
  """

  alias Workstation.Core.{CanonicalJSON, Catalog, Graph, Source}

  # Recording order (also the on-disk directory names) — mirrors
  # golden.lua M.profiles.
  @profiles ["minimal", "full-home", "theme", "conflicts", "shell-order", "nvim-profile"]

  # Catalog profile seeds: minimal records the foundation package alone,
  # theme the theme/tmux/agent closure (their dependency closure adds
  # foundation and node); any profile without seeds records the complete
  # catalog. Mirrors golden.lua catalog_seeds.
  @catalog_seeds %{
    "minimal" => ["foundation"],
    "theme" => ["theme", "tmux", "agent"]
  }

  @doc "Recorded profiles, in recording order (also the directory names)."
  @spec profiles() :: [String.t()]
  def profiles, do: @profiles

  @doc """
  Generate every recorded profile in memory, in recording order:
  `{profile, %{"input.json" => bytes, "expected/plan.json" => bytes,
  "expected/manifest.json" => bytes, "expected/generation.txt" => bytes}}`.
  Pure — the engine runs against no home at all (the plan pipeline reads no
  live state and package assets come from the engine checkout).
  """
  @spec generate() :: [{String.t(), %{String.t() => String.t()}}]
  def generate do
    Enum.map(@profiles, fn profile ->
      input = input_for(profile)
      {catalog, plan} = replay(input)

      files = %{
        "input.json" => CanonicalJSON.encode(input),
        "expected/plan.json" => CanonicalJSON.encode(project_plan(catalog, plan)),
        "expected/manifest.json" => CanonicalJSON.encode(plan.manifest),
        "expected/generation.txt" => plan.generation <> "\n"
      }

      {profile, files}
    end)
  end

  @doc """
  The canonical re-record path: write the generated trees under `root`
  (creation order follows `profiles/0`). Returns the profile names.
  """
  @spec regenerate(String.t()) :: [String.t()]
  def regenerate(root) do
    Enum.each(generate(), fn {profile, files} ->
      Enum.each(files, fn {relative, bytes} ->
        path = Path.join(root, Path.join(profile, relative))
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, bytes)
      end)
    end)

    @profiles
  end

  @doc """
  Project the engine plan into the recorded plan.json view — the single
  projection shared by the generator (`mix workstation.goldens`) and the
  replay contract (`GoldenReplayTest`).
  """
  @spec project_plan(Catalog.t(), Source.plan()) :: map()
  def project_plan(catalog, plan) do
    entries =
      plan.entries
      |> Enum.map(fn entry ->
        %{
          "name" => entry.source_name,
          "target" => entry.target,
          "operation" => entry.operation,
          "type" => entry.type,
          "mode" => (Map.get(entry, :mode) && octal(Map.get(entry, :mode))) || :null,
          "attribution" => entry.attribution,
          "bytes_sha256" =>
            case Map.get(entry, :bytes) do
              nil -> nil
              bytes -> Workstation.Core.Digest.sha256(bytes)
            end,
          "fingerprint" => Map.get(entry, :fingerprint),
          "link" => Map.get(entry, :link),
          "exact" => Map.get(entry, :exact),
          "template" => Map.get(entry, :template)
        }
        |> drop_nil_fields()
      end)
      |> Enum.sort_by(& &1["name"])

    %{
      "profile" => catalog.profile,
      "host" => catalog.host,
      "journal_revision" => plan.journal_revision,
      "baseline_generation" => plan.baseline_generation || :null,
      "entries" => entries,
      "removals" => Enum.map(plan.removals, &%{"owner" => &1.owner, "target" => &1.target}),
      "unsupported_reversals" =>
        Enum.map(plan.unsupported_reversals, &%{"owner" => &1.owner, "target" => &1.target}),
      "fragments_journal" => plan.fragments_journal,
      "composed_profile" => plan.profile && Enum.map(plan.profile, &%{"id" => &1[:id]}),
      "data" => plan.data && %{"owner" => plan.data.owner, "bytes" => plan.data.bytes},
      "remove_file" => plan.remove_file
    }
    |> drop_nil_fields()
  end

  # --- envelope construction ---

  defp input_for(profile) do
    case synthetic_records(profile) do
      nil ->
        packages = catalog_packages(profile)
        {records, assets} = normalize_packages(packages)
        envelope(profile, records, assets)

      records ->
        envelope(profile, records, %{})
    end
  end

  defp envelope(profile, records, assets) do
    %{
      "profile" => profile,
      "host" => "linux",
      "home" => Catalog.canonical_home(),
      "packages" => records,
      "assets" => assets
    }
  end

  # The catalog closure of the profile's seeds, in declaration order (the
  # recorded construction order). Mirrors golden.lua catalog_closure.
  defp catalog_packages(profile) do
    packages = Catalog.Packages.packages()
    by_id = Map.new(packages, &{&1.id, &1})
    seeds = Map.get(@catalog_seeds, profile, Enum.map(packages, & &1.id))
    wanted = closure(MapSet.new(seeds), MapSet.new(), by_id)
    Enum.filter(packages, &MapSet.member?(wanted, &1.id))
  end

  defp closure(pending, wanted, by_id) do
    if MapSet.size(pending) == 0 do
      wanted
    else
      [id | rest] = MapSet.to_list(pending)

      if MapSet.member?(wanted, id) do
        closure(MapSet.new(rest), wanted, by_id)
      else
        %{requires: requires} = Map.fetch!(by_id, id)

        closure(
          MapSet.union(MapSet.new(rest), MapSet.new(requires || [])),
          MapSet.put(wanted, id),
          by_id
        )
      end
    end
  end

  # --- normalization: native declarations -> recorded envelope shape ---

  defp normalize_packages(packages) do
    Enum.map_reduce(packages, %{}, fn package, assets ->
      {contributes, assets} =
        Enum.map_reduce(package.contributes, assets, &normalize_recipe(package.id, &1, &2))

      record =
        %{"id" => package.id, "requires" => package.requires || [], "contributes" => contributes}
        |> put_supported_hosts(package.supported_hosts)

      {record, assets}
    end)
  end

  # The recorded hosts shape is a host->true table (verbatim Lua semantics);
  # native declarations already carry that map form (the graph gates on it),
  # and the list form normalizes into it. CanonicalJSON sorts the keys.
  defp put_supported_hosts(record, nil), do: record

  defp put_supported_hosts(record, hosts) when is_map(hosts),
    do: Map.put(record, "supported_hosts", hosts)

  defp put_supported_hosts(record, hosts) when is_list(hosts),
    do: Map.put(record, "supported_hosts", Map.new(hosts, fn host -> {host, true} end))

  defp normalize_recipe(package_id, %{provider: "chezmoi", spec: spec}, assets) do
    {asset_key, assets} =
      case spec.asset do
        nil ->
          {nil, assets}

        relative ->
          key = package_id <> ":" <> relative
          {key, Map.put(assets, key, Catalog.package_asset!(package_id, relative))}
      end

    spec =
      %{
        "target" => spec.target,
        "kind" => Atom.to_string(spec.kind),
        "executable" => spec.executable,
        "private" => spec.private,
        "exact" => spec.exact,
        "template" => spec.template,
        "to" => spec.to,
        "content" => spec.content,
        "asset" => asset_key
      }
      |> drop_nil_fields()

    {%{"provider" => "chezmoi", "spec" => spec}, assets}
  end

  defp normalize_recipe(_package_id, %{provider: "shell", spec: spec}, assets) do
    spec = %{
      "target" => spec.target,
      "fragment" =>
        %{
          "id" => spec.fragment.id,
          "marker" => spec.fragment.marker,
          "body" => spec.fragment.body,
          "order" => spec.fragment.order
        }
        |> drop_nil_fields()
    }

    {%{"provider" => "shell", "spec" => spec}, assets}
  end

  defp normalize_recipe(_package_id, %{provider: "chezmoi-data", spec: spec}, assets) do
    {%{"provider" => "chezmoi-data", "spec" => %{"content" => spec.content}}, assets}
  end

  # nvim-profile specs stay raw validated maps (the compositor's own entry
  # shape); emission is a mechanical atom->string pass that drops nil fields
  # (absent Lua keys) and keeps declared-empty lists.
  defp normalize_recipe(_package_id, %{provider: "nvim-profile", spec: spec}, assets) do
    {%{"provider" => "nvim-profile", "spec" => stringify(spec)}, assets}
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)

  defp stringify(value) when is_map(value) do
    value
    |> Enum.reject(fn {_key, element} -> is_nil(element) end)
    |> Map.new(fn {key, element} -> {to_string(key), stringify(element)} end)
  end

  defp stringify(value), do: value

  # --- synthetic profiles: plain normalized envelopes, validated by the
  # engine at replay time. They exercise the two-declarers-one-target
  # directory merge (with an exact single-owner directory for contrast),
  # explicit shell fragment order keys with the collection-order tie-break,
  # and nvim profile intents with the same tie-break, without importing any
  # package module. Mirrors golden.lua synthetic_profiles verbatim.

  defp synthetic_records("conflicts") do
    [
      %{
        "id" => "declarer-alpha",
        "requires" => [],
        "contributes" => [
          %{
            "provider" => "chezmoi",
            "spec" => %{"target" => ".config/goldens-share", "kind" => "directory"}
          },
          %{
            "provider" => "chezmoi",
            "spec" => %{
              "target" => ".config/goldens-share/alpha.txt",
              "kind" => "file",
              "content" => "alpha\n"
            }
          },
          %{
            "provider" => "chezmoi",
            "spec" => %{
              "target" => ".config/goldens-share/inner",
              "kind" => "directory",
              "private" => true
            }
          },
          %{
            "provider" => "chezmoi",
            "spec" => %{
              "target" => ".config/goldens-share/inner/keep.txt",
              "kind" => "file",
              "content" => "kept\n"
            }
          },
          %{
            "provider" => "chezmoi",
            "spec" => %{
              "target" => ".local/goldens-private",
              "kind" => "directory",
              "exact" => true,
              "private" => true
            }
          },
          %{
            "provider" => "chezmoi",
            "spec" => %{
              "target" => ".local/goldens-private/only.txt",
              "kind" => "file",
              "content" => "exact-owned\n"
            }
          }
        ]
      },
      %{
        "id" => "declarer-beta",
        "requires" => [],
        "contributes" => [
          %{
            "provider" => "chezmoi",
            "spec" => %{"target" => ".config/goldens-share", "kind" => "directory"}
          },
          %{
            "provider" => "chezmoi",
            "spec" => %{
              "target" => ".config/goldens-share/inner",
              "kind" => "directory",
              "private" => true
            }
          },
          %{
            "provider" => "chezmoi",
            "spec" => %{
              "target" => ".config/goldens-share/beta.txt",
              "kind" => "file",
              "content" => "beta\n"
            }
          }
        ]
      }
    ]
  end

  defp synthetic_records("shell-order") do
    [
      %{
        "id" => "shell-orderer-a",
        "requires" => [],
        "contributes" => [
          %{
            "provider" => "shell",
            "spec" => %{
              "target" => ".config/goldens-order.sh",
              "fragment" => %{
                "id" => "late-a",
                "marker" => "# goldens: late",
                "body" => "export GOLDEN_ORDER=late",
                "order" => 30
              }
            }
          },
          %{
            "provider" => "shell",
            "spec" => %{
              "target" => ".config/goldens-order.sh",
              "fragment" => %{
                "id" => "first-a",
                "marker" => "# goldens: first",
                "body" => "export GOLDEN_ORDER=first",
                "order" => 10
              }
            }
          }
        ]
      },
      %{
        "id" => "shell-orderer-b",
        "requires" => [],
        "contributes" => [
          %{
            "provider" => "shell",
            "spec" => %{
              "target" => ".config/goldens-order.sh",
              "fragment" => %{
                "id" => "middle-b",
                "marker" => "# goldens: middle",
                "body" => "export GOLDEN_ORDER=middle",
                "order" => 20
              }
            }
          },
          %{
            "provider" => "shell",
            "spec" => %{
              "target" => ".config/goldens-order.sh",
              "fragment" => %{
                "id" => "tied-b",
                "marker" => "# goldens: tied",
                "body" => "export GOLDEN_ORDER=tied",
                "order" => 10
              }
            }
          }
        ]
      }
    ]
  end

  defp synthetic_records("nvim-profile") do
    [
      %{
        "id" => "lang-goldens-go",
        "requires" => [],
        "contributes" => [
          %{
            "provider" => "nvim-profile",
            "spec" => %{
              "order" => 10,
              "entry" => %{
                "id" => "goldens-go",
                "requires" => ["go"],
                "lazyvim_extras" => ["lazyvim.plugins.extras.lang.go"],
                "language_cases" => [
                  %{
                    "language" => "go",
                    "filename" => "goldens_test.go",
                    "contents" => "package goldens\n",
                    "client" => "gopls"
                  }
                ]
              }
            }
          }
        ]
      },
      %{
        "id" => "lang-goldens-ts",
        "requires" => [],
        "contributes" => [
          %{
            "provider" => "nvim-profile",
            "spec" => %{
              "order" => 20,
              "entry" => %{
                "id" => "goldens-ts",
                "lazyvim_extras" => [],
                "mason_packages" => ["goldens-typescript-language-server"],
                "language_cases" => [
                  %{
                    "language" => "javascript",
                    "filename" => "goldens-test.js",
                    "contents" => "const answer = 42;\n",
                    "client" => "goldens-ts"
                  }
                ]
              }
            }
          }
        ]
      },
      %{
        "id" => "lang-goldens-std",
        "requires" => [],
        "contributes" => [
          %{
            "provider" => "nvim-profile",
            "spec" => %{
              "order" => 20,
              "entry" => %{
                "id" => "goldens-std",
                "lazyvim_extras" => ["lazyvim.plugins.extras.lang.toml"],
                "language_cases" => [
                  %{
                    "language" => "toml",
                    "filename" => "goldens-test.toml",
                    "contents" => "answer = 42\n",
                    "client" => "taplo"
                  }
                ]
              }
            }
          }
        ]
      }
    ]
  end

  defp synthetic_records(_profile), do: nil

  # --- replay (the recorded envelope goes through the real pipeline) ---

  defp replay(input) do
    catalog = Catalog.load(input)

    graph =
      Graph.order(%{
        host: catalog.host,
        specifications: catalog.packages
      })

    {catalog, Source.plan(%{graph: graph})}
  end

  # A nil Lua field is an absent key, not a null: the projection must drop it
  # so the canonical encoding reproduces the recorded bytes field-for-field.
  defp drop_nil_fields(map) do
    map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  end

  defp octal(mode), do: mode |> Integer.to_string(8) |> String.pad_leading(4, "0")
end
