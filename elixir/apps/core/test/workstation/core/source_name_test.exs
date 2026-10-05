defmodule Workstation.Core.SourceNameTest do
  @moduledoc """
  Byte-parity cases for the chezmoi source-name encoding against
  `workstation/lua/workstation/provision/chezmoi.lua`: every name here is
  load-bearing for generation digests, so the expected strings are literals,
  not recomputed by the code under test.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.EngineState
  alias Workstation.Core.SourceName

  defp recipe(options), do: SourceName.recipe(options)

  describe "recipe option validation" do
    test "accepts a minimal private executable modify recipe" do
      recipe = recipe(%{"target" => ".profile", "kind" => "modify", "content" => "export PATH=1", "executable" => true})

      assert recipe["provider"] == "chezmoi"
      assert recipe["spec"]["target"] == ".profile"
      assert recipe["spec"]["components"] == [".profile"]
      assert recipe["spec"]["kind"] == "modify"
      assert recipe["spec"]["executable"] == true
      assert recipe["spec"]["content"] == "export PATH=1"
    end

    test "rejects unknown options and structured fragments" do
      assert_raise ArgumentError, ~r/chezmoi recipe has unknown option "nope"/, fn ->
        recipe(%{"target" => "x", "kind" => "file", "content" => "y", "nope" => true})
      end

      assert_raise ArgumentError, ~r/rejects structured fragments/, fn ->
        recipe(%{"target" => "x", "kind" => "modify", "fragments" => []})
      end
    end

    test "rejects malformed targets" do
      # An empty target dies in validate_options (anchor: "requires a target")
      # before normalize_target's stricter "requires a target string" wording.
      assert_raise ArgumentError, ~r/chezmoi recipe requires a target/, fn ->
        recipe(%{"target" => "", "kind" => "file", "content" => "y"})
      end

      assert_raise ArgumentError, ~r/must be relative to the destination home/, fn ->
        recipe(%{"target" => "/abs", "kind" => "file", "content" => "y"})
      end

      assert_raise ArgumentError, ~r/must not contain backslashes/, fn ->
        recipe(%{"target" => "a\\b", "kind" => "file", "content" => "y"})
      end

      assert_raise ArgumentError, ~r/must not traverse/, fn ->
        recipe(%{"target" => "a/../b", "kind" => "file", "content" => "y"})
      end

      assert_raise ArgumentError, ~r/control characters/, fn ->
        recipe(%{"target" => "a\nb", "kind" => "file", "content" => "y"})
      end
    end

    test "rejects body conflicts and flag misuse" do
      opts = %{"target" => "x", "kind" => "file"}

      assert_raise ArgumentError, ~r/accepts exactly one inline body or package-relative asset/, fn ->
        recipe(Map.merge(opts, %{"content" => "a", "asset" => "b"}))
      end

      assert_raise ArgumentError, ~r/requires content or a package-relative asset/, fn ->
        recipe(opts)
      end

      assert_raise ArgumentError, ~r/executable cannot be disabled/, fn ->
        recipe(%{"target" => "x", "kind" => "file", "content" => "y", "executable" => false})
      end

      assert_raise ArgumentError, ~r/exact is only representable for directories/, fn ->
        recipe(%{"target" => "x", "kind" => "file", "content" => "y", "exact" => true})
      end

      assert_raise ArgumentError, ~r/symlinks take no executable or private attributes/, fn ->
        recipe(%{"target" => "x", "kind" => "symlink", "to" => "y", "private" => true})
      end

      assert_raise ArgumentError, ~r/removals take no attributes/, fn ->
        recipe(%{"target" => "x", "kind" => "remove", "template" => true})
      end

      assert_raise ArgumentError, ~r/removal recipe accepts no content/, fn ->
        recipe(%{"target" => "x", "kind" => "remove", "content" => "y"})
      end

      assert_raise ArgumentError, ~r/directories cannot be templates/, fn ->
        recipe(%{"target" => "x", "kind" => "directory", "template" => true})
      end

      assert_raise ArgumentError, ~r/option to is only valid for symlinks/, fn ->
        recipe(%{"target" => "x", "kind" => "file", "content" => "y", "to" => "z"})
      end

      assert_raise ArgumentError, ~r/symlink recipe requires exactly a link destination/, fn ->
        recipe(%{"target" => "x", "kind" => "symlink", "content" => "y"})
      end

      assert_raise ArgumentError, ~r/modify recipe requires one whole body or package-relative asset/, fn ->
        recipe(%{"target" => "x", "kind" => "modify"})
      end
    end

    test "relative symlink destinations must stay inside the destination home" do
      # Walk depth starts at #components - 1: two levels of target allow one
      # level of upward travel, three allow two.
      recipe(%{"target" => "a/b", "kind" => "symlink", "to" => "../c"})
      recipe(%{"target" => "a/b/c", "kind" => "symlink", "to" => "../../d"})

      assert_raise ArgumentError, ~r/destination escapes the destination home/, fn ->
        recipe(%{"target" => "a/b", "kind" => "symlink", "to" => "../../c"})
      end

      assert_raise ArgumentError, ~r/destination escapes the destination home/, fn ->
        recipe(%{"target" => "a/b", "kind" => "symlink", "to" => "../../../c"})
      end
    end
  end

  describe "source_component" do
    test "encodes leading dots as the dot_ prefix" do
      assert SourceName.source_component(".profile", true, false) == "dot_profile"
      assert SourceName.source_component("plain", true, false) == "plain"
    end

    test "rejects reserved attribute prefixes fail-closed" do
      for component <- ["dot_profile", "modify_tool", "private_x", "executable_sh", "run_once"] do
        assert_raise ArgumentError, ~r/not representable as native source state/, fn ->
          SourceName.source_component(component, true, false)
        end
      end
    end

    test "a literal .tmpl component is only representable as an intended template" do
      assert SourceName.source_component("config.tmpl", true, true) == "config.tmpl"

      assert_raise ArgumentError, ~r/only representable as the intended template itself/, fn ->
        SourceName.source_component("config.tmpl", true, false)
      end

      assert_raise ArgumentError, ~r/only representable as the intended template itself/, fn ->
        SourceName.source_component("config.tmpl", false, true)
      end
    end
  end

  describe "source_name" do
    test "modify + executable + private encodes attribute prefixes in anchored order" do
      spec = recipe(%{"target" => ".profile", "kind" => "modify", "content" => "x", "executable" => true, "private" => true})
      assert SourceName.source_name(spec["spec"]) == "modify_private_executable_dot_profile"
    end

    test "plain file with private flag under a plain directory" do
      spec = recipe(%{"target" => ".config/app/settings.conf", "kind" => "file", "content" => "x", "private" => true})

      assert SourceName.source_name(spec["spec"]) == "dot_config/app/private_settings.conf"
    end

    test "ancestors propagate owning directory attributes onto path components" do
      spec = recipe(%{"target" => ".config/nvim/init.lua", "kind" => "file", "content" => "x"})

      ancestors = %{".config" => %{"private" => true}, ".config/nvim" => %{"exact" => true, "private" => true}}

      assert SourceName.source_name(spec["spec"], ancestors) ==
               "private_dot_config/exact_private_nvim/init.lua"
    end

    test "symlink and exact private directory encodings" do
      spec = recipe(%{"target" => ".zshrc", "kind" => "symlink", "to" => "dots/zshrc"})
      assert SourceName.source_name(spec["spec"]) == "symlink_dot_zshrc"

      spec = recipe(%{"target" => ".config", "kind" => "directory", "exact" => true, "private" => true})
      assert SourceName.source_name(spec["spec"]) == "exact_private_dot_config"
    end

    test "template bodies carry the .tmpl suffix" do
      spec = recipe(%{"target" => "zshrc", "kind" => "file", "content" => "x", "template" => true})
      assert SourceName.source_name(spec["spec"]) == "zshrc.tmpl"

      spec = recipe(%{"target" => ".tmux.conf", "kind" => "file", "content" => "x", "template" => true})
      assert SourceName.source_name(spec["spec"]) == "dot_tmux.conf.tmpl"
    end

    test "a .tmpl final component stays fail-closed when the template flag is dropped" do
      # The per-component check inside source_component fires before
      # source_name's own defensive flag assert, exactly as in the anchor.
      assert_raise ArgumentError, ~r/only representable as the intended template itself/, fn ->
        spec = recipe(%{"target" => "config.tmpl", "kind" => "file", "content" => "x"})
        # recipe/1 accepts the component only when template is set, so this
        # path is reached with a hand-built spec whose template flag was
        # dropped after construction.
        SourceName.source_name(Map.put(spec["spec"], "template", false))
      end

      spec = recipe(%{"target" => "config.tmpl", "kind" => "file", "content" => "x", "template" => true})
      assert SourceName.source_name(spec["spec"]) == "config.tmpl.tmpl"
    end

    test "removal recipes have no source name" do
      assert_raise ArgumentError, ~r/removal recipes have no chezmoi source name/, fn ->
        SourceName.source_name(%{"kind" => "remove", "components" => ["x"], "target" => "x"})
      end
    end
  end

  describe "entry_mode" do
    test "proven chezmoi mode table" do
      file = fn opts -> recipe(Map.merge(%{"target" => "f", "kind" => "file", "content" => "x"}, opts))["spec"] end
      dir = fn opts -> recipe(Map.merge(%{"target" => "d", "kind" => "directory"}, opts))["spec"] end

      assert SourceName.entry_mode(file.(%{})) == 0o644
      assert SourceName.entry_mode(file.(%{"private" => true})) == 0o600
      assert SourceName.entry_mode(file.(%{"executable" => true})) == 0o755
      assert SourceName.entry_mode(file.(%{"private" => true, "executable" => true})) == 0o700
      assert SourceName.entry_mode(dir.(%{})) == 0o755
      assert SourceName.entry_mode(dir.(%{"private" => true})) == 0o700

      symlink = recipe(%{"target" => "s", "kind" => "symlink", "to" => "t"})["spec"]
      assert SourceName.entry_mode(symlink) == nil
    end
  end

  describe "expected_state" do
    test "computes full type/mode/content identity where the recipe allows it" do
      spec = recipe(%{"target" => "f", "kind" => "file", "content" => "hello"})["spec"]

      assert SourceName.expected_state(spec, "hello") == %{
               "type" => "file",
               "sha256" => EngineState.sha256("hello"),
               "mode" => 0o644
             }

      symlink = recipe(%{"target" => "s", "kind" => "symlink", "to" => "t"})["spec"]
      assert SourceName.expected_state(symlink, nil) == %{"type" => "link", "link" => "t"}

      dir = recipe(%{"target" => "d", "kind" => "directory", "private" => true})["spec"]
      assert SourceName.expected_state(dir, nil) == %{"type" => "directory", "mode" => 0o700}

      template = recipe(%{"target" => "t", "kind" => "file", "content" => "x", "template" => true})["spec"]
      assert SourceName.expected_state(template, "anything") == nil

      modify = recipe(%{"target" => "m", "kind" => "modify", "content" => "x"})["spec"]
      assert SourceName.expected_state(modify, "x") == nil
    end
  end

  describe "confined asset reads" do
    setup do
      root = Path.join(System.tmp_dir!(), "workstation-b4-asset-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "assets/nested"))
      File.write!(Path.join(root, "assets/nested/body.txt"), "asset-bytes")

      on_exit(fn -> File.rm_rf!(root) end)

      %{root: root}
    end

    test "reads package-relative assets inside the owner root", %{root: root} do
      assert SourceName.read_asset(root, "assets/nested/body.txt") == "asset-bytes"
      assert SourceName.source_bytes(recipe(%{"target" => "x", "kind" => "file", "asset" => "assets/nested/body.txt"})["spec"], root) ==
               "asset-bytes"
      assert SourceName.source_bytes(recipe(%{"target" => "x", "kind" => "file", "content" => "inline"})["spec"], root) ==
               "inline"
      assert SourceName.source_bytes(recipe(%{"target" => "d", "kind" => "directory"})["spec"], root) == nil
    end

    test "rejects missing, traversing, absolute, empty and non-file assets", %{root: root} do
      assert_raise ArgumentError, ~r/chezmoi asset is missing/, fn ->
        SourceName.read_asset(root, "assets/missing")
      end

      assert_raise ArgumentError, ~r/must not traverse/, fn ->
        SourceName.read_asset(root, "../escape")
      end

      assert_raise ArgumentError, ~r/must be package-relative/, fn ->
        SourceName.read_asset(root, "/etc/passwd")
      end

      File.write!(Path.join(root, "assets/empty"), "")
      assert_raise ArgumentError, ~r/chezmoi asset is empty/, fn ->
        SourceName.read_asset(root, "assets/empty")
      end

      File.mkdir!(Path.join(root, "assets/adir"))
      assert_raise ArgumentError, ~r/must be a regular file/, fn ->
        SourceName.read_asset(root, "assets/adir")
      end
    end

    test "never traverses a symlink out of the owner root", %{root: root} do
      outside = Path.join(System.tmp_dir!(), "workstation-b4-escape-#{System.unique_integer([:positive])}")
      File.write!(outside, "outside")
      File.ln_s!(outside, Path.join(root, "assets/door"))

      on_exit(fn -> File.rm_rf!(outside) end)

      assert_raise ArgumentError, ~r/component is not a regular entry/, fn ->
        SourceName.read_asset(root, "assets/door")
      end
    end
  end

  describe "validate_spec" do
    test "accepts a materialized spec whose components re-derive" do
      recipe = recipe(%{"target" => ".config/app/rc", "kind" => "file", "content" => "x"})
      assert SourceName.validate_spec(recipe["spec"]) == :ok
    end

    test "rejects mutated envelopes that could redirect the generated path" do
      recipe = recipe(%{"target" => ".config/app/rc", "kind" => "file", "content" => "x"})

      assert_raise ArgumentError, ~r/components changed/, fn ->
        SourceName.validate_spec(Map.put(recipe["spec"], "components", ["other"]))
      end

      assert_raise ArgumentError, ~r/is not normalized/, fn ->
        SourceName.validate_spec(Map.put(recipe["spec"], "target", "a//b"))
      end

      assert_raise ArgumentError, ~r/chezmoi spec has unknown field "weird"/, fn ->
        SourceName.validate_spec(Map.put(recipe["spec"], "weird", true))
      end
    end
  end
end
