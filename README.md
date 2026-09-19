# Stringer

Manually capture ordered codepaths and navigate them in Neovim. A codepath can
span multiple repositories and contain multiple locations in the same file.

Version 0.1 requires **Neovim 0.10+**. The plugin is pure Lua, with no dependencies.

## Installation

Use your plugin manager's local-directory support during development, or put the
repository in your Neovim package directory under `pack/plugins/start/stringer`.
For example, with lazy.nvim:

```lua
{
  dir = '/absolute/path/to/stringer',
  opts = {},
}
```

To try it directly from this checkout:

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
4. Run `:Stringer next` / `:Stringer prev` to follow the saved order.
5. Run `:Stringer show` to view the codepath. On a mark line, press `<CR>` to jump.
6. Move or delete complete mark lines with normal Neovim editing operations.
   Keep the first line (the header) in place. Use `:write` to apply your edits.
7. After restarting Neovim, run `:Stringer open request-flow` to resume using it.

## Commands

| Command | Action |
| --- | --- |
| `:Stringer new <name>` | Create and activate an empty codepath. |
| `:Stringer open [name]` | Activate a saved path, or choose one using `vim.ui.select`. |
| `:Stringer add` | Append the current file and cursor line; save immediately. |
| `:Stringer show` | Open/focus an editable right-side path pane. |
| `:Stringer next` | Jump to the next saved mark, or the first if none is active. |
| `:Stringer prev` | Jump to the previous saved mark, or the last if none is active. |

Names accept letters, numbers, hyphens, and underscores. Completion is available
for subcommands and saved path names. Paths are stored outside repositories, and
only one path is active at a time. Opening a path does not automatically jump.

Navigation does not wrap. It replaces the current code window's buffer. From the
path pane, it uses the most recently focused code window in the current tab,
falling back to another eligible code window. It never replaces the path pane
with code. Open a code window if the pane is the only window in the tab.

No global mappings are installed. Example mappings:

```lua
vim.keymap.set('n', '<leader>sa', '<cmd>Stringer add<CR>')
vim.keymap.set('n', '<leader>ss', '<cmd>Stringer show<CR>')
vim.keymap.set('n', ']s', '<cmd>Stringer next<CR>')
vim.keymap.set('n', '[s', '<cmd>Stringer prev<CR>')
```

## Editing and saving

The pane is the actual persisted text format, edited through a validated write
handler. It has two local mappings:

- `<CR>`: jump to the saved mark on the cursor line.
- `q`: close the pane, keeping the path active; requires a clean buffer.

Reorder or remove marks by moving/deleting whole lines. Ordinary undo works.
Edits take effect only after a successful `:write`. Invalid saves produce
line-specific diagnostics and leave the buffer modified. The stored file and
last valid navigation snapshot remain intact. An invalid `:wq` does not close
the pane.

While the pane has unsaved edits:

- Next/previous still navigate the last valid snapshot.
- Adding a mark, switching paths, and pane `<CR>` jumps are blocked.
- Active highlighting is hidden because draft lines may have moved.

Use `:edit!` **in the path pane** to discard draft edits and reload the saved file.
If Stringer detects that another editor/process changed the file, it refuses to
overwrite it. Copy any draft edits you want to keep, reload with `:edit!`, then
reapply them. With the pane closed and clean, `:Stringer open <name>` also reloads
the path. Content comparison detects external edits; this is not multi-process
locking.

The last successfully navigated mark is highlighted with `StringerActive`
(linked to `Visual` by default). A save that changes the ordered mark list clears
the active mark; a save with unchanged marks preserves it. Appending a mark
preserves an existing active position. Opening/reopening a path resets it.

## Storage format

Each `<name>.stringer` file is JSON Lines: a header followed by one mark per line.

```json
{"type":"stringer","format_version":1,"mark_version":1}
{"file":"/workspace/service/src/main.lua","line":42}
{"file":"/workspace/library/src/client.lua","line":108}
```

Both format versions live in the header, independently of the plugin release.
Files contain absolute paths and positive, one-based line numbers. Duplicate
locations and empty paths (header only) are valid. Unsupported versions, blank
record lines, extra fields, relative paths, and malformed records are rejected.
Normal final newlines are accepted. JSON escaping handles quotes and backslashes
in filenames.

## Lua API

`require('stringer')` exposes `setup(opts)`, `new(name)`, `open(name?)`, `add()`,
`show()`, `next()`, `prev()`, and `jump(index)` (one-based mark index).

Operations return `true` on success or `nil, error` on failure, and report errors
through `vim.notify`. `open()` without a name returns after launching the picker;
selection is asynchronous. `setup` raises an error for invalid configuration.

## Current limits

- File/line references are fixed. Edits can move code without moving its marks.
- Missing targets and line numbers past EOF produce errors; they are not silently
  rewritten. Failed jumps do not change the active mark.
- Navigation respects Neovim's `'hidden'` setting and modified-buffer safeguards.
- Marks require a file that has been saved at least once. Adding from a modified
  buffer records its current cursor line.
- Absolute paths are local to the machine/filesystem layout.
- Active path and position are not restored automatically between sessions.
- Code split navigation, automatic location tracking, a structured editing UI,
  and fish-eye view are deferred.

## Development

From the repository root:

```sh
nvim --headless -u NONE -l tests/run.lua
nvim --headless -u NONE -l tests/ui.lua
```

The dependency-free suite uses temporary fixtures and covers persistence,
validation, failure recovery, editable panes, window selection, and reopening in
a fresh Neovim process. The UI smoke test launches an embedded Neovim with an
attached screen and exercises real key input, rendered highlighting, focus,
reordering, saving, closing, and undo. See `:help stringer` for an in-editor
reference.
