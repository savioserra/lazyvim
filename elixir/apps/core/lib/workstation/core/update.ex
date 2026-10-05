defmodule Workstation.Core.Update do
  @moduledoc """
  The UPDATE lifecycle steps: `pull --ff-only` → `bootstrap` → `apply` →
  `sync` → `verify`, stopping at the first failure — the verb contract
  recorded in `docs/capabilities.md` ("Checked pull --ff-only, fresh launcher
  bootstrap, apply, sync, verify; stop at first failure").

  One module per step under this namespace; each step is a pure function of
  its options plus the engine-owned source and target home, returning
  `{:ok, record}` on success and RAISING `ArgumentError` on failure — the
  same error contract `Workstation.Core.ApplyEngine` uses, so the daemon
  orchestrator surfaces the verbatim engine message on the wire and the
  abort-on-first-failure decision stays with the caller (the TUI chain, one
  daemon op per step).

  Steps never touch engine state outside the apply orchestration: sync and
  verify are read-only reconciliations against the journal, and the mutating
  steps (pull, bootstrap, apply) are gated at the daemon boundary by the
  same graduation flag as the engine applier until the graduation lane flips
  it.

  Engine-checkout resolution: the update lifecycle operates on the
  engine-owned source checkout — the directory holding
  `bootstrap/bootstrap.pins`, `versions.json` and `bin/workstation`. The
  native catalog reads package asset bytes from the same checkout.
  Resolution order: explicit `:engine_root` option, then
  `WORKSTATION_ENGINE_REPO` (with or without the `workstation` child), then
  the dev checkout anchor walked upwards — bounded, fail-closed, so
  a tree without the engine payload never silently updates some other
  checkout.
  """

  @doc "Lifecycle steps in execution order (docs/capabilities.md)."
  @spec steps() :: [String.t()]
  def steps, do: ["pull", "bootstrap", "apply", "sync", "verify"]

  @doc """
  The engine-owned checkout for update steps: `opts[:engine_root]` wins,
  then `WORKSTATION_ENGINE_REPO` (itself or its `workstation` child), then
  the dev checkout anchor walked upwards. Raises when no
  candidate carries the engine payload — a tree without
  `bootstrap/bootstrap.pins` is not an engine checkout, and updating one
  anyway would mutate an unrelated directory.
  """
  @spec engine_root(keyword()) :: String.t()
  def engine_root(opts) when is_list(opts) do
    explicit = Keyword.get(opts, :engine_root)

    candidates =
      [explicit | env_candidates()]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case Enum.find(candidates, &engine_checkout?/1) do
      nil ->
        anchor = checkout_anchor()

        case walk_up(anchor, 4) do
          nil ->
            raise ArgumentError,
                  "no engine checkout found (bootstrap.pins, versions.json and bin/workstation required); " <>
                    "looked at #{inspect(candidates)} and above #{inspect(anchor)}"

          root ->
            root
        end

      root ->
        root
    end
  end

  # The dev anchor: the sibling `workstation/` checkout next to the running
  # `elixir/` tree — the path the engine's development resolution always
  # landed on. Release and test environments resolve through `:engine_root`
  # or `WORKSTATION_ENGINE_REPO`; without any anchor there is no honest
  # checkout to guess.
  defp checkout_anchor do
    case elixir_dir() do
      nil -> nil
      dir -> Path.expand("../workstation", dir)
    end
  end

  defp elixir_dir do
    cwd = File.cwd!()

    if Path.basename(cwd) == "elixir" do
      cwd
    else
      parts = Path.split(cwd)
      idx = Enum.find_index(parts, &(&1 == "elixir"))

      if idx && idx > 0 do
        "/" <> Enum.join(Enum.take(parts, idx + 1), "/")
      else
        nil
      end
    end
  end

  defp env_candidates do
    case System.get_env("WORKSTATION_ENGINE_REPO") do
      dir when is_binary(dir) and dir != "" -> [dir, Path.join(dir, "workstation")]
      _other -> []
    end
  end

  # The payload root is the dev anchor's own directory or an
  # ancestor of it (dev resolution lands on `<repo>/workstation`, the
  # checkout payload is `<repo>/workstation`); the bound keeps a stray deep
  # anchor from walking outside the tree.
  defp walk_up(nil, _remaining), do: nil

  defp walk_up(dir, 0), do: if(engine_checkout?(dir), do: dir, else: nil)

  defp walk_up(dir, remaining) do
    cond do
      engine_checkout?(dir) -> dir
      true -> walk_up(Path.dirname(dir), remaining - 1)
    end
  end

  defp engine_checkout?(dir) when is_binary(dir) do
    File.regular?(Path.join(dir, "bootstrap/bootstrap.pins")) and
      File.regular?(Path.join(dir, "versions.json")) and
      File.regular?(Path.join(dir, "bin/workstation"))
  end

  defp engine_checkout?(_other), do: false

  @doc false
  @spec realpath(String.t()) :: String.t()
  def realpath(path) do
    components = path |> Path.expand() |> String.split("/", trim: true)
    resolve_components(components, "/", 40)
  end

  # True path resolution (the pinned Elixir build has no File.realpath):
  # every component is expanded no-follow and link targets are spliced back
  # into the component queue, hop-bounded because a link cycle is
  # filesystem data, never something to loop on (the same bound the shipped
  # launcher applies to its own symlink chain).
  defp resolve_components(_components, _acc, 0), do: raise(ArgumentError, "update: symlink loop while resolving a path")

  defp resolve_components([], acc, _depth), do: acc

  defp resolve_components([component | rest], acc, depth) do
    current = Path.join(acc, component)

    case File.read_link(current) do
      {:ok, link} -> resolve_components(String.split(Path.expand(link, acc), "/", trim: true) ++ rest, "/", depth - 1)
      {:error, _reason} -> resolve_components(rest, current, depth)
    end
  end
end
