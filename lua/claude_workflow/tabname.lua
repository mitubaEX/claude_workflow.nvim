-- Reflect the cwd's claude session in the *outer* terminal's tab/window title.
--
-- The plugin's unit is the cwd (typically a git worktree), so the title tracks
-- the focused window's cwd:
--   ⠋ <branch>   claude is actively working (animated; see `working` config)
--   🔔 <branch>   that session has gone idle / needs attention (notify.pending)
--   🤖 <branch>   a claude session is live but idle for this cwd
--   <branch>      no claude session for this cwd
--
-- We set the title through Neovim's native 'title'/'titlestring' options rather
-- than writing the OSC escape ourselves. Neovim runs its TUI in a *separate*
-- process; the core process (where this Lua runs) has no controlling terminal,
-- so a raw `io.open("/dev/tty", "w")` fails with "Device not configured" and
-- never reaches the terminal. The TUI process, which does own the terminal,
-- emits the proper title sequence for us (terminfo-correct, tmux-aware, and
-- restored on exit) the moment 'titlestring' changes.
--
-- Enabled by default; configured through `setup({ tabname = ... })`:
--   tabname = false                                    -- disable
--   tabname = true                                     -- defaults (🤖 / Braille spinner / 🔔)
--   tabname = { working = "⚙️" }                       -- static working marker (no animation)
--   tabname = { working = { "A", "B", "C" },           -- animated spinner frames
--               working_interval_ms = 100 }
--   tabname = function(info) ... end                   -- full custom formatter, may return nil
-- `info` passed to a formatter is { cwd, branch, running, working, pending, frame }.
-- `frame` is the 1-based spinner index when working; useful for custom formatters.

local M = {}

-- Braille dot rotation — half-width, present in nerd-font-free terminals, and the
-- conventional "I'm doing something" glyph for CLIs (npm, cargo, claude itself).
local DEFAULT_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local DEFAULT_INTERVAL_MS = 100

M.enabled = true
M.config = {
	running = "🤖",
	working = DEFAULT_FRAMES,
	working_interval_ms = DEFAULT_INTERVAL_MS,
	attention = "🔔",
	format = nil,
}

--- Push `title` to the terminal via Neovim's native title machinery. 'title'
--- must be on for Neovim to drive the title at all; 'titlestring' is evaluated
--- like 'statusline', so a literal % in a branch name is escaped to %%.
--- @param title string
function M.apply(title)
	vim.o.title = true
	vim.o.titlestring = (tostring(title):gsub("%%", "%%%%"))
end

--- Compose the title from session info, honoring a custom formatter.
--- "needs attention" outranks "working" (both can't really be true at once —
--- pending only sets after output settles — but ordering keeps it deterministic).
--- When `working` is a table of frames, info.frame (1-based, wraps) picks the
--- current glyph; a string `working` ignores it (static marker).
--- @param info table { cwd, branch, running, working, pending, frame }
--- @return string|nil
function M.compose(info)
	if M.config.format then
		return M.config.format(info)
	end
	if info.pending then
		return M.config.attention .. " " .. info.branch
	elseif info.working then
		local w = M.config.working
		local glyph
		if type(w) == "table" then
			local n = #w
			if n == 0 then
				glyph = ""
			else
				local i = ((info.frame or 1) - 1) % n + 1
				glyph = w[i]
			end
		else
			glyph = w
		end
		return glyph .. " " .. info.branch
	elseif info.running then
		return M.config.running .. " " .. info.branch
	end
	return info.branch
end

-- Branch name is stable per worktree, so cache the (one) git call per cwd.
local branch_cache = {}

--- Branch for `cwd`, falling back to the worktree directory's basename when git
--- can't answer (bare dir, detached HEAD, git missing).
--- @param cwd string
--- @return string
function M.branch_for(cwd)
	local cached = branch_cache[cwd]
	if cached ~= nil then
		return cached
	end
	local out = vim.fn.systemlist({ "git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD" })
	local branch
	if vim.v.shell_error == 0 and out[1] and out[1] ~= "" and out[1] ~= "HEAD" then
		branch = out[1]
	else
		branch = vim.fn.fnamemodify(cwd, ":t")
	end
	branch_cache[cwd] = branch
	return branch
end

local function has_session(cwd)
	local ok, term = pcall(require, "claude_workflow.term")
	return ok and term.has and term.has(cwd) or false
end

local function is_pending(cwd)
	local ok, notify = pcall(require, "claude_workflow.notify")
	return ok and notify.pending(cwd) or false
end

local function is_busy(cwd)
	local ok, notify = pcall(require, "claude_workflow.notify")
	return ok and notify.busy(cwd) or false
end

-- Spinner frame, monotonically incremented by the timer; compose() wraps it.
local spinner_frame = 1
local spinner_timer = nil

--- True iff the animation timer is currently running.
--- @return boolean
function M.spinner_active()
	return spinner_timer ~= nil
end

--- Stop and release the spinner timer. Safe to call when not running.
function M.spinner_stop()
	if spinner_timer then
		spinner_timer:stop()
		if not spinner_timer:is_closing() then
			spinner_timer:close()
		end
		spinner_timer = nil
	end
end

--- Session info for the focused window's cwd.
--- @return table { cwd, branch, running, working, pending, frame }
function M.current()
	local cwd = vim.fn.getcwd()
	local running = has_session(cwd)
	return {
		cwd = cwd,
		branch = M.branch_for(cwd),
		running = running,
		working = running and is_busy(cwd) or false,
		pending = running and is_pending(cwd) or false,
		frame = spinner_frame,
	}
end

-- Only drive the title for a real terminal: skip headless nvim (tests,
-- `claude -p` subprocesses) where no UI is attached and there is nothing to
-- title.
local function can_emit()
	return M.enabled and #vim.api.nvim_list_uis() > 0
end

local last_written

--- Recompute the title and emit it only when it changed (so the User-event /
--- autocmd churn doesn't churn the title).
function M.update()
	if not can_emit() then
		-- Still need to drive spinner lifecycle in headless tests so tests can
		-- observe spinner_active(); apply() itself is a harmless no-op for UI.
		M._sync_spinner()
		return
	end
	M._sync_spinner()
	local title = M.compose(M.current())
	if title == nil or title == last_written then
		return
	end
	last_written = title
	M.apply(title)
end

--- Start/stop the spinner timer based on whether any cwd is busy and `working`
--- is configured as a frame table. Idempotent.
function M._sync_spinner()
	local should_animate = type(M.config.working) == "table"
		and #M.config.working > 1
		and is_busy(vim.fn.getcwd())
		-- pending outranks working, so don't waste timer ticks then
		and not is_pending(vim.fn.getcwd())
	if should_animate then
		if spinner_timer then
			return
		end
		spinner_frame = 1
		spinner_timer = vim.uv.new_timer()
		local interval = M.config.working_interval_ms or DEFAULT_INTERVAL_MS
		spinner_timer:start(
			interval,
			interval,
			vim.schedule_wrap(function()
				spinner_frame = spinner_frame + 1
				if not can_emit() then
					return
				end
				local title = M.compose(M.current())
				if title == nil or title == last_written then
					return
				end
				last_written = title
				M.apply(title)
			end)
		)
	else
		M.spinner_stop()
	end
end

--- Best-effort restore on exit: drop the marker back to the bare dir name. The
--- shell's prompt usually retitles on the next command anyway.
function M.restore()
	M.spinner_stop()
	if not can_emit() then
		return
	end
	M.apply(vim.fn.fnamemodify(vim.fn.getcwd(), ":t"))
end

--- @param opts boolean|table|function|nil  see module header. nil -> enabled.
function M.setup(opts)
	M.spinner_stop()
	if opts == false then
		M.enabled = false
		return
	end
	M.enabled = true

	local cfg = {}
	if type(opts) == "function" then
		cfg.format = opts
	elseif type(opts) == "table" then
		cfg = opts
	end
	M.config = {
		running = cfg.running or "🤖",
		working = cfg.working ~= nil and cfg.working or DEFAULT_FRAMES,
		working_interval_ms = cfg.working_interval_ms or DEFAULT_INTERVAL_MS,
		attention = cfg.attention or "🔔",
		format = cfg.format,
	}

	local group = vim.api.nvim_create_augroup("ClaudeWorkflowTabname", { clear = true })

	-- Recompute when focus or cwd changes, or a terminal opens/closes.
	vim.api.nvim_create_autocmd(
		{ "VimEnter", "BufEnter", "WinEnter", "TabEnter", "DirChanged", "TermOpen", "TermClose" },
		{ group = group, callback = M.update }
	)
	-- notify fires these as its flags flip, so 🤖→spinner→🔔 needs no polling.
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = { "ClaudeWorkflowPending", "ClaudeWorkflowBusy" },
		callback = M.update,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = M.restore,
	})

	M.update()
end

return M
