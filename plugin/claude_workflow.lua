-- User commands for claude_workflow.nvim.
-- Loaded at startup (per nvim plugin/ convention). Lazy loaders can still
-- defer the require of the lua/ modules behind these — the user commands
-- themselves are cheap stubs.

if vim.g.loaded_claude_workflow then
	return
end
vim.g.loaded_claude_workflow = 1

local function claude()
	return require("claude_workflow")
end

vim.api.nvim_create_user_command("Claude", function(opts)
	claude().open({ prompt = opts.args ~= "" and opts.args or nil })
end, {
	nargs = "?",
	desc = "Open claude in a :terminal split (optional initial prompt)",
})

vim.api.nvim_create_user_command("ClaudeContinue", function()
	claude().open({ continue = true })
end, { desc = "Open claude with -c (continue last session in cwd)" })

vim.api.nvim_create_user_command("ClaudeResume", function(opts)
	claude().open({ resume = opts.args ~= "" and opts.args or true })
end, {
	nargs = "?",
	desc = "Open claude with -r (interactive picker if no session id given)",
})

vim.api.nvim_create_user_command("ClaudeFromPR", function(opts)
	if opts.args == "" then
		vim.api.nvim_err_writeln("PR number required")
		return
	end
	claude().open({ from_pr = opts.args })
end, {
	nargs = 1,
	desc = "Open claude with --from-pr <num>",
})

vim.api.nvim_create_user_command("ClaudeToggle", function()
	claude().toggle()
end, { desc = "Toggle the claude terminal for the current cwd" })

vim.api.nvim_create_user_command("ClaudeKill", function()
	claude().kill()
end, { desc = "Kill the claude terminal for the current cwd" })

vim.api.nvim_create_user_command("ClaudeSend", function(opts)
	claude().send(opts.args)
end, {
	nargs = "+",
	desc = "Send text to the cwd's claude terminal (open if missing)",
})
