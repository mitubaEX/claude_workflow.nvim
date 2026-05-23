#!/usr/bin/env bash
# Coverage for claude_workflow.tabname:
# - API surface + osc() byte layout (OSC 0 then OSC 2, BEL-terminated)
# - compose() default markers (running/attention/none) and custom formatter
# - setup(false) disables and update() stays a harmless no-op
# - setup() registers the User ClaudeWorkflowPending hook and tolerates it firing
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# 1. API exists, including the term.has() accessor it depends on.
run_nv -c 'lua local m = require("claude_workflow.tabname"); for _, fn in ipairs({"osc","compose","current","update","restore","setup"}) do if type(m[fn]) ~= "function" then print("missing: " .. fn); vim.cmd("cquit") end end; if type(require("claude_workflow").has) ~= "function" then print("missing: claude_workflow.has"); vim.cmd("cquit") end' -c qa

# 2. osc() is exactly OSC 0 (icon+title) then OSC 2 (title), each BEL-terminated.
run_nv -c 'lua local m = require("claude_workflow.tabname"); local esc, bel = string.char(27), string.char(7); local want = esc .. "]0;X" .. bel .. esc .. "]2;X" .. bel; local got = m.osc("X"); if got ~= want then print("osc mismatch: " .. vim.inspect(got)); vim.cmd("cquit") end' -c qa

# 3. compose() default markers: running -> 🤖, pending -> 🔔, neither -> bare branch.
run_nv -c 'lua local m = require("claude_workflow.tabname"); m.setup(true); local cases = {{{branch="br",running=true},"🤖 br"},{{branch="br",running=true,pending=true},"🔔 br"},{{branch="br"},"br"}}; for _, c in ipairs(cases) do local got = m.compose(c[1]); if got ~= c[2] then print("compose -> " .. tostring(got)); vim.cmd("cquit") end end' -c qa

# 4. setup(table) overrides markers; setup(function) is a full custom formatter.
run_nv -c 'lua local m = require("claude_workflow.tabname"); m.setup({ running = "R", attention = "A" }); if m.compose({branch="br",running=true}) ~= "R br" then print("marker override failed"); vim.cmd("cquit") end; m.setup(function(info) return "X:" .. info.branch end); if m.compose({branch="br"}) ~= "X:br" then print("formatter failed"); vim.cmd("cquit") end' -c qa

# 5. setup(false) disables; update() must not error (no UI / disabled -> no-op).
run_nv -c 'lua local m = require("claude_workflow.tabname"); m.setup(false); if m.enabled ~= false then print("not disabled"); vim.cmd("cquit") end; if not pcall(m.update) then print("update errored when disabled"); vim.cmd("cquit") end' -c qa

# 6. setup() wires the User ClaudeWorkflowPending hook and survives it firing.
run_nv -c 'lua local m = require("claude_workflow.tabname"); m.setup(true); local au = vim.api.nvim_get_autocmds({ group = "ClaudeWorkflowTabname" }); local user = false; for _, a in ipairs(au) do if a.event == "User" then user = true end end; if not user then print("no User autocmd registered"); vim.cmd("cquit") end; if not pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "ClaudeWorkflowPending", data = { cwd = vim.fn.getcwd(), pending = true } }) then print("firing pending event errored"); vim.cmd("cquit") end' -c qa
