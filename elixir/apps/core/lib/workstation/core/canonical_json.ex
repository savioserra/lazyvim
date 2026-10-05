defmodule Workstation.Core.CanonicalJSON do
  @moduledoc """
  JSON encoding for the plain-data shapes the plan pipeline produces,
  byte-identical to Neovim's `vim.json.encode(value, { sort_keys = true })`.

  The generation id and every entry fingerprint are content addresses over
  these bytes, so any drift here breaks golden parity silently. The recorded
  quirks (probe-verified against Neovim 0.11 `vim.json.encode`) that a generic
  JSON encoder gets wrong:

  * object keys are sorted bytewise, recursively; array order is preserved;
  * an EMPTY object encodes as `[]`, because a Lua table cannot distinguish
    an empty map from an empty list — the goldens rely on this (`assets: []`,
    `fragments_journal: []`);
  * `nil` map values drop the key entirely (Lua `nil` fields do not exist),
    while the distinct `:null` token (the `vim.NIL` anchor) emits `null` —
    that is how `baseline_generation` stays an explicit null on a fresh
    journal while absent `link`/`exact`/`template` keys disappear;
  * control bytes (< 0x20 and DEL 0x7f) escape as `\\u00xx` lowercase four-digit
    hex, with the named shortcuts `\\b \\t \\n \\f \\r`; slash is never escaped;
    non-ASCII UTF-8 passes through raw;
  * integers encode in decimal without exponent or fraction.
  """

  @type json_value ::
          binary()
          | integer()
          | boolean()
          | nil
          | :null
          | [json_value()]
          | %{optional(String.t()) => json_value()}

  @doc """
  Encode a plain-data value to the exact `vim.json.encode(sort_keys)` bytes.
  Raises `ArgumentError` on values outside the supported shape (floats,
  atoms other than `:null`/booleans, non-binary keys) — those cannot occur in
  a validated plan, so failing closed beats guessing an encoding.
  """
  @spec encode(json_value()) :: binary()
  def encode(value), do: value |> enc() |> IO.iodata_to_binary()

  defp enc(nil) do
    # Map values that are literally nil mirror a missing Lua field: the key
    # itself is dropped by the caller building the map, so reaching nil here
    # means a list element or a top level nil, which Lua could not encode.
    raise ArgumentError, "canonical JSON cannot encode nil; drop the key or use :null"
  end

  defp enc(:null), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(value) when is_binary(value), do: quote_string(value)
  defp enc(value) when is_integer(value), do: Integer.to_string(value)

  defp enc(value) when is_float(value) do
    raise ArgumentError, "canonical JSON cannot encode float #{inspect(value)}; the plan carries integers only"
  end

  defp enc(value) when is_atom(value) do
    raise ArgumentError, "canonical JSON cannot encode atom #{inspect(value)}"
  end

  defp enc(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &enc/1) <> "]"
  end

  defp enc(value) when is_map(value) do
    # A Lua table with no entries is an array to vim.json.encode, so every
    # empty map must encode as [] for byte parity.
    case :maps.to_list(value) do
      [] ->
        "[]"

      pairs ->
        members =
          Enum.sort_by(pairs, fn {key, _} -> key end)
          |> Enum.map(fn
            {key, value} when is_binary(key) -> [quote_string(key), ?:, enc(value)]
            {key, _value} -> raise ArgumentError, "canonical JSON object keys must be strings, got #{inspect(key)}"
          end)

        "{" <> Enum.join(members, ",") <> "}"
    end
  end

  # Mirrors the vim.json escape set exactly: named shortcuts for the five
  # classic control bytes, lowercase \\u00xx for every other byte below 0x20
  # and for DEL (0x7f), backslash and quote escaped, everything else raw.
  # (b5 bugfix: the old ~c charlist accidentally listed the apostrophe itself
  # as escapable — an @named lookup with no entry, so any apostrophe crashed
  # the encoder. vim.json.encode and the recorded goldens leave apostrophes
  # raw, and the b5 core wire's patch texts contain them, so the escapable
  # set is spelled out as exactly the @named keys.)
  @escape [?", ?\\, ?\b, ?\t, ?\n, ?\f, ?\r]
  @named %{
    ?" => ~S(\"),
    ?\\ => ~S(\\),
    ?\b => ~S(\b),
    ?\t => ~S(\t),
    ?\n => ~S(\n),
    ?\f => ~S(\f),
    ?\r => ~S(\r)
  }

  defp quote_string(value) do
    escaped =
      for <<char::utf8 <- value>> do
        cond do
          char in @escape -> Map.fetch!(@named, char)
          char < 0x20 -> :io_lib.format("\\u~4.16.0b", [char])
          char == 0x7F -> ~S(\u007f)
          true -> <<char::utf8>>
        end
      end

    "\"" <> IO.iodata_to_binary(escaped) <> "\""
  end

  @doc """
  Lowercase-hex SHA-256 of binary contents — the byte-for-byte anchor of
  `state.sha256` (`vim.fn.sha256`), used for fingerprints, manifest digests
  and generation ids.
  """
  @spec sha256(binary()) :: String.t()
  def sha256(contents) when is_binary(contents) do
    :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
  end
end
