# quickselect.nvim

A Treesitter-powered plugin for quick selection, expanding outward layer by layer.

## Install

```lua
-- lazy.nvim
{
  "zetatez/quickselect.nvim",
  dependencies = { "nvim-treesitter/nvim-treesitter" },
  config = function()
    require("quickselect").setup({
      keymap = {
        { key = "<CR>", fn = function() require("quickselect").expand() end, desc = "Expand selection" },
        { key = "<BS>", fn = function() require("quickselect").shrink() end, desc = "Shrink selection" },
      },
    })
  end,
}
```

## API

- `require("quickselect").expand()`: Expand to parent node
- `require("quickselect").shrink()`: Shrink to child node
