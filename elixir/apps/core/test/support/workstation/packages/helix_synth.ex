defmodule Workstation.Packages.HelixSynth do
  @moduledoc """
  The R3 self-serve proof's synthetic package — what a helix/zed-style
  author literally writes: a manifest (this Spec implementation, pure
  data) plus payloads (recipe content), and nothing else. It lives under
  `test/support`, so production discovery never admits it (zero catalog
  drift — the same deterministic exclusion the GhostFixture proves); the
  proof drives it through the documented `:specifications` composition
  seam.
  """

  @behaviour Workstation.Core.Catalog.Spec

  alias Workstation.Core.Catalog.Packages
  alias Workstation.Core.Theme.Derivation

  @impl Workstation.Core.Catalog.Spec
  def spec do
    %{
      foundation: "foundation/editor",
      id: "helix-synth",
      requires: ["foundation", "theme"],
      supported_hosts: nil,
      contributes: [
        # Payload: a managed config file whose bytes are RENDERED from theme
        # roles through the consumer-owned derivation adapter (the
        # envelope-rendered canon exercised end to end).
        Packages.chezmoi(
          target: ".config/helix-synth/theme.toml",
          kind: :file,
          content: theme_payload()
        ),
        # Payload: a shared-shell fragment on the startup files.
        Packages.shell(".zshrc", %{
          id: "managed-helix-synth",
          order: 15,
          marker: "# chezmoi: managed helix-synth",
          body: "export HELIX_SYNTH=1"
        })
      ]
    }
  end

  # The consumer-owned adapter: theme roles in, payload bytes out.
  defp theme_payload do
    descriptor =
      Derivation.declare(%{"roles" => ["accent", "bg"], "appearances" => ["dark", "light"]})

    Derivation.derive(descriptor, fn resolved ->
      colors = resolved["colors"]
      "[theme]\naccent = \"#{colors["accent"]}\"\nbg = \"#{colors["bg"]}\"\n"
    end)
    |> Enum.map_join("\n", fn {appearance, artifact} ->
      "# appearance: " <> appearance <> "\n" <> artifact
    end)
    |> Kernel.<>("\n")
  end
end
