#!/usr/bin/env python3
"""Thin wrapper that forwards to the package-owned agent runtime."""

from __future__ import annotations

import os
import sys
from pathlib import Path


def main() -> None:
    wrapper = Path(__file__).resolve()
    plugin_root = wrapper.parent.parent
    core_root = wrapper.parents[3] / "packages" / "coordkit-core"
    os.environ.setdefault("COORDKIT_PLUGIN_ROOT", str(plugin_root))
    os.environ.setdefault("COORDKIT_CORE_ROOT", str(core_root))
    os.execv(sys.executable, [sys.executable, str(core_root / "scripts" / "agent-runtime.py"), *sys.argv[1:]])


if __name__ == "__main__":
    main()
