-- herdr (terminal agent multiplexer) integration.
--
-- herdr detects agents by inspecting a pane's foreground process and its
-- screen output. A claude running inside an nvim :terminal lives on a
-- separate pty as a child of nvim, so herdr only ever sees `nvim` and the
-- session is invisible in its sidebar. herdr ships a socket API for exactly
-- this case (see herdr's docs "Custom status labels" / socket API):
--
--   herdr pane report-agent  <pane> --source ID --agent claude --state ...
--   herdr pane release-agent <pane> --source ID --agent claude
--
-- Inside a herdr pane every process inherits HERDR_ENV=1, HERDR_PANE_ID and
-- HERDR_SOCKET_PATH, so this module pushes the plugin's own busy/pending
-- signals to herdr whenever they change. Outside herdr it is a no-op.
--
-- One nvim (= one herdr pane) can host claude sessions for several cwds
-- (worktrees), so the reported state is the aggregate across all of them:
--   any busy            -> working
--   else any pending    -> blocked   (drives herdr's needs-attention rollup)
--   else any session    -> idle
--   no session at all   -> release-agent (only if something was reported)

local M = {}

M.enabled = true
M.config = {
	source = "custom:claude-workflow-nvim",
	agent = "claude",
	bin = nil, -- nil -> $HERDR_BIN_PATH, then `herdr` from $PATH
}

-- herdr uses --seq to drop reports that arrive out of order, remembering the
-- highest seq per source for the *pane's* lifetime — longer than one nvim
-- process. A plain counter restarting at 1 would be silently ignored after
-- an nvim restart in the same pane, so seq is epoch milliseconds, bumped to
-- stay strictly increasing when two sends land in the same millisecond.
local seq = 0
local function next_seq()
	local sec, usec = vim.uv.gettimeofday()
	seq = math.max(sec * 1000 + math.floor(usec / 1000), seq + 1)
	return seq
end
-- Last state string sent, nil when nothing is live on herdr's side. Guards
-- both duplicate reports and a release without a prior report.
local last_reported = nil

--- The herdr binary to invoke, or nil when none is usable. An explicit
--- `bin` from setup() is trusted as-is (also what the tests inject).
--- @return string|nil
function M.resolve_bin()
	if M.config.bin then
		return M.config.bin
	end
	local env_bin = vim.env.HERDR_BIN_PATH
	if env_bin and env_bin ~= "" and vim.fn.executable(env_bin) == 1 then
		return env_bin
	end
	if vim.fn.executable("herdr") == 1 then
		return "herdr"
	end
	return nil
end

--- True when nvim runs inside a herdr pane and the CLI is reachable.
--- @return boolean
function M.available()
	if vim.env.HERDR_ENV ~= "1" then
		return false
	end
	local pane = vim.env.HERDR_PANE_ID
	if not pane or pane == "" then
		return false
	end
	return M.resolve_bin() ~= nil
end

--- Collapse the per-cwd session flags into one pane state.
--- @param sessions table[] list of { cwd, busy, pending } (notify.sessions())
--- @return string|nil "working" | "blocked" | "idle", nil when no sessions
function M.aggregate(sessions)
	if not sessions or #sessions == 0 then
		return nil
	end
	local pending = false
	for _, s in ipairs(sessions) do
		if s.busy then
			return "working"
		end
		pending = pending or s.pending
	end
	return pending and "blocked" or "idle"
end

--- Spawn the herdr CLI. Failures are swallowed on purpose: state reporting
--- is best-effort decoration and must never break the editing session.
--- Overridable for tests. `opts.sync` waits briefly (VimLeavePre, where an
--- async spawn would be killed with nvim before reaching the socket).
--- @param argv string[]
--- @param opts table|nil { sync = bool }
function M._run(argv, opts)
	local ok, proc = pcall(vim.system, argv)
	if ok and opts and opts.sync then
		pcall(proc.wait, proc, 500)
	end
end

local function send(subcommand, state, opts)
	local argv = {
		M.resolve_bin(),
		"pane",
		subcommand,
		vim.env.HERDR_PANE_ID,
		"--source",
		M.config.source,
		"--agent",
		M.config.agent,
		"--seq",
		tostring(next_seq()),
	}
	if state then
		table.insert(argv, "--state")
		table.insert(argv, state)
	end
	last_reported = state
	M._run(argv, opts)
end

--- Recompute the aggregate and push it to herdr if it changed.
function M.update()
	if not (M.enabled and M.available()) then
		return
	end
	local state = M.aggregate(require("claude_workflow.notify").sessions())
	if state == last_reported then
		return
	end
	if state == nil then
		send("release-agent", nil)
	else
		send("report-agent", state)
	end
end

--- Hand the pane back to herdr's own detection. Called on VimLeavePre
--- (synchronously — nvim is about to take the child processes down with it)
--- and from update() when the last session closes.
function M.release()
	if not (M.enabled and M.available()) or last_reported == nil then
		return
	end
	send("release-agent", nil, { sync = true })
end

--- @param opts boolean|table|nil  nil/true -> enabled with defaults,
--- false -> disabled, table -> { source = string, agent = string, bin = string }
function M.setup(opts)
	if opts == false then
		M.enabled = false
		return
	end
	M.enabled = true

	local cfg = type(opts) == "table" and opts or {}
	M.config = {
		source = cfg.source or "custom:claude-workflow-nvim",
		agent = cfg.agent or "claude",
		bin = cfg.bin,
	}

	local group = vim.api.nvim_create_augroup("ClaudeWorkflowHerdr", { clear = true })
	-- notify fires these as sessions open/close and busy/pending flip, so the
	-- pane state tracks claude without polling.
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = { "ClaudeWorkflowBusy", "ClaudeWorkflowPending", "ClaudeWorkflowSession" },
		callback = M.update,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = M.release,
	})

	M.update()
end

return M
