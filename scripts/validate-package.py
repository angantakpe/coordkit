#!/usr/bin/env python3
"""Validate CoordKit's checked-in plugin package without external tooling."""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any


class ValidationError(Exception):
    """A package contract is invalid."""


def fail(message: str) -> None:
    raise ValidationError(message)


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"missing JSON file: {path}")
    except json.JSONDecodeError as error:
        fail(f"invalid JSON in {path}: {error.msg} at line {error.lineno}")


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty string")
    return value


def resolve_inside(base: Path, reference: Any, label: str, *, kind: str) -> Path:
    raw = require_string(reference, label)
    candidate = (base / raw).resolve()
    package_root = base.resolve()
    try:
        candidate.relative_to(package_root)
    except ValueError:
        fail(f"{label} escapes the plugin directory: {raw}")

    valid = candidate.is_dir() if kind == "directory" else candidate.is_file()
    if not valid:
        fail(f"{label} references missing {kind}: {raw}")
    return candidate


def validate_manifest_paths(plugin: Path, manifest: dict[str, Any]) -> None:
    skills = resolve_inside(plugin, manifest.get("skills"), "manifest skills", kind="directory")
    skill_files = sorted(skills.glob("*/SKILL.md"))
    if not skill_files:
        fail("manifest skills directory contains no */SKILL.md files")

    if "commands" in manifest:
        commands = resolve_inside(plugin, manifest["commands"], "manifest commands", kind="directory")
        command_files = [path for path in commands.glob("*.md") if path.name != "README.md"]
        if not command_files:
            fail("manifest commands directory contains no command Markdown files")

    file_fields = {
        "hooks": manifest.get("hooks"),
        "mcpServers": manifest.get("mcpServers"),
        "lspServers": manifest.get("lspServers"),
    }
    for field, reference in file_fields.items():
        if reference is not None:
            resolve_inside(plugin, reference, f"manifest {field}", kind="file")

    experimental = manifest.get("experimental", {})
    if experimental:
        experimental = require_object(experimental, "manifest experimental")
        for field, reference in experimental.items():
            resolve_inside(plugin, reference, f"manifest experimental.{field}", kind="file")


def validate_agents(plugin: Path, manifest: dict[str, Any]) -> None:
    references = manifest.get("agents")
    if not isinstance(references, list) or not references:
        fail("Claude manifest agents must be a non-empty array of file paths")
    references = [
        require_string(reference, f"manifest agents[{index}]")
        for index, reference in enumerate(references)
    ]
    if len(references) != len(set(references)):
        fail("Claude manifest agents contains duplicate paths")

    referenced = {
        resolve_inside(plugin, reference, f"manifest agents[{index}]", kind="file")
        for index, reference in enumerate(references)
    }
    shipped = set((plugin / "agents").glob("*.md"))
    if referenced != shipped:
        missing = sorted(str(path.relative_to(plugin)) for path in shipped - referenced)
        extra = sorted(str(path.relative_to(plugin)) for path in referenced - shipped)
        details = []
        if missing:
            details.append(f"unreferenced: {', '.join(missing)}")
        if extra:
            details.append(f"outside agents catalog: {', '.join(extra)}")
        fail(f"Claude manifest agents must list every shipped agent ({'; '.join(details)})")


def validate_adapter(plugin: Path, adapter_path: Path) -> None:
    adapter = require_object(load_json(adapter_path), str(adapter_path))
    adapter_dir = adapter_path.parent
    for field in ("manifestPath", "hooksPath", "commandsPath"):
        raw = require_string(adapter.get(field), f"{adapter_path.name} {field}")
        candidate = (adapter_dir / raw).resolve()
        try:
            candidate.relative_to(plugin.resolve())
        except ValueError:
            fail(f"{adapter_path.name} {field} escapes the plugin directory: {raw}")
        if not candidate.exists():
            fail(f"{adapter_path.name} {field} references a missing path: {raw}")


def validate_hooks(hooks_path: Path) -> None:
    document = require_object(load_json(hooks_path), str(hooks_path))
    hooks = require_object(document.get("hooks"), "hooks.json hooks")
    if not hooks:
        fail("hooks.json hooks must not be empty")
    for event, groups in hooks.items():
        if not isinstance(groups, list) or not groups:
            fail(f"hooks.json {event} must contain at least one hook group")
        for group_index, group in enumerate(groups):
            group = require_object(group, f"hooks.json {event}[{group_index}]")
            handlers = group.get("hooks")
            if not isinstance(handlers, list) or not handlers:
                fail(f"hooks.json {event}[{group_index}].hooks must not be empty")
            for handler_index, handler in enumerate(handlers):
                handler = require_object(
                    handler, f"hooks.json {event}[{group_index}].hooks[{handler_index}]"
                )
                if handler.get("type") != "command":
                    fail(f"hooks.json {event} handler type must be command")
                require_string(handler.get("command"), f"hooks.json {event} command")


def validate_executables(plugin: Path) -> None:
    entrypoints = (
        "adapters/hook.sh",
        "scripts/repo-memory-gate.sh",
        "scripts/agent-runtime.py",
        "bin/coordkit-subagent-statusline",
    )
    for relative in entrypoints:
        path = plugin / relative
        if not path.is_file():
            fail(f"missing runtime entrypoint: {relative}")
        if not os.access(path, os.X_OK):
            fail(f"runtime entrypoint is not executable: {relative}")


def marketplace_plugin(document: Any, path: Path) -> dict[str, Any]:
    marketplace = require_object(document, str(path))
    plugins = marketplace.get("plugins")
    if not isinstance(plugins, list):
        fail(f"{path} plugins must be an array")
    matches = [entry for entry in plugins if isinstance(entry, dict) and entry.get("name") == "coordkit"]
    if len(matches) != 1:
        fail(f"{path} must contain exactly one coordkit plugin")
    return matches[0]


def validate_repository(root: Path) -> None:
    root = root.resolve()
    plugin = root / "plugins" / "coordkit"
    if not plugin.is_dir():
        fail(f"missing plugin directory: {plugin}")

    json_paths = sorted(plugin.rglob("*.json")) + [
        root / ".claude-plugin" / "marketplace.json",
        root / ".agents" / "plugins" / "marketplace.json",
    ]
    documents = {path: load_json(path) for path in json_paths}

    codex_path = plugin / ".codex-plugin" / "plugin.json"
    claude_path = plugin / ".claude-plugin" / "plugin.json"
    codex = require_object(load_json(codex_path), str(codex_path))
    claude = require_object(load_json(claude_path), str(claude_path))
    for label, manifest in (("Codex", codex), ("Claude", claude)):
        if manifest.get("name") != "coordkit":
            fail(f"{label} manifest name must be coordkit")
        validate_manifest_paths(plugin, manifest)

    if "hooks" in codex:
        fail("Codex manifest must not declare hooks; Codex discovers hooks/hooks.json")
    validate_agents(plugin, claude)

    version = require_string(codex.get("version"), "Codex manifest version")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", version):
        fail(f"Codex manifest version is not semantic: {version}")
    claude_version = require_string(claude.get("version"), "Claude manifest version")
    claude_market_path = root / ".claude-plugin" / "marketplace.json"
    claude_market = marketplace_plugin(documents[claude_market_path], claude_market_path)
    market_version = require_string(claude_market.get("version"), "Claude marketplace version")
    if len({version, claude_version, market_version}) != 1:
        fail(
            "package versions do not match: "
            f"Codex={version}, Claude={claude_version}, marketplace={market_version}"
        )

    source = require_string(claude_market.get("source"), "Claude marketplace source")
    if (root / source).resolve() != plugin:
        fail(f"Claude marketplace source must resolve to plugins/coordkit: {source}")

    agents_market_path = root / ".agents" / "plugins" / "marketplace.json"
    agents_market = marketplace_plugin(documents[agents_market_path], agents_market_path)
    source_object = require_object(agents_market.get("source"), "Agents marketplace source")
    agents_source = require_string(source_object.get("path"), "Agents marketplace source path")
    if (root / agents_source).resolve() != plugin:
        fail(f"Agents marketplace source must resolve to plugins/coordkit: {agents_source}")

    hooks_path = plugin / "hooks" / "hooks.json"
    validate_hooks(hooks_path)
    validate_adapter(plugin, plugin / "adapters" / "codex" / "adapter.json")
    validate_adapter(plugin, plugin / "adapters" / "claude-code" / "adapter.json")
    validate_executables(plugin)


def main(argv: list[str]) -> int:
    if len(argv) > 2:
        print("usage: validate-package.py [repository-root]", file=sys.stderr)
        return 2
    root = Path(argv[1]) if len(argv) == 2 else Path(__file__).resolve().parent.parent
    try:
        validate_repository(root)
    except ValidationError as error:
        print(f"package validation failed: {error}", file=sys.stderr)
        return 1
    print("package validation: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
