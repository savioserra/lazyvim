defmodule Workstation.Core.Contracts.Recorded do
  @moduledoc """
  Recorded-envelope field readers shared by the contract dialects that
  denormalize string-keyed golden specs (the `from_recorded/2`
  implementors): non-empty strings and positive integers, every failure
  naming the package id.

  Layer: kernel. The kernel law: a recorded envelope field is data read
  fail-closed — non-empty string or positive integer, sentence-bearing
  failure naming the package. (implementor policy: the `from_recorded/2`
  dialect owners read their own recorded shapes through these readers;
  nothing else consumes the envelope field rules.)
  """

  @doc "Read one non-empty string field, naming the package in the failure."
  @spec string!(map(), String.t(), String.t()) :: String.t()
  def string!(spec, field, package_id) do
    value = Map.get(spec, field)
    is_binary(value) and value != "" ||
      raise(ArgumentError, "#{package_id} requires a non-empty string #{field}")

    value
  end

  @doc "Read one positive integer field, naming the package in the failure."
  @spec positive_integer!(map(), String.t(), String.t()) :: pos_integer()
  def positive_integer!(spec, field, package_id) do
    value = Map.get(spec, field)

    unless is_integer(value) and value > 0,
      do: raise(ArgumentError, "#{package_id} #{field} must be a positive integer")

    value
  end
end
