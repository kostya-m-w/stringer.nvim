# Stringer

Capture ordered codepaths and navigate them in Neovim. A codepath can span
multiple repositories and contain multiple locations in the same file.

Version **0.4** requires **Neovim 0.10+**. Pure Lua, with no dependencies.

## Installation

Install with lazy.nvim:

```lua
{
  'kostya-m-w/stringer.nvim',
  opts = {},
}
```

For example, this lazy.nvim configuration loads Stringer at startup and
adds normal-mode shortcuts for capturing and navigating marks. Save it as
`lua/plugins/stringer.lua` when using lazy.nvim's `{ import = 'plugins' }` setup:

```lua
return {
  'kostya-m-w/stringer.nvim',
  lazy = false,
  opts = {},
  keys = {
    { '<leader>+', '<cmd>Stringer add<CR>', desc = 'Stringer: add location' },
    { '<leader>s]', '<cmd>Stringer next<CR>', desc = 'Stringer: next location' },
    { '<leader>s[', '<cmd>Stringer prev<CR>', desc = 'Stringer: previous location' },
  },
}
```

`lazy = false` keeps `:Stringer` available immediately, even with key-based loading
triggers configured. Set `vim.g.mapleader` before initializing lazy.nvim; with
`vim.g.mapleader = ' '`, the shortcuts are Space then `+`, Space then `s]`, and
Space then `s[`.

To try it from this checkout:

```sh
nvim --cmd 'set runtimepath+=.'
```

Setup is optional. Defaults:

```lua
require('stringer').setup({
  storage_dir = vim.fn.stdpath('data') .. '/stringer/paths',
  pane_width = 48,
  gutter = true,
  gutter_sign = 'o',
  gutter_note_sign = 'N',
  gutter_priority = 10,
  inline_notes = true,
  symbol_labels = true,
})
```

## Quick start

1. Open a saved code file and run `:Stringer new request-flow`.
2. Put the cursor on an interesting line and run `:Stringer add`.
3. Visit other locations, including other codebases, and add more marks.
4. Use `:Stringer next` / `:Stringer prev` to follow the path cyclically.
5. Run `:Stringer show` for a dedicated mark view. Press `<CR>` to jump, `dd` to
   remove a mark, or `K` / `J` to move it up/down. **Changes save immediately.**
6. Press `u` to undo a mark change, `r` to rename the path, or `q` to close the pane.
7. After restarting Neovim, use `:Stringer open request-flow` to reopen the path.

## Commands

| Command | Action |
| --- | --- |
| `:Stringer new [name]` | Create and activate a path; prompt when name is omitted. |
| `:Stringer open [name]` | Activate a path, or select one with `vim.ui.select`. |
| `:Stringer rename [name]` | Rename the active path; prompt when name is omitted. |
| `:Stringer add` | Append the current file and line. |
| `:Stringer show` | Open/focus the mark pane. |
| `:Stringer next` / `prev` | Jump to the next/previous mark, wrapping at either end. |
| `:Stringer remove` | Remove the selected mark. |
| `:Stringer move-up` / `move-down` | Move the selected mark one position. |
| `:Stringer undo` | Undo the last successful mark change, including notes and skipping. |
| `:Stringer reload` | Reload the active path from storage. |
| `:Stringer skip` | Toggle skipping the selected mark during navigation. |
| `:Stringer hide-skipped` | Hide/reveal skipped marks in the pane. |
| `:Stringer note` | Edit the selected mark's multiline note. |
| `:Stringer import [name]` | Import the whole buffer's stacktrace into a new codepath. |
| `:Stringer import-report` | Show the most recent import's results and excluded frames. |
| `:Stringer cancel-import` | Cancel pending source lookup or an import prompt. |

In the pane, the selected mark is the row under its cursor. From code, actions
use the active mark. Moving marks does not wrap at the ends; navigation does.

Names accept letters, numbers, hyphens, and underscores. Existing names are never
overwritten by creation or renaming. Only one path is active. Opening a path does
not jump automatically. If `open` finds no saved paths, it prompts for a new name;
cancelling the prompt creates nothing.

No global mappings are installed. For example:

```lua
vim.keymap.set('n', '<leader>sa', '<cmd>Stringer add<CR>')
vim.keymap.set('n', '<leader>ss', '<cmd>Stringer show<CR>')
vim.keymap.set('n', ']s', '<cmd>Stringer next<CR>')
vim.keymap.set('n', '[s', '<cmd>Stringer prev<CR>')
```

## Active mark and navigation

Moving the cursor in a marked code file selects its **nearest enabled marked line**.
Distance is measured in lines; there is no Tree-sitter dependency or maximum
distance. If two entries are equally close, Stringer keeps the active entry when
it is tied; otherwise it picks the earlier codepath entry. Repeated marks at the
same location remain independently navigable.

The active mark is highlighted with `StringerActive` (linked to `Visual`) and a
`>` sign. Moving the pane cursor selects an entry for actions without changing
the active mark. In an unmarked file, the previous active mark remains active.
With no active mark, next starts at the first enabled entry and previous at the last.

Navigation uses the current code window. From the pane, it uses the last focused
code window in the current tab, falling back to another eligible code window.
It never replaces the pane with code. Open a code window if the pane is the only
window in the tab. Neovim's `'hidden'` and modified-buffer safeguards are honored.

## Dedicated mark view

The pane is a noneditable view, separate from the persisted file format:

| Pane key | Action |
| --- | --- |
| `<CR>` | Jump to the mark under the cursor. |
| `dd` | Remove the selected mark. |
| `K` / `J` | Move the mark up/down and follow it with the pane cursor. |
| `u` | Undo the last mark change and save the restored state. |
| `r` | Prompt to rename the codepath. |
| `R` | Reload the codepath from disk. |
| `s` | Toggle skipped state and save immediately. |
| `H` | Hide/reveal skipped marks without changing storage. |
| `n` | Open the selected mark's multiline note editor. |
| `q` | Close the pane; keep the codepath active. |

Each mark now has two rows: a contextual title, then a readable location ending
in its filename and line number. Paths use the shortest trailing suffix that
distinguishes files in the active path. Long locations are shortened from the
left, preserving the useful ending rather than the directory prefix.

```text
3 [note] TasksController.show
   controllers/tasks_controller.rb:7
   │ Builds the task before rendering.
   │ Check behavior when the owner is missing.
4 Task.initialize
   models/task.rb:23
```

Imported marks use their recorded method/function label when recognizable.
Otherwise Stringer can obtain the enclosing method/function from hierarchical
document symbols supplied by an already attached LSP server. It includes class
or module context when available, and falls back to the filename. No server is
started and no file is loaded just to obtain labels. Set `symbol_labels = false`
for filename-only titles. Tree-sitter is not required.

Both entry rows and any expanded note rows belong to the same mark: Enter, dd,
K/J, s, and n work from any of them. Layout adapts to pane width and handles
Unicode display widths. A pane buffer shared by windows uses the narrowest
visible pane's available width. Stored paths remain absolute and unchanged.

## Source gutter indicators

Marks in the **active codepath only** have signs beside source line numbers:
`o` for ordinary marks, `N` if a mark on that line has a note. Active marks use
`StringerGutterActive`; ordinary and all-skipped groups use `StringerGutter` and
`StringerGutterSkipped`. Default links are `Search`, `Special`, and `Comment`.

Multiple marks at the same source line share one sign. Any note makes it a note
sign; it is dimmed only if all marks on that line are skipped. Hiding skipped
marks in the list does not remove their source signs. Signs appear only in loaded
code buffers, and out-of-range marks are not clamped onto unrelated lines.

Stringer respects existing signcolumn/statuscolumn settings and other plugins'
namespaces. If signs are hidden by your layout, enable a signcolumn; if they
compete with diagnostics or Git signs, adjust `gutter_priority` or the available
sign columns. Sign text must occupy one or two display cells. Set `gutter = false`
to disable these indicators.

These remain fixed line references: signs are reconciled to the stored lines
after edits, not used to silently relocate persisted marks.

## Skipped marks

Skipped marks stay in the codepath but are excluded from next/previous navigation
and nearest-line detection. They are dimmed with `StringerSkipped` (linked to
`Comment`) and labeled `[skip]`. You can still jump to one explicitly with Enter.
If every mark is skipped, navigation reports that there are no enabled marks.

The header shows total, skipped, and hidden counts. `H` changes only the view;
hidden marks remain stored. With filtering enabled, K/J move a mark before/after
its adjacent visible neighbor, preserving the relative order of hidden marks.
Visibility survives pane close/reopen and rename, but resets on path open/reload.

## Multiline notes

Press `n` on a mark to open a Markdown note editor. Use normal text editing, then
`:write` to persist or `:wq` to save and close. Empty content removes the note.
The active mark's full note expands directly below its location row, wrapping
long lines and preserving blank lines. It collapses when another mark becomes
active; the new mark's note appears if present. Moving the pane cursor alone does
not change the active mark. Hidden marks have no orphaned note section. Inline
notes display Markdown source as read-only text with `StringerNote` highlighting
(default `Comment`); set `inline_notes = false` to disable automatic expansion.

The separate editor and its drafts are unaffected by automatic reflow. `q` closes a saved note; use
`:bwipeout!` to explicitly discard a draft. Opening another note never replaces
an unsaved draft.

A note save is one undoable mark change. If the mark list changes while the note
is open (including reorder, skip, undo, or path reload), saving is rejected rather
than applying the text to a possibly different mark. Copy the draft, discard its
editor, reopen the intended mark's note, and paste it there. Navigation, hiding,
and renaming do not invalidate the editor. Failed saves keep the draft modified.

## Import stacktraces

Paste a trace into any buffer, set Neovim's working directory inside the relevant
project, and run:

```vim
:Stringer import request-failure
```

Omit the name to prompt. Input is the **whole current buffer**, including scratch,
log, and terminal buffers. The source text and existing quickfix list are retained.
Each import creates a new codepath; an existing name is never replaced.

Supported initial formats:

- Ruby: conventional `path.rb:line:in ...` and `from path.rb:line:in ...` frames.
- JavaScript/TypeScript: V8/Node `at function (path:line:column)` or
  `at path:line:column`. Local `.ts`/`.tsx` paths must already appear in the trace.
- Java: standard `at package.Class.method(File.java:line)` frames.

These formats print deepest calls first. Stringer reverses parsed frames so the
outermost available caller appears at the top. Repeated locations and framework
frames are preserved. Original frame text is stored separately from your notes
and supplies contextual titles when recognizable.

Absolute local paths are used directly; relative paths resolve against the Git
root containing the captured working directory, falling back to that directory.
Local `file:///` URIs are accepted. Remote URLs and container path remapping are
not supported. Java basename-only frames use a project-local `.java` index,
narrowed by package path when possible; only unique matches are accepted. The
index yields to Neovim during large searches and can be cancelled.

Missing, ambiguous, native, and unsupported-location frames are excluded with
source-line-specific reasons in the import report. A partial import is labeled
as partial and opens its report automatically; reopen it with `import-report`.
If no frames resolve, no codepath is created. Line numbers past EOF still use
the normal stale-mark checks at navigation time.

Use one conventional stack per buffer: chained/suppressed exceptions, elided Java
chains, interrupted/multiple stacks, and outermost-first Ruby tracebacks are
rejected rather than merged into a misleading codepath. Browser-specific trace
formats and source-map reconstruction are outside this initial coverage.

## Persistence and recovery

Append, remove, move, skip, and undo save immediately; notes save on `:write`.
The in-memory marks and pane
update only after the write succeeds. Moves preserve the active entry even when
its index changes; removing the active entry clears it until proximity detection
or navigation selects another. Undo restores the previous marks and active index.

Undo history is in memory, scoped to the loaded path. Reloading or opening a path
clears it. Renaming preserves it; rename itself is not a mark operation and is
not undone by `u`. There is no redo in this iteration.

If the storage file changes externally, mutations fail instead of overwriting
it. Use `:Stringer reload` or pane `R` to load the saved version. Malformed files
produce errors with record line numbers and leave the previous valid state
intact. Unsaved edits in a manually opened raw storage buffer must be saved or
discarded first. External-edit checks are content-based, not multi-process locks.

## Storage format and compatibility

Existing 0.1/0.2 paths load without rewriting. New paths and successful mutations
use mark format v2. Each `<name>.stringer` file contains a JSON Lines header and
one mark per physical line:

Version 0.4 uses the same storage format as 0.3; gutter signs, labels, and layout
are transient presentation state, not mark mutations.

```json
{"type":"stringer","format_version":1,"mark_version":2}
{"file":"/workspace/service/src/main.lua","line":42}
{"file":"/workspace/library/src/client.lua","line":108,"skipped":true,"note":"First line\nSecond line","frame":"original imported frame"}
```

Format versions are independent of the plugin version. Absolute file paths and
positive, one-based integer line numbers are required. Duplicate locations and
header-only paths are valid. Invalid JSON, blank records, extra fields, relative
paths, and unsupported versions are rejected. A normal final newline is valid.

Optional v2 fields are boolean `skipped` and string `note`/`frame`; absent skipped
means false. Multiline strings are JSON-escaped. Older Stringer releases reject
mark format v2, so upgraded paths require Stringer 0.3+.

Unlike 0.1, the pane is no longer raw JSON: editing text and `:write` have been
replaced by explicit, immediately persisted mark actions.

## Lua API

`require('stringer')` exposes:

- `setup(opts)`
- `new(name?)`, `open(name?)`, `rename(name?)`, `reload()`
- `add()`, `show()`, `next()`, `prev()`, `jump(index)`
- `remove(index?)`, `move_up(index?)`, `move_down(index?)`, `undo()`
- `skip(index?)`, `hide_skipped()`, `note(index?)`
- `import(name?)`, `import_report()`, `cancel_import()`

Indices refer to the full stored mark list, including hidden entries, and are
one-based. Omitted action indices use pane selection or the active
mark. Operations return `true` or `nil, error` and notify on failure. Prompting
operations return after launching an asynchronous prompt; cancelling is harmless.
Import also returns before asynchronous lookup/prompts finish; completion and
errors are reported through notifications and the import report. `setup` raises
an error for invalid options.

## Current limits

- Stored line references are fixed: code edits do not relocate them.
- Missing files and lines past EOF produce navigation errors; they are not
  silently rewritten. Failed jumps preserve the active mark.
- Marks require a file saved at least once. Modified buffers use the current
  cursor line.
- Active path, navigation position, and undo history do not survive a restart.
- Split-based code navigation, Tree-sitter selection, automatic location
  tracking, and fish-eye view are deferred.

## Development

From the repository root:

```sh
nvim --headless -u NONE -l tests/run.lua
nvim --headless -u NONE -l tests/ui.lua
```

The regression suite covers persistence, proximity selection, cyclic navigation,
mark mutations, rename, conflicts, path presentation, and reopening in a fresh
process. The UI suite drives real keyboard input in an embedded Neovim with an
attached screen. In-editor reference: `:help stringer`.
