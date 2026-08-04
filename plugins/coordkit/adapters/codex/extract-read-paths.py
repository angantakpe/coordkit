#!/usr/bin/env python3
"""Best-effort file-read extraction for Codex Bash PostToolUse payloads.

Codex has no generic Read tool: normal repository inspection goes through Bash.
This recognizes conservative, read-oriented commands and returns only explicit
arguments that resolve to existing regular files. It never executes the command.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys


READERS = re.compile(
    r"(?:^|[;&|]\s*)(?:command\s+)?(?:cat|bat|head|tail|sed|nl|less|more|stat|"
    r"file|wc|grep|rg|awk|diff|git\s+(?:diff|show|status|log))\b",
    re.MULTILINE,
)
MUTATORS = re.compile(
    r"(?:^|[;&|]\s*)(?:command\s+)?(?:rm|mv|cp|install|truncate|touch|tee|dd|"
    r"chmod|chown|perl\s+-i|sed\s+(?:-[^\s]*i\b|--in-place\b))\b",
    re.MULTILINE,
)


def load_payload() -> dict:
    try:
        value = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        return {}
    return value if isinstance(value, dict) else {}


def shell_tokens(command: str) -> list[str]:
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|<>")
        lexer.whitespace_split = True
        lexer.commenters = ""
        return list(lexer)
    except ValueError:
        return command.split()


def candidate_path(token: str, cwd: str) -> str | None:
    if not token or token.startswith("-") or token in {";", "&&", "||", "|", "<", ">", ">>"}:
        return None
    if token.startswith(("$", "http://", "https://")):
        return None
    # Common diagnostic form produced by rg/grep: path/to/file:line[:column].
    raw = re.sub(r":\d+(?::\d+)?(?::.*)?$", "", token)
    path = raw if os.path.isabs(raw) else os.path.join(cwd, raw)
    path = os.path.abspath(path)
    return path if os.path.isfile(path) else None


def main() -> int:
    payload = load_payload()
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return 0
    command = tool_input.get("command")
    if not isinstance(command, str) or not READERS.search(command) or MUTATORS.search(command):
        return 0
    # Do not treat a command that writes normal stdout to a file as a read-only
    # observation. Stderr redirections such as 2>/dev/null remain acceptable.
    if re.search(r"(?<![0-9])(?:>>|>)(?!&)", command):
        return 0

    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else os.getcwd()
    seen: set[str] = set()
    for token in shell_tokens(command):
        path = candidate_path(token, cwd)
        if path and path not in seen:
            seen.add(path)
            print(path)
            if len(seen) >= 64:
                break
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
