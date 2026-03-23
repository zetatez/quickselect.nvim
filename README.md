# quickselect.nvim

A Tree-sitter powered Neovim plugin for growing and shrinking selections layer by layer.

## Features

- Starts from the smallest useful selection under the cursor
- Expands through named Tree-sitter ancestors step by step
- Handles inner selections for strings and common delimited nodes such as `(...)`, `[...]`, and `{...}`
- Shrinks back through the same selection history while staying in visual mode
- Falls back to selecting the whole buffer as the final step

## Requirements

- Neovim with Tree-sitter available
- A parser installed for the current buffer
- `nvim-treesitter/nvim-treesitter`

## Installation

```lua
{
  "zetatez/quickselect.nvim",
  dependencies = { "nvim-treesitter/nvim-treesitter" },
  config = function()
    require("quickselect").setup({
      keymap = {
        { key = "<CR>", fn = function() require("quickselect").expand() end, desc = "Expand selection", },
        { key = "<BS>", fn = function() require("quickselect").shrink() end, desc = "Shrink selection", },
      },
    })
  end,
}
```

`setup()` only registers the keymaps you provide. The plugin does not define default mappings on its own.

## Usage

1. Place the cursor on a node in normal mode.
2. Call `require("quickselect").expand()` to start selecting.
3. Call `require("quickselect").expand()` again to grow the selection outward.
4. While visual mode is active, call `require("quickselect").shrink()` to move back inward.

Selection state is cleared automatically when leaving visual mode, changing buffers or windows, or entering insert or command-line mode.

## API

- `require("quickselect").setup(opts)`: Register autocmds and optional keymaps from `opts.keymap`
- `require("quickselect").expand()`: Start or grow the current selection
- `require("quickselect").shrink()`: Shrink the current visual selection by one step
- `require("quickselect").clear()`: Clear cached selection state
