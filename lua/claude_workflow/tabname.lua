-- Reflect the cwd's claude session in the *outer* terminal's tab/window title.
--
-- The plugin's unit is the cwd (typically a git worktree), so the title tracks
-- the focused window's cwd:
--   🤖 <branch>   a claude session is live for this cwd
--   🔔 <branch>   that session has gone idle / needs attention (notify.pending)
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
--   tabname = false                      -- disable
--   tabname = true                       -- defaults (🤖 / 🔔)
--   tabname = { running = "▶", attention = "!" }  -- override markers
--   tabname = function(info) ... end     -- full custom formatter, may return nil
-- `info` passed to a formatter is { cwd, branch, running, pending }.

local M = {}

M.enabled = true
M.config = { running = "🤖", attention = "🔔", format = nil }

--- Push `title` to the terminal via Neovim's native title machinery. 'title'
--- must be on for Neovim to drive the title at all; 'titlestring' is evaluated
--- like 'statusline', so a literal % in a branch name is escaped to %%.
--- @param title string
function M.apply(title)
	vim.o.title = true
	vim.o.titlestring = (tostring(title):gsub("%%", "%%%%"))
end

--- Compose the title from session info, honoring a custom formatter.
--- @param info table { cwd, branch, running, pending }
--- @return string|nil
function M.compose(info)
	if M.config.format then
		return M.config.format(info)
	end
	if info.pending then
		return M.config.attention .. " " .. info.branch
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

--- Session info for the focused window's cwd.
--- @return table { cwd, branch, running, pending }
function M.current()
	local cwd = vim.fn.getcwd()
	local running = has_session(cwd)
	return {
		cwd = cwd,
		branch = M.branch_for(cwd),
		running = running,
		pending = running and is_pending(cwd) or false,
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
		return
	end
	local title = M.compose(M.current())
	if title == nil or title == last_written then
		return
	end
	last_written = title
	M.apply(title)
end

--- Best-effort restore on exit: drop the marker back to the bare dir name. The
--- shell's prompt usually retitles on the next command anyway.
function M.restore()
	if not can_emit() then
		return
	end
	M.apply(vim.fn.fnamemodify(vim.fn.getcwd(), ":t"))
end

--- @param opts boolean|table|function|nil  see module header. nil -> enabled.
function M.setup(opts)
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
		attention = cfg.attention or "🔔",
		format = cfg.format,
	}

	local group = vim.api.nvim_create_augroup("ClaudeWorkflowTabname", { clear = true })

	-- Recompute when focus or cwd changes, or a terminal opens/closes.
	vim.api.nvim_create_autocmd(
		{ "VimEnter", "BufEnter", "WinEnter", "TabEnter", "DirChanged", "TermOpen", "TermClose" },
		{ group = group, callback = M.update }
	)
	-- notify fires this when its idle flag flips, so 🤖→🔔 needs no polling.
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "ClaudeWorkflowPending",
		callback = M.update,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = M.restore,
	})

	M.update()
end

return M
