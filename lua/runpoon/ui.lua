local runpoon = require("runpoon")
local popup = require("plenary.popup")
local Marked = require("runpoon.mark")
local utils = require("runpoon.utils")
local log = require("runpoon.dev").log

local M = {}

runpoon_win_id = nil
runpoon_bufh = nil

-- We save before we close because we use the state of the buffer as the list
-- of items.
local function close_menu(force_save)
	force_save = force_save or false
	local global_config = runpoon.get_global_settings()

	if global_config.save_on_toggle or force_save then
		require("runpoon.ui").on_menu_save()
	end

	vim.api.nvim_win_close(runpoon_win_id, true)

	runpoon_win_id = nil
	runpoon_bufh = nil
end

local function create_window()
	log.trace("_create_window()")
	local config = runpoon.get_menu_config()
	local width = config.width or 60
	local height = config.height or 10
	local borderchars = config.borderchars or { "─", "│", "─", "│", "╭", "╮", "╯", "╰" }
	local bufnr = vim.api.nvim_create_buf(false, false)

	local runpoon_win_id, win = popup.create(bufnr, {
		title = "runpoon",
		highlight = "runpoonWindow",
		line = math.floor(((vim.o.lines - height) / 2) - 1),
		col = math.floor((vim.o.columns - width) / 2),
		minwidth = width,
		minheight = height,
		borderchars = borderchars,
	})

	vim.api.nvim_win_set_option(win.border.win_id, "winhl", "Normal:runpoonBorder")

	return {
		bufnr = bufnr,
		win_id = runpoon_win_id,
	}
end

local function get_menu_items()
	log.trace("_get_menu_items()")
	local lines = vim.api.nvim_buf_get_lines(runpoon_bufh, 0, -1, true)
	local indices = {}

	for _, line in pairs(lines) do
		if not utils.is_white_space(line) then
			table.insert(indices, line)
		end
	end

	return indices
end

function M.toggle_quick_menu()
	log.trace("toggle_quick_menu()")
	if runpoon_win_id ~= nil and vim.api.nvim_win_is_valid(runpoon_win_id) then
		close_menu()
		return
	end

	local curr_file = utils.normalize_path(vim.api.nvim_buf_get_name(0))
	vim.cmd(
		string.format(
			"autocmd Filetype runpoon "
				.. "let path = '%s' | call clearmatches() | "
				-- move the cursor to the line containing the current filename
				.. "call search('\\V'.path.'\\$') | "
				-- add a hl group to that line
				.. "call matchadd('runpoonCurrentFile', '\\V'.path.'\\$')",
			curr_file:gsub("\\", "\\\\")
		)
	)

	local win_info = create_window()
	local contents = {}
	local global_config = runpoon.get_global_settings()

	runpoon_win_id = win_info.win_id
	runpoon_bufh = win_info.bufnr

	for idx = 1, Marked.get_length() do
		local file = Marked.get_marked_file_name(idx)
		if file == "" then
			file = "(empty)"
		end
		contents[idx] = string.format("%s", file)
	end

	vim.api.nvim_win_set_option(runpoon_win_id, "number", true)
	vim.api.nvim_buf_set_name(runpoon_bufh, "runpoon-menu")
	vim.api.nvim_buf_set_lines(runpoon_bufh, 0, #contents, false, contents)
	vim.api.nvim_buf_set_option(runpoon_bufh, "filetype", "runpoon")
	vim.api.nvim_buf_set_option(runpoon_bufh, "buftype", "acwrite")
	vim.api.nvim_buf_set_option(runpoon_bufh, "bufhidden", "delete")
	vim.api.nvim_buf_set_keymap(
		runpoon_bufh,
		"n",
		"q",
		"<Cmd>lua require('runpoon.ui').toggle_quick_menu()<CR>",
		{ silent = true }
	)
	vim.api.nvim_buf_set_keymap(
		runpoon_bufh,
		"n",
		"<ESC>",
		"<Cmd>lua require('runpoon.ui').toggle_quick_menu()<CR>",
		{ silent = true }
	)
	vim.api.nvim_buf_set_keymap(runpoon_bufh, "n", "<CR>", "<Cmd>lua require('runpoon.ui').select_menu_item()<CR>", {})
	vim.cmd(string.format("autocmd BufWriteCmd <buffer=%s> lua require('runpoon.ui').on_menu_save()", runpoon_bufh))
	if global_config.save_on_change then
		vim.cmd(
			string.format(
				"autocmd TextChanged,TextChangedI <buffer=%s> lua require('runpoon.ui').on_menu_save()",
				runpoon_bufh
			)
		)
	end
	vim.cmd(string.format("autocmd BufModifiedSet <buffer=%s> set nomodified", runpoon_bufh))
	vim.cmd("autocmd BufLeave <buffer> ++nested ++once silent lua require('runpoon.ui').toggle_quick_menu()")
end

function M.select_menu_item()
	local idx = vim.fn.line(".")
	close_menu(true)
	M.run_file(idx)
end

function M.on_menu_save()
	log.trace("on_menu_save()")
	Marked.set_mark_list(get_menu_items())
end

local function get_or_create_buffer(filename)
	local buf_exists = vim.fn.bufexists(filename) ~= 0
	if buf_exists then
		return vim.fn.bufnr(filename)
	end

	return vim.fn.bufadd(filename)
end

function M.run_file(id)
	log.trace("run_file(): Launching ", id)
	local idx = Marked.get_index_of(id)
	if not Marked.valid_index(idx) then
		log.debug("run_file(): No mark exists for id", id)
		return
	end

	local mark = Marked.get_marked_file(idx)
	local filename = vim.fs.normalize(mark.filename)

	local commands = require("runpoon.commands").commands
	local file_type = vim.fn.fnamemodify(filename, ":e")

	if not file_type then
		vim.notify("No filetype found for " .. filename)
		return
	end

	local toExecute = commands[file_type]

	if not toExecute then
		vim.notify("No command found for filetype " .. file_type)
		return
	end

	vim.notify("Running " .. filename)

	if type(toExecute) == "string" then
		toExecute = { toExecute }
	end

	for _, command in pairs(toExecute) do
		command = string.gsub(command, "%%", filename)
		vim.cmd(command)
	end
end

function M.location_window(options)
	local default_options = {
		relative = "editor",
		style = "minimal",
		width = 30,
		height = 15,
		row = 2,
		col = 2,
	}
	options = vim.tbl_extend("keep", options, default_options)

	local bufnr = options.bufnr or vim.api.nvim_create_buf(false, true)
	local win_id = vim.api.nvim_open_win(bufnr, true, options)

	return {
		bufnr = bufnr,
		win_id = win_id,
	}
end

function M.notification(text)
	local win_stats = vim.api.nvim_list_uis()[1]
	local win_width = win_stats.width

	local prev_win = vim.api.nvim_get_current_win()

	local info = M.location_window({
		width = 20,
		height = 2,
		row = 1,
		col = win_width - 21,
	})

	vim.api.nvim_buf_set_lines(info.bufnr, 0, 5, false, { "!!! Notification", text })
	vim.api.nvim_set_current_win(prev_win)

	return {
		bufnr = info.bufnr,
		win_id = info.win_id,
	}
end

function M.close_notification(bufnr)
	vim.api.nvim_buf_delete(bufnr)
end

function M.nav_next()
	log.trace("nav_next()")
	local current_index = Marked.get_current_index()
	local number_of_items = Marked.get_length()

	if current_index == nil then
		current_index = 1
	else
		current_index = current_index + 1
	end

	if current_index > number_of_items then
		current_index = 1
	end
	M.run_file(current_index)
end

function M.nav_prev()
	log.trace("nav_prev()")
	local current_index = Marked.get_current_index()
	local number_of_items = Marked.get_length()

	if current_index == nil then
		current_index = number_of_items
	else
		current_index = current_index - 1
	end

	if current_index < 1 then
		current_index = number_of_items
	end

	M.run_file(current_index)
end

return M
