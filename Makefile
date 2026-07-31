.PHONY: claude

claude:
	claude --dangerously-skip-permissions --dangerously-load-development-channels plugin:annotate@claude-annotate --model sonnet --name CoordKit --effort medium
	