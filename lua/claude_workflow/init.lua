-- claude_workflow.nvim: per-cwd claude :terminal manager + idle/done notifier.
-- Public surface lives on the top-level module so callers can write
-- `require("claude_workflow").open(...)` instead of digging into submodules.

local M = {}

local term = require("claude_workflow.term")
local notify = require("claude_workflow.notify")

-- Terminal control.
M.open = term.open
M.toggle = term.toggle
M.kill = term.kill
M.send = term.send

-- Notification queries (intended for status line / bufferline integrations).
M.pending = notify.pending
M.clear_pending = notify.clear

-- Submodules are exported for callers that want the raw object (e.g. to call
-- `require("claude_workflow").notify.watch(buf, cwd)` directly).
M.term = term
M.notify = notify

--- Optional setup. Accepts defaults that are merged into every `open` call,
--- so the user commands (`:Claude`, `:ClaudeContinue`, ...) pick them up too.
--- @param opts table|nil { env = { KEY = "val" }, extra_args = { "--flag" }, cmd_prefix = "direnv exec ." }
function M.setup(opts)
	opts = opts or {}
	term.set_defaults({
		env = opts.env,
		extra_args = opts.extra_args,
		cmd_prefix = opts.cmd_prefix,
	})
end

return M
