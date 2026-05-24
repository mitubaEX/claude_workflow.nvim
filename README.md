# claude_workflow.nvim

Per-cwd `claude` (Claude Code CLI) `:terminal` manager for Neovim. Each
current working directory — typically a git worktree — gets at most one
claude terminal buffer, so switching tabs/worktrees keeps sessions
isolated.

Also ships a per-cwd "pending attention" flag suitable for plugging into
status lines or bufferlines, so you can see at a glance which worktree's
claude has gone idle while you were elsewhere.

## Install

`lazy.nvim`:

```lua
{
  "mitubaEX/claude_workflow.nvim",
  event = "VeryLazy",
  -- or: cmd = { "Claude", "ClaudeContinue", "ClaudeResume", "ClaudeFromPR",
  --             "ClaudeToggle", "ClaudeKill", "ClaudeSend" },
  opts = {
    -- env vars merged into every claude process (e.g. HOGE=1 claude)
    env = { HOGE = "1" },
    -- extra args appended to the claude command for every session
    extra_args = { "--dangerously-skip-permissions" },
    -- string prepended verbatim before `claude` (shell features work)
    -- e.g. -> `direnv exec . claude ...`
    cmd_prefix = "direnv exec .",
    -- terminal tab/window title reflecting the cwd's claude session.
    -- enabled by default; set `tabname = false` to turn it off. See below.
    tabname = true,
  },
}
```

## User commands

All commands operate on the current cwd's claude session, opening a new
one if there isn't one already.

| command                | what                                          |
| ---------------------- | --------------------------------------------- |
| `:Claude [prompt]`     | open fresh session (optional initial prompt)  |
| `:ClaudeContinue`      | `claude -c` (continue last session in cwd)    |
| `:ClaudeResume [id]`   | `claude -r` (interactive picker if no id)     |
| `:ClaudeFromPR <num>`  | `claude --from-pr <num>`                      |
| `:ClaudeToggle`        | hide / re-show the terminal split             |
| `:ClaudeKill`          | kill the cwd's claude terminal                |
| `:ClaudeSend <text>`   | send text to the cwd's claude (open if none)  |

## Lua API

```lua
local claude = require("claude_workflow")

claude.open({
  prompt = "summarize TODO.md",  -- initial prompt
  continue = true,               -- -c
  resume = "abc123",             -- -r [id]
  from_pr = 42,                  -- --from-pr <num>
  append_system_prompt = "...",  -- --append-system-prompt
  name = "feat-x",               -- -n <name>
  no_split = false,              -- reuse current window instead of vsplit
  env = { HOGE = "1" },          -- env vars merged into the claude process
  extra_args = { "--foo" },      -- extra CLI args appended to the claude cmd
  cmd_prefix = "direnv exec .",  -- string prepended verbatim before `claude`
})

claude.toggle()
claude.kill()
claude.send("hello")

-- Notification helpers (for status line integrations)
claude.busy(vim.fn.getcwd())       -- bool: claude is actively streaming output
claude.pending(vim.fn.getcwd())    -- bool: idle output waiting to be read
claude.clear_pending(cwd)          -- mark as read
```

The buffer for each session is named `claude://<cwd>`. Pickers (Telescope
buffers, etc.) can pattern-match on this scheme to single out claude
terminals.

## Status line / bufferline integration

`claude.busy(cwd)` is `true` while the cwd's claude is actively streaming
output (generation/spinner running) and flips back to `false` once the
output has been silent for `IDLE_MS` (1500ms). Use it to show a
"working" indicator regardless of whether the terminal is visible.

`claude.pending(cwd)` flips to `true` `IDLE_MS` (1500ms) after the
terminal stops streaming output, **if** the buffer is not currently
visible in the active tab. It clears when the buffer becomes visible
again, or when `claude.clear_pending(cwd)` is called.

Example with `bufferline.nvim`:

```lua
require("bufferline").setup({
  options = {
    mode = "tabs",
    name_formatter = function(opts)
      local cwd = vim.fn.getcwd(-1, opts.tabnr)
      local label = vim.fn.fnamemodify(cwd, ":t")
      if require("claude_workflow").pending(cwd) then
        return "● " .. label
      end
      return label
    end,
  },
})
```

## Terminal tab/window title

`setup()` makes the outer terminal's tab/window title track the focused
window's cwd:

| state                                   | title           |
| --------------------------------------- | --------------- |
| claude is actively working for the cwd  | `⚙️ <branch>`   |
| that session is idle / needs attention  | `🔔 <branch>`   |
| claude session live but idle            | `🤖 <branch>`   |
| no claude session for the cwd           | `<branch>`      |

`<branch>` is the cwd's git branch (falling back to its directory name).
The `⚙️` (working) and `🔔` (attention) states mirror `busy(cwd)` /
`pending(cwd)` and update the moment they flip — no polling — because
`notify` fires `User ClaudeWorkflowBusy` / `User ClaudeWorkflowPending`
autocmds (see below). "Needs attention" outranks "working". The title is
written only when it changes, never under headless nvim, and is reset to
the bare directory name on exit.

The title is driven through Neovim's native `'title'`/`'titlestring'`
options, so Neovim's TUI emits the terminfo-correct title sequence (and
handles tmux passthrough and exit-restore). Writing the OSC escape
directly is not an option: Neovim runs its TUI in a separate process, so
the process running this Lua has no controlling terminal — `/dev/tty` is
not writable from it.

It is **on by default**. Configure it through the `tabname` option:

```lua
require("claude_workflow").setup({
  -- tabname = true,                       -- default
  -- tabname = false,                      -- disable entirely
  -- override the markers (any subset; the rest keep their defaults):
  -- tabname = { running = "▶", working = "…", attention = "!" },
  -- full custom formatter; return a string, or nil to leave the title alone:
  tabname = function(info)
    -- info = { cwd, branch, running = bool, working = bool, pending = bool }
    return (info.pending and "! " or info.working and "~ " or info.running and "* " or "")
      .. info.branch
  end,
})
```

### `User ClaudeWorkflowBusy` / `User ClaudeWorkflowPending`

Whenever a session's busy or pending flag flips, the plugin fires the
matching autocmd:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = { "ClaudeWorkflowBusy", "ClaudeWorkflowPending" },
  callback = function(ev)
    -- ClaudeWorkflowBusy:    ev.data = { cwd = "<cwd>", busy = true|false }
    -- ClaudeWorkflowPending: ev.data = { cwd = "<cwd>", pending = true|false }
  end,
})
```

These are the same hooks the tab-title feature uses; status lines /
bufferlines can react to them instead of polling `busy(cwd)` /
`pending(cwd)`.

## Worktree integration

This plugin doesn't depend on `git_worktree.nvim`. The per-cwd isolation
makes them naturally compose: switch worktrees → cwd changes → next
`:ClaudeToggle` opens the right session.

For an opinionated "open worktree + claude in a new tab" flow, see
[`mitubaEX/git_worktree.nvim`](https://github.com/mitubaEX/git_worktree.nvim)
and your own glue, e.g.:

```lua
vim.keymap.set("n", "<leader>gwa", function()
  vim.cmd("tabnew")
  vim.cmd("GitWorktreeCreate " .. branch)
  require("claude_workflow").open({
    no_split = true,
    append_system_prompt = "your worktree workflow rules...",
  })
end)
```

## License

MIT.
