--- Input handling: the core loop that intercepts user input and replays it
--- at each virtual cursor location.
local utils = require("multi-cursors.utils")

local M = {}

-- Module-level state
M.char = ""
M.saved_char = ""
M.from_mode = ""
M.to_mode = ""
M.saved_linecount = -1
M.bad_input = 0
M.saved_keys = ""
M.retry_keys = ""

--- Consume any typeahead that arrived between getchar() calls
---@return string consumed keys
local function consume_typeahead()
  local keys = ""
  while true do
    local c = utils.get_char(true)
    if c == "" then
      break
    end
    keys = keys .. c
  end
  return keys
end

--- Revert Vim to the appropriate mode for replay
---@param from string current mode
---@param to string target mode
local function revert_mode(from, to, cm)
  if to == "v" then
    cm:reapply_visual_selection()
  elseif to == "V" then
    cm:reapply_visual_selection()
    vim.cmd("normal! V")
  elseif to == "n" and from == "i" then
    vim.cmd("stopinsert")
  elseif to == "i" and vim.fn.mode() ~= "i" then
    -- Re-enter insert mode if we've been kicked out.
    -- After exiting insert mode the cursor moves one left,
    -- so use 'a' (append) to compensate back to the original column.
    -- At column 1 'a' would overshoot, so use 'startinsert' instead.
    if vim.fn.col(".") <= 1 then
      vim.cmd("startinsert")
    else
      vim.cmd("noautocmd normal! a")
    end
  end
end

--- Handle I/A in visual mode → transition to insert
---@param cm CursorManager
local function handle_visual_IA_to_normal(cm)
  if (M.char == "I" or M.char == "A") and (M.from_mode == "v" or M.from_mode == "V") then
    M.saved_char = M.char
    M.char = M.from_mode -- spoof visual mode key to transition V→N
  end
end

--- Complete transition into insert after I/A in visual
---@param cm CursorManager
local function handle_visual_IA_to_insert(cm)
  if M.saved_char ~= "" and (M.char == "v" or M.char == "V") and M.to_mode == "n" then
    if M.saved_char == "I" then
      cm:reposition_all_within_region(true)
    end
    -- Queue the lowercase key so the next loop iteration fans it out to all cursors
    M.saved_keys = string.lower(M.saved_char)
    M.saved_char = ""
  end
end

--- Process user input at one cursor, then move to the next.
--- This is the core "fan-out" function.
---@param cm CursorManager
---@param config table
local function process_at_cursor(cm, config)
  local cur = cm:get_current()
  vim.fn.cursor(cur.position)

  -- Revert to the mode the user was in
  revert_mode(M.to_mode, M.from_mode, cm)

  -- Update line length before applying action
  cur:update_line_length()
  M.saved_linecount = vim.fn.line("$")
  cm._saved_linecount = M.saved_linecount

  -- Restore per-cursor unnamed register before replay
  if M.from_mode == "n" or M.from_mode == "v" or M.from_mode == "V" then
    cur:restore_unnamed_register()
  end

  -- Join undos in insert mode
  if M.from_mode == "i" or M.to_mode == "i" then
    pcall(vim.cmd, "undojoin")
  end

  -- Execute the user's keys
  local ok = true
  local old_mode = vim.fn.mode(1)
  vim.api.nvim_feedkeys(M.char, "", false)
  -- Force processing of feedkeys
  vim.api.nvim_feedkeys("", "x", false)

  local new_mode_raw = vim.fn.mode(1)
  local new_mode = new_mode_raw:sub(1, 1)
  -- Normalize mode
  if new_mode == "n" or new_mode == "i" then
    -- keep as is
  elseif new_mode == "v" or new_mode == "V" or new_mode == "\22" then
    if new_mode == "V" then
      new_mode = "V"
    elseif new_mode == "\22" then
      new_mode = "v" -- treat block visual as visual for our purposes
    else
      new_mode = "v"
    end
  elseif new_mode == "s" or new_mode == "S" then
    new_mode = "v" -- select mode → treat as visual
  else
    new_mode = "n"
  end

  -- Save to_mode only on first cursor
  if M.to_mode == "" then
    M.to_mode = new_mode
    if M.to_mode == "v" then
      local vm = vim.fn.visualmode()
      if vm == "V" then
        M.to_mode = "V"
      end
    end
  end

  -- Update the current cursor's state
  cm:update_current(M.from_mode, M.to_mode)

  -- Advance to next
  cm:next()

  return cm:loop_done()
end

--- Display error for bad/unreplayable input
---@param cm CursorManager
---@param config table
local function display_error(cm, config)
  local normal_maps = config.normal_maps or {}
  local visual_maps = config.visual_maps or {}

  if M.bad_input == cm:size() then
    local first_char = M.char:sub(1, 1)
    if (M.from_mode == "n" and normal_maps[first_char])
        or ((M.from_mode == "v" or M.from_mode == "V") and visual_maps[first_char]) then
      M.retry_keys = M.char
    else
      M.retry_keys = ""
      if M.bad_input > 0 then
        vim.api.nvim_echo({
          { ("Key '%s' cannot be replayed at %d cursor location%s"):format(
            M.char, M.bad_input, M.bad_input == 1 and "" or "s"), "ErrorMsg" },
        }, false, {})
      end
    end
  else
    M.retry_keys = ""
    if M.bad_input > 0 then
      vim.api.nvim_echo({
        { ("Key '%s' cannot be replayed at %d cursor location%s"):format(
          M.char, M.bad_input, M.bad_input == 1 and "" or "s"), "ErrorMsg" },
      }, false, {})
    end
  end
  M.bad_input = 0
end

--- Check if a string is a prefix of any string in a list
---@param s string
---@param list string[]
---@return boolean
local function starts_any(s, list)
  for _, item in ipairs(list) do
    if item:sub(1, #s) == s then
      return true
    end
  end
  return false
end

--- Main wait-for-input loop. This is the heart of the plugin.
--- Uses an iterative loop to avoid stack overflow with many keystrokes.
---@param cm CursorManager
---@param mode string starting mode ("n", "v", "V", "i")
---@param config table
function M.wait_for_input(cm, mode, config)
  local current_mode = mode

  while true do
    display_error(cm, config)

    M.from_mode = current_mode
    if current_mode == "" then
      M.from_mode = M.to_mode
    end
    M.to_mode = ""

    -- Redraw to show highlights
    vim.cmd("redraw")

    -- Build char from retry + saved + new input
    M.char = M.retry_keys .. M.saved_keys
    if #M.saved_keys == 0 then
      M.char = M.char .. utils.get_char()
      handle_visual_IA_to_normal(cm)
    else
      M.saved_keys = ""
    end

    -- Handle insert mode imap resolution
    local support_imap = config.support_imap ~= false
    if M.from_mode == "i" and vim.fn.mapcheck(M.char, "i") ~= "" and support_imap then
      local s_time = vim.fn.reltime()
      while true do
        local map_dict = vim.fn.maparg(M.char, "i", false, true)
        if map_dict and next(map_dict) then
          local rhs
          if map_dict.expr and map_dict.expr ~= 0 then
            rhs = vim.api.nvim_eval(map_dict.rhs)
          else
            rhs = vim.fn.maparg(M.char, "i")
          end
          M.char = vim.api.nvim_replace_termcodes(rhs, true, true, true)
          break
        end
        if vim.fn.mapcheck(M.char, "i") == "" then
          break
        end
        local elapsed = tonumber(vim.fn.reltimefloat(vim.fn.reltime(s_time))) * 1000
        if elapsed > vim.o.timeoutlen then
          break
        end
        local new_char = utils.get_char(true)
        if new_char ~= "" then
          M.char = M.char .. new_char
        else
          vim.cmd("sleep 50m")
        end
      end
    elseif M.from_mode ~= "i" and M.char:sub(1, 1) == ":" then
      -- Colon typed in normal mode → drop to command line and exit
      vim.api.nvim_feedkeys(M.char, "n", false)
      cm:reset(true, true, true)
      return
    elseif M.from_mode == "n" or M.from_mode == "v" or M.from_mode == "V" then
      -- Consume numeric prefix (count)
      while M.char:sub(-1):match("%d") do
        if M.char:match("^%a?0") or M.char:match("^0$") then
          break
        end
        M.char = M.char .. utils.get_char()
      end
    end

    -- Clear echo area (mode-safe, unlike normal! : which exits insert mode)
    vim.cmd("echo ''")

    -- Check for special keys (next/prev/skip) and quit key
    local special_keys_for_mode = {}
    local next_key = config.next_key or ""
    local prev_key = config.prev_key or ""
    local skip_key = config.skip_key or ""
    local quit_key = config.quit_key or ""

    if M.from_mode == "v" or M.from_mode == "V" then
      special_keys_for_mode = { next_key, prev_key, skip_key }
    elseif M.from_mode == "n" then
      special_keys_for_mode = { next_key }
    end

    local is_special = false
    local is_quit = false

    -- Try to resolve ambiguous multi-char keys
    local s_time = vim.fn.reltime()
    while true do
      local starts_special = starts_any(M.char, special_keys_for_mode)
      local starts_quit = quit_key:sub(1, #M.char) == M.char

      if not starts_special and not starts_quit then
        break
      end

      for _, sk in ipairs(special_keys_for_mode) do
        if sk == M.char then
          is_special = true
          break
        end
      end
      is_quit = (quit_key == M.char)

      if is_special or is_quit then
        break
      end

      local elapsed = tonumber(vim.fn.reltimefloat(vim.fn.reltime(s_time))) * 1000
      if elapsed > vim.o.timeoutlen then
        break
      end

      local new_char = utils.get_char(true)
      if new_char ~= "" then
        M.char = M.char .. new_char
      else
        vim.cmd("sleep 50m")
      end
    end

    -- Check for quit
    if M.char == quit_key then
      local should_exit = false
      if M.from_mode == "n" then
        should_exit = true
      elseif (M.from_mode == "v" or M.from_mode == "V") and config.exit_from_visual_mode then
        should_exit = true
      elseif M.from_mode == "i" and config.exit_from_insert_mode then
        vim.cmd("stopinsert")
        should_exit = true
      end
      if should_exit then
        cm:reset(true, true, true)
        return
      end
    end

    -- Handle special keys (next/prev/skip) → return to caller
    if is_special then
      M.saved_keys = consume_typeahead()
      return M.char, M.from_mode
    end

    -- Fan out the input to all cursors
    cm:start_loop()
    M.saved_keys = consume_typeahead()

    repeat
      local done = process_at_cursor(cm, config)
      if done then
        if M.to_mode == "v" or M.to_mode == "V" then
          local cur = cm:get_current()
          if #cur.visual > 0 then
            utils.update_visual_markers(cur.visual)
          end
        end
        handle_visual_IA_to_insert(cm)
        break
      end
    until false

    -- Continue loop with updated mode
    current_mode = M.to_mode
    if current_mode == "" then
      current_mode = M.from_mode
    end
  end
end

return M
