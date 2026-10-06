defmodule Workstation.CLI.TUI.Shell.CapabilitiesBrowser do
  @moduledoc """
  The TUI capabilities browser: the grouped envelope
  (`Workstation.CLI.Capabilities.group/1` — the same fold the
  `workstation capabilities` verb renders) as a three-level outline with
  drill-down. The top level is the rollup rows only (domain → package →
  file leaves stay collapsed until drilled), so the browser can never
  degrade into a raw file dump; unattributed entries surface under their
  own honest domain row instead of vanishing.

  Pure data + view: the shell owns the keyboard (↑↓ move, enter/→ expand,
  ← collapse) and forwards messages; expansion state is keyed by outline
  path so a data refresh (`r`) keeps the drilled-open subtree open.
  """

  alias TermUI.Style
  alias TermUI.Widget.Helpers

  defstruct [:envelope, :rows, :expanded, :selected, :offset]

  @type row :: %{
          required(:kind) => :domain | :package | :file,
          required(:path) => String.t(),
          required(:text) => String.t(),
          required(:depth) => non_neg_integer(),
          required(:expandable) => boolean(),
          required(:planned) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          envelope: map() | nil,
          rows: [row()],
          expanded: MapSet.t(String.t()),
          selected: non_neg_integer(),
          offset: non_neg_integer()
        }

  @doc "Build the browser over a grouped envelope (nil renders the empty state)."
  @spec init(map() | nil) :: t()
  def init(envelope) do
    %__MODULE__{
      envelope: envelope,
      rows: rows(envelope, MapSet.new()),
      expanded: MapSet.new(),
      selected: 0,
      offset: 0
    }
  end

  @doc """
  Swap in a refreshed envelope, preserving expansion, cursor and scroll.
  """
  @spec set_envelope(t(), map() | nil) :: t()
  def set_envelope(%__MODULE__{} = browser, envelope) do
    %{browser | envelope: envelope, rows: rows(envelope, browser.expanded)}
    |> clamp_selection()
  end

  @doc "Scroll keys + expand/collapse; everything else is ignored."
  @spec update(term(), t()) :: t()
  def update({:key, :down}, t), do: move(t, 1)
  def update({:key, :up}, t), do: move(t, -1)
  def update({:key, :page_down}, t), do: move(t, 10)
  def update({:key, :page_up}, t), do: move(t, -10)
  def update({:key, :home}, t), do: select(t, 0)
  def update({:key, :end}, t), do: select(t, max(length(t.rows) - 1, 0))

  def update({:key, :enter} = msg, t), do: toggle_or_step(msg, t)
  def update({:key, :right}, t), do: expand_at(t)
  def update({:key, :left}, t), do: collapse_at(t)
  def update(_message, t), do: t

  defp toggle_or_step(_msg, t) do
    case Enum.at(t.rows, t.selected) do
      %{expandable: true, path: path} -> flip(t, path)
      _row -> t
    end
  end

  defp expand_at(%__MODULE__{rows: rows, selected: selected, expanded: expanded} = t) do
    case Enum.at(rows, selected) do
      %{expandable: true, path: path} ->
        %{t | expanded: MapSet.put(expanded, path)}
        |> rebuild()

      _row ->
        t
    end
  end

  defp collapse_at(%__MODULE__{rows: rows, selected: selected, expanded: expanded} = t) do
    case Enum.at(rows, selected) do
      %{expandable: true, path: path} ->
        %{t | expanded: MapSet.delete(expanded, path)}
        |> rebuild()

      # A leaf collapses nothing; it is not an error.
      _row ->
        t
    end
  end

  defp flip(t, path) do
    if MapSet.member?(t.expanded, path) do
      %{t | expanded: MapSet.delete(t.expanded, path)}
    else
      %{t | expanded: MapSet.put(t.expanded, path)}
    end
    |> rebuild()
  end

  defp rebuild(t), do: %{t | rows: rows(t.envelope, t.expanded)} |> clamp_selection()

  defp move(t, delta), do: select(t, t.selected + delta)

  defp select(t, index) do
    index = clamp(index, 0, max(length(t.rows) - 1, 0))
    %{t | selected: index}
  end

  defp clamp_selection(t), do: %{t | selected: clamp(t.selected, 0, max(length(t.rows) - 1, 0))}

  defp clamp(value, min, max), do: value |> max(min) |> min(max)

  ## outline construction

  # Top level: rollup rows ONLY (the owner's no-raw-file-dump rule); the
  # leaves appear under an explicitly expanded package. Domains start
  # collapsed — the rollup IS the view until drilled.
  defp rows(nil, _expanded), do: []

  defp rows(envelope, expanded) do
    domain_rows =
      envelope
      |> Map.get("domains", [])
      |> Enum.flat_map(&domain_rows(&1, expanded))

    unattributed_rows = unattributed_rows(envelope, expanded)

    domain_rows ++ unattributed_rows
  end

  defp domain_rows(domain, expanded) do
    name = domain["name"]
    path = name

    row = %{
      kind: :domain,
      path: path,
      depth: 0,
      expandable: true,
      planned: domain["planned"] || 0,
      text:
        "#{marker(expanded, path)} #{name} — #{length(domain["packages"] || [])} packages · " <>
          "#{domain["files"]} files · #{planned_note(domain["planned"])}"
    }

    package_rows =
      if MapSet.member?(expanded, path) do
        Enum.flat_map(domain["packages"] || [], &package_rows(&1, expanded, path))
      else
        []
      end

    [row] ++ package_rows
  end

  defp package_rows(package, expanded, domain_path) do
    name = package["name"]
    path = "#{domain_path}/#{name}"

    row = %{
      kind: :package,
      path: path,
      depth: 1,
      expandable: true,
      planned: package["planned"] || 0,
      text:
        "#{marker(expanded, path)} #{name} — #{package["files"]} files · " <>
          "#{planned_note(package["planned"])}"
    }

    file_rows =
      if MapSet.member?(expanded, path) do
        Enum.map(package["entries"] || [], &file_row(&1, path))
      else
        []
      end

    [row] ++ file_rows
  end

  defp file_row(entry, package_path) do
    planned = if entry["planned"], do: 1, else: 0
    also = also_note(entry["also"])

    %{
      kind: :file,
      path: "#{package_path}##{entry["target"]}",
      depth: 2,
      expandable: false,
      planned: planned,
      text: "· #{entry["target"]}  [#{entry["operation"]}]#{planned_mark(entry["planned"])}#{also}"
    }
  end

  defp unattributed_rows(envelope, expanded) do
    entries = envelope["unattributed"] || []

    if entries == [] do
      []
    else
      path = "unattributed"

      row = %{
        kind: :domain,
        path: path,
        depth: 0,
        expandable: true,
        planned: envelope["unattributed_planned"] || 0,
        text:
          "#{marker(expanded, path)} unattributed — #{envelope["unattributed_files"]} files · " <>
            "#{planned_note(envelope["unattributed_planned"])}"
      }

      file_rows =
        if MapSet.member?(expanded, path) do
          Enum.map(entries, fn entry ->
            %{
              kind: :file,
              path: "#{path}##{entry["target"]}",
              depth: 1,
              expandable: false,
              planned: if(entry["planned"], do: 1, else: 0),
              text:
                "· #{entry["target"]}  [#{entry["operation"]}]#{planned_mark(entry["planned"])}"
            }
          end)
        else
          []
        end

      [row] ++ file_rows
    end
  end

  defp marker(expanded, path) do
    if MapSet.member?(expanded, path), do: "▾", else: "▸"
  end

  defp planned_note(0), do: "0 would change"
  defp planned_note(count) when is_integer(count), do: "#{count} would change"
  defp planned_note(nil), do: "0 would change"

  defp planned_mark(false), do: ""
  defp planned_mark(nil), do: ""
  defp planned_mark(true), do: "  *"

  defp also_note(also) when is_list(also) and also != [], do: "  (also #{Enum.join(also, ", ")})"
  defp also_note(_other), do: ""

  @doc """
  Render the outline. The cursor is the reverse-video row; planned counts
  carry the accent tint; everything else is plain text.
  """
  @spec view(t(), TermUI.Widget.dimensions(), Style.t()) :: TermUI.Frame.t()
  def view(%__MODULE__{rows: []}, {width, height}, _accent) do
    Helpers.frame(
      [
        "no catalog entries",
        "run `workstation bootstrap` to provision this home"
      ],
      {width, height}
    )
  end

  def view(%__MODULE__{} = browser, {width, height}, accent) do
    offset = window_offset(browser, height)

    rows =
      browser.rows
      |> Enum.drop(offset)
      |> Enum.take(height)
      |> Enum.with_index()
      |> Enum.map(fn {row, index} ->
        if offset + index == browser.selected do
          cursor_row(row, accent)
        else
          row_text(row)
        end
      end)

    Helpers.frame(rows, {width, height})
  end

  # The window follows the cursor: the selected row stays visible when the
  # cursor moves past either edge of the viewport.
  defp window_offset(%__MODULE__{rows: rows, selected: selected, offset: offset}, height) do
    cond do
      selected < offset -> selected
      selected >= offset + height and height > 0 -> selected - height + 1
      true -> offset
    end
    |> clamp(0, max(length(rows) - height, 0))
  end

  defp cursor_row(row, accent) do
    case accent do
      {r, g, b} ->
        [{row_text(row), Style.new(fg: {:rgb, r, g, b}, attrs: [:bold])}]

      nil ->
        [{row_text(row), Style.new(attrs: [:reverse])}]
    end
  end

  defp row_text(row), do: String.duplicate("  ", row.depth) <> String.trim_leading(row.text)
end
