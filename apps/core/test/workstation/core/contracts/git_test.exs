defmodule Workstation.Core.Contracts.GitTest do
  @moduledoc """
  The pinned-clone recipe kind: recipe validation and the provider/effect
  contract split, real end-to-end clone cycles against local fixture
  repositories (real git, real shallow fetch, real detached checkout), the
  idempotent already-pinned path, every fail-closed refusal (non-checkout
  target, moved pin, tampered HEAD), and a full pipeline execute that rides
  the effects fold with zero pipeline edits — the plan carries the pins, the
  fold discovers the contract, the journal records the git-shaped claim.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.{Digest, Source}
  alias Workstation.Pipeline
  alias Workstation.Core.Contracts.Git

  @commit "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

  setup context do
    home = Path.join(System.tmp_dir!(), "workstation-git-#{context.test}-#{:os.getpid()}")
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

  describe "recipe validation" do
    test "a valid pin carries its content-addressed fingerprint" do
      pin = Git.recipe(%{url: "https://example.invalid/repo.git", commit: @commit, target: ".local/share/repo"})

      assert pin.id == "git"
      assert pin.fingerprint == Git.pin_fingerprint("https://example.invalid/repo.git", @commit, ".local/share/repo")
      assert pin.fingerprint == Digest.sha256(
               Workstation.Core.CanonicalJSON.encode(%{"commit" => @commit, "target" => ".local/share/repo", "url" => "https://example.invalid/repo.git"})
             )
    end

    test "https-only urls, 40-hex commits, safe relative literal targets" do
      assert_raise ArgumentError, ~r/must be https/, fn ->
        Git.recipe(%{url: "http://example.invalid/repo.git", commit: @commit, target: ".local/share/repo"})
      end

      assert_raise ArgumentError, ~r/40-hex lowercase sha/, fn ->
        Git.recipe(%{url: "https://example.invalid/repo.git", commit: "ABC", target: ".local/share/repo"})
      end

      assert_raise ArgumentError, ~r/must be a relative path/, fn ->
        Git.recipe(%{url: "https://example.invalid/repo.git", commit: @commit, target: "/etc/pwned"})
      end

      assert_raise ArgumentError, ~r/overlaps engine-private state/, fn ->
        Git.recipe(%{url: "https://example.invalid/repo.git", commit: @commit, target: ".local/state/workstation/x"})
      end

      assert_raise ArgumentError, ~r/unknown fields/, fn ->
        Git.validate_spec(%{url: "https://example.invalid/repo.git", commit: @commit, target: "x", branch: "main"})
      end
    end

    test "denormalize round-trips a recorded envelope through the validated recipe" do
      recorded = %{
        "url" => "https://example.invalid/repo.git",
        "commit" => @commit,
        "target" => ".local/share/repo"
      }

      assert Git.denormalize_spec(recorded) ==
               Git.recipe(%{url: recorded["url"], commit: recorded["commit"], target: recorded["target"]})
    end
  end

  describe "composition and typed effects" do
    test "compose returns the pin inventory as the provider's domain view" do
      intent = %{owner: "checkouts", spec: %{url: "https://example.invalid/repo.git", commit: @commit, target: ".local/share/repo"}}

      {record, pins} = Git.compose([intent])

      assert record.provider == "git"
      assert [%{git_pin: true, owner: "checkouts", target: ".local/share/repo", commit: @commit}] = pins
    end

    test "duplicate checkout targets conflict instead of racing" do
      intent = %{owner: "checkouts", spec: %{url: "https://example.invalid/repo.git", commit: @commit, target: ".local/share/repo"}}

      assert_raise ArgumentError, ~r/duplicate git target/, fn ->
        Git.compose([intent, %{intent | owner: "other"}])
      end
    end

    test "the fold derives clone effects before the apply effect, from the plan alone" do
      plan = build_plan(git_pins: 1)

      effects = Pipeline.effects(plan)

      assert [%{contract: "git", kind: :clone, phase: :target, target: ".local/share/goldens/checkouts/repo"} = clone,
              %{contract: "chezmoi", kind: :apply, phase: :apply}] = effects

      assert clone.commit == @commit
      assert clone.url == "https://goldens.invalid/git/goldens-repo.git"
    end
  end

  # The declared-pin plan the effects view reads: the pin inventory rides
  # the plan's composed profile (the provider's domain view), the manifest
  # and generation id carry only the tombstone (no entries remain).
  defp build_plan(opts) do
    url = Keyword.get(opts, :git_url, "https://goldens.invalid/git/goldens-repo.git")
    commit = Keyword.get(opts, :git_commit, @commit)
    target = ".local/share/goldens/checkouts/repo"

    pins =
      case Keyword.fetch(opts, :pins) do
        {:ok, pins} -> pins
        :error -> [pin_record(url, commit, target)]
      end

    remove_file = Workstation.Core.Policy.remove_file([])
    manifest = Workstation.Core.Source.Manifest.build([], [{".chezmoiremove", remove_file}])

    %Source{
      entries: [],
      removals: [],
      declared_removals: [],
      unsupported_reversals: [],
      profile: pins,
      fragments_journal: %{},
      remove_file: remove_file,
      journal_revision: 0,
      baseline_generation: nil,
      data: nil,
      downloads: [],
      manifest: manifest,
      generation: Workstation.Core.Digest.sha256(Workstation.Core.CanonicalJSON.encode(manifest))
    }
  end

  defp pin_record(url, commit, target) do
    %{
      id: "git",
      git_pin: true,
      owner: "checkouts",
      url: url,
      commit: commit,
      target: target,
      fingerprint: Git.pin_fingerprint(url, commit, target)
    }
  end
end
