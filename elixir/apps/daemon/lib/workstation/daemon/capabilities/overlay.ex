defmodule Workstation.Daemon.Capabilities.Overlay do
  @moduledoc """
  Capability shell for the domain-ownership primitive.

  Serves no wire ops and owns no domain names of its own (domains belong to
  the capabilities that publish on them). Its role is supervisory: the
  `Workstation.Daemon.Overlay` claim/release server is contributed as a
  capability child, so under the application's `:rest_for_one` ordering it
  starts after the capability registry (and the event bus its pub fanout
  needs) and never outlives them.
  """

  use Workstation.Daemon.Capability

  alias Workstation.Daemon.Overlay

  @impl true
  def children, do: [Overlay]
end
