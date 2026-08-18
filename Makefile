.PHONY: claude test test-fast

claude:
	claude --dangerously-skip-permissions --dangerously-load-development-channels plugin:annotate@claude-annotate --model sonnet --name Coordkit --effort medium

codex:
	codex --yolo

test-fast:
	bash -n plugins/coordkit/scripts/*.sh plugins/coordkit/transports/*.sh plugins/coordkit/bin/cbus plugins/coordkit/bin/cobus plugins/coordkit/bin/sync.sh plugins/coordkit/adapters/hook.sh plugins/coordkit/adapters/codex/hook.sh
	python3 -c 'import ast, pathlib; [ast.parse(path.read_text()) for path in (pathlib.Path("plugins/coordkit/adapters/codex/extract-read-paths.py"), pathlib.Path("plugins/coordkit/scripts/agent-runtime.py"))]'
	node --check plugins/coordkit/apps/relay/server.mjs
	jq -e . plugins/coordkit/.codex-plugin/plugin.json plugins/coordkit/hooks/hooks.json .agents/plugins/marketplace.json >/dev/null
	bash tests/plugin-package.sh
	bash tests/config-init.sh
	bash tests/context-config.sh
	bash tests/codex-adapter.sh
	bash tests/agent-runtime.sh

test: test-fast
	bash tests/token-budget-ledger.sh
	bash tests/hook-context-compact.sh
	bash tests/relay-e2e.sh
	bash tests/logseq-bridge.sh
