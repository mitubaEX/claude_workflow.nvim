#!/usr/bin/env bash
# Coverage for claude_workflow.herdr (issue #7):
# - API surface (available/aggregate/update/release/setup + notify.sessions)
# - aggregate() maps sessions -> working/blocked/idle/nil with working > blocked
# - update() reports state changes to `herdr pane report-agent` with a
#   monotonically increasing --seq, dedupes repeats, and releases when the
#   last session disappears
# - notify.watch()/detach drive sessions() and fire User ClaudeWorkflowSession
# - outside a herdr pane (no HERDR_ENV) update() never spawns anything
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# 1. API exists: herdr module functions and the notify.sessions() enumerator.
run_nv -c 'lua local h = require("claude_workflow.herdr"); for _, fn in ipairs({"available","aggregate","update","release","setup"}) do if type(h[fn]) ~= "function" then print("missing: herdr." .. fn); vim.cmd("cquit") end end; if type(require("claude_workflow.notify").sessions) ~= "function" then print("missing: notify.sessions"); vim.cmd("cquit") end' -c qa

# 2. aggregate(): {} -> nil, idle session -> idle, pending -> blocked,
#    busy -> working, and working outranks blocked across cwds.
run_nv -c 'lua local h = require("claude_workflow.herdr"); local cases = {{{}, nil},{{{cwd="/a",busy=false,pending=false}}, "idle"},{{{cwd="/a",busy=false,pending=true}}, "blocked"},{{{cwd="/a",busy=true,pending=false}}, "working"},{{{cwd="/a",busy=true,pending=false},{cwd="/b",busy=false,pending=true}}, "working"},{{{cwd="/a",busy=false,pending=false},{cwd="/b",busy=false,pending=true}}, "blocked"}}; for i, c in ipairs(cases) do local got = h.aggregate(c[1]); if got ~= c[2] then print("aggregate case " .. i .. " -> " .. tostring(got)); vim.cmd("cquit") end end' -c qa

# 3. update() with a stubbed runner: reports on change, dedupes identical
#    states, and releases when sessions vanish. herdr drops seq <= the highest
#    it has seen per source *for the pane's lifetime*, so seq must be
#    epoch-ms-based (survives nvim restarts in the same pane), strictly
#    increasing within the session.
run_nv -c 'lua vim.env.HERDR_ENV = "1"; vim.env.HERDR_PANE_ID = "w1:p1"; local h = require("claude_workflow.herdr"); local calls = {}; h._run = function(argv) table.insert(calls, argv) end; h.setup({ bin = "herdr-fake" }); local n = require("claude_workflow.notify"); local sess = {}; n.sessions = function() return sess end; local function seq_of(argv) local a = table.concat(argv, " "); return tonumber(a:match("--seq (%d+)")) end; sess = { { cwd = "/a", busy = true, pending = false } }; h.update(); if #calls ~= 1 then print("expected 1 call, got " .. #calls); vim.cmd("cquit") end; local a = table.concat(calls[1], " "); if not (a:find("report%-agent") and a:find("w1:p1") and a:find("--state working") and a:find("--agent claude")) then print("bad argv: " .. a); vim.cmd("cquit") end; if not seq_of(calls[1]) or seq_of(calls[1]) < 1700000000000 then print("seq not epoch-ms-based: " .. tostring(seq_of(calls[1]))); vim.cmd("cquit") end; h.update(); if #calls ~= 1 then print("duplicate state was re-reported"); vim.cmd("cquit") end; sess = { { cwd = "/a", busy = false, pending = true } }; h.update(); if #calls ~= 2 or not table.concat(calls[2], " "):find("--state blocked") then print("blocked not reported"); vim.cmd("cquit") end; if seq_of(calls[2]) <= seq_of(calls[1]) then print("seq did not increase"); vim.cmd("cquit") end; sess = {}; h.update(); if #calls ~= 3 or not table.concat(calls[3], " "):find("release%-agent") then print("release not sent"); vim.cmd("cquit") end; if seq_of(calls[3]) <= seq_of(calls[2]) then print("release seq did not increase"); vim.cmd("cquit") end' -c qa

# 4. notify.watch() adds a sessions() entry and fires User ClaudeWorkflowSession
#    (running=true); wiping the buffer removes it and fires running=false.
run_nv -c 'lua local n = require("claude_workflow.notify"); local events = {}; vim.api.nvim_create_autocmd("User", { pattern = "ClaudeWorkflowSession", callback = function(ev) table.insert(events, ev.data) end }); local buf = vim.api.nvim_create_buf(false, true); n.watch(buf, "/tmp/x"); vim.wait(100, function() return #events >= 1 end); local s = n.sessions(); if #s ~= 1 or s[1].cwd ~= "/tmp/x" then print("sessions() missing entry: " .. vim.inspect(s)); vim.cmd("cquit") end; if #events < 1 or events[1].running ~= true or events[1].cwd ~= "/tmp/x" then print("no running=true event: " .. vim.inspect(events)); vim.cmd("cquit") end; vim.cmd("bwipeout! " .. buf); vim.wait(200, function() return #events >= 2 end); if #n.sessions() ~= 0 then print("session not removed on wipe"); vim.cmd("cquit") end; if #events < 2 or events[2].running ~= false then print("no running=false event: " .. vim.inspect(events)); vim.cmd("cquit") end' -c qa

# 5. Outside herdr (env cleared) update() spawns nothing even with live sessions.
run_nv -c 'lua vim.env.HERDR_ENV = nil; vim.env.HERDR_PANE_ID = nil; local h = require("claude_workflow.herdr"); local calls = {}; h._run = function(argv) table.insert(calls, argv) end; h.setup(true); require("claude_workflow.notify").sessions = function() return { { cwd = "/a", busy = true, pending = false } } end; h.update(); if h.available() then print("available() should be false outside herdr"); vim.cmd("cquit") end; if #calls ~= 0 then print("spawned outside herdr: " .. vim.inspect(calls)); vim.cmd("cquit") end' -c qa
