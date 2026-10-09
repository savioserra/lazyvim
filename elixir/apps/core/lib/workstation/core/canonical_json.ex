defmodule Workstation.Core.CanonicalJSON do
  @moduledoc """
  Layer: kernel. The kernel law: this module names no package, no backend and no
  consumer -- it speaks only contracts and shapes (docs/architecture.md,
  "Module hierarchy & moduledoc conventions").
  JSON encoding for the plain-data shapes the plan pipeline produces — the
  single byte format of every recorded artifact: plan envelopes, golden
  trees, journal records.

  The generation id and every entry fingerprint are content addresses over
  these bytes, and the committed goldens pin them, so any drift here breaks
  golden replay. The recorded format rules that a generic JSON encoder gets
  wrong:

  * object keys are sorted bytewise, recursively; array order is preserved;
  * an EMPTY object encodes as `[]` — the recorded envelope format has no
    distinct empty object (an empty map and an empty list are the same
    bytes), and the goldens rely on this (`assets: []`,
    `fragments_journal: []`);
  * callers building maps drop `nil` values entirely — an absent optional
    field leaves no key — while the distinct `:null` token emits a literal
    `null`: that is how `baseline_generation` stays an explicit null on a
    fresh journal while absent `link`/`exact`/`template` keys disappear;
    a raw `nil` that does reach the encoder also emits `null` (never a
    dropped key), so nil-able envelope fields such as `applied_generation`
    (fresh home, no journal) and a file row's `mode` encode deterministically
    instead of crashing;
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
  Encode a plain-data value to the exact recorded envelope bytes (the module
  doc's format rules).
  Raises `ArgumentError` on values outside the supported shape (floats,
  atoms other than `:null`/booleans, non-binary keys) — those cannot occur in
  a validated plan, so failing closed beats guessing an encoding. `nil` is
  inside the shape and encodes as the JSON literal `null`.
  """
  @spec encode(json_value()) :: binary()
  def encode(value), do: value |> enc(:envelope) |> IO.iodata_to_binary()

  @doc """
  Encode engine-record JSON (the journal's applied/failed/pending records):
  identical to `encode/1` except an empty object encodes as `{}` — the journal
  readers require object shapes for `targets`, `source_index` and `fragments`,
  and an empty-catalog apply must record a parseable journal, so the
  envelope's empty-object-as-`[]` rule must never leak into recorded state
  (the 2026-10-05
  real-host incident: an empty plan wrote `[]` and every later apply refused
  to parse its own journal).
  """
  @spec encode_record(json_value()) :: binary()
  def encode_record(value), do: value |> enc(:record) |> IO.iodata_to_binary()

  # A raw nil encodes as the JSON literal null, never a dropped key. Callers
  # drop nil map values when building plan shapes, but nil-able
  # envelope fields (applied_generation with no journal, a file row's mode)
  # pass straight through, and dropping keys there would destabilize the
  # output shape. No input that previously encoded successfully contained a
  # nil, so this cannot change any pre-existing byte output.
  defp enc(nil, mode), do: enc(:null, mode)

  defp enc(:null, _mode), do: "null"
  defp enc(true, _mode), do: "true"
  defp enc(false, _mode), do: "false"
  defp enc(value, _mode) when is_binary(value), do: quote_string(value)
  defp enc(value, _mode) when is_integer(value), do: Integer.to_string(value)

  defp enc(value, _mode) when is_float(value) do
    raise ArgumentError, "canonical JSON cannot encode float #{inspect(value)}; the plan carries integers only"
  end

  defp enc(value, _mode) when is_atom(value) do
    raise ArgumentError, "canonical JSON cannot encode atom #{inspect(value)}"
  end

  defp enc(value, mode) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &enc(&1, mode)) <> "]"
  end

  defp enc(value, mode) when is_map(value) do
    # The recorded envelope format has no distinct empty object, so envelope
    # bytes (:envelope) encode every empty map as [] — byte-identical to the
    # recorded goldens. Engine records (:record) demand the object shape —
    # see encode_record/1.
    case :maps.to_list(value) do
      [] ->
        if mode == :envelope, do: "[]", else: "{}"

      pairs ->
        members =
          Enum.sort_by(pairs, fn {key, _} -> key end)
          |> Enum.map(fn
            {key, value} when is_binary(key) -> [quote_string(key), ?:, enc(value, mode)]
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
  Lowercase-hex SHA-256 of binary contents — the content address used for
  fingerprints, manifest digests and generation ids.
  """
  @spec sha256(binary()) :: String.t()
  def sha256(contents) when is_binary(contents) do
    :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
  end
end
