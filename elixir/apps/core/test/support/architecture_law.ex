defmodule Workstation.Core.ArchitectureLaw do
  @moduledoc """
  Pure scanner primitives for the layer-law suites.

  Every scanner is a function over source TEXT (never over repo paths), so
  the suites can prove detection power directly: the self-test in
  `Workstation.Core.LayerLawTest` runs each scanner against planted
  violating fixtures and against sanctioned forms, in addition to the
  whole-tree scans in `Workstation.Core.ArchitectureDepsTest`. The tree
  scans and the self-test share these exact functions, so a scanner that
  passes its fixture self-test is the same code that guards the tree.
  """

  @consumer_atoms ~w(tmux2k herdr nunchux pi nvim tmux editor agent elixir_lang typescript)

  @doc "Consumer package ids that must never appear in engine/platform modules."
  def consumer_atoms, do: @consumer_atoms

  @doc "Backend target-name encoding scanners (label + regex pairs)."
  def encoding_regexes do
    [
      {"dot_ mapping", ~r/dot_/},
      {"_tmpl suffix", ~r/_tmpl/},
      {"reserved attribute prefix literal", ~r/["'](symlink_|private_|executable_|modify_|exact_|empty_|encrypted_|create_|once_|run_)/},
      {"reserved remove prefix literal", ~r/["']remove_(?!file)/}
    ]
  end

  @doc """
  Consumer-package names appearing in `source`. Word-bounded,
  case-insensitive: prose and identifiers are equally load-bearing here,
  because a name in a comment is exactly how a coupling sneaks back in.
  """
  def consumer_violations(source, atoms \\ @consumer_atoms) do
    for atom <- atoms,
        regex = word_regex(atom),
        match = Regex.run(regex, source),
        do: "#{atom} (matched #{inspect(match)})"
  end

  @doc "Backend encoding tokens appearing in `code` (label list)."
  def encoding_violations(code) do
    for {label, regex} <- encoding_regexes(),
        Regex.match?(regex, code),
        do: label
  end

  @doc """
  Backend mentions in code after the sanctioned forms are removed:
  fully-qualified `Workstation.Core.Source.Chezmoi` references,
  `Chezmoi.<fn>` module-API calls, and `@chezmoi`-style compile-time
  attributes bound to them. Any remaining "chezmoi" in code is a violation.
  Comment lines and @doc/@moduledoc string bodies are stripped first, so
  documentation prose about the backend contract does not mask code-level
  violations (and does not false-positive either).
  """
  def backend_literal_violations(source) do
    code =
      source
      |> code_lines()
      |> String.replace(~r/Workstation\.Core\.Source\.Chezmoi/, "")
      |> String.replace(~r/(?<!\w)Chezmoi\.\w+/, "")
      |> String.replace(~r/@\w*chezmoi\b/i, "")

    if code =~ ~r/chezmoi/i, do: ["raw backend mention outside the module API"], else: []
  end

  @doc """
  Static references from generic engine code to a CONCRETE package module
  (`Catalog.Packages.<Segment>` or the package namespace
  `Workstation.Packages.<Segment>`, with a capitalized segment). The registry
  composition point and the discovery namespace constant reference the
  package LAYER generically and do not match; a concrete segment is a
  named package and inverts the dependency direction.
  """
  def concrete_package_violations(code) do
    code
    |> code_lines()
    |> then(fn code -> Regex.scan(~r/(?:Catalog\.Packages|Workstation\.Packages)\.[A-Z]\w+/, code) end)
    |> Enum.map(&"concrete package reference #{inspect(hd(&1))}")
  end

  @doc """
  Kernel-side static imports of the package layer: alias/import/require of
  the catalog DSL family (`Workstation.Core.Catalog.Packages`) or the
  package namespace (`Workstation.Packages`). Kernel consumes packages only
  through contracts and dynamic discovery, never by static alias.
  """
  def kernel_package_import_violations(code) do
    code
    |> code_lines()
    |> then(fn code ->
      Regex.scan(
        ~r/(?:alias|import|require)\s+(?:(?:Workstation\.Core\.)?Catalog\.Packages[\.\s{]|Workstation\.Packages[\.\s{])/,
        code
      )
    end)
    |> Enum.map(&"static package-layer import #{inspect(hd(&1))}")
  end

  @doc """
  Strips comment lines and @doc/@moduledoc string bodies: the law is about
  code, and doc prose is the architecture's own documentation surface.
  """
  def code_lines(source) do
    source
    |> String.split("\n")
    |> Enum.reject(&(String.trim_leading(&1) =~ ~r/^#/))
    |> drop_docstrings()
    |> Enum.join("\n")
  end

  defp word_regex(atom) do
    Regex.compile!("(?i)\\b#{Regex.escape(atom)}\\b")
  end

  defp drop_docstrings(lines, acc \\ {false, []})
  defp drop_docstrings([], {_in_doc, acc}), do: Enum.reverse(acc)

  defp drop_docstrings([line | rest], {in_doc, acc}) do
    trimmed = String.trim_leading(line)

    cond do
      not in_doc and trimmed =~ ~r/^@(doc|moduledoc)\b/ and trimmed =~ ~r/"""/ ->
        # Block docstring opener on the attribute line.
        drop_docstrings(rest, {true, acc})

      not in_doc and trimmed =~ ~r/^@(doc|moduledoc)\b/ ->
        # One-liner attribute doc: drop the line, keep scanning code.
        drop_docstrings(rest, {false, acc})

      in_doc and trimmed =~ ~r/^"""$/ ->
        drop_docstrings(rest, {false, acc})

      in_doc ->
        drop_docstrings(rest, {true, acc})

      true ->
        drop_docstrings(rest, {false, [line | acc]})
    end
  end
end
