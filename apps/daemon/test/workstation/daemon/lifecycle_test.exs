defmodule Workstation.Daemon.LifecycleTest do
  use ExUnit.Case, async: false

  # Fixture homes are cross-VM collision-proof: `System.unique_integer/1`
  # restarts its sequence in every `mix test` VM, so a home that outlives its
  # run (a killed run's leftovers) is re-drawn verbatim by a later one. The
  # boot millisecond in base36 never repeats across VMs, any same-named
  # leftover is swept before use, and the home is removed on exit (the full
  # note lives in apps/daemon/test/workstation/daemon/generation_test.exs).
  defp unique_home(prefix) do
    token = Integer.to_string(:os.system_time(:millisecond), 36)
    home = Path.join(System.tmp_dir!(), "#{prefix}-#{token}")

    File.rm_rf!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    home
  end


  # End-to-end lifecycle-op coverage over a real socket (b8 graduation
  # wiring): the orchestrator lock is taken and released around the op, and
  # the refusal is the honest `not_graduated` gate — never a fake success.
  # Serial like ListenerTest: the tree binds a real unix socket per test
  # home and never touches the real HOME.
  alias Workstation.Core.EngineState
  alias Workstation.Daemon.{ApplyOrchestrator, Listener, Protocol}

  # git is the sandbox fixture transport; without it the pull fixtures
  # cannot exist (the same guard the core PullTest suite pins).
  @git_present System.find_executable("git") != nil

  setup do
    home = unique_home("b8-lifecycle")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    # The graduation default is OPEN (the daemon is the only mutation
    # engine); normalize the flag so suite-order shuffles cannot leak a
    # pinned-off apply pipeline into the default-path tests.
    Application.delete_env(:daemon, :engine_apply)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      Application.delete_env(:daemon, :engine_apply)
    end)

    start_supervised!(Workstation.Daemon.Application.supervisor_spec())
    wait_for_file(Listener.socket_path())

    %{home: home}
  end

  defp wait_for_file(path, tries \\ 100)

  defp wait_for_file(_path, 0), do: flunk("listener socket never appeared")

  defp wait_for_file(path, tries) do
    if File.exists?(path), do: :ok, else: (Process.sleep(20) && wait_for_file(path, tries - 1))
  end

  defp request(op, params) do
    {:ok, sock} = :socket.open(:local, :stream, :default)

    try do
      :ok = :socket.connect(sock, %{family: :local, path: String.to_charlist(Listener.socket_path())}, 2_000)
      :ok = :socket.send(sock, Protocol.encode_frame(hello_body()))
      {:ok, _hello_frame} = recv_frame(sock)

      :ok = :socket.send(sock, Protocol.encode_frame(Jason.encode!(%{"v" => 1, "id" => "l1", "op" => op, "params" => params})))
      # Ops stream progress events ahead of the reply now (the daemon owns
      # the chain); drain the event frames until the id-matched result.
      recv_result(sock, "l1")
    after
      :socket.close(sock)
    end
  end

  defp hello_body, do: Jason.encode!(%{"v" => 1, "id" => "h1", "op" => "hello", "params" => %{"protocol" => Protocol.protocol_name()}})

  defp recv_result(sock, id) do
    case recv_frame(sock) do
      {:ok, %{"id" => ^id} = reply} -> reply
      {:ok, %{"event" => _event}} -> recv_result(sock, id)
      {:ok, other} -> flunk("unexpected frame: " <> inspect(other))
    end
  end

  defp recv_frame(sock) do
    {:ok, <<length::unsigned-big-integer-size(32)>>} = :socket.recv(sock, 4, 2_000)
    {:ok, body} = recv_exact(sock, length, [])
    {:ok, Jason.decode!(body)}
  end

  defp recv_exact(_sock, 0, chunks), do: {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}

  defp recv_exact(sock, remaining, chunks) do
    {:ok, data} = :socket.recv(sock, remaining, 2_000)
    recv_exact(sock, remaining - byte_size(data), [data | chunks])
  end

  test "with graduation open (the default), apply.run reaches the engine and refuses on merit" do
    # The gate is open: the refusal is the ENGINE's precondition (the
    # requested generation cannot match a plan built on an empty sandbox),
    # never the graduation gate.
    reply = request("apply.run", %{"generation" => "gen-1", "entries" => []})

    assert %{"ok" => false, "error" => %{"code" => "apply_refused", "message" => message}} = reply
    assert message =~ "stale plan"

    # The orchestration is real: the lock is gone once the op answers.
    refute File.exists?(ApplyOrchestrator.lock_path(EngineState.state_root()))
  end

  test "with the graduation flag pinned off, the apply pipeline answers the honest refusal" do
    # The env flag is the off switch for the APPLY PIPELINE ONLY: the
    # lifecycle chain (bootstrap provisioning et al) is deliberately never
    # gated — bootstrap is what installs the release, pre-graduation
    # included (parity with the retired in-process engine path).
    Application.put_env(:daemon, :engine_apply, false)

    reply = request("apply.run", %{"generation" => "gen-1", "entries" => []})

    assert %{"ok" => false, "error" => %{"code" => "not_graduated", "message" => message}} = reply
    assert message == Workstation.Daemon.Apply.not_graduated_message()

    refute File.exists?(ApplyOrchestrator.lock_path(EngineState.state_root()))
  end

  # The "for real" lifecycle step runs git against a SANDBOX checkout — a
  # throwaway origin + clone carrying the engine payload markers, pinned
  # through the daemon's sanctioned resolution seam (WORKSTATION_ENGINE_REPO,
  # first in the Workstation.Core.Update resolution order). Serving the live
  # checkout made the assertion a function of git topology (a diverged
  # developer branch ⇢ the honest ff-only refusal) instead of tree content —
  # an environment-coupled red of the same class the fixture-home work
  # collision-proofed. The engine's checked pull --ff-only refusal is
  # CORRECT and is pinned here positively and negatively over the wire; the
  # plumbing mirrors apps/core/test/workstation/core/update/pull_test.exs,
  # which pins the refusal at the core layer (suites don't share test
  # support across apps).

  @tag skip: if(@git_present, do: false, else: "git not available")
  test "update.run executes the cheap lifecycle step for real (the chain is never graduation-gated)" do
    # pull is the cheapest chain step and is read-only for the home: its
    # honest ok over the wire — with the fetched head actually landed on the
    # sandbox checkout — is the proof the lifecycle chain runs regardless of
    # the apply-pipeline flag.
    {checkout, origin, base} = sandbox_checkout()
    second = push_upstream!(base, origin, "second\n")

    with_engine_repo(checkout, fn ->
      reply = request("update.run", %{"step" => "pull"})

      assert %{"ok" => true, "result" => %{"step" => "pull", "status" => "ok", "head" => ^second}} = reply
      assert git_out!(checkout, ["rev-parse", "HEAD"]) == second
    end)

    refute File.exists?(ApplyOrchestrator.lock_path(EngineState.state_root()))
  end

  @tag skip: if(@git_present, do: false, else: "git not available")
  test "a diverged engine checkout refuses the pull step on the wire and is never reset" do
    # The engine's half of the contract over the real socket: the checked
    # ff-only refusal (a diverged upstream aborts the update, never resets
    # owner work) rides the wire verbatim as update_failed, and the checkout
    # still owns its local head afterwards.
    {checkout, origin, base} = sandbox_checkout()

    File.write!(Path.join(checkout, "local.txt"), "local work\n")
    git_out!(checkout, ["add", "."])
    git_out!(checkout, ["commit", "-q", "-m", "local"])
    local_head = git_out!(checkout, ["rev-parse", "HEAD"])

    sideways = clone!(base, origin, Path.join(base, "sideways"))
    File.write!(Path.join(sideways, "sideways.txt"), "sideways\n")
    git_out!(sideways, ["add", "."])
    git_out!(sideways, ["commit", "-q", "-m", "sideways"])
    git_out!(sideways, ["push", "-q", "--force", "origin", "HEAD:refs/heads/main"])
    refute git_out!(sideways, ["rev-parse", "HEAD"]) == local_head

    with_engine_repo(checkout, fn ->
      reply = request("update.run", %{"step" => "pull"})

      assert %{"ok" => false, "error" => %{"code" => "update_failed", "message" => message}} = reply
      assert message =~ "upstream is not a fast-forward"
      assert message =~ "refusing to reset"
    end)

    assert git_out!(checkout, ["rev-parse", "HEAD"]) == local_head
    refute File.exists?(ApplyOrchestrator.lock_path(EngineState.state_root()))
  end

  test "a held lock reports its owner instead of running the op" do
    {:ok, token, _path} = ApplyOrchestrator.acquire("held by test")

    reply = request("apply.run", %{"generation" => "gen-1", "entries" => []})

    assert %{"ok" => false, "error" => %{"code" => "locked", "message" => message}} = reply
    # The owner report is the recorded metadata (uid + node), not the
    # purpose — that is the fail-closed report the wire pins.
    assert message =~ "apply lock held by uid="

    :ok = ApplyOrchestrator.release(token)
  end

  test "invalid params are refused by the schema, never dispatched" do
    for {op, params} <- [
          {"apply.run", %{}},
          {"apply.run", %{"generation" => ""}},
          {"apply.run", %{"generation" => "gen-1", "entries" => %{"bad" => "shape"}}},
          {"update.run", %{"step" => "reboot"}},
          {"update.run", %{}}
        ] do
      reply = request(op, params)
      assert %{"ok" => false, "error" => %{"code" => "invalid_params"}} = reply
    end

    refute File.exists?(ApplyOrchestrator.lock_path(EngineState.state_root()))
  end

  ## sandbox git plumbing (all git operations are filesystem-local)

  # A complete engine checkout (versions.json + bin/workstation) cloned from
  # a throwaway bare origin, its payload materialized as owner WIP: the
  # markers are what Workstation.Core.Update adopts, and their absence would
  # let resolution fall through to the live repository checkout.
  defp sandbox_checkout do
    base = unique_home("b8-pull")
    File.mkdir_p!(base)

    origin = Path.join(base, "origin.git")
    File.mkdir_p!(origin)
    git_out!(origin, ["init", "--bare"])
    git_out!(origin, ["symbolic-ref", "HEAD", "refs/heads/main"])

    seed = Path.join(base, "seed")
    File.mkdir_p!(seed)
    git_out!(seed, ["init", "-b", "main"])
    File.write!(Path.join(seed, "first.txt"), "first\n")
    git_out!(seed, ["add", "."])
    git_out!(seed, ["commit", "-q", "-m", "first"])
    git_out!(seed, ["push", "-q", origin, "HEAD:refs/heads/main"])

    checkout = clone!(base, origin, Path.join(base, "checkout"))
    File.mkdir_p!(Path.join(checkout, "bin"))
    File.write!(Path.join(checkout, "versions.json"), "{}")
    File.write!(Path.join(checkout, "bin/workstation"), "#!/bin/sh\n")

    {checkout, origin, base}
  end

  defp clone!(base, origin, path) do
    git_out!(base, ["clone", "-q", origin, path])
    path
  end

  # Move the upstream forward from a THIRD clone: the sandbox checkout may
  # carry owner WIP, so upstream commits come from elsewhere, never from it.
  defp push_upstream!(base, origin, contents) do
    work = clone!(base, origin, Path.join(base, "push-#{System.unique_integer([:positive])}"))
    File.write!(Path.join(work, "second.txt"), contents)
    git_out!(work, ["add", "."])
    git_out!(work, ["commit", "-q", "-m", "second"])
    git_out!(work, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    git_out!(work, ["rev-parse", "HEAD"])
  end

  defp git_out!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], env: git_env(), stderr_to_stdout: true)
    String.trim_trailing(out)
  end

  # The fixtures are independent of the operator's git configuration,
  # exactly like the production step's pinned environment.
  defp git_env,
    do: [
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_SYSTEM", "/dev/null"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_AUTHOR_NAME", "fixture"},
      {"GIT_AUTHOR_EMAIL", "fixture@test"},
      {"GIT_COMMITTER_NAME", "fixture"},
      {"GIT_COMMITTER_EMAIL", "fixture@test"}
    ]

  # WORKSTATION_ENGINE_REPO is the daemon's sanctioned engine-checkout seam
  # (Workstation.Core.Update resolution order, before the dev-anchor walk),
  # and this suite is serialized (async: false), so the pin is invisible to
  # every other test. The bracket restores the caller's value even when an
  # assertion raises.
  defp with_engine_repo(checkout, fun) do
    previous = System.get_env("WORKSTATION_ENGINE_REPO")
    System.put_env("WORKSTATION_ENGINE_REPO", checkout)

    try do
      fun.()
    after
      if previous,
        do: System.put_env("WORKSTATION_ENGINE_REPO", previous),
        else: System.delete_env("WORKSTATION_ENGINE_REPO")
    end
  end
end
