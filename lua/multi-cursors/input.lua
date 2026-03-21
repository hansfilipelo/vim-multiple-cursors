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

-- Pre-computed key codes
local esc = vim.api.nvim_replace_termcodes("<Esc>", true, true, true)

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
---@param from string current mode (M.to_mode from previous cursor)
---@param to string target mode (M.from_mode, what user was in)
local function revert_mode(from, to, cm)
  if to == "v" then
    cm:reapply_visual_selection()
  elseif to == "V" then
    cm:reapply_visual_selection()
    vim.cmd("normal! V")
  elseif to == "n" and from == "i" then
    -- Previous cursor ended in logical insert mode, but with feedkeys+"x"
    -- we're already in normal mode. stopinsert is a safe no-op here.
    vim.cmd("stopinsert")
  end
  -- Note: to == "i" is handled separately via atomic insert in process_at_cursor
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

--- Ensure Vim is in normal mode before repositioning
local function ensure_normal_mode()
  local m = vim.fn.mode():sub(1, 1)
  if m == "i" or m == "s" then
    vim.cmd("stopinsert")
  elseif m == "v" or m == "V" or m == "\22" then
    vim.cmd('execute "normal! \\<Esc>"')
  end
end

--- Events to suppress during feedkeys to prevent nvim-cmp, Copilot, ALE, etc.
--- from interfering with our atomic insert/normal operations.
--- NOTE: InsertEnter is intentionally NOT listed — we need it for our own
--- insert-mode detection autocmd in process_normal_at_cursor.
local suppressed_events = "InsertLeave,TextChangedI,TextChangedP,"
    .. "CursorMovedI,CompleteDone,CompleteChanged,TextChanged,CursorMoved,"
    .. "BufModifiedSet,TextYankPost"

--- Process user input at one cursor in insert mode.
--- Uses atomic "i" + char + Esc to avoid Vim's feedkeys exiting insert mode.
---@param cm CursorManager
---@param config table
---@return boolean done
local function process_insert_at_cursor(cm, config)
  local cur = cm:get_current()
  ensure_normal_mode()

  local is_exit = (M.char == esc) or (M.char == "\x03") -- Esc or Ctrl-C

  if is_exit then
    -- Exiting insert mode: position cursor one left of insert point (Vim convention)
    local exit_col = math.max(1, (cur.insert_col or cur.position[2]) - 1)
    vim.fn.cursor(cur.position[1], exit_col)
    cur.insert_col = nil

    cur:update_line_length()
    M.saved_linecount = vim.fn.line("$")
    cm._saved_linecount = M.saved_linecount

    if M.to_mode == "" then
      M.to_mode = "n"
    end
  else
    -- Atomic insert: position at insert_col, type char via "i" + char + Esc
    local ic = cur.insert_col or cur.position[2]
    vim.fn.cursor(cur.position[1], ic)

    cur:update_line_length()
    M.saved_linecount = vim.fn.line("$")
    cm._saved_linecount = M.saved_linecount

    pcall(vim.cmd, "undojoin")

    -- Suppress ALL autocmds during atomic insert — no plugin should fire
    -- during our synthetic "i" + char + Esc sequence.
    local saved_ei = vim.o.eventignore
    vim.o.eventignore = "all"

    vim.api.nvim_feedkeys("i" .. M.char .. esc, "n", false)
    vim.api.nvim_feedkeys("", "x", false)

    vim.o.eventignore = saved_ei

    -- Update insert_col: after "i" + char + Esc, cursor is on the typed char.
    -- The next insert point is one past that.
    cur.insert_col = vim.fn.col(".") + 1

    if M.to_mode == "" then
      M.to_mode = "i"
    end
  end

  cm:update_current(M.from_mode, M.to_mode)
  cm:next()
  return cm:loop_done()
end

--- Process user input at one cursor in non-insert mode.
--- Uses InsertEnter autocmd to detect transitions into insert mode,
--- since feedkeys+"x" always exits insert mode.
---@param cm CursorManager
---@param config table
---@return boolean done
local function process_normal_at_cursor(cm, config)
  local cur = cm:get_current()
  ensure_normal_mode()

  vim.fn.cursor(cur.position)
  revert_mode(M.to_mode, M.from_mode, cm)

  cur:update_line_length()
  M.saved_linecount = vim.fn.line("$")
  cm._saved_linecount = M.saved_linecount

  if M.from_mode == "n" or M.from_mode == "v" or M.from_mode == "V" then
    cur:restore_unnamed_register()
  end

  if M.to_mode == "i" then
    pcall(vim.cmd, "undojoin")
  end

  -- Detect insert mode transitions via InsertEnter autocmd
  local detected_insert = false
  local insert_col = nil
  local augroup = vim.api.nvim_create_augroup("mc_insert_detect", { clear = true })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = augroup,
    once = true,
    callback = function()
      detected_insert = true
      insert_col = vim.fn.col(".")
    end,
  })

  -- Suppress most autocmds to prevent nvim-cmp, Copilot, ALE etc. from
  -- interfering. We keep InsertEnter unblocked for our own detection above.
  local saved_ei = vim.o.eventignore
  vim.o.eventignore = suppressed_events

  vim.api.nvim_feedkeys(M.char, "", false)
  vim.api.nvim_feedkeys("", "x", false)

  vim.o.eventignore = saved_ei
  pcall(vim.api.nvim_del_augroup_by_id, augroup)

  -- Determine the resulting mode
  local new_mode
  if detected_insert then
    new_mode = "i"
    cur.insert_col = insert_col
  else
    local new_mode_raw = vim.fn.mode(1):sub(1, 1)
    if new_mode_raw == "v" or new_mode_raw == "V" or new_mode_raw == "\22" then
      if new_mode_raw == "V" then
        new_mode = "V"
      else
        new_mode = "v"
      end
    elseif new_mode_raw == "s" or new_mode_raw == "S" then
      new_mode = "v"
    else
      new_mode = "n"
    end
  end

  if M.to_mode == "" then
    M.to_mode = new_mode
    if M.to_mode == "v" then
      local vm = vim.fn.visualmode()
      if vm == "V" then
        M.to_mode = "V"
      end
    end
  end

  cm:update_current(M.from_mode, M.to_mode)
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

    -- Force full redraw to show highlights (bang clears and redraws completely)
    vim.cmd("redraw!")

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

    -- Clear echo area
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
        should_exit = true
      end
      if should_exit then
        ensure_normal_mode()
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
      local done
      if M.from_mode == "i" then
        done = process_insert_at_cursor(cm, config)
      else
        done = process_normal_at_cursor(cm, config)
      end
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

    -- After every fan-out: nuclear refresh of all highlights.
    -- Clears all extmarks and recreates them from current state.
    cm:refresh_all_highlights()

    -- In insert mode, position the Vim cursor at cursor 1's insert point
    -- so the user has a visible real cursor there too.
    if M.to_mode == "i" then
      local primary = cm:get(1)
      if primary and primary.insert_col then
        vim.fn.cursor(primary.position[1], primary.insert_col)
      end
    end

    -- Continue loop with updated mode
    current_mode = M.to_mode
    if current_mode == "" then
      current_mode = M.from_mode
    end
  end
end

return M
