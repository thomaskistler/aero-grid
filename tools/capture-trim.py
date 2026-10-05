# SPDX-License-Identifier: GPL-2.0-only
"""Compatibility entry point for the original trim capture command."""
import runpy
import sys
from pathlib import Path

if __name__ == "__main__":
    sys.argv[1:1] = ["--component", "trim-panel"]
    runpy.run_path(str(Path(__file__).with_name("capture-panels.py")), run_name="__main__")
