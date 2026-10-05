defmodule Workstation.Core.Catalog.Packages.PiNtfyNotifier do
  @moduledoc """
  The `pi-ntfy-notifier` workstation package's native contribution:
  the pinned notifier extension payload plus its environment
  fragment.

  The notifier still executes in future shells: stopping source management of
  its environment fragment is not removal — the fragment order (40) places it
  after the runtime loaders it may shadow. Extension behavior verification
  (manifest shape, node --test) stays with the factory's Lua `verify`
  handler.
  """

  alias Workstation.Core.Catalog.Packages

  @extension_dir ".pi/agent/extensions/ntfy-notifier"

  @payload_files [
    "README.md",
    "extensions/ntfy-notifier.ts",
    "package.json",
    "src/ntfy.js",
    "test/ntfy.test.mjs"
  ]

  @spec spec() :: map()
  def spec do
    payload =
      Enum.map(@payload_files, fn name ->
        Packages.chezmoi(
          target: "#{@extension_dir}/#{name}",
          kind: :file,
          asset: "files/#{@extension_dir}/#{name}"
        )
      end)

    %{
      id: "pi-ntfy-notifier",
      requires: ["agent"],
      supported_hosts: nil,
      contributes:
        [Packages.chezmoi(target: ".pi/agent", kind: :directory, private: true)] ++
          payload ++
          [
            Packages.shell(".profile", %{
              id: "managed-ntfy-notifier-env",
              order: 40,
              marker: "# chezmoi: managed ntfy notifier env",
              body: "[ -r /etc/ntfy/notifier.env ] && { set -a; . /etc/ntfy/notifier.env; set +a; }"
            })
          ]
    }
  end
end
