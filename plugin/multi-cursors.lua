-- Plugin loader for multi-cursors
-- Auto-runs setup with defaults if the user hasn't called setup() explicitly

if vim.g.loaded_multi_cursors_lua then
  return
end
vim.g.loaded_multi_cursors_lua = true

-- Defer setup to allow user to call require("multi-cursors").setup() first
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    -- Only auto-setup if the user hasn't already called setup()
    -- We detect this by checking if the command exists
    if vim.fn.exists(":MultipleCursorsFind") ~= 2 then
      require("multi-cursors").setup()
    end
  end,
  once = true,
})
