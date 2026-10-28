#!/usr/bin/env python3
"""Select focused regression files for changed paths; never silently run everything."""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "tests/plugin-package.sh"
MODULES = {
    "agent-runtime.py": ["agent-runtime.sh"],
    "bootstrap.sh": ["config-init.sh", "codex-adapter.sh", "agent-runtime.sh"],
    "bus.sh": ["codex-adapter.sh", "hook-context-compact.sh", "presence.sh"],
    "common.sh": ["config-init.sh", "context-config.sh", "codex-adapter.sh", "command-registry.sh"],
    "command-registry.sh": ["command-registry.sh"],
    "context.sh": ["context-config.sh", "hook-context-compact.sh"],
    "dispatch.sh": ["dispatch.sh"],
    "gc.sh": ["token-budget-ledger.sh"],
    "guard.sh": ["codex-adapter.sh", "hook-context-compact.sh"],
    "init-git.sh": ["config-init.sh"],
    "init-relay.sh": ["config-init.sh"],
    "ledger.sh": ["token-budget-ledger.sh", "hook-context-compact.sh", "linear-bridge.sh", "logseq-bridge.sh"],
    "linear.sh": ["linear-bridge.sh"],
    "logseq.sh": ["logseq-bridge.sh"],
    "migrate.sh": ["token-budget-ledger.sh"],
    "presence.sh": ["presence.sh"],
    "relay-client.sh": ["relay-e2e.sh"],
    "repo-memory-gate.sh": ["repo-memory-gate.sh"],
    "skill-activation.sh": ["hook-context-compact.sh"],
    "statusline.sh": ["hook-context-compact.sh"],
    "statusline-setup.sh": ["hook-context-compact.sh"],
    "swarm.sh": ["codex-adapter.sh", "hook-context-compact.sh"],
    "worker-runtime.sh": ["token-budget-ledger.sh"],
}


def select_tests(paths):
    selected = set()
    for path in paths:
        path = path.removeprefix("./")
        name = Path(path).name
        if path.startswith("tests/") and Path(path).suffix in (".sh", ".py"):
            selected.add("tests/linear-bridge.sh" if path.startswith("tests/fixtures/") else path)
        elif path in ("Makefile", "scripts/select-tests.py") or path.startswith(".github/workflows/"):
            selected.update(("tests/test_selection.py", PACKAGE))
        elif path == "scripts/validate-package.py":
            selected.update(("tests/validate-package.sh", PACKAGE))
        elif path.startswith((".claude-plugin/", ".agents/plugins/")):
            selected.add(PACKAGE)
        elif path.startswith("plugins/coordkit/"):
            selected.add(PACKAGE)
            if "/scripts/" in path and name in MODULES:
                selected.update("tests/" + test for test in MODULES[name])
            elif "/adapters/" in path and Path(path).suffix in (".sh", ".py"):
                selected.add("tests/codex-adapter.sh")
            elif "/transports/" in path and path.endswith(".sh"):
                selected.update(("tests/token-budget-ledger.sh", "tests/relay-e2e.sh", "tests/presence.sh", "tests/dispatch.sh"))
            elif "/apps/relay/" in path:
                selected.add("tests/relay-e2e.sh")
            elif "/agents/" in path:
                selected.add("tests/agent-runtime.sh")
            elif "/commands/" in path:
                selected.add("tests/command-registry.sh")
            elif "/templates/" in path:
                selected.update(("tests/config-init.sh", "tests/context-config.sh"))
            elif "/hooks/" in path:
                selected.add("tests/codex-adapter.sh")
            elif "/bin/" in path:
                selected.update(("tests/command-registry.sh", "tests/agent-runtime.sh"))
            elif Path(path).suffix not in (".md", ".json", ".toml"):
                raise ValueError(f"No focused test mapping for {path}; add its affected tests to scripts/select-tests.py")
        elif path.endswith((".py", ".sh")):
            raise ValueError(f"No focused test mapping for {path}; select or add its affected tests explicitly")
    return sorted(selected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--base", help="Compare this Git revision with the current tracked working tree")
    source.add_argument("--paths", nargs="+", help="Explicit changed paths")
    args = parser.parse_args()
    try:
        if args.base:
            base = subprocess.check_output(["git", "rev-parse", "--verify", "--end-of-options", args.base + "^{commit}"], cwd=ROOT, text=True).strip()
            paths = subprocess.check_output(["git", "diff", "--name-only", "--diff-filter=ACDMRT", "-z", base, "--"], cwd=ROOT).decode().split("\0")
        else:
            paths = args.paths
        selected = select_tests(path for path in paths if path)
        missing = [test for test in selected if not (ROOT / test).is_file()]
        if missing:
            raise ValueError("Selected test files are missing: " + ", ".join(missing))
        print(" ".join(selected))
    except (ValueError, subprocess.CalledProcessError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
