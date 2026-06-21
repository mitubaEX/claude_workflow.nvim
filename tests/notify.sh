#!/usr/bin/env bash
# Coverage for claude_workflow.notify busy gating:
# - typing into the buffer (no "esc to interrupt" marker) must NOT flip busy=true,
#   so the tabname spinner doesn't churn while the user is composing a prompt.
# - once claude's "esc to interrupt" line appears in the buffer tail, busy=true.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# 1. API surface
run_nv -c 'lua local n = require("claude_workflow.notify"); for _, fn in ipairs({"watch","busy","pending","clear"}) do if type(n[fn]) ~= "function" then print("missing: " .. fn); vim.cmd("cquit") end end' -c qa

# 2. Plain buffer changes (user typing) must not set busy=true.
#    Watch a scratch buffer, write a plain "hello\n", let on_lines fire, expect busy=false.
run_nv -c 'lua
local n = require("claude_workflow.notify")
local cwd = "/tmp/typing-cwd"
local buf = vim.api.nvim_create_buf(false, true)
n.watch(buf, cwd)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello", "world", "user typing here" })
vim.wait(80, function() return false end)
if n.busy(cwd) then print("busy should be false while user is typing"); vim.cmd("cquit") end
' -c qa

# 3. When claude renders its "esc to interrupt" line, busy flips to true.
run_nv -c 'lua
local n = require("claude_workflow.notify")
local cwd = "/tmp/working-cwd"
local buf = vim.api.nvim_create_buf(false, true)
n.watch(buf, cwd)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "some output", "more output", "* Thinking... (esc to interrupt)" })
vim.wait(80, function() return n.busy(cwd) end)
if not n.busy(cwd) then print("busy should be true when esc to interrupt is present"); vim.cmd("cquit") end
' -c qa

# 4. busy flips back to false after IDLE_MS of silence (using a short patched value
#    via writing a marker buffer and waiting). Here we just verify the inverse of #2:
#    once busy is set, removing the marker and waiting clears it.
run_nv -c 'lua
local n = require("claude_workflow.notify")
local cwd = "/tmp/idle-cwd"
local buf = vim.api.nvim_create_buf(false, true)
n.watch(buf, cwd)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "* Thinking... (esc to interrupt)" })
vim.wait(80, function() return n.busy(cwd) end)
if not n.busy(cwd) then print("busy should be true after marker line"); vim.cmd("cquit") end
-- silence beyond IDLE_MS (1500ms) should drop busy
vim.wait(2000, function() return not n.busy(cwd) end)
if n.busy(cwd) then print("busy should clear after idle period"); vim.cmd("cquit") end
' -c qa
