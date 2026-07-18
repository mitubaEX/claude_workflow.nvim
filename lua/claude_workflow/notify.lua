-- Per-cwd activity flags for the claude :terminal in that cwd.
-- Bufferline's name_formatter (or any other UI) can call `pending(cwd)` and
-- prepend a marker to the matching tab, so the user can see which worktree's
-- claude has gone idle while they were elsewhere.
--
-- Two flags, both driven by the same output-activity signal:
--   busy(cwd)     true while claude is actively streaming output (the buffer
--                 keeps changing — generation/spinner running), false once the
--                 output has been silent for IDLE_MS.
--   pending(cwd)  true once the output settles *and* the buffer is hidden, i.e.
--                 claude finished while you were elsewhere and you should look.

local M = {}

-- cwd -> { pending = bool, busy = bool, timer = uv_timer, buf = number }
local state = {}

-- Output is considered "settled" after this many ms of silence — that's when
-- we decide claude has stopped streaming and the user might want to look.
local IDLE_MS = 1500

local augroup = vim.api.nvim_create_augroup("ClaudeNotify", { clear = true })

local function buf_visible_in_current_tab(buf)
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(win) == buf then
			return true
		end
	end
	return false
end

local function set_pending(cwd, val)
	local entry = state[cwd]
	if not entry then
		return
	end
	if entry.pending == val then
		return
	end
	entry.pending = val
	vim.schedule(function()
		pcall(vim.cmd, "redrawtabline")
		-- Public extension point: the tab-title integration (and any other
		-- consumer) reacts to this instead of polling pending().
		pcall(vim.api.nvim_exec_autocmds, "User", {
			pattern = "ClaudeWorkflowPending",
			data = { cwd = cwd, pending = val },
		})
	end)
end

-- Flip the busy flag, notifying only on a real change (on_lines fires on every
-- streamed line, so without this guard the User event would spam). Fired as its
-- own event so the tab-title integration can react the moment generation
-- starts/stops without polling.
local function set_busy(cwd, val)
	local entry = state[cwd]
	if not entry then
		return
	end
	if entry.busy == val then
		return
	end
	entry.busy = val
	vim.schedule(function()
		pcall(vim.cmd, "redrawtabline")
		pcall(vim.api.nvim_exec_autocmds, "User", {
			pattern = "ClaudeWorkflowBusy",
			data = { cwd = cwd, busy = val },
		})
	end)
end

function M.pending(cwd)
	local entry = state[cwd]
	return entry and entry.pending or false
end

function M.busy(cwd)
	local entry = state[cwd]
	return entry and entry.busy or false
end

--- Snapshot of every watched session's flags — for integrations (e.g. herdr)
--- that need the aggregate across cwds rather than a single cwd's flag.
--- @return table[] list of { cwd = string, busy = bool, pending = bool }
function M.sessions()
	local out = {}
	for cwd, entry in pairs(state) do
		table.insert(out, { cwd = cwd, busy = entry.busy, pending = entry.pending })
	end
	return out
end

function M.clear(cwd)
	set_pending(cwd, false)
end

-- Session lifecycle event: fired when a claude terminal starts being watched
-- (running = true) and when its buffer goes away (running = false), so
-- integrations learn about session open/close without polling sessions().
local function fire_session(cwd, running)
	vim.schedule(function()
		pcall(vim.api.nvim_exec_autocmds, "User", {
			pattern = "ClaudeWorkflowSession",
			data = { cwd = cwd, running = running },
		})
	end)
end

local function close_timer(entry)
	if entry and entry.timer then
		entry.timer:stop()
		entry.timer:close()
		entry.timer = nil
	end
end

function M.watch(buf, cwd)
	-- Wipe any prior watcher for this cwd (reuse can happen if a buffer dies
	-- and gets recreated under the same cwd key).
	close_timer(state[cwd])

	local entry = { pending = false, busy = false, buf = buf, timer = vim.loop.new_timer() }
	state[cwd] = entry

	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function()
			if not entry.timer then
				return
			end
			-- Output is moving -> claude is working. (Setting a table field is
			-- safe in the on_lines fast-callback; set_busy only defers the API
			-- calls via vim.schedule.)
			set_busy(cwd, true)
			entry.timer:stop()
			entry.timer:start(
				IDLE_MS,
				0,
				vim.schedule_wrap(function()
					if not vim.api.nvim_buf_is_valid(buf) then
						return
					end
					-- Output has been silent for IDLE_MS: generation settled.
					set_busy(cwd, false)
					if buf_visible_in_current_tab(buf) then
						return
					end
					set_pending(cwd, true)
				end)
			)
		end,
		on_detach = function()
			close_timer(entry)
			state[cwd] = nil
			fire_session(cwd, false)
			vim.schedule(function()
				pcall(vim.cmd, "redrawtabline")
			end)
		end,
	})

	fire_session(cwd, true)

	vim.api.nvim_create_autocmd("BufEnter", {
		group = augroup,
		buffer = buf,
		callback = function()
			set_pending(cwd, false)
		end,
	})
end

-- A single TabEnter handler clears pending for any claude buffer that becomes
-- visible in the newly-entered tab — avoids creating one autocmd per buffer.
vim.api.nvim_create_autocmd("TabEnter", {
	group = augroup,
	callback = function()
		for cwd, entry in pairs(state) do
			if
				entry.buf
				and vim.api.nvim_buf_is_valid(entry.buf)
				and buf_visible_in_current_tab(entry.buf)
			then
				set_pending(cwd, false)
			end
		end
	end,
})

return M
