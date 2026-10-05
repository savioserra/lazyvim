defmodule Workstation.Core.JSON do
  @moduledoc """
  Strict RFC 8259 JSON text decoder, the read-side counterpart of
  `Workstation.Core.CanonicalJSON` emission. Decoding is fail-closed: any
  malformed byte sequence yields `{:error, :malformed}` instead of a partial
  value and never raises, so a half-decoded record can never be mistaken for
  engine-owned state.
  """

  @spec decode(binary()) :: {:ok, term()} | {:error, :malformed}
  def decode(binary) when is_binary(binary) do
    case json_value(skip_ws(binary)) do
      {value, rest} ->
        case skip_ws(rest) do
          <<>> -> {:ok, value}
          _other -> {:error, :malformed}
        end

      :malformed ->
        {:error, :malformed}
    end
  rescue
    _error -> {:error, :malformed}
  catch
    # The parser funnels every malformed byte sequence through throw :malformed;
    # thrown values are not Exceptions, so they need their own funnel arm to
    # uphold the decode contract ({:error, :malformed}, never a crash).
    :throw, :malformed -> {:error, :malformed}
    :exit, _reason -> {:error, :malformed}
  end

  # json_value/1 returns {value, rest} or throws :malformed (caught above via
  # throw/raise funnels); keeping the parser pure over binaries avoids
  # intermediate string churn on journal-sized payloads.
  defp json_value(<<"{", rest::binary>>), do: json_object(skip_ws(rest), %{})
  defp json_value(<<"[", rest::binary>>), do: json_array(skip_ws(rest), [])
  defp json_value(<<"\"", rest::binary>>), do: json_string(rest, <<>>)
  defp json_value(<<"true", rest::binary>>), do: {true, rest}
  defp json_value(<<"false", rest::binary>>), do: {false, rest}
  defp json_value(<<"null", rest::binary>>), do: {nil, rest}
  defp json_value(binary), do: json_number(binary)

  # Empty-object entry: closing on entry is legal only when no pair has been
  # consumed yet, so `{"a":1,}` (trailing comma) cannot reach this clause —
  # the comma branch re-enters with a non-empty acc and must find another key.
  defp json_object(<<"}", rest::binary>>, acc) when map_size(acc) == 0, do: {acc, rest}

  # After each pair the stream is either a comma (next pair follows) or the
  # closing brace; a comma is consumed exactly where it is seen, never
  # re-expected on entry, or the second pair would be misread as malformed.
  defp json_object(binary, acc) do
    {key, rest} = json_key(binary)
    rest = expect_colon(rest)
    {value, rest} = json_value(rest)

    case skip_ws(rest) do
      <<",", rest::binary>> -> json_object(skip_ws(rest), Map.put(acc, key, value))
      <<"}", rest::binary>> -> {Map.put(acc, key, value), rest}
      _other -> throw(:malformed)
    end
  end

  defp json_key(<<"\"", rest::binary>>), do: json_string(rest, <<>>)
  defp json_key(_other), do: throw(:malformed)

  defp expect_comma(<<",", rest::binary>>), do: skip_ws(rest)
  defp expect_comma(_other), do: throw(:malformed)

  defp expect_colon(binary) do
    case skip_ws(binary) do
      <<":", rest::binary>> -> skip_ws(rest)
      _other -> throw(:malformed)
    end
  end

  defp json_array(<<"]", rest::binary>>, acc), do: {Enum.reverse(acc), rest}

  defp json_array(binary, acc) do
    {value, rest} =
      if acc == [] do
        json_value(binary)
      else
        binary |> expect_comma() |> json_value()
      end

    json_array(skip_ws(rest), [value | acc])
  end

  defp skip_ws(<<" ", rest::binary>>), do: skip_ws(rest)
  defp skip_ws(<<"\t", rest::binary>>), do: skip_ws(rest)
  defp skip_ws(<<"\n", rest::binary>>), do: skip_ws(rest)
  defp skip_ws(<<"\r", rest::binary>>), do: skip_ws(rest)
  defp skip_ws(rest), do: rest

  defp json_string(<<"\"", rest::binary>>, acc), do: {acc, rest}
  defp json_string(<<"\\", rest::binary>>, acc), do: json_escape(rest, acc)
  defp json_string(<<byte, _rest::binary>>, _acc) when byte < 0x20, do: throw(:malformed)

  defp json_string(<<codepoint::utf8, rest::binary>>, acc) do
    json_string(rest, <<acc::binary, codepoint::utf8>>)
  end

  defp json_string(_other, _acc), do: throw(:malformed)

  defp json_escape(<<"\"", rest::binary>>, acc), do: json_string(rest, <<acc::binary, ?">>)
  defp json_escape(<<"\\", rest::binary>>, acc), do: json_string(rest, <<acc::binary, ?\\>>)
  defp json_escape(<<"/", rest::binary>>, acc), do: json_string(rest, <<acc::binary, ?/>>)
  defp json_escape(<<"b", rest::binary>>, acc), do: json_string(rest, <<acc::binary, ?\b>>)
  defp json_escape(<<"f", rest::binary>>, acc), do: json_string(rest, <<acc::binary, ?\f>>)
  defp json_escape(<<"n", rest::binary>>, acc), do: json_string(rest, <<acc::binary, ?\n>>)
  defp json_escape(<<"r", rest::binary>>, acc), do: json_string(rest, <<acc::binary, ?\r>>)
  defp json_escape(<<"t", rest::binary>>, acc), do: json_string(rest, <<acc::binary, ?\t>>)

  defp json_escape(<<"u", hex::binary-size(4), rest::binary>>, acc) do
    json_unicode(String.to_integer(hex, 16), rest, acc)
  end

  defp json_escape(_other, _acc), do: throw(:malformed)

  # A lone surrogate is malformed JSON; a high surrogate must pair with a low
  # one to form one codepoint, never two broken halves.
  defp json_unicode(cp, <<"\\u", low::binary-size(4), rest::binary>>, acc) when cp in 0xD800..0xDBFF do
    low_cp = String.to_integer(low, 16)

    if low_cp in 0xDC00..0xDFFF do
      combined = 0x10000 + (cp - 0xD800) * 0x400 + (low_cp - 0xDC00)
      json_string(rest, <<acc::binary, combined::utf8>>)
    else
      throw(:malformed)
    end
  end

  defp json_unicode(cp, _rest, _acc) when cp in 0xD800..0xDFFF, do: throw(:malformed)
  defp json_unicode(cp, rest, acc), do: json_string(rest, <<acc::binary, cp::utf8>>)

  @number_regex ~r/\A-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/

  defp json_number(binary) do
    {token, rest} = take_number(binary)
    value = if token =~ ~r/[.eE]/, do: String.to_float(token), else: parse_int(token)
    {value, rest}
  end

  defp take_number(binary) do
    case Regex.run(@number_regex, binary, return: :index) do
      [{0, length}] ->
        {binary_part(binary, 0, length), binary_part(binary, length, byte_size(binary) - length)}

      _other ->
        throw(:malformed)
    end
  end

  defp parse_int(token) do
    {int, ""} = Integer.parse(token)
    int
  end
end
