defmodule Workstation.Core.Update.VerifyTest do
  @moduledoc """
  The verify step: launcher canonicity plus per-package journal fingerprint
  verification, over a sandbox home. Drift must fail WITH the owning
  package and target named — the wire message is the operator's diagnosis.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.Update.Verify
  alias Workstation.Core.{EngineState, Journal}

  setup do
    base = Path.join(System.tmp_dir!(), "c2-verify-#{System.unique_integer([:positive])}")
    home = Path.join(base, "home")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(base)
    end)

    %{base: base, home: home, root: engine_payload!(Path.join(base, "engine"))}
  end

  test "verifies a launcher plus untouched applied targets per package", %{home: home, root: root} do
    publish_launcher!(root, home)

    _ =
      seed_targets!(home, %{
        "fixture" => [{".config/fixture/rc", "export FIXTURE=1\n"}],
        "linker" => [{"dot_local/bin/tool", "link"}]
      })

    assert {:ok,
            %{
              "step" => "verify",
              "status" => "ok",
              "generation" => _,
              "packages" => packages
            }} = Verify.run(engine_root: root, home: home)

    # Deterministic per-package records, sorted by owning package.
    assert Enum.map(packages, & &1["package"]) == ["fixture", "linker"]
    assert Enum.all?(packages, &(&1["status"] == "ok" and &1["drifted"] == []))
  end

  test "a drifted target fails with the package and target named", %{home: home, root: root} do
    publish_launcher!(root, home)
    seed_targets!(home, %{"fixture" => [{".config/fixture/rc", "export FIXTURE=1\n"}]})

    # Drift AFTER the journal claims ownership.
    File.write!(Path.join(home, ".config/fixture/rc"), "tampered\n")

    assert_raise ArgumentError, ~r/verify: targets drifted.*fixture: \.config\/fixture\/rc/, fn ->
      Verify.run(engine_root: root, home: home)
    end
  end

  test "a deleted target is drift, not absence", %{home: home, root: root} do
    publish_launcher!(root, home)
    seed_targets!(home, %{"fixture" => [{".config/fixture/rc", "export FIXTURE=1\n"}]})
    File.rm_rf!(Path.join(home, ".config"))

    assert_raise ArgumentError, ~r/fixture: \.config\/fixture\/rc/, fn ->
      Verify.run(engine_root: root, home: home)
    end
  end

  test "a non-canonical launcher fails verify", %{home: home, root: root} do
    seed_targets!(home, %{"fixture" => [{".config/fixture/rc", "export FIXTURE=1\n"}]})
    launcher = Path.join([home, ".local", "bin", "workstation"])
    File.mkdir_p!(Path.dirname(launcher))
    File.ln_s!(Path.join(root, "bin/other"), launcher)

    assert_raise ArgumentError, ~r/public launcher mismatch/, fn ->
      Verify.run(engine_root: root, home: home)
    end
  end

  test "verify without an applied generation refuses", %{home: home, root: root} do
    publish_launcher!(root, home)

    assert_raise ArgumentError, ~r/no applied generation/, fn ->
      Verify.run(engine_root: root, home: home)
    end
  end

  ## fixtures

  # The payload markers the update steps resolve the engine checkout by.
  defp engine_payload!(root) do
    File.mkdir_p!(Path.join(root, "bootstrap"))
    File.mkdir_p!(Path.join(root, "bin"))
    File.write!(Path.join(root, "bootstrap/bootstrap.pins"), "fixture")
    File.write!(Path.join(root, "versions.json"), "{}")
    File.write!(Path.join(root, "bin/workstation"), "#!/bin/sh\n")
    root
  end

  defp publish_launcher!(root, home) do
    launcher = Path.join([home, ".local", "bin", "workstation"])
    File.mkdir_p!(Path.dirname(launcher))
    File.ln_s!(Workstation.Core.Update.realpath(Path.join(root, "bin/workstation")), launcher)
    launcher
  end

  # Write the live targets and record their ownership in the journal, the
  # way the applied engine leaves the home behind.
  defp seed_targets!(home, packages) do
    targets =
      for {owner, entries} <- packages,
          {target, contents} <- entries do
        {target, contents, owner}
      end

    Enum.each(targets, fn
      {target, "link", _owner} ->
        path = EngineState.join_home(home, target)
        File.mkdir_p!(Path.dirname(path))
        File.rm(path)
        File.ln_s!("/fixture/target", path)

      {target, contents, _owner} ->
        path = EngineState.join_home(home, target)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, contents)
    end)

    fingerprinted =
      Map.new(targets, fn {target, _contents, owner} ->
        fingerprint = EngineState.target_fingerprint(home, target)

        {target,
         fingerprint
         |> Map.put("owner", owner)
         |> Map.put("operation", "create")}
      end)

    :ok = EngineState.ensure_roots!(home)
    :ok = Journal.record_applied(home, String.duplicate("ab", 32), fingerprinted, [], [], %{})
    fingerprinted
  end
end
