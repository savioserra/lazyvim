defmodule Mix.Tasks.Workstation.Goldens do
  @shortdoc "Regenerate tests/goldens from the native Elixir engine"

  @moduledoc """
  The canonical golden re-record path: regenerates every recorded profile
  under `tests/goldens/` from the native engine (`Workstation.Core.Golden`).

      mix workstation.goldens            # rewrite the repository goldens
      mix workstation.goldens <out-root> # record into an explicit root

  The recorded bytes must match the committed tree exactly; the drift anchor
  (`Workstation.Core.GoldenGenerateTest`) fails closed otherwise. A golden
  drift is an engine or envelope change and is re-recorded deliberately after
  review — never by editing the committed bytes.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {_opts, argv, _invalid} = OptionParser.parse(args, strict: [])

    root =
      case argv do
        [] -> default_root()
        [dir] -> dir
        _ -> Mix.raise("usage: mix workstation.goldens [output-root]")
      end

    profiles = Workstation.Core.Golden.regenerate(root)

    Mix.shell().info(
      "goldens: recorded #{length(profiles)} profiles under #{root} (#{Enum.join(profiles, ", ")})"
    )
  end

  # The engine checkout anchor is the repository, so the default destination
  # is the recorded tree itself: regeneration must be a byte no-op on a
  # consistent tree, which is exactly what the drift anchors assert.
  defp default_root do
    Path.join([Path.dirname(Workstation.Core.Update.engine_root([])), "tests", "goldens"])
  end
end
