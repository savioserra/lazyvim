defmodule Workstation.Core.ShellProgram do
  @moduledoc """
  The shared-shell compositor. Byte-for-byte parity anchor:
  `workstation/lua/workstation/provision/shell.lua` — the emitted modify
  program bytes are load-bearing: they are part of generated source state, so
  generation digests, change sets and baseline comparisons only agree when
  this provider reproduces them exactly, including fragment order and the
  sequence tie-break.

  Capabilities contribute stable, individually owned fragments (marker +
  literal single-line body) to shared shell startup files; this provider
  composes one native chezmoi modify program per target in a deterministic
  order. Every owned block — retained, replaced or retiring — is verified
  against the exact recorded marker+body pair: edited, duplicated or
  ambiguous blocks conflict (the generated programs exit 70; POSIX `set -e`
  ignores failures of commands outside AND-OR lists, so conflicts must be
  explicit exits, never silent set-e failures) instead of being overwritten
  or silently kept. Arbitrary user modifiers are never concatenated or
  reversed here.
  """

  @doc """
  Compose the native modify program for one shared target.
  `desired` is an ordered list of fragment records (`"id"`, `"marker"`,
  `"body"`, `"order"`); `recorded` maps fragment id to the previously applied
  record. Explicit fragment order with graph collection order as the stable
  tie-break keeps the emitted block sequence deterministic. Returns
  `{program, ids}`.
  """
  @spec compose(String.t(), [map()], %{optional(String.t()) => map()} | nil) :: {String.t(), [String.t()]}
  def compose(target, desired, recorded) do
    recorded = recorded || %{}

    if desired == [] and map_size(recorded) == 0 do
      raise(ArgumentError, "shell composition requires at least one fragment: #{target}")
    end

    ordered =
      desired
      |> Enum.with_index(1)
      |> Enum.map(fn {fragment, sequence} ->
        %{
          "order" => fragment["order"] || 0,
          "marker" => fragment["marker"],
          "body" => fragment["body"],
          "id" => fragment["id"],
          "sequence" => sequence
        }
      end)
      # The sort key mirrors the anchor's comparator: order first, then the
      # original desired position as tie-break.
      |> Enum.sort_by(fn fragment -> [fragment["order"], fragment["sequence"]] end)

    removals = planned_removals(ordered, recorded)

    {ids, _markers} =
      Enum.map_reduce(ordered, %{}, fn fragment, markers ->
        if Map.has_key?(markers, fragment["marker"]) do
          raise(ArgumentError, "duplicate shell marker owned by two fragments on #{target}: #{fragment["marker"]}")
        end

        {fragment["id"], Map.put(markers, fragment["marker"], fragment["id"])}
      end)

    lines = [
      "#!/usr/bin/env sh",
      "# Managed by the workstation engine; do not edit deployed shared state by hand.",
      "# Owned fragments: " <> Enum.join(ids, ", "),
      "# Emit shell expressions literally for future shells, never evaluate at render time.",
      "# shellcheck disable=SC2016",
      "set -eu",
      "work=\"$(mktemp)\"",
      "trap 'rm -f \"$work\" \"$work.next\"' EXIT HUP INT TERM",
      "cat >\"$work\""
    ]

    lines =
      Enum.reduce(removals, lines, fn fragment, acc ->
        acc ++
          [
            "# retire fragment #{fragment["id"]}: remove its exact recorded block",
            "if grep -Fqx #{shell_quote(fragment["marker"])} \"$work\"; then",
            "  " <> removal_program(fragment["marker"], fragment["body"]),
            "fi"
          ]
      end)

    lines =
      Enum.reduce(ordered, lines, fn fragment, acc ->
        acc ++
          [
            "if grep -Fqx #{shell_quote(fragment["marker"])} \"$work\"; then",
            "  " <> verification_program(fragment["marker"], fragment["body"]),
            "else",
            "  printf '\\n%s\\n%s\\n' #{shell_quote(fragment["marker"])} #{shell_quote(fragment["body"])} >>\"$work\"",
            "fi"
          ]
      end)

    program = Enum.join(lines ++ ["cat \"$work\""], "\n") <> "\n"
    {program, ids}
  end

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end

  # Escape a single-line string as an awk double-quoted literal. Escaping
  # runs in two passes over the original bytes: the backslash pass never
  # re-touches the quote pass's output, so the result matches the anchor's
  # single-pass gsub.
  defp awk_quote(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  # Build the exact-block removal for one retiring or replaced fragment. The
  # generated awk program removes a marker line followed by exactly the
  # recorded body line (plus the blank line the composer emits before a
  # block) and fails on an edited or duplicated block instead of guessing.
  defp removal_program(marker, body) do
    program =
      Enum.join(
        [
          "BEGIN { m = #{awk_quote(marker)}; b = #{awk_quote(body)}; found = 0; bad = 0 }",
          "{ lines[NR] = $0 }",
          "END {",
          "  for (i = 1; i <= NR; i++) {",
          "    if (lines[i] == m) {",
          "      if (i < NR && lines[i + 1] == b) {",
          "        found++; i++",
          "        if (out > 0 && text[out] == \"\") out--",
          "      } else { bad = 1 }",
          "    } else { text[++out] = lines[i] }",
          "  }",
          "  for (i = 1; i <= out; i++) print text[i]",
          "  if (bad || found > 1) exit 70",
          "}"
        ],
        "\n"
      ) <> "\n"

    "awk #{shell_quote(program)} \"$work\" >\"$work.next\" || exit 70" <>
      "\n  " <> "mv \"$work.next\" \"$work\" || exit 70"
  end

  # Build the verification for one retained or newly appended fragment: when
  # the marker is present it must appear exactly once, followed by exactly
  # the expected body. Anything else is an edited, duplicated or ambiguous
  # owned block and conflicts.
  defp verification_program(marker, body) do
    program =
      Enum.join(
        [
          "BEGIN { m = #{awk_quote(marker)}; b = #{awk_quote(body)}; count = 0; bad = 0 }",
          "{ lines[NR] = $0 }",
          "END {",
          "  for (i = 1; i <= NR; i++) {",
          "    if (lines[i] == m) {",
          "      count++",
          "      if (i < NR && lines[i + 1] == b) { i++ } else { bad = 1 }",
          "    }",
          "  }",
          "  if (bad || count > 1) exit 70",
          "}"
        ],
        "\n"
      ) <> "\n"

    "awk #{shell_quote(program)} \"$work\" || exit 70"
  end

  # Compute the exact-block removals a composition needs: retiring fragments
  # and the recorded old blocks of same-id fragments whose body changed.
  # Removals sort by fragment id so the program is independent of map
  # iteration order.
  defp planned_removals(desired, recorded) do
    {removals, kept} =
      Enum.reduce(desired, {[], %{}}, fn fragment, {removals, kept} ->
        case recorded[fragment["id"]] do
          nil ->
            {removals, Map.put(kept, fragment["id"], true)}

          prior ->
            if prior["marker"] != fragment["marker"] or prior["body"] != fragment["body"] do
              # Same-id declaration change: remove the exact old block first,
              # then the normal append path installs the new one.
              {[prior | removals], Map.put(kept, fragment["id"], true)}
            else
              {removals, Map.put(kept, fragment["id"], true)}
            end
        end
      end)

    retirement_removals =
      recorded
      |> Enum.reject(fn {id, _prior} -> kept[id] end)
      |> Enum.map(fn {_id, prior} -> prior end)

    (removals ++ retirement_removals)
    |> Enum.sort_by(& &1["id"])
  end

  @doc """
  Pre-backend validation of one shared target's current content against the
  composed intent. Mirrors the generated programs so an edited, duplicated or
  ambiguous owned block conflicts before the backend mutates anything.
  A replaced fragment still shows its recorded old body right now, so the
  expected body for same-id changes is the recorded one. Returns
  `{:ok, nil}` or `{:error, conflict}`.
  """
  @spec validate_target(String.t(), [map()], %{optional(String.t()) => map()} | nil) ::
          {:ok, nil} | {:error, String.t()}
  def validate_target(target_path, desired, recorded) do
    recorded = recorded || %{}

    lines =
      case File.read(target_path) do
        {:ok, contents} ->
          # Mirror the anchor's line reader: strip one trailing \r\n or \n per
          # line; blank interior lines stay significant.
          lines = contents |> String.split("\n") |> Enum.map(&String.replace_suffix(&1, "\r", ""))

          if String.ends_with?(contents, "\n") do
            List.delete_at(lines, length(lines) - 1)
          else
            lines
          end

        {:error, _reason} ->
          nil
      end

    if is_nil(lines) do
      {:ok, nil}
    else
      removals = planned_removals(desired, recorded)
      removal_set = Map.new(removals, fn fragment -> {fragment["id"], fragment} end)

      find_conflict = fn marker, body, label ->
        {count, bad} =
          lines
          |> Enum.with_index(1)
          |> Enum.reduce({0, false}, fn {line, index}, {count, bad} ->
            if line == marker do
              exact_pair = index < length(lines) and Enum.at(lines, index) == body
              {count + 1, bad or not exact_pair}
            else
              {count, bad}
            end
          end)

        cond do
          count == 0 -> nil
          bad or count > 1 -> "edited, duplicated or ambiguous owned block #{label} (#{marker})"
          true -> false
        end
      end

      removal_verdict =
        Enum.find_value(removals, fn fragment ->
          find_conflict.(fragment["marker"], fragment["body"], "to be removed for " <> fragment["id"])
        end)

      if is_binary(removal_verdict) do
        {:error, removal_verdict}
      else
        desired_verdict =
          Enum.find_value(desired, fn fragment ->
            expected =
              case removal_set[fragment["id"]] do
                nil -> fragment["body"]
                prior -> prior["body"]
              end

            find_conflict.(fragment["marker"], expected, "for " <> fragment["id"])
          end)

        if is_binary(desired_verdict) do
          {:error, desired_verdict}
        else
          {:ok, nil}
        end
      end
    end
  end

  @doc """
  Pure recipe constructor: one owned fragment for one shared shell target.
  """
  @spec recipe(map()) :: map()
  def recipe(options) do
    unless is_map(options), do: raise(ArgumentError, "shell recipe requires an options table")

    Enum.each(Map.keys(options), fn field ->
      unless field in ["target", "fragment"], do: raise(ArgumentError, "shell recipe has unknown option #{inspect(field)}")
    end)

    validate_target_string(options["target"])
    validate_fragment(options["fragment"])

    components = String.split(options["target"], "/", trim: true)
    fragment = options["fragment"]

    %{
      "provider" => "shell",
      "spec" => %{
        "target" => Enum.join(components, "/"),
        "components" => components,
        "fragment" => %{
          "id" => fragment["id"],
          "marker" => fragment["marker"],
          "body" => fragment["body"],
          "order" => fragment["order"]
        }
      }
    }
  end

  @doc """
  Validate a materialized shell spec at collection time: the derived
  components must re-derive from the logical target.
  """
  @spec validate_spec(map()) :: :ok
  def validate_spec(spec) do
    validate_target_string(spec["target"])
    validate_fragment(spec["fragment"])

    components = String.split(spec["target"], "/", trim: true)

    unless length(components) == length(spec["components"]), do: raise(ArgumentError, "shell target components changed")

    Enum.with_index(components, fn component, index ->
      unless Enum.at(spec["components"], index) == component,
        do: raise(ArgumentError, "shell target component does not re-derive")
    end)

    :ok
  end

  defp validate_target_string(target) do
    unless is_binary(target) and target != "", do: raise(ArgumentError, "shell recipe requires a target")

    unless not String.starts_with?(target, "/"),
      do: raise(ArgumentError, "shell target must be relative to the destination home: #{target}")

    unless not String.contains?(target, "\\"),
      do: raise(ArgumentError, "shell target must not contain backslashes: #{target}")

    unless not String.match?(target, ~r/[\x00-\x1f\x7f]/),
      do: raise(ArgumentError, "shell target must not contain control characters or newlines")

    Enum.each(String.split(target, "/", trim: true), fn component ->
      if component in [".", ".."], do: raise(ArgumentError, "shell target must not traverse: #{target}")
    end)
  end

  defp validate_fragment(fragment) do
    unless is_map(fragment), do: raise(ArgumentError, "shell fragment must be a table")

    Enum.each(Map.keys(fragment), fn field ->
      unless field in ["id", "marker", "body", "order"],
        do: raise(ArgumentError, "shell fragment has unknown field #{inspect(field)}")
    end)

    unless is_binary(fragment["id"]) and fragment["id"] != "", do: raise(ArgumentError, "shell fragment requires an id")

    unless is_binary(fragment["marker"]) and fragment["marker"] != "",
      do: raise(ArgumentError, "shell fragment requires a marker")

    unless is_binary(fragment["body"]) and fragment["body"] != "",
      do: raise(ArgumentError, "shell fragment requires a body")

    order = fragment["order"]

    unless is_number(order) and order > 0 and order == trunc(order),
      do: raise(ArgumentError, "shell fragment requires a positive integer order")

    # Ids, markers and bodies are embedded in generated shell comments and
    # programs; control bytes and newlines could not survive literally.
    Enum.each([{"id", fragment["id"]}, {"marker", fragment["marker"]}, {"body", fragment["body"]}], fn {label, value} ->
      if String.match?(value, ~r/[\x00-\x1f\x7f]/) do
        raise(ArgumentError, "shell fragment #{label} must not contain control characters or newlines")
      end
    end)
  end
end
