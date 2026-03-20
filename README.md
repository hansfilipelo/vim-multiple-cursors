# multi-cursors.nvim

Neovim Lua port of [vim-multiple-cursors](https://github.com/terryma/vim-multiple-cursors). Emulates Sublime Text's multiple selection feature natively in Lua.

**Requires Neovim 0.11 or higher.**

## Contents
 - [About](#about)
 - [Installation](#installation)
 - [Quick Start](#quick-start)
 - [Setup](#setup)
 - [Mappings](#mappings)
 - [Commands](#commands)
 - [Highlight](#highlight)
 - [Hooks](#hooks)
 - [FAQ](#faq)
 - [Credit](#credit)

## About

This plugin provides Sublime Text-style multiple cursors for Neovim. Select a word, press `<C-n>` to find the next occurrence, and edit them all simultaneously.

### It's great for quick refactoring
![Example1](assets/example1.gif?raw=true)

Vim command sequence: `fp<C-n><C-n><C-n>cname`

### Add a cursor to each line of your visual selection
![Example2](assets/example2.gif?raw=true)

Vim command sequence: `vip<C-n>i"<Right><Right><Right>",<Esc>vipgJ$r]Idays = [`

### Match characters from visual selection
![Example3](assets/example3.gif?raw=true)

Vim command sequence: `df[$r,0f,v<C-n>…<C-n>c<CR><Up><Del><Right><Right><Right><Del>`

### Use the command to match regexp
![Example4](assets/example4.gif?raw=true)

## Installation

### lazy.nvim

```lua
{
  "terryma/vim-multiple-cursors",
  config = function()
    require("multi-cursors").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "terryma/vim-multiple-cursors",
  config = function()
    require("multi-cursors").setup()
  end,
}
```

### Manual

Clone/add this repo to your Neovim runtimepath and add to your `init.lua`:

```lua
require("multi-cursors").setup()
```

## Quick Start

### Normal mode / Visual mode
  * start:          `<C-n>` start multicursor and add a _virtual cursor + selection_ on the match
    * next:         `<C-n>` add a new _virtual cursor + selection_ on the next match
    * skip:         `<C-x>` skip the next match
    * prev:         `<C-p>` remove current _virtual cursor + selection_ and go back on previous match
  * select all:     `<A-n>` start multicursor and directly select all matches

You can now change the _virtual cursors + selection_ with **visual mode** commands.
For instance: `c`, `s`, `I`, `A` work without any issues.
You could also go to **normal mode** by pressing `v` and use normal commands there.

At any time, you can press `<Esc>` to exit back to regular Vim.

**NOTE**: start with `g<C-n>` to match without boundaries (behaves like `g*` instead of `*`)

### Visual mode when multiple lines are selected
  * start: `<C-n>` add _virtual cursors_ on each line

You can now change the _virtual cursors_ with **normal mode** commands.
For instance: `ciw`.

### Command
The command `:MultipleCursorsFind` accepts a range and a pattern (regexp), creating a cursor at the end of each match. Defaults to the entire buffer.

## Setup

Call `setup()` with your preferred options:

```lua
require("multi-cursors").setup({
  -- Key bindings (defaults shown)
  start_word_key = "<C-n>",       -- Start with word boundary (normal & visual)
  start_key = "g<C-n>",           -- Start without word boundary
  select_all_word_key = "<A-n>",  -- Select all matches (word boundary)
  select_all_key = "g<A-n>",      -- Select all matches (no boundary)
  next_key = "<C-n>",             -- Add next match (during multicursor)
  prev_key = "<C-p>",             -- Remove current, go to previous
  skip_key = "<C-x>",             -- Skip current match
  quit_key = "<Esc>",             -- Exit multicursor mode

  -- Behavior
  exit_from_visual_mode = false,  -- Quit key exits from visual mode
  exit_from_insert_mode = false,  -- Quit key exits from insert mode
  support_imap = true,            -- Support insert mode mappings
})
```

Set any key to `false` to disable that mapping.

**Backwards compatibility:** The plugin also reads legacy `g:multi_cursor_*` Vim global variables.

## Mappings

| Key | Mode | Description |
|-----|------|-------------|
| `<C-n>` | n | Start multicursor on word under cursor |
| `<C-n>` | x | Start multicursor on visual selection / add cursors per line |
| `g<C-n>` | n | Start multicursor (no word boundary) |
| `g<C-n>` | x | Start multicursor on selection (no word boundary) |
| `<A-n>` | n | Select all occurrences of word |
| `<A-n>` | x | Select all occurrences of selection |
| `g<A-n>` | n | Select all (no word boundary) |
| `g<A-n>` | x | Select all visual (no word boundary) |

While in multicursor mode:

| Key | Action |
|-----|--------|
| `<C-n>` | Add next match |
| `<C-p>` | Remove current cursor, go to previous |
| `<C-x>` | Skip current match |
| `<Esc>` | Exit multicursor mode |

## Commands

### `:MultipleCursorsFind {pattern}`

Create cursors at each match of `{pattern}`. Accepts a range.

```vim
:MultipleCursorsFind \<foo\>
:'<,'>MultipleCursorsFind bar
```

## Highlight

Two highlight groups are used:

| Group | Default | Description |
|-------|---------|-------------|
| `MultipleCursorsCursor` | `reverse` | Virtual cursor appearance |
| `MultipleCursorsVisual` | links to `Visual` | Visual selection appearance |

Customize in your config:

```lua
vim.api.nvim_set_hl(0, "MultipleCursorsCursor", { reverse = true })
vim.api.nvim_set_hl(0, "MultipleCursorsVisual", { link = "Visual" })
```

## Hooks

The plugin fires `User` autocommands for integration with other plugins:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "MultipleCursorsPre",
  callback = function()
    -- Disable completion, etc.
  end,
})

vim.api.nvim_create_autocmd("User", {
  pattern = "MultipleCursorsPost",
  callback = function()
    -- Re-enable completion, etc.
  end,
})
```

Legacy `Multiple_cursors_before()` / `Multiple_cursors_after()` functions are also supported.

## FAQ

#### **Q** Pressing <kbd>i</kbd> after selecting words with <kbd>C-n</kbd> makes the plugin hang, why?
**A** When selecting words with <kbd>C-n</kbd>, the plugin behaves like in **visual** mode.
Once you pressed <kbd>i</kbd>, you can still press <kbd>I</kbd> to insert text.

#### **Q** How can I select `n` keywords with several keystrokes? `200<C-n>` does not work.
**A** Use `:MultipleCursorsFind keyword`. For example:

```lua
vim.keymap.set({"n", "x"}, "<M-j>", ":MultipleCursorsFind <C-R>/<CR>", { silent = true })
```

This allows you to search with `*` and then create cursors with `Alt-j`.

## Credit

Originally created by [Terry Ma](https://github.com/terryma/vim-multiple-cursors).
Inspired by Sublime Text's [multiple selection][sublime-multiple-selection] and Emacs' [multiple cursors][emacs-multiple-cursors] by Magnar Sveen.

[sublime-multiple-selection]:http://www.sublimetext.com/docs/2/multiple_selection_with_the_keyboard.html
[emacs-multiple-cursors]:https://github.com/magnars/multiple-cursors.el
