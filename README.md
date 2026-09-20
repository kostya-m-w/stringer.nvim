# Stringer

Capture ordered codepaths and navigate them in Neovim. A codepath can span
multiple repositories and contain multiple locations in the same file.

Version **0.2** requires **Neovim 0.10+**. Pure Lua, with no dependencies.

## Installation

Use your plugin manager's local-directory support, or place this repository under
`pack/plugins/start/stringer` in a Neovim package directory. With lazy.nvim:

```lua
{
  dir = '/absolute/path/to/stringer',
  opts = {},
}
```

To try it from this checkout:

```sh
nvim --cmd 'set runtimepath+=.'
```

Setup is optional. Defaults:

```lua
require('stringer').setup({
  storage_dir = vim.fn.stdpath('data') .. '/stringer/paths',
  pane_width = 48,
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
| `:Stringer undo` | Undo the last successful append, removal, or move. |
| `:Stringer reload` | Reload the active path from storage. |

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

Moving the cursor in a marked code file selects its **nearest marked line**.
Distance is measured in lines; there is no Tree-sitter dependency or maximum
distance. If two entries are equally close, Stringer keeps the active entry when
it is tied; otherwise it picks the earlier codepath entry. Repeated marks at the
same location remain independently navigable.

The active mark is highlighted with `StringerActive` (linked to `Visual`) and a
`>` sign. Moving the pane cursor selects an entry for actions without changing
the active mark. In an unmarked file, the previous active mark remains active.
With no active mark, next starts at the first entry and previous at the last.

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
| `q` | Close the pane; keep the codepath active. |

Display paths use the Git root containing **Neovim's working directory**, falling
back to that working directory if no `.git` directory/file is found:

- Inside this project: `lua/stringer/init.lua:42`.
- Elsewhere under your home: `~/workspace/other/main.lua:10`.
- Otherwise: `/absolute/path/main.lua:10`.

Jumping across codebases does not change the display root. Changing Neovim's
working directory refreshes the view. Stored paths remain absolute.

## Persistence and recovery

Append, remove, move, and undo save immediately. The in-memory marks and pane
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

## Storage format and 0.1 compatibility

Existing 0.1 codepaths work without migration. Each `<name>.stringer` file still
contains a versioned JSON Lines header and one mark per line:

```json
{"type":"stringer","format_version":1,"mark_version":1}
{"file":"/workspace/service/src/main.lua","line":42}
{"file":"/workspace/library/src/client.lua","line":108}
```

Format versions are independent of the plugin version. Absolute file paths and
positive, one-based integer line numbers are required. Duplicate locations and
header-only paths are valid. Invalid JSON, blank records, extra fields, relative
paths, and unsupported versions are rejected. A normal final newline is valid.

Unlike 0.1, the pane is no longer raw JSON: editing text and `:write` have been
replaced by explicit, immediately persisted mark actions.

## Lua API

`require('stringer')` exposes:

- `setup(opts)`
- `new(name?)`, `open(name?)`, `rename(name?)`, `reload()`
- `add()`, `show()`, `next()`, `prev()`, `jump(index)`
- `remove(index?)`, `move_up(index?)`, `move_down(index?)`, `undo()`

Indices are one-based. Omitted action indices use pane selection or the active
mark. Operations return `true` or `nil, error` and notify on failure. Prompting
operations return after launching an asynchronous prompt; cancelling is harmless.
`setup` raises an error for invalid options.

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
