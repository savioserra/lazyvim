defmodule Workstation.Core.Golden do
  @moduledoc """
  The golden generator — the canonical re-record path for the
  `tests/goldens/<profile>/` trees.

  Each profile records four files: `input.json` (the only replay input),
  `expected/plan.json`, `expected/manifest.json` and
  `expected/generation.txt` (the sha256 of the exact manifest bytes plus one
  newline). The recorded bytes must stay identical across generator runs and
  against the committed tree; `GoldenGenerateTest` runs the drift assertion
  (no cross-process check is needed here: `CanonicalJSON` is deterministic,
  there is no encoder seeding).

  Envelope rules (the recorded header contract):

  * catalog profiles record the dependency closure of their seeds in
    discovery order (module-name / id sort — there is no registration
    list): `minimal` seeds `foundation`, `theme` seeds
    `theme`/`tmux`/`agent`, `full-home` records the complete catalog;
    `conflicts`, `shell-order` and `nvim-profile` are synthetic literal
    envelopes, validated by the engine at replay time;
  * declared spec fields are recorded verbatim, derived `components` are
    dropped (recipe constructors re-derive them at replay time), package
    asset bodies move into the top-level `assets` map under
    `"<package id>:<asset path>"`;
  * home-anchored symlink destinations are pinned at declaration time in the
    native catalog (`Catalog.canonical_home/0`, the recorder's own
    destination pinning), so normalization copies them verbatim — that
    pinning IS the recorded bytes;
  * nil struct fields disappear from `input.json` (absent key, not null),
    while empty lists stay present (`lazyvim_extras: []`) and an empty
    assets map encodes as `[]`.

  A golden drift is an engine or envelope change: it must be re-recorded
  deliberately (`mix workstation.goldens`) after review — never by editing
  the committed bytes. This module is the only generator; the committed
  bytes are the evidence every replay must reproduce.
  """

  alias Workstation.Core.{CanonicalJSON, Catalog, Graph, Source}
  alias Workstation.Backends.Chezmoi

  # Recording order (also the on-disk directory names).
  @profiles [
    "minimal",
    "full-home",
    "theme",
    "conflicts",
    "shell-order",
    "nvim-profile",
    "download",
    "git",
    "context"
  ]

  # Catalog profile seeds: minimal records the foundation package alone,
  # theme the theme/tmux/agent closure (their dependency closure adds
  # foundation and node); any profile without seeds records the complete
  # catalog.
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
      "remove_file" => plan.remove_file,
      "context" => plan_context_view(plan.context),
      "effects" => plan_effects_view(plan)
    }
    |> drop_nil_fields()
  end

  # The resolved package context: per-package, dependency-scoped views —
  # recorded only when non-empty (the nil-drop convention; profiles whose
  # packages declare no context_requires keep their recorded bytes).
  defp plan_context_view(context) do
    case context do
      m when m == %{} ->
        nil

      context ->
        Map.new(context, fn {package, keys} ->
          {package,
           Map.new(keys, fn {key, entry} ->
             {key, %{"schema" => entry.schema, "value" => entry.value}}
           end)}
        end)
    end
  end

  # The typed mutation program the apply fold runs, in fold order: the
  # recorded plan DECLARES its effects (contract, kind, phase ordering) —
  # pinned-artifact installs and composed shell programs first, the single
  # staged-generation apply last. This is the declared typed-effects plan
  # shape the goldens were regenerated for (one deliberate re-record; it
  # replaces the download-only pin view the wire carried before). Projected
  # only when present: a plan without effects (none can exist today — the
  # staged-generation apply effect is unconditional) would keep its bytes.
  defp plan_effects_view(plan) do
    case Workstation.Pipeline.effects(plan) do
      [] ->
        nil

      effects ->
        Enum.map(effects, fn effect ->
          %{
            "contract" => effect.contract,
            "kind" => to_string(effect.kind),
            "target" => effect[:target],
            "owner" => effect[:owner],
            "url" => effect[:url],
            "version" => effect[:version],
            "sha256" => effect[:sha256],
            "commit" => effect[:commit],
            "fingerprint" => effect[:fingerprint],
            "attribution" => effect[:attribution],
            "generation" => effect[:generation]
          }
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()
        end)
    end
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

  # The catalog closure of the profile's seeds, in discovery order (module
  # name / id sort — the recorded construction order). Only `requires` edges
  # pull packages into the closure:
  # `after` edges are sequencing-only and never widen the recording.
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
        %{
          "id" => package.id,
          "requires" => package.requires || [],
          "contributes" => contributes
        }
        |> put_after(Map.get(package, :after))
        |> put_supported_hosts(package.supported_hosts)
        |> put_exports(Map.get(package, :exports))
        |> put_context_requires(Map.get(package, :context_requires))

      {record, assets}
    end)
  end

  # The package-context surface records only when declared (the nil-drop
  # convention); export values are already pure string-keyed data — the
  # same bytes the recorded envelope and the wire carry.
  defp put_exports(record, nil), do: record
  defp put_exports(record, []), do: record

  defp put_exports(record, exports) when is_list(exports),
    do: Map.put(record, "exports", Enum.map(exports, &stringify/1))

  defp put_context_requires(record, nil), do: record
  defp put_context_requires(record, []), do: record

  defp put_context_requires(record, requires) when is_list(requires),
    do:
      Map.put(
        record,
        "context_requires",
        Enum.map(requires, fn req -> %{"key" => req.key, "schema" => req.schema} end)
      )

  # Ordering-only edges are recorded only when declared (nil-dropped like
  # every absent field); the graph applies them only between present,
  # enabled packages.
  defp put_after(record, edges) when is_list(edges) and edges != [],
    do: Map.put(record, "after", edges)

  defp put_after(record, _), do: record

  # The recorded hosts shape is a host->true map;
  # native declarations already carry that form (the graph gates on it),
  # and the list form normalizes into it. CanonicalJSON sorts the keys.
  defp put_supported_hosts(record, nil), do: record

  defp put_supported_hosts(record, hosts) when is_map(hosts),
    do: Map.put(record, "supported_hosts", hosts)

  defp put_supported_hosts(record, hosts) when is_list(hosts),
    do: Map.put(record, "supported_hosts", Map.new(hosts, fn host -> {host, true} end))

  # Generic-backend shapes route through the family constants; capability
  # specs stay raw validated maps (their owner module's own entry shape).
  # Generic-backend shapes route through the family constants; capability
  # specs stay raw validated maps (their owner module's own entry shape),
  # discovered through the provider contract — no capability is named here.
  defp normalize_recipe(package_id, %{provider: provider, spec: spec}, assets) do
    cond do
      provider == Chezmoi.provider_id() ->
        normalize_chezmoi(package_id, spec, assets)

      provider == Chezmoi.data_provider_id() ->
        {%{"provider" => provider, "spec" => %{"content" => spec.content}}, assets}

      provider == Workstation.Core.Contracts.Shell.provider_id() ->
        {%{"provider" => provider, "spec" => normalize_shell_spec(spec)}, assets}

      provider == Workstation.Core.Contracts.Download.provider_id() ->
        {%{"provider" => provider, "spec" => normalize_download_spec(spec)}, assets}

      true ->
        case Workstation.Core.Contracts.Provider.Discover.lookup(provider) do
          {:ok, _module} ->
            {%{"provider" => provider, "spec" => stringify(spec)}, assets}

          :error ->
            raise ArgumentError,
                  "cannot normalize #{package_id} contribution: unknown provider #{inspect(provider)}"
        end
    end
  end

  defp normalize_chezmoi(package_id, spec, assets) do
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

    {%{"provider" => Chezmoi.provider_id(), "spec" => spec}, assets}
  end

  defp normalize_download_spec(spec) do
    base = %{
      "version" => spec.version,
      "target" => spec.target
    }

    case spec.assets do
      nil ->
        Map.merge(base, %{"url" => spec.url, "sha256" => spec.sha256})

      assets ->
        Map.put(base, "assets", Map.new(assets, fn {tag, asset} -> {tag, %{"url" => asset.url, "sha256" => asset.sha256}} end))
    end
  end

  defp normalize_shell_spec(spec) do
    %{
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
  # package module.

  defp synthetic_records("conflicts") do
    [
      %{
        "id" => "declarer-alpha",
        "requires" => [],
        "contributes" => [
          %{
            "provider" => Chezmoi.provider_id(),
            "spec" => %{"target" => ".config/goldens-share", "kind" => "directory"}
          },
          %{
            "provider" => Chezmoi.provider_id(),
            "spec" => %{
              "target" => ".config/goldens-share/alpha.txt",
              "kind" => "file",
              "content" => "alpha\n"
            }
          },
          %{
            "provider" => Chezmoi.provider_id(),
            "spec" => %{
              "target" => ".config/goldens-share/inner",
              "kind" => "directory",
              "private" => true
            }
          },
          %{
            "provider" => Chezmoi.provider_id(),
            "spec" => %{
              "target" => ".config/goldens-share/inner/keep.txt",
              "kind" => "file",
              "content" => "kept\n"
            }
          },
          %{
            "provider" => Chezmoi.provider_id(),
            "spec" => %{
              "target" => ".local/goldens-private",
              "kind" => "directory",
              "exact" => true,
              "private" => true
            }
          },
          %{
            "provider" => Chezmoi.provider_id(),
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
            "provider" => Chezmoi.provider_id(),
            "spec" => %{"target" => ".config/goldens-share", "kind" => "directory"}
          },
          %{
            "provider" => Chezmoi.provider_id(),
            "spec" => %{
              "target" => ".config/goldens-share/inner",
              "kind" => "directory",
              "private" => true
            }
          },
          %{
            "provider" => Chezmoi.provider_id(),
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

  # The download profile exercises the pinned-artifact contract without any
  # package wiring: two synthetic contributions (a versioned opt artifact and
  # a bin artifact) whose descriptors are content-addressed into the manifest
  # and projected into the recorded plan view. The urls are under the
  # reserved .invalid TLD and the checksums are synthetic -- replay never
  # fetches, the pure plan only pins.
  defp synthetic_records("download") do
    [
      %{
        "id" => "tooling-goldens",
        "requires" => [],
        "contributes" => [
          %{
            "provider" => "download",
            "spec" => %{
              "url" => "https://goldens.invalid/artifacts/nunchux/0.1.0/nunchux",
              "version" => "0.1.0",
              "sha256" => "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
              "target" => ".local/opt/goldens/nunchux"
            }
          },
          %{
            "provider" => "download",
            "spec" => %{
              "url" => "https://goldens.invalid/artifacts/goldens-ls/1.2.3/goldens-ls",
              "version" => "1.2.3",
              "sha256" => "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
              "target" => ".local/bin/goldens-ls"
            }
          }
        ]
      }
    ]
  end

  # The git profile exercises the pinned-clone contract without any package
  # wiring: one synthetic contribution whose pin (url + commit + target) is
  # content-addressed into the plan's composed profile and declared as a
  # clone effect on the recorded wire. The url is under the reserved
  # .invalid TLD and the commit is a synthetic sha -- replay never clones,
  # the pure plan only pins.
  defp synthetic_records("git") do
    [
      %{
        "id" => "checkouts-goldens",
        "requires" => [],
        "contributes" => [
          %{
            "provider" => "git",
            "spec" => %{
              "url" => "https://goldens.invalid/git/goldens-repo.git",
              "commit" => "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
              "target" => ".local/share/goldens/checkouts/repo"
            }
          }
        ]
      }
    ]
  end

  # The context profile exercises the package-context API without any
  # package wiring: two exporters (a theme-shaped capability and an editor
  # capability) and a consumer that requires both, declaring its
  # context_requires against DECLARED dependencies only. The recorded plan
  # carries the consumer's resolved, dependency-scoped view — the fold is a
  # pure function of (manifests, resolver order), so the same envelopes
  # replay byte-identically forever. Replay composes; nothing applies.
  defp synthetic_records("context") do
    [
      %{
        "id" => "goldens-theme",
        "requires" => [],
        "exports" => [
          %{
            "key" => "goldens-theme",
            "schema" => 1,
            "value" => %{
              "appearance" => "dark",
              "roles" => ["base", "accent", "muted"],
              "slots" => %{"statusline" => "statusline", "tabline" => "tabline"}
            }
          }
        ],
        "contributes" => []
      },
      %{
        "id" => "goldens-editor",
        "requires" => [],
        "exports" => [
          %{
            "key" => "goldens-editor",
            "schema" => 1,
            "value" => %{"config_root" => ".config/nvim", "kind" => "editor", "name" => "goldens-nvim"}
          }
        ],
        "contributes" => []
      },
      %{
        "id" => "goldens-consumer",
        "requires" => ["goldens-theme", "goldens-editor"],
        "context_requires" => [
          %{"key" => "goldens-editor", "schema" => 1},
          %{"key" => "goldens-theme", "schema" => ">=1"}
        ],
        "contributes" => []
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

  # A nil field is an absent key, not a null: the projection must drop it
  # so the canonical encoding reproduces the recorded bytes field-for-field.
  defp drop_nil_fields(map) do
    map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  end

  defp octal(mode), do: mode |> Integer.to_string(8) |> String.pad_leading(4, "0")
end
