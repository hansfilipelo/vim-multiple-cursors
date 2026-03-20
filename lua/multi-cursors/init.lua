--- multi-cursors: Neovim Lua port of vim-multiple-cursors
--- Emulate Sublime Text's multi-cursor / multiple-selection feature.
local CursorManager = require("multi-cursors.cursor_manager")
local highlight = require("multi-cursors.highlight")
local input = require("multi-cursors.input")
local utils = require("multi-cursors.utils")

local M = {}

-- Singleton cursor manager
local cm = CursorManager.new()

-- Default configuration
local default_config = {
  -- Keys (internal key codes)
  next_key = vim.api.nvim_replace_termcodes("<C-n>", true, true, true),
  prev_key = vim.api.nvim_replace_termcodes("<C-p>", true, true, true),
  skip_key = vim.api.nvim_replace_termcodes("<C-x>", true, true, true),
  quit_key = vim.api.nvim_replace_termcodes("<Esc>", true, true, true),
  -- Behavior
  exit_from_visual_mode = false,
  exit_from_insert_mode = false,
  support_imap = true,
  -- Keys that require waiting for multi-char sequences in normal/visual mode
  normal_maps = {
    ["!"] = true, ["@"] = true, ["="] = true, ["q"] = true, ["r"] = true,
    ["t"] = true, ["T"] = true, ["y"] = true, ["["] = true, ["]"] = true,
    ["\\"] = true, ["d"] = true, ["f"] = true, ["F"] = true, ["g"] = true,
    ['"'] = true, ["z"] = true, ["c"] = true, ["m"] = true, ["<"] = true,
    [">"] = true,
  },
  visual_maps = {
    ["i"] = true, ["a"] = true, ["f"] = true, ["F"] = true,
    ["t"] = true, ["T"] = true,
  },
}

-- Active config
local config = vim.deepcopy(default_config)

--- Whether the plugin uses word boundary for searching
local use_word_boundary = true

--- Start the input loop (called after cursors are set up)
---@param mode string "n" or "v" or "V"
local function start_input_loop(mode)
  -- Protect against recursive errors
  local ok, result, from_mode = pcall(input.wait_for_input, cm, mode, config)
  if not ok then
    -- On error, clean up
    cm:reset(true, true, true)
    if type(result) == "string" and result ~= "Keyboard interrupt" then
      vim.api.nvim_err_writeln("multi-cursors: " .. result)
    end
    return
  end

  -- If wait_for_input returned a special key, handle it
  if type(result) == "string" and from_mode then
    M._handle_special_key(result, from_mode)
  end
end

--- Handle special keys (next/prev/skip) that manage cursors
---@param key string
---@param mode string
function M._handle_special_key(key, mode)
  local next_key = config.next_key or ""
  local prev_key = config.prev_key or ""
  local skip_key = config.skip_key or ""

  if key == next_key then
    if use_word_boundary then
      M.new("v", true)
    else
      M.new("v", false)
    end
  elseif key == prev_key then
    M.prev()
  elseif key == skip_key then
    M.skip()
  end
end

--- Create a new cursor.
--- In normal mode: selects word under cursor.
--- In visual mode with multi-line selection: creates cursor per line.
--- In visual mode with single-line selection: finds next match.
---@param mode string "n" or "v"
---@param word_boundary boolean
function M.new(mode, word_boundary)
  cm:fire_pre_triggers()
  use_word_boundary = word_boundary

  if mode == "n" then
    cm:reset(false, false)
    -- Select word under cursor
    vim.cmd("normal! viw")
    utils.exit_visual_mode()
    -- Add cursor at end of word with visual region
    cm:add(utils.pos("'>"), utils.region("'<", "'>"))
    start_input_loop("v")
  elseif mode == "v" then
    local start_line = vim.fn.line("'<")
    local finish_line = vim.fn.line("'>")

    if start_line ~= finish_line then
      -- Multi-line visual: one cursor per line
      cm:reset(false, false)
      local col = vim.fn.col("'<")
      for line = start_line, finish_line do
        cm:add({ line, col })
      end
      start_input_loop("n")
    else
      -- Single-line visual: search for next occurrence
      if cm:is_empty() then
        cm:reset(false, false)
        if vim.fn.visualmode() == "V" then
          local left = { vim.fn.line("."), 1 }
          local right_col = vim.fn.col("$") - 1
          if right_col == 0 then
            return
          end
          local right = { vim.fn.line("."), right_col }
          cm:add(right, { left, right })
        else
          cm:add(utils.pos("'>"), utils.region("'<", "'>"))
        end
      end

      local content = utils.get_text(utils.region("'<", "'>"))
      local next_match = utils.find_next(content, use_word_boundary)
      if next_match then
        if cm:add(next_match[2], next_match) then
          utils.update_visual_markers(next_match)
        else
          local cur = cm:get_current()
          vim.fn.cursor(cur.position)
          vim.api.nvim_echo({ { "No more matches", "WarningMsg" } }, false, {})
        end
      else
        vim.api.nvim_echo({ { "No more matches", "WarningMsg" } }, false, {})
      end
      start_input_loop("v")
    end
  end
end

--- Remove current cursor and go to previous
function M.prev()
  cm:delete_current()
  if not cm:is_empty() then
    local cur = cm:get_current()
    if #cur.visual > 0 then
      utils.update_visual_markers(cur.visual)
    end
    vim.fn.cursor(cur.position)
    start_input_loop("v")
  end
end

--- Skip current match and find next
function M.skip()
  cm:delete_current()
  local content = utils.get_text(utils.region("'<", "'>"))
  local next_match = utils.find_next(content, use_word_boundary)
  if next_match then
    cm:add(next_match[2], next_match)
    utils.update_visual_markers(next_match)
  end
  start_input_loop("v")
end

--- Find pattern in range and create cursors at each match
---@param start_line number
---@param end_line number
---@param pattern string
function M.find(start_line, end_line, pattern)
  cm.saved_winview = vim.fn.winsaveview()
  cm.start_from_find = true

  local pos1, pos2
  if vim.fn.visualmode() == "v" and start_line == vim.fn.line("'<") and end_line == vim.fn.line("'>") then
    pos1 = utils.pos("'<")
    pos2 = utils.pos("'>")
  else
    pos1 = { start_line, 1 }
    pos2 = { end_line, vim.fn.col({ end_line, "$" }) }
  end

  vim.fn.cursor(pos1)
  local first = true

  while true do
    local match
    if first then
      local saved_ve = vim.o.virtualedit
      vim.o.virtualedit = "onemore"
      match = vim.fn.search(pattern, "cW")
      vim.o.virtualedit = saved_ve
      first = false
    else
      match = vim.fn.search(pattern, "W")
    end

    if match == 0 then
      break
    end

    local left = utils.pos(".")
    local bmatch = vim.fn.search(pattern, "bceW")
    local right = utils.pos(".")

    if bmatch == 0 or utils.compare_pos(right, left) ~= 0 then
      vim.fn.cursor(left)
      vim.fn.search(pattern, "ceW")
      right = utils.pos(".")
    end

    if utils.compare_pos(right, pos2) > 0 then
      vim.fn.search(pattern, "be")
      break
    end

    cm:add(right, { left, right })
  end

  if cm:is_empty() then
    if cm.saved_winview then
      vim.fn.winrestview(cm.saved_winview)
    end
    vim.api.nvim_echo({ { "No match found", "ErrorMsg" } }, false, {})
    return
  end

  vim.api.nvim_echo({
    { ("Added %d cursor%s"):format(cm:size(), cm:size() > 1 and "s" or ""), "Normal" },
  }, false, {})

  cm:fire_pre_triggers()
  start_input_loop("v")
end

--- Select all matches and create cursors
---@param mode string "n" or "v"
---@param word_boundary boolean
function M.select_all(mode, word_boundary)
  local pattern
  if mode == "v" then
    local save_a = vim.fn.getreg("a")
    vim.cmd('normal! gv"ay')
    pattern = vim.fn.getreg("a")
    vim.fn.setreg("a", save_a)
  else
    pattern = vim.fn.expand("<cword>")
  end

  if word_boundary then
    pattern = "\\<" .. pattern .. "\\>"
  end

  M.find(1, vim.fn.line("$"), pattern)
end

--- Quit multicursor mode
function M.quit()
  cm:reset(true, true, true)
end

--- Setup function for user configuration
---@param opts table|nil
function M.setup(opts)
  opts = opts or {}

  -- Merge user config
  if opts.exit_from_visual_mode ~= nil then
    config.exit_from_visual_mode = opts.exit_from_visual_mode
  end
  if opts.exit_from_insert_mode ~= nil then
    config.exit_from_insert_mode = opts.exit_from_insert_mode
  end
  if opts.support_imap ~= nil then
    config.support_imap = opts.support_imap
  end
  if opts.normal_maps then
    config.normal_maps = opts.normal_maps
  end
  if opts.visual_maps then
    config.visual_maps = opts.visual_maps
  end

  -- Key configuration: translate to keycodes
  local key_opts = { "next_key", "prev_key", "skip_key", "quit_key" }
  for _, k in ipairs(key_opts) do
    if opts[k] then
      config[k] = vim.api.nvim_replace_termcodes(opts[k], true, true, true)
    end
  end

  -- Set up default highlights
  highlight.setup_defaults()

  -- Custom highlight overrides
  if opts.cursor_highlight then
    vim.api.nvim_set_hl(0, highlight.cursor_hl_group, opts.cursor_highlight)
  end
  if opts.visual_highlight then
    vim.api.nvim_set_hl(0, highlight.visual_hl_group, opts.visual_highlight)
  end

  -- Set up keymaps
  local use_default = opts.use_default_mapping
  if use_default == nil then
    use_default = true
  end

  -- Read legacy g: variables for backwards compat
  local function g(name, default)
    local val = vim.g["multi_cursor_" .. name]
    if val ~= nil then
      return val
    end
    return default
  end

  if vim.g.multi_cursor_use_default_mapping == 0 then
    use_default = false
  end

  config.exit_from_visual_mode = g("exit_from_visual_mode", config.exit_from_visual_mode)
  config.exit_from_insert_mode = g("exit_from_insert_mode", config.exit_from_insert_mode)
  config.support_imap = g("support_imap", config.support_imap)

  -- Translate legacy g: key vars
  for _, k in ipairs(key_opts) do
    local gvar = vim.g["multi_cursor_" .. k]
    if gvar then
      config[k] = vim.api.nvim_replace_termcodes(gvar, true, true, true)
    end
  end

  -- Map user-facing key strings for mappings (not internal keycodes)
  local start_word_key = opts.start_word_key or g("start_word_key", use_default and "<C-n>" or nil)
  local start_key = opts.start_key or g("start_key", use_default and "g<C-n>" or nil)
  local select_all_word_key = opts.select_all_word_key or g("select_all_word_key", use_default and "<A-n>" or nil)
  local select_all_key = opts.select_all_key or g("select_all_key", use_default and "g<A-n>" or nil)

  if start_key then
    vim.keymap.set("n", start_key, function() M.new("n", false) end,
      { silent = true, desc = "Multi-cursor: start (no word boundary)" })
    vim.keymap.set("x", start_key, function()
      vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, true, true))
      M.new("v", false)
    end, { silent = true, desc = "Multi-cursor: start visual (no word boundary)" })
  end

  if start_word_key then
    vim.keymap.set("n", start_word_key, function() M.new("n", true) end,
      { silent = true, desc = "Multi-cursor: start (word boundary)" })
    vim.keymap.set("x", start_word_key, function()
      vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, true, true))
      M.new("v", false) -- visual mode doesn't use word boundary
    end, { silent = true, desc = "Multi-cursor: start visual" })
  end

  if select_all_key then
    vim.keymap.set("n", select_all_key, function() M.select_all("n", false) end,
      { silent = true, desc = "Multi-cursor: select all (no word boundary)" })
    vim.keymap.set("x", select_all_key, function()
      vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, true, true))
      M.select_all("v", false)
    end, { silent = true, desc = "Multi-cursor: select all visual (no word boundary)" })
  end

  if select_all_word_key then
    vim.keymap.set("n", select_all_word_key, function() M.select_all("n", true) end,
      { silent = true, desc = "Multi-cursor: select all (word boundary)" })
    vim.keymap.set("x", select_all_word_key, function()
      vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, true, true))
      M.select_all("v", false)
    end, { silent = true, desc = "Multi-cursor: select all visual" })
  end

  -- MultipleCursorsFind command
  vim.api.nvim_create_user_command("MultipleCursorsFind", function(cmd_opts)
    M.find(cmd_opts.line1, cmd_opts.line2, cmd_opts.args)
  end, {
    nargs = 1,
    range = "%",
    desc = "Create cursors at each match of a pattern",
  })
end

return M
