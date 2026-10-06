defmodule Workstation.Daemon.LifecycleHandoffTest do
  @moduledoc """
  The release-refresh + handoff-note composition contract, daemon-side.

  Migrated from the retired `Workstation.CLI.Engine` suite (engine work,
  M1): the refresh gating, the handoff note, and the stamp-vs-path identity
  rule are implemented once in `Workstation.Daemon.Lifecycle` and the CLI
  is a thin protocol client, so these tests exercise the module the daemon
  actually runs. Semantics are pinned verbatim from the original suite —
  including the P0 0fb69a4f writer-identity ordering and the 2026-10-05
  in-place-refresh incident.
  """

  use ExUnit.Case, async: false

  alias Workstation.Daemon.{Lifecycle, Listener}

  setup do
    home = Path.join(System.tmp_dir!(), "c2-daemon-handoff-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(home)
    end)

    # The bootstrap step locks through the orchestrator, so the daemon
    # supervisor (orchestrator included) must be up even for these
    # module-level tests.
    start_supervised!(Workstation.Daemon.Application.supervisor_spec())
    wait_for_file(Listener.socket_path())

    %{home: home}
  end

  test "release refresh skips honestly without a buildable anchor", %{home: home} do
    # A valid ENGINE checkout (the launcher's three anchor files) that does
    # not ship the elixir/ umbrella — laid out as <tmp>/workstation so the
    # engine's anchor resolution evaluates this tree and finds no release
    # source: engine_root accepts it, and the honest answer is a skip.
    parent = Path.join(System.tmp_dir!(), "ws-anchorless-#{System.unique_integer([:positive])}")
    anchorless = Path.join(parent, "workstation")
    File.mkdir_p!(Path.join([anchorless, "bin"]))
    File.mkdir_p!(Path.join([anchorless, "bootstrap"]))

    File.cp!(Path.join([repo_root(), "workstation", "bootstrap", "bootstrap.pins"]), Path.join([anchorless, "bootstrap", "bootstrap.pins"]))
    File.cp!(Path.join([repo_root(), "workstation", "versions.json"]), Path.join([anchorless, "versions.json"]))
    File.cp!(Path.join([repo_root(), "workstation", "bin", "workstation"]), Path.join([anchorless, "bin", "workstation"]))

    on_exit(fn -> File.rm_rf!(parent) end)

    {spy, installer} = spy_install()

    assert {:ok, false} = Lifecycle.release_refresh(engine_root: anchorless, home: home, installer: installer)
    assert spy_calls(spy) == []
  end

  test "a stale release refreshes through the installer and a stamped release then skips", %{home: home} do
    {spy, installer} = spy_install()

    assert {:ok, true} = Lifecycle.release_refresh(engine_root: repo_root(), home: home, installer: installer)
    assert spy_calls(spy) == [{repo_root(), home}]

    # The installer's stamp names the source HEAD it built; the next
    # refresh against the same checkout is a no-op (this is what makes the
    # update handoff terminate).
    assert {:ok, false} =
             Lifecycle.release_refresh(engine_root: repo_root(), home: home,
               installer: fn _a, _h -> flunk("installer must not run when the stamp matches HEAD") end
             )
  end

  test "a failed installer aborts the refresh with its output", %{home: home} do
    assert {:error, "boom"} =
             Lifecycle.release_refresh(engine_root: repo_root(), home: home,
               installer: fn _a, _h -> {"boom\n", 1} end
             )
  end

  test "the bootstrap step records the refresh and leaves a handoff note for its own release", %{home: home} do
    {_spy, installer} = spy_install()

    assert {:ok, record} =
             Lifecycle.run_step("bootstrap",
               home: home,
               engine_root: repo_root(),
               bootstrap_run: bootstrap_stub(),
               installer: installer
             )

    assert record["release_refreshed"] == true

    assert {:ok, %{"from_release" => release}} =
             note_path(home)
             |> File.read!()
             |> Jason.decode()

    assert release == :code.root_dir() |> to_string()

    # Probing under the release that wrote the note hands off — and the
    # note SURVIVES the handoff decision, so a crashed re-exec re-derives
    # the same handoff on the next run instead of finishing under stale
    # code.
    assert {:ok, ^release} = Lifecycle.update_handoff(home: home)
    assert File.exists?(note_path(home))
  end

  test "the handoff note records the identity captured BEFORE the installer re-stamps (P0 in 0fb69a4f)",
       %{home: home} do
    # The live P0: the note was written from a POST-install identity read.
    # The installer re-stamps the release, so the note then described the
    # NEW code; the refreshed process compared it against a fresh read of
    # the same stamp, saw its own note as its own identity, and handed off
    # forever (each generation re-deriving the note, the last one spawning
    # an empty --resume-from). The writer identity must be captured before
    # the installer runs — pinned here with an explicit value that no
    # post-install read could produce, since the fake installer leaves the
    # stamp untouched.
    {_spy, installer} = spy_install()

    assert {:ok, _record} =
             Lifecycle.run_step("bootstrap",
               home: home,
               engine_root: repo_root(),
               bootstrap_run: bootstrap_stub(),
               installer: installer,
               writer_identity: "pre-refresh-stamp"
             )

    assert {:ok, %{"from_release" => "pre-refresh-stamp"}} =
             note_path(home)
             |> File.read!()
             |> Jason.decode()
  end

  test "a refresh-free bootstrap clears a leftover handoff note and never calls the installer", %{home: home} do
    File.mkdir_p!(Path.dirname(stamp_path(home)))
    File.write!(stamp_path(home), repo_head() <> "\n")
    File.mkdir_p!(Path.dirname(note_path(home)))
    File.write!(note_path(home), Jason.encode!(%{"from_release" => "/opt/some-release"}))

    assert {:ok, record} =
             Lifecycle.run_step("bootstrap",
               home: home,
               engine_root: repo_root(),
               bootstrap_run: bootstrap_stub(),
               installer: fn _a, _h -> flunk("installer must not run when the stamp matches HEAD") end
             )

    assert record["release_refreshed"] == false
    refute File.exists?(note_path(home))
  end

  test "a note naming a different (newer) release is consumed with no handoff", %{home: home} do
    File.mkdir_p!(Path.dirname(note_path(home)))
    File.write!(note_path(home), Jason.encode!(%{"from_release" => "/opt/fake-release"}))

    assert {:ok, nil} = Lifecycle.update_handoff(home: home)
    refute File.exists?(note_path(home))
  end

  test "an in-place refresh is identified by stamp, not by path (live handoff incident)", %{home: home} do
    # The live 2026-10-05 incident: the refreshed release reuses the SAME
    # release root, so path identity made the refreshed code see its own
    # handoff note as foreign-stale and re-hand off forever (each child
    # slicing off one more step until an empty --resume-from exited 2).
    # Identity is the installer's stamp: old stamp in the note, new stamp
    # in the caller — the refreshed code is the handoff TARGET and consumes.
    File.mkdir_p!(Path.dirname(note_path(home)))
    File.write!(note_path(home), Jason.encode!(%{"from_release" => "old-head"}))

    assert {:ok, nil} = Lifecycle.update_handoff(home: home, release_identity: "new-head")
    refute File.exists?(note_path(home))
  end

  test "a note naming the caller's own stamp hands off and survives", %{home: home} do
    File.mkdir_p!(Path.dirname(note_path(home)))
    File.write!(note_path(home), Jason.encode!(%{"from_release" => "pulled-head"}))

    assert {:ok, "pulled-head"} = Lifecycle.update_handoff(home: home, release_identity: "pulled-head")

    # Survives deliberately: a crashed re-exec must re-derive the handoff
    # instead of finishing the chain under stale code; the successful
    # parent clears it (the plain runner pins that half).
    assert File.exists?(note_path(home))
  end

  test "release identity prefers the installer stamp over the path" do
    scratch = Path.join(System.tmp_dir!(), "ws-identity-#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf!(scratch) end)

    stamped = Path.join(scratch, "stamped-release")
    File.mkdir_p!(stamped)
    File.write!(Path.join(stamped, ".built-from"), "b44162c3\ntrailing junk line\n")

    assert Lifecycle.release_identity(stamped) == "b44162c3"

    unstamped = Path.join(scratch, "unstamped-release")
    File.mkdir_p!(unstamped)

    assert Lifecycle.release_identity(unstamped) == unstamped
  end

  test "a malformed handoff note is an error, never a silent continue", %{home: home} do
    File.mkdir_p!(Path.dirname(note_path(home)))
    File.write!(note_path(home), "not json")

    assert {:error, message} = Lifecycle.update_handoff(home: home)
    assert message =~ "malformed release handoff note"
  end

  ## release refresh + handoff plumbing (carried from the retired engine suite)

  # The repo root doubles as the engine anchor: it holds the elixir/ umbrella
  # directly, so opts[:engine_root] = repo_root() pins every resolution.
  # One level deeper than the retired CLI suite was — six ups from here.
  defp repo_root, do: Path.expand("../../../../../../", __DIR__)

  # Mirrors the engine's config-isolated rev-parse exactly: the staleness
  # comparison is stamp vs THIS value.
  defp repo_head do
    {out, 0} =
      System.cmd("git", ["-C", repo_root(), "rev-parse", "HEAD"],
        stderr_to_stdout: true,
        env: [{"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}]
      )

    String.trim_trailing(out)
  end

  defp stamp_path(home), do: Path.join([home, ".local", "opt", "workstation", ".built-from"])

  defp note_path(home),
    do: Path.join([home | Workstation.Core.EngineState.state_components()] ++ ["update", "handoff.json"])

  # The production installer contract, faked: record the invocation, stage
  # the activated release's HEAD stamp. A refresh test that needs a
  # never-call installer passes a flunking closure instead.
  defp spy_install do
    {:ok, pid} = Agent.start_link(fn -> [] end)

    fun = fn anchor, home ->
      Agent.update(pid, &[{anchor, home} | &1])
      File.mkdir_p!(Path.dirname(stamp_path(home)))
      File.write!(stamp_path(home), repo_head() <> "\n")
      {"installed\n", 0}
    end

    {pid, fun}
  end

  defp spy_calls(pid), do: Agent.get(pid, &Enum.reverse/1)

  defp bootstrap_stub, do: fn _opts -> {:ok, %{"step" => "bootstrap", "status" => "ok"}} end

  defp wait_for_file(path, tries \\ 100)

  defp wait_for_file(_path, 0), do: flunk("listener socket never appeared")

  defp wait_for_file(path, tries) do
    if File.exists?(path), do: :ok, else: (Process.sleep(20) && wait_for_file(path, tries - 1))
  end
end
