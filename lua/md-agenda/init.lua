local M = {}
M.ns = vim.api.nvim_create_namespace("agenda_virtual_text")

local json = vim.fn.json_decode

M.config = {
	vault_dir = nil, -- read env var by default
	state_colors = {
		TODO = "#a9dc76",
		DONE = "#404040",
		NEXT = "#a0b9ce",
		WAIT = "#fce094",
		LATER = "#fce094",
		IN_PROGRESS = "#d84b82",
	},
	property_colors = {
		fg = "#f0f0f0",
		bg = "#353535",
	},
	tag_colors = {
		bg = "#353535",
		fg = "#828282",
	},
	conceal_properties = true,
}

function M.api(cmd_body)
	local full_cmd = "agenda-core " .. cmd_body

	if M.config.vault_dir ~= nil then
		full_cmd = "AGENDA_VAULT_DIR=" .. M.config.vault_dir .. " " .. full_cmd
	end

	local handle = io.popen(full_cmd)
	if not handle then
		return nil, "Failed to execute command: " .. full_cmd
	end
	local result = handle:read("*a")
	handle:close()
	local ok, parsed = pcall(json, result)
	if not ok then
		return nil, "Failed to parse JSON: " .. result
	end
	return parsed
end

local function finalize_buffer(buf)
	-- remove first line if it's empty (always by default)
	local first_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
	if first_line == "" then
		vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
	end
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
end

local function cmd_agenda_task_goto()
	local buf = vim.api.nvim_get_current_buf()
	local bt = vim.api.nvim_buf_get_option(buf, "buftype")

	if bt ~= "nofile" then
		print("Error: AgendaTaskGoTo can only be used from an agenda buffer")
		return
	end

	local line = vim.api.nvim_win_get_cursor(0)[1] - 1
	local extmarks = vim.api.nvim_buf_get_extmarks(buf, M.ns, { line, 0 }, { line, -1 }, { details = true })

	if extmarks and #extmarks > 0 then
		local virt = extmarks[1][4].virt_text
		if virt and #virt > 0 then
			local task_id = virt[1][1]:gsub("^id:", "")
			local filename, line_number = task_id:match("(.+):(%d+)")
			if filename and line_number then
				vim.cmd("edit " .. filename)
				vim.api.nvim_win_set_cursor(0, { tonumber(line_number), 0 })
			else
				print("Invalid task id format: " .. task_id)
			end
			return
		end
	end
	print("No task ID found on this line")
end

function M.open_agenda_buffer(last_cmd)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(buf)

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = true

	vim.b[buf].agenda_last_cmd = last_cmd

	vim.api.nvim_buf_set_keymap(buf, "n", "<CR>", "", {
		callback = function()
			cmd_agenda_task_goto()
		end,
		noremap = true,
		silent = true,
	})

	return buf
end

function M.render_line(buf, text, virt_text)
	local line_count = vim.api.nvim_buf_line_count(buf)
	vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { text or "" })

	if virt_text then
		vim.api.nvim_buf_set_extmark(buf, M.ns, line_count, 0, {
			virt_text = { { virt_text, "AgendaMetadata" } },
			virt_text_pos = "eol",
		})
	end
end

-- tmp 4th argument
function RenderTasks(buf, tasks, padding, include_hour)
	include_hour = include_hour or false
	padding = padding or 0
	for _, task in ipairs(tasks) do
		RenderTask(buf, task, padding, include_hour)
	end
end

function RenderTask(buf, task, padding, include_hour)
	padding = padding or 0
	include_hour = include_hour or false
	local indent = string.rep(" ", padding)
	local content = task.content or ""

	local prefix = ""
	-- TURBO MVP
	if include_hour then
		local scheduled = task.properties and task.properties["scheduled"]
		if scheduled then
			local _, time = scheduled:match("(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")

			if time then
				prefix = " " .. time .. " "
			else
				prefix = "       "
			end
		else
			prefix = "       "
		end
	end

	for key, value in pairs(task.properties) do
		content = content .. " @" .. key .. "(" .. value .. ")"
	end

	for _, value in ipairs(task.tags) do
		content = content .. " #" .. value
	end

	M.render_line(buf, prefix .. indent .. task.state .. " " .. content, "id:" .. task.id)

	if task.children and #task.children > 0 then
        -- dont include hour but reserve space for it
        -- if subtask has hour and is in the same day, it will be rendered independent of parent anyway
		RenderTasks(buf, task.children, padding + 2, include_hour)
	end
end

local function list_tasks(buf)
	local tasks, err = M.api("get")
	if not tasks then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Error: " .. err })
		return
	end
	RenderTasks(buf, tasks)
end

local function tasks_remove_property(tasks, property)
	for _, t in pairs(tasks) do
		t.properties[property] = nil
	end
end

local function date_format(date)
	local year, month, day = date:match("^(%d+)%-(%d+)%-(%d+)$")
	if not (year and month and day) then
		return date
	end

	local time = os.time({ year = year, month = month, day = day })
	local weekday = os.date("%A", time) -- localized weekday name
	return string.format("%s %s", weekday, date)
end

local function list_tasks_by_date(buf)
	local grouped, err = M.api("get --group date")
	if not grouped then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Error: " .. err })
		return
	end

	local keys_ordered = {}
	for date, _ in pairs(grouped) do
		table.insert(keys_ordered, date)
	end
	table.sort(keys_ordered)

	local today = os.date("%Y-%m-%d")

	for _, date in ipairs(keys_ordered) do
		local tasks = grouped[date]
		local date_formatted = date_format(date)
		local is_today = (date == today)

		if is_today then
			date_formatted = "TODAY " .. date_formatted
		end

		M.render_line(buf, date_formatted, "")
		-- tasks_remove_property(tasks, "scheduled")
		RenderTasks(buf, tasks, 2, true)
		M.render_line(buf, "", "")
	end
end

local function list_tasks_by_tag(buf)
	local grouped, err = M.api("get --group tag")
	if not grouped then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Error: " .. err })
		return
	end
	for date, tasks in pairs(grouped) do
		M.render_line(buf, date, "")
		RenderTasks(buf, tasks, 4)
		M.render_line(buf, "", "")
	end
end

local function open_task_by_id(task_id)
	local buf = M.open_agenda_buffer(function()
		open_task_by_id(task_id)
	end)

	local task, err = M.api("get --task-id " .. task_id)
	if not task then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Error: " .. err })
		return
	end
	task = task.task
	RenderTask(buf, task)
	finalize_buffer(buf)
end

local function go_to_parent_task(task_id)
	local task, err = M.api("get --parent-of " .. task_id)

	if task == nil or task == vim.NIL or task.task == nil or task.task == vim.NIL then
		print("Error: this task doesn't seem to have a parent")
		return
	end

	local buf = M.open_agenda_buffer(function()
		go_to_parent_task(task_id)
	end)
	RenderTask(buf, task.task)
	finalize_buffer(buf)
end

function M.cmd_agenda_list()
	local buf = M.open_agenda_buffer(function()
		M.cmd_agenda_list()
	end)

	list_tasks_by_date(buf)

	M.render_line(buf, "", "")
	M.render_line(buf, "", "")
	-- list_tasks(buf)
	list_tasks_by_tag(buf)

	finalize_buffer(buf)
end

function M.cmd_agenda_task_open()
	local buf = vim.api.nvim_get_current_buf()
	local ft = vim.api.nvim_buf_get_option(buf, "filetype")
	local bt = vim.api.nvim_buf_get_option(buf, "buftype")
	local task_id = nil

	if ft == "markdown" then
		local filename = vim.api.nvim_buf_get_name(buf)
		local line = vim.api.nvim_win_get_cursor(0)[1]
		task_id = filename .. ":" .. line
	elseif bt == "nofile" then
		local line = vim.api.nvim_win_get_cursor(0)[1] - 1
		local extmarks = vim.api.nvim_buf_get_extmarks(buf, M.ns, { line, 0 }, { line, -1 }, { details = true })
		if extmarks and #extmarks > 0 then
			local virt = extmarks[1][4].virt_text
			if virt and #virt > 0 then
				task_id = virt[1][1]:gsub("^id:", "")
			end
		end
	end

	if task_id then
		open_task_by_id(task_id)
	else
		local new_buf = M.open_agenda_buffer()
		vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, { "TODO" })
	end
end

local tags = { "TODO", "IN_PROGRESS", "DONE", "NEXT", "WAIT", "LATER" }

local function get_state_from_line(line)
	for _, tag in ipairs(tags) do
		if string.find(line, "#" .. tag, 1, true) then
			return tag
		end
	end
	return nil
end

local function trim_end(s)
	return s:gsub("%s+$", "")
end

local function get_property_default_value(key)
	if key == "scheduled" then
		local today = os.date("%Y-%m-%d")
		return today
	end
	return ""
end

local function should_eval_date(key)
	-- should read from user defined config someday
	if key == "scheduled" then
		return true
	end
	return false
end

-- natural language date
local function has_time(date_input)
	-- this doesnt handle inputs like 'jan 2', 'jan 2 12:30'
	-- TODO: handle numeral date inputs
	return date_input:match("%d") or date_input == "now"
end

local function eval_date(value)
	-- already valid?
	if value:match("^%d%d%d%d%-%d%d%-%d%d$") or value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d$") then
		return value
	end

	-- GNU date parses natural language
	local cmd = string.format([[date -d %q +"%%Y-%%m-%%dT%%H:%%M"]], value)

	local out = vim.fn.system(cmd):gsub("%s+$", "")
	if vim.v.shell_error ~= 0 then
		print("invalid date format - coulnd't parse")
		return nil
	end

	if has_time(value) then
		return out
	end

	return out:sub(1, 10)
end

local function task_set_property(property_key)
	local row = vim.api.nvim_win_get_cursor(0)[1] -- current line number
	local line = vim.api.nvim_get_current_line()
	local buf = vim.api.nvim_get_current_buf()
	local bt = vim.api.nvim_buf_get_option(buf, "buftype")

	-- agenda buffer
	if bt == "nofile" and vim.b[buf].agenda_last_cmd then
		-- local state = get_state_from_line(line)
		-- if not state then
		-- 	print("There is no task on this line")
		-- 	return
		-- end

		local task_id = nil
		local extmarks = vim.api.nvim_buf_get_extmarks(buf, M.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })
		if extmarks and #extmarks > 0 then
			local virt = extmarks[1][4].virt_text
			if virt and #virt > 0 then
				task_id = virt[1][1]:gsub("^id:", "")
			end
		end

		local default_value = get_property_default_value(property_key)
		local pattern = "@" .. property_key .. "%b()"
		local match = line:match(pattern)
		if match then
			default_value = match:sub(#property_key + 3, -2)
		end

		vim.ui.input({ prompt = property_key .. ": ", default = default_value }, function(input)
			if not input then
				return
			end

			local value = input
			if value and value ~= "" and should_eval_date(property_key) then
				value = eval_date(value)
				if not value then
					return
				end
			end

			if task_id then
				local ok, err =
					M.api(string.format("change --task-id %s --property %s %s", task_id, property_key, value))
				if not ok then
					print("Error changing property:", err)
					return
				end

				local last_cmd = vim.b[buf].agenda_last_cmd
				if type(last_cmd) == "function" then
					last_cmd()
					vim.api.nvim_win_set_cursor(0, { tonumber(row), 0 })
				end
			end
		end)
	else
		-- regular buffer
		if get_state_from_line(line) == nil then
			print("There is no task on this line")
			return
		end

		local default_value = ""
		local pattern = "@" .. property_key .. "%b()"
		local match = line:match(pattern)
		if match then
			default_value = match:sub(#property_key + 3, -2)
		else
			default_value = get_property_default_value(property_key)
		end

		vim.ui.input({ prompt = property_key .. ": ", default = default_value }, function(input)
			if input == nil or input == "" then
				line = trim_end(line):gsub("@" .. property_key .. "%b()", "")
				vim.api.nvim_buf_set_lines(0, row - 1, row, false, { trim_end(line) or "" })
				return
			end

			local value = input
			if should_eval_date(property_key) then
				value = eval_date(value)
				if not value then
					return
				end
			end

			if line:match(pattern) then
				line = line:gsub(pattern, "@" .. property_key .. "(" .. value .. ")")
			else
				line = trim_end(line) .. " @" .. property_key .. "(" .. value .. ")"
			end

			vim.api.nvim_buf_set_lines(0, row - 1, row, false, { line })
		end)
	end
end

-- local function task_set_property(property_key)
-- 	local row = vim.api.nvim_win_get_cursor(0)[1] -- current line number
-- 	local line = vim.api.nvim_get_current_line()
--
-- 	-- TODO: check if agenda buffer
-- 	--   if so, delegate property change to agenda and refresh the buffer
-- 	--     (as mvp just rerun last command and set cursor back to prev pos)
-- 	if get_state_from_line(line) == nil then
-- 		print("there is no task on this line")
-- 		return
-- 	end
--
-- 	local default_value = ""
-- 	local pattern = "@" .. property_key .. "%b()"
-- 	local match = line:match(pattern)
-- 	if match then
-- 		-- remove `@property_key(` and trailing `)`
-- 		default_value = match:sub(#property_key + 3, -2)
-- 	else
-- 		default_value = get_property_default_value(property_key)
-- 	end
--
-- 	vim.ui.input({ prompt = property_key .. ": ", default = default_value }, function(input)
-- 		if input == nil or input == "" then
-- 			line = trim_end(line):gsub("@" .. property_key .. "%b()", "")
-- 			vim.api.nvim_buf_set_lines(0, row - 1, row, false, { trim_end(line) or "" })
-- 			return
-- 		end
--
-- 		local value = input
--
-- 		if should_eval_date(property_key) then
-- 			value = eval_date(value)
-- 		end
--
-- 		if line:match(pattern) then
-- 			line = line:gsub(pattern, "@" .. property_key .. "(" .. value .. ")")
-- 		else
-- 			line = trim_end(line) .. " @" .. property_key .. "(" .. value .. ")"
-- 		end
--
-- 		vim.api.nvim_buf_set_lines(0, row - 1, row, false, { line })
-- 	end)
-- end

local function get_next_state(current_state)
	current_state = current_state:gsub("^#", "")
	return M.api("get --next-state " .. current_state)
end

function M.cmd_agenda_state_cycle()
	local line = vim.api.nvim_get_current_line()

	local state = get_state_from_line(line)

	if state then
		local new_state = get_next_state(state)
		line = line:gsub("#" .. state, "#" .. new_state)

		local row = vim.api.nvim_win_get_cursor(0)[1]
		vim.api.nvim_buf_set_lines(0, row - 1, row, false, { line })
		return
	else
		local bullet_pattern = "^%s*([%*%-%+])%s(.*)"
		local heading_pattern = "^#%s"

		if string.match(line, bullet_pattern) then
			local indent, bullet, content = string.match(line, "^(%s*)([%*%-%+])%s(.*)")
			line = string.format("%s%s #TODO %s", indent, bullet, content)
		elseif string.match(line, heading_pattern) then
			return
		else
			line = "* #TODO " .. line
		end

		local row = vim.api.nvim_win_get_cursor(0)[1]
		vim.api.nvim_buf_set_lines(0, row - 1, row, false, { line })
	end
end

local function cmd_agenda_go_to_parent()
	local buf = vim.api.nvim_get_current_buf()
	local ft = vim.api.nvim_buf_get_option(buf, "filetype")
	local bt = vim.api.nvim_buf_get_option(buf, "buftype")
	local task_id = nil

	if bt ~= "nofile" then
		print("Error: AgendaTaskGoTo can only be used from an agenda buffer")
		return
	end

	-- TODO: DRY
	local line = vim.api.nvim_win_get_cursor(0)[1] - 1
	local extmarks = vim.api.nvim_buf_get_extmarks(buf, M.ns, { line, 0 }, { line, -1 }, { details = true })
	if extmarks and #extmarks > 0 then
		local virt = extmarks[1][4].virt_text
		if virt and #virt > 0 then
			task_id = virt[1][1]:gsub("^id:", "")
		end
	end

	if task_id then
		go_to_parent_task(task_id)
	else
		local new_buf = M.open_agenda_buffer()
		vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, { "TODO" })
	end
end

local function list_tasks_today(buf)
	local grouped, err = M.api("get --group date")
	if not grouped then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Error: " .. err })
		return
	end

	local today = os.date("%Y-%m-%d")
	local today_tasks = grouped[today] or {}
	local overdue = {}

	-- collect overdue tasks
	for date, tasks in pairs(grouped) do
		if date < today then
			table.insert(overdue, { date = date, tasks = tasks })
		end
	end

	table.sort(overdue, function(a, b)
		return a.date < b.date
	end)

	M.render_line(buf, "TODAY", "")
	-- tasks_remove_property(today_tasks, "scheduled")
	RenderTasks(buf, today_tasks, 4, true)
	M.render_line(buf, "", "")

	if #overdue > 0 then
		M.render_line(buf, "OVERDUE", "")
		for _, entry in ipairs(overdue) do
			local date_formatted = "  " .. date_format(entry.date)
			M.render_line(buf, date_formatted, "")
			tasks_remove_property(entry.tasks, "scheduled")
			RenderTasks(buf, entry.tasks, 6, true)
			M.render_line(buf, "", "")
		end
	end
end

function M.cmd_agenda_today()
	local buf = M.open_agenda_buffer(function()
		M.cmd_agenda_today()
	end)
	list_tasks_today(buf)
	finalize_buffer(buf)
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	vim.api.nvim_create_user_command("AgendaList", function()
		M.cmd_agenda_list()
	end, {})
	vim.api.nvim_create_user_command("AgendaTaskGoTo", function()
		cmd_agenda_task_goto()
	end, {})
	vim.api.nvim_create_user_command("AgendaTaskOpen", function()
		M.cmd_agenda_task_open()
	end, {})
	vim.api.nvim_create_user_command("AgendaStateCycle", function()
		M.cmd_agenda_state_cycle()
	end, {})
	vim.api.nvim_create_user_command("AgendaSetProperty", function(arg)
		local key = arg.args
		task_set_property(key)
	end, { nargs = 1 })

	vim.api.nvim_create_user_command("AgendaParentGoTo", function()
		cmd_agenda_go_to_parent()
	end, {})

	vim.api.nvim_create_user_command("AgendaToday", function()
		M.cmd_agenda_today()
	end, {})

	M.setup_highlighting()
end

function M.setup_highlighting()
	-- Define highlight groups
	for state, color in pairs(M.config.state_colors) do
		vim.api.nvim_set_hl(0, "AgendaState" .. state, { fg = color, bold = true })
	end

	local property_colors = M.config.property_colors or {
		fg = "#88ccff",
		bg = "#2a3f5f",
	}
	local tag_colors = M.config.tag_colors or { fg = "#828282", bg = "#353535" }

	vim.api.nvim_set_hl(0, "AgendaProperty", { fg = property_colors.fg, bg = property_colors.bg })
	if M.config.conceal_properties then
		vim.api.nvim_set_hl(0, "AgendaPropertyDelim", { fg = property_colors.bg, bg = property_colors.bg })
	else
		vim.api.nvim_set_hl(0, "AgendaPropertyDelim", { fg = property_colors.fg, bg = property_colors.bg })
	end
	vim.api.nvim_set_hl(0, "AgendaTag", { fg = tag_colors.fg, bg = tag_colors.bg, bold = true })

	local function apply_syntax()
		local bufnr = vim.api.nvim_get_current_buf()
		local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
		local bt = vim.api.nvim_buf_get_option(bufnr, "buftype")

		-- Properties
		if ft == "markdown" or bt == "nofile" then
			vim.cmd([[syntax match AgendaProperty /@\w\+([^)]*)/ contains=AgendaPropertyDelim containedin=ALL]])
			vim.cmd([[syntax match AgendaPropertyDelim /@\|(\|)/ contained]])
		else
			vim.cmd([[syntax match AgendaProperty /@\w\+([^)]*)/ containedin=ALL]])
		end

		-- Conceal only the '#' for state tags
		if ft == "markdown" then
			for state, _ in pairs(M.config.state_colors) do
				-- Match the '#' only if followed by the state word
				vim.cmd(string.format([[syntax match AgendaHashConceal /#\ze%s\>/ conceal containedin=ALL]], state))
			end
			vim.opt_local.conceallevel = 2
			vim.opt_local.concealcursor = "nc"
		end

		-- Highlight the state word itself (without '#')
		for state, _ in pairs(M.config.state_colors) do
			vim.cmd(string.format([[syntax match AgendaState%s /%s/ containedin=ALL]], state, state))
		end
	end

	local augroup = vim.api.nvim_create_augroup("AgendaHighlighting", { clear = true })

	vim.api.nvim_create_autocmd({ "Syntax", "FileType" }, {
		group = augroup,
		pattern = { "markdown" },
		callback = function()
			vim.schedule(apply_syntax)
		end,
	})

	vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
		group = augroup,
		pattern = { "*.md", "*.markdown" },
		callback = function()
			vim.schedule(apply_syntax)
		end,
	})

	vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
		group = augroup,
		callback = function()
			local bt = vim.api.nvim_buf_get_option(0, "buftype")
			if bt == "nofile" then
				vim.schedule(function()
					apply_syntax()
					local normal_bg = vim.api.nvim_get_hl(0, { name = "Normal" }).bg
					if normal_bg then
						local bg_hex = string.format("#%06x", normal_bg)
						vim.api.nvim_set_hl(0, "AgendaMetadata", { fg = bg_hex, bg = bg_hex })
					else
						vim.api.nvim_set_hl(0, "AgendaMetadata", { fg = "#1e1e1e", bg = "#1e1e1e" })
					end
				end)
			end
		end,
	})

	vim.schedule(function()
		for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(bufnr) then
				local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
				if ft == "markdown" then
					-- Switch to buffer, apply syntax, switch back
					local current = vim.api.nvim_get_current_buf()
					vim.api.nvim_set_current_buf(bufnr)
					apply_syntax()
					if vim.api.nvim_buf_is_valid(current) then
						vim.api.nvim_set_current_buf(current)
					end
				end
			end
		end
	end)
end

return M
