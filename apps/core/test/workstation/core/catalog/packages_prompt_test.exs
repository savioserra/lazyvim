defmodule Workstation.Core.Catalog.PackagesPromptTest do
  @moduledoc """
  The prompt package's pin and wiring contracts. The terminal shell-UX
  capability (operator ruling 2026-10-19/20): eza is the managed `ls` and
  starship the cross-shell prompt, both download-contract pins mirrored from
  `workstation/versions.json` (the nunchux pin-mirror pattern). eza is
  linux-only by upstream asset availability — zero darwin_arm64 assets across
  every upstream release — so the package is linux-only (the operator ruled
  eza absent-and-fine on darwin) while starship's honest both-platform pins
  stay recorded. eza's identity rides the content probe (its `--version`
  leads with the tagline; the version token is on the second line), starship's
  the exec probe. The rc surface is marker-guarded fragments (`managed-eza`,
  `managed-starship`) into the interactive shells only — `.profile` stays
  untouched — and the omarchy-lean starship config ships as plain data.
  See docs/capabilities.md and docs/tools.md.
  """

  use ExUnit.Case, async: true

  alias Workstation.Core.Catalog.Discover
  alias Workstation.Core.Contracts.Download

  @repo_root Path.expand("../../../../../../", __DIR__)
  @payload_root Path.join(@repo_root, "workstation/packages/terminal/prompt")

  test "the manifest is data in the package tree, not a compiled module" do
    assert File.regular?(Path.join(@payload_root, "manifest.json"))
    assert {:error, _reason} = Code.ensure_loaded(Workstation.Packages.Prompt)
  end

  test "the spec is a linux-only terminal-domain package requiring foundation" do
    spec = prompt_spec()

    assert spec.id == "prompt"
    assert spec.foundation == "foundation/terminal"
    # The theme envelope carries nothing this package consumes: the lean
    # starship config is plain data, so requires stays minimal.
    assert spec.requires == ["foundation"]
    # eza publishes no darwin_arm64 release asset (0 across every upstream
    # release); the operator ruled eza absent-and-fine on darwin, so the
    # package gates itself off there instead of pinning a phantom asset.
    assert spec.supported_hosts == %{"darwin" => false, "linux" => true}
  end

  test "the eza pin mirrors the versions manifest and is honestly linux-only" do
    manifest = versions_manifest()
    pin = download_entry(".local/opt/eza")

    assert %Download{} = pin.spec
    assert pin.spec.version == manifest["eza"]
    assert pin.spec.version == "0.23.5"
    assert pin.spec.archive == "tar.gz"
    # The lone root file IS the tree (the fzf shape).
    assert pin.spec.layout == nil
    assert pin.spec.target == ".local/opt/eza"

    # The content probe: `eza --version` leads with the tagline, so the
    # exec probe cannot pin it — the binary's own bytes do.
    assert pin.spec.probe == %{
             member: "eza",
             sha256: manifest["eza_bin_linux_x86_64_sha256"]
           }

    # linux-only by upstream asset availability; the darwin gap is declared,
    # never papered over with a phantom URL.
    assert Map.keys(pin.spec.assets) == ["linux_x86_64"]

    assert String.replace(manifest["eza_linux_x86_64_url"], "{V}", pin.spec.version) ==
             pin.spec.assets["linux_x86_64"].url

    assert pin.spec.assets["linux_x86_64"].sha256 == manifest["eza_linux_x86_64_sha256"]
  end

  test "the starship pin mirrors the versions manifest for both hosts" do
    manifest = versions_manifest()
    pin = download_entry(".local/opt/starship")

    assert %Download{} = pin.spec
    assert pin.spec.version == manifest["starship"]
    assert pin.spec.version == "1.27.0"
    assert pin.spec.archive == "tar.gz"
    assert pin.spec.target == ".local/opt/starship"

    # The exec probe: the first --version line carries the pinned version.
    assert pin.spec.probe == %{argv: ["starship", "--version"], output: "starship {V}"}

    assert MapSet.new(Map.keys(pin.spec.assets)) ==
             MapSet.new(["linux_x86_64", "darwin_arm64"])

    for platform <- ~w(linux_x86_64 darwin_arm64) do
      assert String.replace(manifest["starship_#{platform}_url"], "{V}", pin.spec.version) ==
               pin.spec.assets[platform].url

      assert pin.spec.assets[platform].sha256 == manifest["starship_#{platform}_sha256"]
    end
  end

  test "the rc fragments are guarded, marker-owned and interactive-only" do
    fragments = shell_fragments()
    targets = Enum.map(fragments, & &1.spec.target)

    # The alias/init surface is the interactive shells only; .profile stays
    # untouched (the foundation PATH fragment already covers it).
    assert Enum.uniq(targets) == [".bashrc", ".zshrc"]
    assert length(fragments) == 4

    for entry <- fragments do
      fragment = entry.spec.fragment
      assert fragment.id in ["managed-eza", "managed-starship"]
      assert fragment.marker in ["# chezmoi: managed eza ls", "# chezmoi: managed starship prompt"]
      # Every body guards on resolution: a host without the pin keeps plain
      # `ls` / no prompt (and the card's darwin note stays true if the
      # package ever widens).
      assert String.starts_with?(fragment.body, "command -v ")
    end

    eza_bodies = fragment_bodies("managed-eza")
    assert Enum.uniq(eza_bodies) == [
             "command -v eza >/dev/null 2>&1 && alias ls='eza -lh --group-directories-first --icons=auto'"
           ]

    assert fragment_bodies("managed-starship") == [
             "command -v starship >/dev/null 2>&1 && eval \"$(starship init bash)\"",
             "command -v starship >/dev/null 2>&1 && eval \"$(starship init zsh)\""
           ]

    # One id per target per fragment: the compositor's uniqueness law.
    for target <- Enum.uniq(targets) do
      ids = fragments |> Enum.filter(&(&1.spec.target == target)) |> Enum.map(& &1.spec.fragment.id)
      assert Enum.uniq(ids) == ids
    end
  end

  test "the starship config is plain omarchy-lean data at .config/starship.toml" do
    entry =
      Enum.find(prompt_spec().contributes, &(&1.spec.target == ".config/starship.toml"))

    assert entry.provider == "chezmoi"
    assert entry.spec.kind == :file
    # No theme slots: the lean look is plain cyan data, not a template.
    assert entry.spec.template != true
    assert entry.spec.asset == "files/.config/starship.toml"

    body = File.read!(Path.join(@payload_root, "files/.config/starship.toml"))
    assert body =~ "success_symbol = \"[❯](bold cyan)\""
    assert body =~ "Managed by the workstation terminal/prompt capability"
  end

  test "the launchers are within-package symlinks into the pinned trees" do
    for tool <- ~w(eza starship) do
      entry = Enum.find(prompt_spec().contributes, &(&1.spec.target == ".local/bin/#{tool}"))

      assert entry.provider == "chezmoi"
      assert entry.spec.kind == :symlink
      assert entry.spec.to == "../opt/#{tool}/#{tool}"
    end
  end

  test "every download/asset pin carries 64-hex digests and https urls" do
    for entry <- prompt_spec().contributes, entry.provider == "download" do
      :ok = Download.validate(entry.spec)
    end
  end

  test "the host verify script asserts the pins and the rc wiring" do
    script = Path.join(@payload_root, "verify/prompt.sh")

    assert File.regular?(script)
    assert File.stat!(script).mode >= 0o100755, "verify script must stay executable"

    assert {_, 0} = System.cmd("sh", ["-n", script])
  end

  defp download_entry(target) do
    Enum.find(prompt_spec().contributes, &(&1.provider == "download" && &1.spec.target == target)) ||
      raise("no download contribution targets #{target}")
  end

  defp shell_fragments do
    Enum.filter(prompt_spec().contributes, &(&1.provider == "shell"))
  end

  defp fragment_bodies(id) do
    shell_fragments()
    |> Enum.filter(&(&1.spec.fragment.id == id))
    |> Enum.map(& &1.spec.fragment.body)
  end

  # The package's discovered spec: the data manifest read through the
  # production seam (the kernel reader's denormalized output).
  defp prompt_spec do
    Discover.specs() |> Enum.find(&(&1.id == "prompt")) ||
      raise("prompt is not discovered — the data manifest must serve the package")
  end

  defp versions_manifest do
    @repo_root
    |> Path.join("workstation/versions.json")
    |> File.read!()
    |> Jason.decode!()
  end
end
