# SPDX-License-Identifier: GPL-2.0-only

from pathlib import Path

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


def run_test(path: Path, remove_string_metatable: bool = False) -> None:
    lua = LuaRuntime(unpack_returned_tuples=True)
    if remove_string_metatable:
        lua.execute('debug.setmetatable("", nil)')
    lua.execute(path.read_text(encoding="ascii"), str(ROOT))


for test_name in ("test_runtime.lua", "test_widget.lua"):
    test_path = ROOT / "tests" / test_name
    run_test(test_path)
    run_test(test_path, remove_string_metatable=True)