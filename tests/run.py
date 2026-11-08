# SPDX-License-Identifier: GPL-2.0-only

from pathlib import Path
import argparse
import sys

from lupa.lua53 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


class InstrumentedSuiteError(RuntimeError):
    def __init__(self, error, rows, declarations):
        super().__init__(str(error))
        self.rows = rows
        self.declarations = declarations


def run_test(path: Path, *, instructions=False, snapshot_path=None, work_samples=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute('debug.setmetatable("", nil)')
    if snapshot_path is not None:
        lua.execute("""
            local candidate = ...
            local originalLoadfile = loadfile
            function loadfile(filename, ...)
                if type(filename) == "string"
                    and string.match(filename, "/lib/instruction_snapshot%.lua$") then
                    filename = candidate
                end
                return originalLoadfile(filename, ...)
            end
        """, str(snapshot_path))
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
        sys.path.insert(0, str(ROOT / "tools"))
        import scheduler_audit
        from instruction_snapshot import native_bound, load as load_snapshot, load_estimates
        estimates = load_estimates(snapshot_path) if snapshot_path else load_snapshot()["estimates"]
        def span_bound(label):
            result = native_bound(label, estimates)
            if result is None:
                return None
            name, stage, exclusive = result
            return lua.table_from(dict(name=name, stage=stage, exclusive=exclusive))
        def patched_main(filename):
            source = scheduler_audit.patch_main(Path(filename).read_text(encoding="ascii"))
            for original, replacement in scheduler_audit.MAIN_PATCHES:
                source = source.replace(replacement, original)
            return source.removeprefix(scheduler_audit.MAIN_PREFIX)
        lua.globals().__instructionSpanBound = span_bound
        lua.globals().__instructionMain = patched_main
        if work_samples is not None:
            def witness(value):
                work_samples.append(dict(value.items(), suite=path.relative_to(ROOT).as_posix()))
            lua.globals().__instructionWitness = witness
        lua.execute("""
            local originalLoadfile = loadfile
            function loadfile(filename, ...)
                if type(filename) == "string" and string.match(filename, "WIDGETS/AeroGrid/main%.lua$") then
                    return load(__instructionMain(filename), "@" .. filename)
                end
                return originalLoadfile(filename, ...)
            end
        """)
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
    except Exception as error:
        print(f"Failed Lua suite: {path}", file=sys.stderr)
        if len(logs):
            print("Captured AeroGrid logs:", file=sys.stderr)
            for index in range(1, len(logs) + 1):
                print(logs[index], file=sys.stderr)
        if instructions:
            raise InstrumentedSuiteError(error, rows, declared) from error
        raise
    if instructions:
        return rows, declared


def main() -> None:
    parser = argparse.ArgumentParser(description="Run Lua suites in fresh mock runtimes.")
    parser.add_argument("suites", nargs="*", type=Path, help="Lua test files; omit to run all suites")
    parser.add_argument("--snapshot", type=Path, help="Use this candidate snapshot without replacing the shipped file")
    args = parser.parse_args()
    snapshot = args.snapshot.resolve() if args.snapshot else None
    if snapshot is not None and not snapshot.is_file():
        parser.error(f"Snapshot file not found: {snapshot}")
    if args.suites:
        suites = []
        for path in args.suites:
            path = path.resolve()
            if not path.is_relative_to(ROOT / "tests") or not path.name.startswith("test_") \
                    or path.suffix != ".lua" or not path.is_file() \
                    or "support" in path.relative_to(ROOT / "tests").parts:
                parser.error(f"Not a Lua test suite beneath tests/: {path}")
            suites.append(path)
    else:
        suites = [path for path in sorted((ROOT / "tests").rglob("test_*.lua"))
                  if "support" not in path.relative_to(ROOT).parts]
    for path in suites:
        run_test(path, snapshot_path=snapshot)


if __name__ == "__main__":
    main()