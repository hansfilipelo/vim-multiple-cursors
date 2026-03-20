local Cursor = require("multi-cursors.cursor")
local highlight = require("multi-cursors.highlight")
local utils = require("multi-cursors.utils")

---@class CursorManager
---@field cursors Cursor[]
---@field current_index number 1-based, or 0 if empty
---@field starting_index number 1-based
---@field saved_settings table
---@field saved_winview table|nil
---@field start_from_find boolean
---@field bufnr number
---@field before_called boolean
---@field paste_buffer_temp_text string
---@field paste_buffer_temp_type string
local CursorManager = {}
CursorManager.__index = CursorManager

--- Create a new CursorManager
---@return CursorManager
function CursorManager.new()
  local self = setmetatable({}, CursorManager)
  self.cursors = {}
  self.current_index = 0
  self.starting_index = 0
  self.saved_settings = {}
  self.saved_winview = nil
  self.start_from_find = false
  self.bufnr = 0
  self.before_called = false
  self.paste_buffer_temp_text = ""
  self.paste_buffer_temp_type = ""
  return self
end

--- Fire pre-trigger hooks (User autocommand + legacy function)
function CursorManager:fire_pre_triggers()
  if not self.before_called then
    vim.cmd("silent! doautocmd User MultipleCursorsPre")
    if vim.fn.exists("*Multiple_cursors_before") == 1 then
      vim.fn["Multiple_cursors_before"]()
    end
    self.before_called = true
  end
end

--- Fire post-trigger hooks
function CursorManager:fire_post_triggers()
  if self.before_called then
    if vim.fn.exists("*Multiple_cursors_after") == 1 then
      vim.fn["Multiple_cursors_after"]()
    end
    vim.cmd("silent! doautocmd User MultipleCursorsPost")
    self.before_called = false
  end
end

--- Initialize settings when entering multicursor mode
function CursorManager:initialize()
  self.bufnr = vim.api.nvim_get_current_buf()
  self.saved_settings = {
    virtualedit = vim.o.virtualedit,
    cursorline = vim.o.cursorline,
    lazyredraw = vim.o.lazyredraw,
    paste = vim.o.paste,
    clipboard = vim.o.clipboard,
  }
  vim.o.virtualedit = "onemore"
  vim.o.cursorline = false
  vim.o.lazyredraw = true
  vim.o.paste = false
  -- Remove unnamed/unnamedplus from clipboard
  local cb = vim.o.clipboard
  cb = cb:gsub("unnamed%+?", ""):gsub(",,", ","):gsub("^,", ""):gsub(",$", "")
  vim.o.clipboard = cb

  if not self.start_from_find then
    self.saved_winview = vim.fn.winsaveview()
  end

  -- Save unnamed register
  self.paste_buffer_temp_text = vim.fn.getreg('"')
  self.paste_buffer_temp_type = vim.fn.getregtype('"')
end

--- Restore user settings when leaving multicursor mode
function CursorManager:restore_settings()
  if next(self.saved_settings) then
    vim.o.virtualedit = self.saved_settings.virtualedit or ""
    vim.o.cursorline = self.saved_settings.cursorline or false
    vim.o.lazyredraw = self.saved_settings.lazyredraw or false
    vim.o.paste = self.saved_settings.paste or false
    vim.o.clipboard = self.saved_settings.clipboard or ""
  end
  -- Restore unnamed register
  vim.fn.setreg('"', self.paste_buffer_temp_text, self.paste_buffer_temp_type)
end

--- Reset all cursors, optionally restoring view and settings
---@param restore_view boolean
---@param restore_setting boolean
---@param fire_post boolean|nil
function CursorManager:reset(restore_view, restore_setting, fire_post)
  if restore_view then
    if self.saved_winview then
      vim.fn.winrestview(self.saved_winview)
    end
    if not self:is_empty() and not self.start_from_find then
      vim.fn.cursor(self:get(1).position)
    end
  end

  -- Destroy all cursor highlights
  for _, c in ipairs(self.cursors) do
    c:destroy()
  end

  self.cursors = {}
  self.current_index = 0
  self.starting_index = 0
  self.saved_winview = nil
  self.start_from_find = false

  if restore_setting then
    self:restore_settings()
  end

  if fire_post then
    self:fire_post_triggers()
  end
end

--- Is the cursor list empty?
---@return boolean
function CursorManager:is_empty()
  return #self.cursors == 0
end

--- Return number of cursors
---@return number
function CursorManager:size()
  return #self.cursors
end

--- Get current cursor
---@return Cursor
function CursorManager:get_current()
  return self.cursors[self.current_index]
end

--- Get cursor at index (1-based)
---@param i number
---@return Cursor
function CursorManager:get(i)
  return self.cursors[i]
end

--- Delete the current cursor and adjust index
function CursorManager:delete_current()
  local cur = self:get_current()
  cur:destroy()
  table.remove(self.cursors, self.current_index)
  self.current_index = self.current_index - 1
  if self.current_index < 1 and #self.cursors > 0 then
    self.current_index = #self.cursors
  end
end

--- Add a new cursor at pos. Optionally with a visual region.
--- Returns true if added, false if duplicate.
---@param pos number[]
---@param region number[][]|nil
---@return boolean
function CursorManager:add(pos, region)
  -- Lazy init
  if self:is_empty() then
    self:initialize()
  end

  -- Don't add duplicates
  for _, c in ipairs(self.cursors) do
    if utils.pos_equal(c.position, pos) then
      return false
    end
  end

  local cursor = Cursor.new(pos, self.bufnr)
  if region then
    cursor:update_visual_selection(region)
  end

  table.insert(self.cursors, cursor)
  self.current_index = #self.cursors
  return true
end

--- Advance to next cursor (wrapping)
function CursorManager:next()
  self.current_index = (self.current_index % self:size()) + 1
end

--- Start the replay loop from cursor 1
function CursorManager:start_loop()
  self.current_index = 1
  self.starting_index = 1
end

--- Check if we've completed a full loop
---@return boolean
function CursorManager:loop_done()
  return self.current_index == self.starting_index
end

--- Update current cursor from Vim's actual cursor state.
--- Adjusts other cursors if line count or columns changed.
---@param from_mode string
---@param to_mode string
---@return boolean changed
function CursorManager:update_current(from_mode, to_mode)
  local cur = self:get_current()

  if to_mode == "v" or to_mode == "V" then
    if to_mode == "V" then
      vim.cmd([[normal! gvv\<Esc>]])
    end
    vim.cmd([[normal! gv\<Esc>]])
    cur:update_visual_selection(utils.get_visual_region(utils.pos(".")), to_mode)
  elseif from_mode == "v" or from_mode == "V" then
    cur:save_unnamed_register()
    cur:remove_visual_selection()
  elseif from_mode == "i" and to_mode == "n" and self.current_index ~= 1 then
    vim.cmd("normal! h")
  elseif from_mode == "n" then
    cur:save_unnamed_register()
  end

  local pos = utils.pos(".")
  local saved_linecount = self._saved_linecount or vim.fn.line("$")
  local vdelta = vim.fn.line("$") - saved_linecount

  if vdelta ~= 0 then
    if self.current_index ~= self:size() then
      local cur_col_offset = (cur:column() - vim.fn.col(".")) * -1
      local new_line_length = #vim.fn.getline(".")
      for i = self.current_index + 1, self:size() do
        local c = self:get(i)
        local hdelta = 0
        if cur:line() == c:line() or utils.pos_equal(cur.position, pos) then
          if vdelta > 0 then
            hdelta = cur_col_offset
          else
            hdelta = new_line_length
          end
        end
        c:move(vdelta, hdelta)
      end
    end
  else
    local hdelta = vim.fn.col("$") - cur.line_length
    if hdelta ~= 0 and cur:line() == vim.fn.line(".") then
      if self.current_index ~= self:size() then
        for i = self.current_index + 1, self:size() do
          local c = self:get(i)
          if cur:line() == c:line() then
            c:move(0, hdelta)
          else
            break
          end
        end
      end
    end
  end

  if utils.pos_equal(cur.position, pos) then
    return false
  end
  cur:update_position(pos)
  return true
end

--- Reposition all cursors to start or end of their saved visual region
---@param to_start boolean
function CursorManager:reposition_all_within_region(to_start)
  for _, c in ipairs(self.cursors) do
    if #c.saved_visual > 0 then
      local idx = to_start and 1 or 2
      c:update_position(c.saved_visual[idx])
    end
  end
end

--- Reselect the current cursor's visual region
function CursorManager:reapply_visual_selection()
  local cur = self:get_current()
  if #cur.visual > 0 then
    utils.select_in_visual_mode(cur.visual)
  end
end

return CursorManager
