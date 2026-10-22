defmodule Workstation.Core.PlanTest do
  @moduledoc """
  The composition-boundary contract for declared removals: `Source.plan/1`
  composes every declared removal inert (replay purity — a golden records a
  fresh journal and no filesystem), and `Pipeline.composed_plan/2` is the
  one production surface that activates them, exactly when the journal
  recorded the target or the target is present in the destination home. The
  tmux2k cutover tombstone is the first real consumer: without this
  boundary the declared removal was validated-but-inert on every surface.
  """

  use ExUnit.Case, async: false

  setup context do
    home = Path.join(System.tmp_dir!(), "workstation-plan-#{context.test}-#{:os.getpid()}")
    File.rm_rf!(home)
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

end
