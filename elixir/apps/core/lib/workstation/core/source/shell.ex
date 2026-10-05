defmodule Workstation.Core.Source.Shell do
  @moduledoc """
  The shared-shell compositor: one deterministic native chezmoi modify
  program per shared shell startup file.

  Capabilities contribute stable, individually owned fragments (marker +
  literal single-line body) to shared shell startup files; this provider
  composes one native chezmoi modify program per target in a deterministic
  order. Every owned block — retained, replaced or retiring — is verified
  against the exact recorded marker+body pair; edited, duplicated or ambiguous
  blocks conflict instead of being overwritten or silently kept.
  """

  defstruct [:target, :components, :fragment]

  @type t :: %__MODULE__{
          target: String.t(),
          components: [String.t()],
          fragment: %{
            required(:id) => String.t(),
            required(:marker) => String.t(),
            required(:body) => String.t(),
            required(:order) => pos_integer()
          }
        }

  @spec validate_fragment(term()) :: :ok
  def validate_fragment(fragment) do
    unless is_map(fragment), do: raise_arg("shell fragment must be a table")

    for field <- Map.keys(fragment) do
      unless field in [:id, :marker, :body, :order] do
        raise_arg("shell fragment has unknown field #{inspect(field)}")
      end
    end

    nonempty_string?(fragment[:id]) || raise_arg("shell fragment requires an id")
    nonempty_string?(fragment[:marker]) || raise_arg("shell fragment requires a marker")
    nonempty_string?(fragment[:body]) || raise_arg("shell fragment requires a body")

    order = fragment[:order]

    unless is_integer(order) and order > 0 do
      raise_arg("shell fragment requires a positive integer order")
    end

    # Ids, markers and bodies are embedded in generated shell comments and
    # programs; control bytes and newlines could not survive literally.
    reject_control(fragment[:id], "shell fragment id")
    reject_control(fragment[:marker], "shell fragment marker")
    reject_control(fragment[:body], "shell fragment body")
    :ok
  end

  @spec validate_target(term()) :: :ok
  def validate_target(target) do
    nonempty_string?(target) || raise_arg("shell recipe requires a target")
    String.starts_with?(target, "/") && raise_arg("shell target must be relative to the destination home: #{target}")
    String.contains?(target, "\\") && raise_arg("shell target must not contain backslashes: #{target}")

    if String.match?(target, ~r/[\x00-\x1f\x7f]/) do
      raise_arg("shell target must not contain control characters or newlines")
    end

    target
    |> String.split("/", trim: true)
    |> Enum.each(fn component ->
      component in [".", ".."] && raise_arg("shell target must not traverse: #{target}")
    end)

    :ok
  end

  @doc """
  Pure recipe constructor: one owned fragment for one shared shell target.
  """
  @spec recipe(map()) :: t()
  def recipe(options) do
    unless is_map(options), do: raise_arg("shell recipe requires an options table")

    for field <- Map.keys(options) do
      unless field in [:target, :fragment] do
        raise_arg("shell recipe has unknown option #{inspect(field)}")
      end
    end

    :ok = validate_target(options[:target])
    :ok = validate_fragment(options[:fragment])
    components = String.split(options[:target], "/", trim: true)

    fragment = options[:fragment]
    fragment = fragment |> then(&%{id: &1[:id], marker: &1[:marker], body: &1[:body], order: &1[:order]})

    %__MODULE__{
      target: Enum.join(components, "/"),
      components: components,
      fragment: fragment
    }
  end

  @doc """
  Validate a materialized shell spec at collection time: the derived
  components must re-derive from the logical target.
  """
  @spec validate_spec(t()) :: :ok
  def validate_spec(%__MODULE__{} = spec) do
    :ok = validate_target(spec.target)
    :ok = validate_fragment(spec.fragment)
    components = String.split(spec.target, "/", trim: true)
    length(components) == length(spec.components) || raise_arg("shell target components changed")

    components == spec.components || raise_arg("shell target component does not re-derive")
    :ok
  end

  @doc """
  Compose the native modify program for one shared target. `desired` is the
  ordered list of fragment records `{id, marker, body, order}` (explicit
  fragment order with collection order as the stable tie-breaker);
  `recorded` maps fragment id to the previously applied `{id, marker, body}`.
  Returns the program bytes and the ordered owner-fragment ids.

  The parity-critical byte shapes are the `%q`-free awk literals
  (`awk_quote` escapes only backslash and quote) and the single-quoted shell
  words (`shell_quote` embeds `'` as `'\\''`).
  """
  @spec compose(String.t(), [map()], %{optional(String.t()) => map()}) :: {String.t(), [String.t()]}
  def compose(target, desired, recorded) when is_binary(target) and is_list(desired) do
    recorded = recorded || %{}

    unless desired != [] or map_size(recorded) > 0 do
      raise_arg("shell composition requires at least one fragment: #{target}")
    end

    ordered =
      desired
      |> Enum.with_index(1)
      |> Enum.map(fn {fragment, sequence} ->
        %{order: fragment[:order] || 0, marker: fragment[:marker], body: fragment[:body], id: fragment[:id], sequence: sequence}
      end)
      |> Enum.sort_by(&{&1.order, &1.sequence})

    removals = planned_removals(ordered, recorded)

    markers = Enum.map(ordered, & &1.marker)

    if Enum.uniq(markers) != markers do
      raise_arg("duplicate shell marker owned by two fragments on #{target}")
    end

    ids = Enum.map(ordered, & &1.id)

    header = [
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

    removal_lines =
      Enum.flat_map(removals, fn fragment ->
        [
          "# retire fragment #{fragment.id}: remove its exact recorded block",
          ~s(if grep -Fqx #{shell_quote(fragment.marker)} "$work"; then),
          "  " <> removal_program(fragment.marker, fragment.body),
          "fi"
        ]
      end)

    fragment_lines =
      Enum.flat_map(ordered, fn fragment ->
        [
          ~s(if grep -Fqx #{shell_quote(fragment.marker)} "$work"; then),
          "  " <> verification_program(fragment.marker, fragment.body),
          "else",
          "  printf '\\n%s\\n%s\\n' " <> shell_quote(fragment.marker) <> " " <> shell_quote(fragment.body) <> " >>\"$work\"",
          "fi"
        ]
      end)

    program = Enum.join(header ++ removal_lines ++ fragment_lines ++ ["cat \"$work\""], "\n") <> "\n"
    {program, ids}
  end

  defp planned_removals(desired, recorded) do
    kept_ids = MapSet.new(desired, & &1.id)

    replacements =
      for fragment <- desired,
          prior = recorded[fragment.id],
          prior[:marker] != fragment.marker or prior[:body] != fragment.body do
        prior
      end

    orphans =
      recorded
      |> Map.reject(fn {_id, prior} -> MapSet.member?(kept_ids, prior.id) end)
      |> Map.values()

    (replacements ++ orphans)
    |> Enum.sort_by(& &1.id)
  end

  defp shell_quote(value), do: "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"

  # Escape a single-line string as an awk double-quoted literal.
  defp awk_quote(value), do: "\"" <> String.replace(value, ["\\", "\""], &"\\#{&1}") <> "\""

  # Build the exact-block removal for one retiring or replaced fragment. The
  # generated awk program removes a marker line followed by exactly the
  # recorded body line (plus the blank line the composer emits before a block)
  # and fails on an edited or duplicated block instead of guessing. Failures
  # are explicit exits: POSIX set -e ignores failures of commands that are not
  # the last element of an AND-OR list, so a conflict must not rely on it.
  defp removal_program(marker, body) do
    program =
      Enum.join(
        [
          "BEGIN { m = " <> awk_quote(marker) <> "; b = " <> awk_quote(body) <> "; found = 0; bad = 0 }",
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

    "awk " <> shell_quote(program) <> ~s( "$work" >"$work.next" || exit 70\n  mv "$work.next" "$work" || exit 70)
  end

  # Build the verification for one retained or newly appended fragment: when
  # the marker is present it must appear exactly once, followed by exactly the
  # expected body. Anything else is an edited, duplicated or ambiguous owned
  # block and conflicts.
  defp verification_program(marker, body) do
    program =
      Enum.join(
        [
          "BEGIN { m = " <> awk_quote(marker) <> "; b = " <> awk_quote(body) <> "; count = 0; bad = 0 }",
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

    "awk " <> shell_quote(program) <> ~s( "$work" || exit 70)
  end

  defp nonempty_string?(value), do: is_binary(value) and value != ""

  defp reject_control(value, label) do
    if String.match?(value, ~r/[\x00-\x1f\x7f]/) do
      raise_arg("#{label} must not contain control characters or newlines")
    end
  end

  defp raise_arg(message), do: raise(ArgumentError, message)
end
