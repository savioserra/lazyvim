defmodule Workstation.CLI.TUI.Shell.CapabilitiesBrowser do
  @moduledoc """
  The TUI capabilities browser: the grouped envelope
  (`Workstation.CLI.Capabilities.group/1` — the same fold the
  `workstation capabilities` verb renders) as a three-level outline with
  drill-down. The top level is the rollup rows only (domain → package →
  file leaves stay collapsed until drilled), so the browser can never
  degrade into a raw file dump; unattributed entries surface under their
  own honest domain row instead of vanishing.

  Pure data + view: the shell owns the keyboard and forwards messages —
  ↑↓ move, enter/→ expand, ←/backspace collapse (the shell routes the
  arrows and backspace here only while the capabilities tab is active);
  expansion state is keyed by outline path so a data refresh (`r`) keeps
  the drilled-open subtree open.
  """

  alias TermUI.{Layout, Style}
  alias TermUI.Widget.Helpers
  alias Workstation.CLI.TUI.Shell.Box

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

  # backspace is the drill-axis pop key (one level out), same collapse
  # as ←; `q` stays the shell-wide quit (the footer's documented key).
  def update({:key, :backspace}, t), do: collapse_at(t)

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
  Render the browser as the btop split mosaic: a domains box (the tab's
  rollup rows) and a drill box (the active domain's expanded subtree)
  side by side, with an inspector box underneath showing the selected
  row's detail; the drill grammar rides the inspector's border as
  buttons, position counters live in the pane borders, the cursor
  renders as the selected bg+fg pair (never color-alone) and file rows
  that would change read warn.
  """
  @spec view(t(), TermUI.Widget.dimensions(), %{
          required(:title) => term(),
          required(:shortcut) => Style.t(),
          required(:chrome) => Style.t(),
          required(:warn) => Style.t(),
          required(:selected) => Style.t(),
          required(:plain) => Style.t(),
          optional(atom()) => term()
        }) :: TermUI.Frame.t()
  def view(%__MODULE__{rows: []}, {width, height}, styles) do
    Box.frame(
      [
        [{" no catalog entries", styles.plain}],
        [],
        [{" run `workstation bootstrap` to provision this home", styles.plain}]
      ],
      {width, height},
      border_style: styles.chrome,
      title: styles.title
    )
  end

  def view(%__MODULE__{} = browser, {width, height}, styles) do
    [top_rect, inspect_rect] = Layout.column(Layout.new({width, height}), [Layout.percentage(75), Layout.fill()])
    [left_rect, right_rect] = Layout.row(top_rect, [Layout.percentage(40), Layout.fill()])

    Helpers.frame([], {width, height})
    |> Helpers.compose(left_rect, &domains_box(browser, styles, &1))
    |> Helpers.compose(right_rect, &drill_box(browser, styles, &1))
    |> Helpers.compose(inspect_rect, &inspector_box(browser, styles, &1))
  end

  ## split panes

  # The domains pane: every rollup row, cursor highlight following the
  # flat cursor when it sits on a domain; the border counter is the
  # highlighted domain's position.
  defp domains_box(browser, styles, {width, height}) do
    domains = Enum.filter(browser.rows, &(&1.kind == :domain))
    visible = max(height - 2, 0)
    domain_index = Enum.find_index(domains, &(&1.path == active_path(browser))) || 0
    offset = window_offset(domain_index, length(domains), visible)

    rows =
      domains
      |> Enum.drop(offset)
      |> Enum.take(visible)
      |> Enum.with_index(offset)
      |> Enum.map(fn {row, index} ->
        if index == browser.selected do
          cursor_row(row, styles.selected)
        else
          row_spans(row, styles)
        end
      end)

    Box.frame(rows, {width, height},
      border_style: styles.chrome,
      title: styles.title,
      counter: [{"#{domain_index + 1}/#{length(domains)}", styles.chrome}]
    )
  end

  # The drill pane: the active domain's subtree (its package/file rows),
  # titled by the domain name; collapsed domains show the drill hint.
  defp drill_box(browser, styles, {width, height}) do
    {active, subtree} = active_subtree(browser)
    visible = max(height - 2, 0)
    cursor_index = subtree_cursor_index(browser)
    offset = if cursor_index, do: window_offset(cursor_index, length(subtree), visible), else: 0

    rows =
      if subtree == [] do
        [[{" collapsed — enter to drill", styles.inactive}]]
      else
        subtree
        |> Enum.drop(offset)
        |> Enum.take(visible)
        |> Enum.with_index(offset)
        |> Enum.map(fn {row, index} ->
          if index == cursor_index do
            cursor_row(row, styles.selected)
          else
            row_spans(row, styles)
          end
        end)
      end

    counter =
      if subtree == [] do
        []
      else
        [{"#{(cursor_index || 0) + 1}/#{length(subtree)}", styles.chrome}]
      end

    title =
      case active do
        %{path: path} -> [{" #{path} ", styles.accent}]
        nil -> [{" drill ", styles.accent}]
      end

    Box.frame(rows, {width, height},
      border_style: styles.chrome,
      title: title,
      counter: counter
    )
  end

  # The inspector: the selected row's kind and full text, with the drill
  # grammar on the bottom border as buttons.
  defp inspector_box(browser, styles, {width, height}) do
    selected_row = Enum.at(browser.rows, browser.selected)

    rows =
      case selected_row do
        nil ->
          [[{" nothing selected", styles.inactive}]]

        row ->
          [
            [{" " <> kind_label(row.kind), styles.accent}],
            [{" " <> row_text(row), row_style(row, styles)}]
          ]
      end

    Box.frame(rows, {width, height},
      border_style: styles.chrome,
      title: [{" inspect ", styles.accent}],
      buttons: [
        [{"enter", styles.shortcut}, {" expand/collapse", styles.chrome}],
        [{"backspace", styles.shortcut}, {" collapse", styles.chrome}],
        [{"r", styles.shortcut}, {" refresh", styles.chrome}]
      ]
    )
  end

  defp kind_label(:domain), do: "domain"
  defp kind_label(:package), do: "package"
  defp kind_label(:file), do: "file"

  # The active domain: the last domain row at or before the flat cursor.
  defp active_path(browser) do
    case active_subtree(browser) do
      {%{path: path}, _subtree} -> path
      {nil, _subtree} -> nil
    end
  end

  # {active domain row, its subtree rows} — the flat rows after the
  # active domain up to the next domain row.
  defp active_subtree(%__MODULE__{rows: rows, selected: selected}) do
    domain_index =
      rows
      |> Enum.take(selected + 1)
      |> Enum.reverse()
      |> Enum.find_index(&(&1.kind == :domain))

    case domain_index do
      nil ->
        {nil, []}

      index ->
        # `index` is the DISTANCE back from the flat cursor to the active
        # domain (a reversed-slice position), never a row index: the
        # domain's global row is `selected - index`. Splitting at the
        # slice-local value would present the wrong subtree (rows after
        # the cursor) under the wrong pane title.
        global = selected - index

        {_before, rest} = Enum.split(rows, global + 1)
        active = Enum.at(rows, global)
        {subtree, _rest} = Enum.split_while(rest, &(&1.kind != :domain))
        {active, subtree}
    end
  end

  # Subtree-relative cursor (nil when the flat cursor is on a domain row
  # or outside the active subtree).
  defp subtree_cursor_index(%__MODULE__{rows: rows, selected: selected}) do
    case Enum.at(rows, selected) do
      %{kind: :domain} -> nil
      _row ->
        domain_index =
          rows
          |> Enum.take(selected + 1)
          |> Enum.reverse()
          |> Enum.find_index(&(&1.kind == :domain))

        case domain_index do
          nil -> nil
          # Subtree-relative cursor: `index - 1` (the domain itself is
          # distance `index` back, the cursor's subtree slot follows it).
          index -> index - 1
        end
    end
  end

  # The pane window is the page containing the highlighted row (stateless
  # and deterministic: the row never scrolls out of its own page).
  defp window_offset(index, total, visible) do
    cond do
      visible <= 0 or total <= 0 -> 0
      total <= visible -> 0
      true -> min(div(max(index, 0), visible) * visible, total - visible)
    end
  end

  # Would-change file rows read warn; everything else stays plain (the
  # saturated color is reserved for the data that matters).
  defp row_style(%{kind: :file, planned: planned}, styles) when is_integer(planned) and planned > 0,
    do: styles.warn

  defp row_style(_row, _styles), do: Style.new()

  defp row_spans(row, styles), do: [{row_text(row), row_style(row, styles)}]

  defp cursor_row(row, selected), do: [{row_text(row), selected}]

  defp row_text(row), do: String.duplicate("  ", row.depth) <> String.trim_leading(row.text)
end
