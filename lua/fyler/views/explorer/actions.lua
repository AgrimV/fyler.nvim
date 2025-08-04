local a = require("fyler.lib.async")
local algos = require("fyler.views.explorer.algos")
local cache = require("fyler.cache")
local config = require("fyler.config")
local confirm_view = require("fyler.views.confirm")
local fs = require("fyler.lib.fs")
local store = require("fyler.views.explorer.store")
local ui = require("fyler.views.explorer.ui")
local util = require("fyler.lib.util")

local M = {}

local fn = vim.fn
local api = vim.api

---@param view table
function M.n_close_view(view)
  return function()
    local success = pcall(api.nvim_win_close, view.win.winid, true)
    if not success then api.nvim_win_set_buf(view.win.winid, fn.bufnr("#", true)) end

    pcall(api.nvim_buf_delete, view.win.bufnr, { force = true })
  end
end

---@param view FylerExplorerView
function M.n_select(view)
  return function()
    local key = util.match_id(api.nvim_get_current_line())
    if not key then return end

    local entry = store.get_entry(key)
    if entry:is_dir() then
      view.fs_root:find(key):toggle()
      api.nvim_exec_autocmds("User", { pattern = "RefreshView" })
    else
      local recent_win = cache.get_entry("recent_win")

      if recent_win and api.nvim_win_is_valid(recent_win) then
        fn.win_execute(recent_win, string.format("edit %s", entry:get_path()))
        fn.win_gotoid(recent_win)

        if config.values.views.explorer.close_on_select then view.win:hide() end
      end
    end
  end
end

---@param view FylerExplorerView
function M.n_select_tab(view)
  return function()
    local key = util.match_id(api.nvim_get_current_line())
    if not key then return end

    local entry = store.get_entry(key)
    if entry:is_dir() then
      view.fs_root:find(key):toggle()
      api.nvim_exec_autocmds("User", { pattern = "RefreshView" })
    else
      local recent_win = cache.get_entry("recent_win")

      if recent_win and api.nvim_win_is_valid(recent_win) then
        fn.execute(string.format("tabedit %s", entry:get_path()))

        if config.values.views.explorer.close_on_select then view.win:hide() end
      end
    end
  end
end

---@param view FylerExplorerView
function M.n_select_vsplit(view)
  return function()
    local key = util.match_id(api.nvim_get_current_line())
    if not key then return end

    local entry = store.get_entry(key)
    if not entry:is_dir() then
      local recent_win = cache.get_entry("recent_win")

      if recent_win and api.nvim_win_is_valid(recent_win) then
        fn.win_gotoid(recent_win)
        fn.execute(string.format("vsplit %s", entry:get_path()))

        if config.values.views.explorer.close_on_select then view.win:hide() end
      end
    end
  end
end

---@param view FylerExplorerView
function M.n_select_split(view)
  return function()
    local key = util.match_id(api.nvim_get_current_line())
    if not key then return end

    local entry = store.get_entry(key)
    if not entry:is_dir() then
      local recent_win = cache.get_entry("recent_win")

      if recent_win and api.nvim_win_is_valid(recent_win) then
        fn.win_gotoid(recent_win)
        fn.execute(string.format("split %s", entry:get_path()))

        if config.values.views.explorer.close_on_select then view.win:hide() end
      end
    end
  end
end

---@param tbl table
---@return table
local function get_tbl(tbl)
  local lines = {}

  if not vim.tbl_isempty(tbl.copy) then
    table.insert(lines, { { str = "COPY", hl = "FylerConfirmYellow" } })
    for _, change in ipairs(tbl.copy) do
      table.insert(lines, {
        { str = "| " },
        { str = fs.relpath(fs.getcwd(), change.src), hl = "FylerConfirmGrey" },
        { str = " > " },
        { str = fs.relpath(fs.getcwd(), change.dst), hl = "FylerConfirmGrey" },
      })
    end
    table.insert(lines, { { str = "" } })
  end

  if not vim.tbl_isempty(tbl.move) then
    table.insert(lines, { { str = "MOVE", hl = "FylerConfirmYellow" } })

    for _, change in ipairs(tbl.move) do
      table.insert(lines, {
        { str = "| " },
        { str = fs.relpath(fs.getcwd(), change.src), hl = "FylerConfirmGrey" },
        { str = " > " },
        { str = fs.relpath(fs.getcwd(), change.dst), hl = "FylerConfirmGrey" },
      })
    end

    table.insert(lines, { { str = "" } })
  end

  if not vim.tbl_isempty(tbl.create) then
    table.insert(lines, { { str = "CREATE", hl = "FylerConfirmGreen" } })

    for _, change in ipairs(tbl.create) do
      table.insert(lines, {
        { str = "| " },
        { str = fs.relpath(fs.getcwd(), change), hl = "FylerConfirmGrey" },
      })
    end

    table.insert(lines, { { str = "" } })
  end

  if not vim.tbl_isempty(tbl.delete) then
    table.insert(lines, { { str = "DELETE", hl = "FylerConfirmRed" } })

    for _, change in ipairs(tbl.delete) do
      table.insert(lines, {
        { str = "| " },
        { str = fs.relpath(fs.getcwd(), change), hl = "FylerConfirmGrey" },
      })
    end

    table.insert(lines, { { str = "" } })
  end

  return lines
end

---@param changes table
---@return boolean
local function can_bypass(changes)
  if not vim.tbl_isempty(changes.delete) then return false end

  if #changes.move > 1 then return false end

  if #changes.create > 5 then return false end

  return true
end

---@param view FylerExplorerView
function M.synchronize(view)
  return a.async(function()
    local changes = algos.compute_fs_actions(view)
    local can_sync = (function()
      if #changes.create == 0 and #changes.delete == 0 and #changes.move == 0 and #changes.copy == 0 then
        return true
      end

      if not config.values.views.explorer.confirm_simple then
        return a.await(confirm_view.open, get_tbl(changes), "(y/n)")
      end

      if can_bypass(changes) then return true end

      return a.await(confirm_view.open, get_tbl(changes), "(y/n)")
    end)()

    if can_sync then
      for _, change in ipairs(changes.copy) do
        local err, success = a.await(fs.copy, change.src, change.dst)
        if not success then vim.schedule(function() vim.notify(err, vim.log.levels.ERROR) end) end
      end

      for _, change in ipairs(changes.move) do
        local err, success = a.await(fs.move, change.src, change.dst)
        if not success then vim.schedule(function() vim.notify(err, vim.log.levels.ERROR) end) end
      end

      for _, change in ipairs(changes.create) do
        local err, success = a.await(fs.create, change)
        if not success then vim.schedule(function() vim.notify(err, vim.log.levels.ERROR) end) end
      end

      for _, change in ipairs(changes.delete) do
        local err, success = a.await(fs.delete, change)
        if not success then vim.schedule(function() vim.notify(err, vim.log.levels.ERROR) end) end
      end
    end

    vim.schedule(function() api.nvim_exec_autocmds("User", { pattern = "RefreshView" }) end)
  end)
end

---@param view FylerExplorerView
---@param on_render function
function M.refreshview(view, on_render)
  return a.async(function()
    if not (util.has_valid_winid(view.win) and util.has_valid_bufnr(view.win)) then return end

    a.await(view.fs_root.update, view.fs_root)
    vim.bo[view.win.bufnr].undolevels = -1

    view.win.ui:render {
      ui_lines = a.await(ui.Explorer, algos.tree_table_from_node(view).children),
      on_render = vim.schedule_wrap(function()
        if on_render then on_render() end
        if util.has_valid_bufnr(view.win) then
          vim.bo[view.win.bufnr].undolevels = vim.go.undolevels
          M.draw_indentscope(view)()
        end
      end),
    }
  end)
end

function M.constrain_cursor(view)
  return function()
    local cur = api.nvim_get_current_line()
    local id = util.match_id(cur)
    if not id then return end

    local _, ub = string.find(cur, id)
    if not util.has_valid_winid(view.win) then return end

    local row, col = unpack(api.nvim_win_get_cursor(view.win.winid))
    if col <= ub then api.nvim_win_set_cursor(view.win.winid, { row, ub + 1 }) end
  end
end

---@param view FylerExplorerView
function M.try_focus_buffer(view)
  return a.schedule_async(function(arg)
    local explorer = require("fyler.views.explorer")

    if arg.file == "" or not util.has_valid_winid(view.win) then return end

    if string.match(arg.file, "^fyler://*") then
      local recent_win = cache.get_entry("recent_win")
      if (type(recent_win) ~= "number") or (not api.nvim_win_is_valid(recent_win)) then return end

      local recent_bufname = fn.bufname(api.nvim_win_get_buf(recent_win))
      if recent_bufname == "" or string.match(recent_bufname, "^fyler://*") then return end

      arg.file = fs.abspath(recent_bufname)
    end

    if not vim.startswith(arg.file, view.cwd) then
      explorer.open {
        enter = fn.bufname("%") == view.win.bufname,
        cwd = fn.fnamemodify(arg.file, ":h"),
      }
    end

    local relpath = fs.relpath(view.cwd, arg.file)
    if not relpath then return end

    local focused_node = view.fs_root
    local last_visit = 0
    local parts = vim.split(relpath, "/")

    a.await(focused_node.update, focused_node)

    for i, part in ipairs(parts) do
      local child = vim
        .iter(focused_node.children)
        :find(function(child) return store.get_entry(child.id).name == part end)

      if not child then break end

      if store.get_entry(child.id):is_dir() then
        child.open = true
        a.await(child.update, child)
      end

      focused_node, last_visit = child, i
    end

    if last_visit ~= #parts then return end

    M.refreshview(view, function()
      if not util.has_valid_winid(view.win) then return end

      local buf_lines = api.nvim_buf_get_lines(view.win.bufnr, 0, -1, false)
      for ln, buf_line in ipairs(buf_lines) do
        if buf_line:find(focused_node.id) then api.nvim_win_set_cursor(view.win.winid, { ln, 0 }) end
      end
    end)()
  end)
end

local extmark_namespace = api.nvim_create_namespace("FylerIndentScope")

---@param view FylerExplorerView
function M.draw_indentscope(view)
  local function draw_line(ln)
    if not util.has_valid_bufnr(view.win) then return end

    local cur_line = unpack(api.nvim_buf_get_lines(view.win.bufnr, ln - 1, ln, false))
    local cur_indent = #util.match_indent(cur_line)
    if cur_indent == 0 then return end

    local indent_depth = math.floor(cur_indent * 0.5)
    for i = 1, indent_depth do
      api.nvim_buf_set_extmark(view.win.bufnr, extmark_namespace, ln - 1, 0, {
        hl_mode = "combine",
        virt_text = {
          {
            config.values.views.explorer.indentscope.marker,
            config.values.views.explorer.indentscope.group,
          },
        },
        virt_text_pos = "overlay",
        virt_text_win_col = (i - 1) * 2,
      })
    end
  end

  return function()
    if not util.has_valid_bufnr(view.win) then return end

    if not config.values.views.explorer.indentscope.enabled then return end

    api.nvim_buf_clear_namespace(view.win.bufnr, extmark_namespace, 0, -1)
    for i = 1, api.nvim_buf_line_count(view.win.bufnr) do
      draw_line(i)
    end
  end
end

return M
