defmodule Workstation.CLI.ControlVerbsTest do
  @moduledoc """
  The release dispatcher's verb contract: the OTP lifecycle surface is
  reachable only through the control verbs; every other verb boots the
  release VM into the Router.
  """

  use ExUnit.Case, async: true

  test "the dispatcher forwards exactly the OTP lifecycle verbs" do
    verbs = Workstation.CLI.ControlVerbs.list()

    for verb <- ~w(start start_iex daemon_iex eval rpc remote restart stop pid version) do
      assert verb in verbs, "OTP lifecycle verb #{verb} must stay a control verb"
    end

    assert verbs == ~w(start start_iex daemon_iex eval rpc remote restart stop pid version)
  end
end
