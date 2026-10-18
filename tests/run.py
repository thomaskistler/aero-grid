# SPDX-License-Identifier: GPL-2.0-only

from pathlib import Path
import sys

from lupa.lua53 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


def run_test(path: Path) -> None:
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
    try:
        lua.execute(path.read_text(encoding="ascii"), str(ROOT))
    except Exception:
        print(f"Failed Lua suite: {path}", file=sys.stderr)
        if len(logs):
            print("Captured AeroGrid logs:", file=sys.stderr)
            for index in range(1, len(logs) + 1):
                print(logs[index], file=sys.stderr)
        raise


def main() -> None:
    for test_path in sorted((ROOT / "tests").rglob("test_*.lua")):
        if "support" in test_path.relative_to(ROOT).parts:
            continue
        run_test(test_path)


if __name__ == "__main__":
    main()