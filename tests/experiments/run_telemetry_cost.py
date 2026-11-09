# SPDX-License-Identifier: GPL-2.0-only
"""Attribute warmed telemetry Lua opcodes without altering the firmware hook."""

import argparse
import json
import re
import subprocess
from pathlib import Path

from lupa.lua53 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline", action="store_true", help="Use preserved build/*-baseline.lua modules")
parser.add_argument("--baseline-ref", help="Preserve the three original modules from this Git ref in build/")
parser.add_argument("--verify", action="store_true", help="Compare exact recorder and mipmap output instead of profiling")
args = parser.parse_args()
if args.baseline_ref:
    (ROOT / "build").mkdir(exist_ok=True)
    for name in ("chart_mipmap", "history_service", "telemetry_service"):
        source = subprocess.check_output(
            ["git", "show", f"{args.baseline_ref}:src/WIDGETS/AeroGrid/lib/{name}.lua"],
            cwd=ROOT, text=True,
        )
        (ROOT / f"build/{name}-baseline.lua").write_text(source)
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('debug.setmetatable("", nil)')
if args.verify:
    lua.execute((ROOT / "tests/experiments/telemetry_equivalence.lua").read_text(encoding="ascii"), str(ROOT))
    raise SystemExit(0)
rows = lua.execute((ROOT / "tests/experiments/telemetry_cost.lua").read_text(encoding="ascii"),
                   str(ROOT), args.baseline)
results = []
for row in rows.values():
    costs = {}
    for location, count in row["counts"].items():
        path, line = location.removeprefix("@").rsplit(":", 1)
        path = Path(path)
        if not path.is_file():
            continue
        definition = path.read_text().splitlines()[int(line) - 1] if int(line) else "<chunk>"
        name = re.search(r"(?:local )?function ([\w.:]+)", definition)
        key = f"{path.name}:{name[1] if name else definition.strip()}"
        costs[key] = count / row["updates"]
    results.append({key: row[key] for key in ("smoothing", "copies", "cap", "updates")} |
                   {"instructions_per_update": dict(sorted(costs.items()))})
print(json.dumps(results, indent=2))
