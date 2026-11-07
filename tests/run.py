# SPDX-License-Identifier: GPL-2.0-only

from pathlib import Path
import sys

from lupa.lua53 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


def run_test(path: Path, *, instructions=False):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute('debug.setmetatable("", nil)')
    logs = lua.execute("""
        local originalPrint = print
        local logs = {}
        local prefix = "[AeroGrid] ERROR "
        print = function(...)
            local message = ...
            if type(message) == "string"
                and string.sub(message, 1, #prefix) == prefix then
                local parts = {}
                for index = 1, select("#", ...) do
                    parts[index] = tostring(select(index, ...))
                end
                logs[#logs + 1] = table.concat(parts, "\\t")
            else
                originalPrint(...)
            end
        end
        return logs
    """)
    recorder = declarations = None
    if instructions:
        rows = {}
        declared = {}
        def declare(name, stage, maximum):
            key = name + "|" + stage
            declared[key] = max(declared.get(key, 0), maximum)
        def sample(kind, name, stage, grant, cost, ok, scenario):
            key = (kind, name, stage, grant)
            row = rows.get(key)
            if row is None:
                row = dict(kind=kind, name=name, stage=stage, grant=grant, n=0,
                           min=cost, max=cost, failures=0,
                           minScenario=scenario, maxScenario=scenario)
                rows[key] = row
            row["n"] += 1
            row["failures"] += int(ok is False)
            if cost < row["min"]:
                row["min"], row["minScenario"] = cost, scenario
            if cost > row["max"]:
                row["max"], row["maxScenario"] = cost, scenario
        costs = lua.execute("""
            local root = ...
            local base = root .. "/src/WIDGETS/AeroGrid/lib/"
            return assert(loadfile(base .. "costs.lua"))().new(
                assert(loadfile(base .. "instruction_snapshot.lua"))())
        """, str(ROOT))
        recorder, declarations = lua.execute(
            (ROOT / "tests/support/instruction_profile.lua").read_text(encoding="ascii"),
            str(ROOT), costs, path.relative_to(ROOT).as_posix(), sample, declare,
        )
    else:
        lua.execute(
            (ROOT / "tests/support/costs.lua").read_text(encoding="ascii"), str(ROOT)
        )
    try:
        lua.execute(path.read_text(encoding="ascii"), str(ROOT))
    except Exception:
        print(f"Failed Lua suite: {path}", file=sys.stderr)
        if len(logs):
            print("Captured AeroGrid logs:", file=sys.stderr)
            for index in range(1, len(logs) + 1):
                print(logs[index], file=sys.stderr)
        raise
    if instructions:
        return rows, declared


def main() -> None:
    for test_path in sorted((ROOT / "tests").rglob("test_*.lua")):
        if "support" in test_path.relative_to(ROOT).parts:
            continue
        run_test(test_path)


if __name__ == "__main__":
    main()