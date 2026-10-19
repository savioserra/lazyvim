defmodule Workstation.Core.Packages.FoundationTest do
  @moduledoc """
  The foundation package's shell fragments against the REAL data manifest.

  The managed `.bash_profile` include closes the bash login-shell PATH gap:
  bash reads `~/.bash_profile` INSTEAD of `~/.profile` when the former
  exists (bash(1) login-shell rule), so a pre-existing hand-written
  `.bash_profile` shadowed every managed `.profile` fragment and the engine
  PATH (`~/.local/bin`) never reached bash login shells — the operator's
  darwin default-login-shell case. The parity case runs the REAL composed
  programs the way the backend apply does (current target on stdin, output
  written back) and proves a bash login shell with a pre-existing
  `.bash_profile` resolves the engine shims from PATH while the hand file
  survives untouched — the guarded-fragment law, never a whole-path
  replacement.
  """

  use ExUnit.Case, async: true

  alias Workstation.Core.Catalog
  alias Workstation.Core.Catalog.Discover
  alias Workstation.Core.Source

  @marker "# chezmoi: load managed profile"
  @include_body "[ -r \"$HOME/.profile\" ] && . \"$HOME/.profile\""

  test "the foundation manifest manages .bash_profile with the profile include" do
    shell = shell_fragments()

    bash_profile = Enum.find(shell, &(&1.spec.target == ".bash_profile"))
    assert bash_profile, "the foundation manifest manages no .bash_profile fragment"
    assert bash_profile.spec.fragment.id == "managed-profile"
    assert bash_profile.spec.fragment.marker == @marker
    assert bash_profile.spec.fragment.body == @include_body

    # The include's source of truth: the managed .profile still carries the
    # engine PATH fragment, so the include is the whole fix, not a copy.
    profile = Enum.find(shell, &(&1.spec.target == ".profile" and &1.spec.fragment.id == "user-local-bin"))
    assert profile, "the foundation manifest lost the .profile PATH fragment"
  end

  test "login-shell parity: a pre-existing hand .bash_profile still sees the engine PATH" do
    assert System.find_executable("bash")
    assert System.find_executable("awk")
    assert System.find_executable("mktemp")

    home = Path.join(System.tmp_dir!(), "workstation-bash-login-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, ".local/bin"))
    on_exit(fn -> File.rm_rf!(home) end)

    # The engine's shims, as bootstrap provisions them before the first
    # public apply (the installer's own contract).
    for name <- ["workstation", "hermes"] do
      shim = Path.join([home, ".local/bin", name])
      File.write!(shim, "#!/bin/sh\nexit 0\n")
      File.chmod!(shim, 0o755)
    end

    # The operator's pre-existing hand-written login file (the shadow).
    hand = "export HAND_WRITTEN=before-engine\n"
    File.write!(Path.join(home, ".bash_profile"), hand)

    # Simulate apply: each composed modify program reads the current target
    # on stdin and its output becomes the new content.
    plan = Source.plan(%{graph: compose_foundation()})

    for target <- [".profile", ".bash_profile"] do
      entry = Enum.find(plan.entries, &(&1.target == target))
      assert entry, "no plan entry for #{target}"

      path = Path.join(home, target)
      File.write!(Path.join(home, "input"), if(File.exists?(path), do: File.read!(path), else: ""))
      script = Path.join(home, target <> ".modify.sh")
      File.write!(script, entry.bytes)

      {out, 0} =
        System.cmd("/bin/sh", [
          "-c",
          "/bin/sh '#{script}' < '#{Path.join(home, "input")}'"
        ])

      File.write!(path, out)
      File.rm!(script)
      File.rm!(Path.join(home, "input"))
    end

    env = %{"HOME" => home, "PATH" => System.get_env("PATH") || "/usr/bin:/bin"}
    {out, 0} = System.cmd("bash", ["--login", "-c", "command -v workstation && command -v hermes"], env: env)

    assert out == "#{home}/.local/bin/workstation\n#{home}/.local/bin/hermes\n"
    # The guarded fragment appended; the operator's own lines survive.
    assert File.read!(Path.join(home, ".bash_profile")) =~ "HAND_WRITTEN=before-engine"
  end

  test "the include is idempotent on hosts whose hand file already sources .profile" do
    assert System.find_executable("bash")

    home = Path.join(System.tmp_dir!(), "workstation-bash-include-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    hand = "[ -r \"$HOME/.profile\" ] && . \"$HOME/.profile\"\n"
    File.write!(Path.join(home, ".bash_profile"), hand)
    # A managed .profile the hand include would also source: the PATH guard
    # keeps the double hop harmless.
    File.write!(Path.join(home, ".profile"), "export PROFILE_SOURCED=1\n")

    plan = Source.plan(%{graph: compose_foundation()})
    entry = Enum.find(plan.entries, &(&1.target == ".bash_profile"))
    script = Path.join(home, "bash_profile.modify.sh")
    File.write!(script, entry.bytes)
    File.write!(Path.join(home, "input"), File.read!(Path.join(home, ".bash_profile")))

    {out, 0} =
      System.cmd("/bin/sh", ["-c", "/bin/sh '#{script}' < '#{Path.join(home, "input")}'"])

    File.write!(Path.join(home, ".bash_profile"), out)
    File.rm!(script)
    File.rm!(Path.join(home, "input"))

    env = %{"HOME" => home, "PATH" => System.get_env("PATH") || "/usr/bin:/bin"}
    {out, 0} = System.cmd("bash", ["--login", "-c", "echo $PROFILE_SOURCED"], env: env)
    assert out == "1\n"
    # The owned block was appended exactly once; the hand include stays.
    managed_blocks = out_count(File.read!(Path.join(home, ".bash_profile")), @marker)
    assert managed_blocks == 1
  end

  defp shell_fragments do
    foundation = Enum.find(Discover.specs(), &(&1.id == "foundation"))
    assert foundation, "the foundation package is not discovered"

    Enum.filter(foundation.contributes, &(&1.provider == "shell"))
  end

  defp compose_foundation do
    native = Catalog.native().packages

    Catalog.compose(
      host: "linux",
      specifications: Enum.filter(native, &(&1.id == "foundation"))
    )
  end

  defp out_count(contents, needle) do
    contents |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
