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

--- Optional setup. Currently a no-op — all behavior is opt-in via the
--- top-level functions and `plugin/claude_workflow.lua` registers user
--- commands automatically. Reserved for future configuration knobs.
function M.setup(_opts) end

return M
