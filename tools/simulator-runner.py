#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Run a bounded real-input test on the native TX16S simulator."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
import zlib

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LIBRARY = Path(
    "/Applications/EdgeTX Companion 2.12.app/Contents/Resources/"
    "libedgetx-tx16s-simulator.dylib"
)
LOG_SIGNALS = {
    "firmware_error": re.compile(r"\bERROR in\b", re.IGNORECASE),
    "instruction_limit": re.compile(r"\bCPU limit\b|\bScript killed\b", re.IGNORECASE),
    "panic": re.compile(r"\bpanic\b", re.IGNORECASE),
    "lua_memory": re.compile(r"\bnot enough memory\b", re.IGNORECASE),
    "lua_shutdown": re.compile(r"\bLua shutdown\b", re.IGNORECASE),
    "lua_reference": re.compile(
        r"\bluaRef\(\).{0,80}\b(?:failed|failure|error)\b|"
        r"\b(?:failed|failure|error)\b.{0,80}\bluaRef\(\)",
        re.IGNORECASE
    ),
}
KEYWORDS = {"down", "up"}


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_sha256(root):
    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
    return digest.hexdigest()


def scheduler_support(root):
    source_files = list(root.rglob("*.lua"))
    detected = any(
        path.name == "scheduler_host.lua"
        or "schedulerTasks" in path.read_text(errors="replace")
        or "schedulerMode" in path.read_text(errors="replace")
        for path in source_files
    )
    return {
        "implementation_detected": detected,
        "effective_mode": (
            "unknown; scheduler implementation detected but Phase 1 does not select or verify its mode"
            if detected else "not applicable; scheduler implementation not detected in selected AeroGrid source"
        ),
    }


def parse_actions(path, ticks):
    actions = []
    previous = -1
    for line_number, original in enumerate(path.read_text().splitlines(), 1):
        line = original.partition("#")[0].strip()
        if not line:
            continue
        fields = line.split()
        try:
            tick = int(fields[0])
        except (ValueError, IndexError) as error:
            raise ValueError(f"invalid tick at line {line_number}") from error
        if tick < previous or not 0 <= tick < ticks:
            raise ValueError(f"unordered or out-of-range tick at line {line_number}")
        if len(fields) == 5 and fields[1] == "touch":
            x, y = int(fields[2]), int(fields[3])
            if not (0 <= x < 480 and 0 <= y < 272 and fields[4] in KEYWORDS):
                raise ValueError(f"invalid touch action at line {line_number}")
            action = {"tick": tick, "type": "touch", "x": x, "y": y, "state": fields[4]}
        elif len(fields) == 4 and fields[1] == "key":
            button = int(fields[2])
            if not (0 <= button <= 255 and fields[3] in KEYWORDS):
                raise ValueError(f"invalid key action at line {line_number}")
            action = {"tick": tick, "type": "key", "button": button, "state": fields[3]}
        elif len(fields) == 4 and fields[1] == "wait":
            timeout_ticks = int(fields[3])
            if not re.fullmatch(r"[A-Za-z0-9_,=+.-]+", fields[2]) or timeout_ticks <= 0:
                raise ValueError(f"invalid wait action at line {line_number}")
            action = {
                "tick": tick, "type": "wait", "token": fields[2],
                "timeout_ticks": timeout_ticks,
            }
        else:
            raise ValueError(f"invalid action at line {line_number}")
        actions.append(action)
        previous = tick
    return actions


def detect_log_signals(text):
    return [name for name, pattern in LOG_SIGNALS.items() if pattern.search(text)]


def progress_complete(heartbeat_seen, postcondition_seen, require_heartbeat):
    return postcondition_seen and (heartbeat_seen or not require_heartbeat)


def png_from_rgb565(raw, destination):
    if len(raw) != 480 * 272 * 2:
        raise ValueError(f"unexpected framebuffer size: {len(raw)}")
    rows = bytearray()
    for y in range(272):
        rows.append(0)
        start = y * 480 * 2
        for offset in range(start, start + 480 * 2, 2):
            pixel = raw[offset] | (raw[offset + 1] << 8)
            red = (pixel >> 11) & 0x1F
            green = (pixel >> 5) & 0x3F
            blue = pixel & 0x1F
            rows.extend(((red << 3) | (red >> 2),
                         (green << 2) | (green >> 4),
                         (blue << 3) | (blue >> 2)))

    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))

    image = (b"\x89PNG\r\n\x1a\n"
             + chunk(b"IHDR", struct.pack(">2I5B", 480, 272, 8, 2, 0, 0, 0))
             + chunk(b"IDAT", zlib.compress(bytes(rows)))
             + chunk(b"IEND", b""))
    destination.write_bytes(image)


def resolve_source(revision, run_dir):
    commit = subprocess.check_output(
        ["git", "rev-parse", "--verify", f"{revision}^{{commit}}"],
        cwd=ROOT, text=True
    ).strip()
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    prepared = run_dir / "prepared-source"
    source_path = Path("src/WIDGETS/AeroGrid")
    dirty_patch = run_dir / "dirty-source.patch"
    patch = subprocess.check_output(
        ["git", "diff", "HEAD", "--", str(source_path)], cwd=ROOT
    )
    dirty_patch.write_bytes(patch)
    untracked = subprocess.check_output(
        ["git", "ls-files", "--others", "--exclude-standard", "--", str(source_path)],
        cwd=ROOT, text=True
    ).splitlines()
    dirty_files = [
        {"path": name, "sha256": sha256_file(ROOT / name)}
        for name in untracked if (ROOT / name).is_file()
    ]
    if commit == head:
        shutil.copytree(ROOT / source_path, prepared)
        for name in untracked:
            item = ROOT / name
            if item.is_file():
                relative = item.relative_to(ROOT / source_path)
                target = prepared / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(item, target)
                dirty_files.append({"path": name, "sha256": sha256_file(item)})
    else:
        archive = subprocess.run(
            ["git", "archive", "--format=tar", commit, str(source_path)],
            cwd=ROOT, check=True, stdout=subprocess.PIPE
        ).stdout
        with tempfile.TemporaryDirectory(prefix="aerogrid-source-") as temporary:
            root = Path(temporary).resolve()
            import io
            with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
                for member in bundle.getmembers():
                    target = (root / member.name).resolve()
                    if root not in target.parents and target != root:
                        raise RuntimeError(f"unsafe source archive entry: {member.name}")
                    if member.isfile():
                        target.parent.mkdir(parents=True, exist_ok=True)
                        extracted = bundle.extractfile(member)
                        if extracted is None:
                            raise RuntimeError(f"cannot extract source file: {member.name}")
                        target.write_bytes(extracted.read())
            archived = root / str(source_path)
            if not archived.is_dir():
                raise RuntimeError(f"{revision} does not contain {source_path}")
            shutil.copytree(archived, prepared)

    development_layouts = ROOT / "tests/fixtures/layouts/development"
    shutil.copytree(development_layouts, prepared / "layouts", dirs_exist_ok=True)
    return {
        "requested_revision": revision,
        "resolved_commit": commit,
        "working_tree_changes_included": commit == head,
        "dirty_source_changes_detected": bool(patch or dirty_files),
        "dirty_source_changes_applied": commit == head,
        "dirty_patch": dirty_patch.name,
        "dirty_patch_sha256": sha256_file(dirty_patch),
        "untracked_source_files": dirty_files,
        "prepared_source_sha256": tree_sha256(prepared),
    }, prepared


def simulator_identity(library, architecture):
    architectures = subprocess.check_output(["lipo", "-archs", str(library)], text=True).split()
    if architecture and architecture not in architectures:
        raise ValueError(f"{library} does not contain requested architecture {architecture}")
    selected_arch = architecture or (architectures[0] if len(architectures) == 1 else None)
    if selected_arch is None:
        raise ValueError("universal simulator library requires --architecture")
    plist = library.parent.parent / "Info.plist"
    app_info = {}
    if plist.is_file():
        with plist.open("rb") as stream:
            metadata = plistlib.load(stream)
        app_info = {
            "bundle_identifier": metadata.get("CFBundleIdentifier"),
            "bundle_version": metadata.get("CFBundleVersion") or None,
            "short_version": metadata.get("CFBundleShortVersionString") or None,
        }
    return {
        "library": str(library),
        "library_sha256": sha256_file(library),
        "available_architectures": architectures,
        "selected_architecture": selected_arch,
        "companion": app_info,
    }


def compile_native(library, architecture, run_dir):
    executable = run_dir / "simulator-runner-native"
    frameworks = library.parent.parent / "Frameworks"
    command = [
        "clang++", "-std=c++11", "-arch", architecture,
        str(ROOT / "tools/simulator-runner-native.cpp"),
        f"-Wl,-rpath,{frameworks}", "-o", str(executable),
    ]
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    (run_dir / "build.log").write_text(result.stdout + result.stderr)
    (run_dir / "build-command.json").write_text(json.dumps({
        "command": command,
        "returncode": result.returncode,
    }, indent=2) + "\n")
    if result.returncode:
        raise RuntimeError(f"native runner compilation failed; inspect {run_dir / 'build.log'}")
    return executable


def install_progress_hook(widget, marker, reload_marker=None, ui_marker=None):
    main = widget / "main.lua"
    source = main.read_text()
    needle = "    refresh = refresh,"
    if source.count(needle) != 1:
        raise RuntimeError("AeroGrid refresh export changed; cannot install test-only progress hook")
    reload_hook = ""
    if reload_marker:
        reload_hook = f"""
        if not context.__runnerReloadRecorded and context.layoutName ~= "Empty"
            and not context.stage and not context.reloadState and context.document
            and #(context.document.panels or {{}}) > 0 then
            context.__runnerReloadRecorded = true
            local file = io.open("/{reload_marker}", "w")
            if file then
                io.write(file, "layout=" .. tostring(context.layoutName) .. "\\n")
                io.write(file, "errors=" .. #(context.errors or {{}}) .. "\\n")
                for _, placement in ipairs(context.document.panels or {{}}) do
                    io.write(file, "panel=" .. table.concat({{
                        tostring(placement.type or ""),
                        tostring(placement.col or ""),
                        tostring(placement.row or ""),
                        tostring(placement.colSpan or ""),
                        tostring(placement.rowSpan or ""),
                    }}, ",") .. "\\n")
                    for _, metric in ipairs(placement.config and placement.config.metrics or {{}}) do
                        io.write(file, "metric=" .. tostring(metric.source or "") .. ","
                            .. tostring(metric.label or "") .. "\\n")
                    end
                end
                io.close(file)
            end
        end
"""
    ui_hook = ""
    if ui_marker:
        ui_hook = f"""
        local state = context.editorUi
        local value = "drawer=none"
        if state and state.session and state.session.draft then
            local panels = state.session.draft.panels or {{}}
            local placement = panels[state.session.selected or 1]
            local metrics = placement and placement.config and placement.config.metrics or {{}}
            local first = metrics[1] or {{}}
            local second = metrics[2] or {{}}
            local geometry = placement and table.concat({{
                tostring(placement.col or 0), tostring(placement.row or 0),
                tostring(placement.colSpan or 1), tostring(placement.rowSpan or 1),
            }}, ",") or ""
            local drawer = "none"
            if state.nativeDrawer then
                if state.drawerListKey then
                    local path = state.drawerItemPath or {{}}
                    drawer = state.drawerListKey .. "," .. tostring(path[1] or 0)
                else
                    drawer = "panel"
                end
            end
            value = table.concat({{
                "panels=" .. #panels,
                "metrics-count=" .. #(placement and placement.config
                    and placement.config.metrics or {{}}),
                "metric1-source=" .. tostring(first.source or ""),
                "metric1-label=" .. tostring(first.label or ""),
                "metric2-source=" .. tostring(second.source or ""),
                "metric2-label=" .. tostring(second.label or ""),
                "geometry=" .. geometry,
                "geometry-moved=" .. tostring(placement and
                    ((placement.col or 0) ~= 0 or (placement.row or 0) ~= 0) or false),
                "geometry-resized=" .. tostring(placement and
                    ((placement.colSpan or 1) > 1 or (placement.rowSpan or 1) > 1) or false),
                "drawer=" .. drawer,
            }}, "\\n")
        end
        if value ~= context.__runnerUiState then
            context.__runnerUiState = value
            local file = io.open("/{ui_marker}", "w")
            if file then
                io.write(file, value)
                io.close(file)
            end
        end
"""
    replacement = f"""    refresh = function(context, widgetEvent, touchState)
        refresh(context, widgetEvent, touchState)
        if not context.__runnerProgressRecorded and not context.stage
            and not context.reloadState and #(context.panels or {{}}) > 0 then
            context.__runnerProgressRecorded = true
            local file = io.open("/{marker}", "w")
            if file then
                io.write(file, "dashboard refresh completed; errors=" .. #(context.errors or {{}})
                    .. "; panels=" .. #(context.panels or {{}}))
                io.close(file)
            end
        end
        {ui_hook}
        {reload_hook}
    end,"""
    main.write_text(source.replace(needle, replacement))


def supervise_process(command, log_path, timeout, popen_kwargs=None):
    started = time.monotonic()
    with log_path.open("wb") as log:
        process = subprocess.Popen(
            command, stdout=log, stderr=subprocess.STDOUT, **(popen_kwargs or {})
        )
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        elapsed = time.monotonic() - started
    return {"returncode": process.returncode, "timed_out": timed_out, "elapsed_seconds": elapsed}


def run_native(
    executable, library, sd, actions_path, frame, ticks, observe, log_path, timeout,
    snapshots=(),
):
    snapshot_plan = "-"
    if snapshots:
        snapshot_plan_path = frame.with_suffix(".snapshots.txt")
        snapshot_plan_path.write_text(
            "".join(f"{tick} {path}\n" for tick, path in snapshots)
        )
        snapshot_plan = str(snapshot_plan_path)
    command = [str(executable), str(library), str(sd), str(actions_path),
               str(frame), str(ticks), "1" if observe else "0", snapshot_plan]
    return supervise_process(command, log_path, timeout)


def detector_self_test():
    cases = {}
    for signal_name, example in (
        ("firmware_error", "ERROR in widget"),
        ("instruction_limit", "CPU limit reached"),
        ("instruction_limit", "Script killed"),
        ("panic", "panic: test"),
        ("lua_memory", "not enough memory"),
        ("lua_shutdown", "Lua shutdown"),
        ("lua_reference", "luaRef() failed"),
    ):
        cases.setdefault(signal_name, []).append(signal_name in detect_log_signals(example))

    import resource

    def no_core_dump():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        crash = supervise_process(
            [sys.executable, str(Path(__file__).resolve()), "--self-test-abort"],
            work / "abort.log", 5, {"preexec_fn": no_core_dump}
        )
        cases["owned_process_abort"] = [
            crash["returncode"] == -signal.SIGABRT and not crash["timed_out"]
        ]
        timed_out = supervise_process(
            [sys.executable, str(Path(__file__).resolve()), "--self-test-sleep"],
            work / "timeout.log", 0.1
        )
        cases["deadline_timeout"] = [
            timed_out["timed_out"] and timed_out["returncode"] != 0
        ]
    cases["missing_action_postcondition"] = [
        not progress_complete(False, False, True)
    ]
    return {
        "suite": "simulator-runner detector self-test",
        "parser_tests_are_end_to_end": False,
        "cases": {
            name: {"passed": all(results), "checks": len(results)}
            for name, results in cases.items()
        },
        "unverified_end_to_end": [
            "firmware trace messages on this selected build",
            "visible script-error overlay/state",
            "AeroGrid context.errors fault injection and rejected/failed panel detection",
            "instruction exhaustion injection",
            "Lua memory exhaustion injection",
            "stopped widget heartbeat in a live simulator",
            "native simulator binary abort injection",
            "resource-growth and instruction near-limit thresholds",
            "luaRef-specific allocation/reference failure",
        ],
        "overall_passed": all(all(results) for results in cases.values()),
    }


def execute(args):
    run_root = args.output_root.resolve()
    run_root.mkdir(parents=True, exist_ok=True)
    run_dir = run_root / f"run-{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"
    run_dir.mkdir()
    report_path = run_dir / "report.json"
    report = {
        "schema_version": 1,
        "run_id": run_dir.name,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "status": "incomplete",
        "failure_category": None,
        "last_confirmed_progress": None,
        "artifacts": {
            "run_directory": str(run_dir),
            "simulator_log": "simulator.log",
            "build_log": "build.log",
            "dirty_source_patch": "dirty-source.patch",
        },
    }
    try:
        if not args.library.is_file():
            raise FileNotFoundError(f"simulator library not found: {args.library}")
        library = args.library.resolve()
        identity = simulator_identity(library, args.architecture)
        report["simulator"] = identity
        source, prepared = resolve_source(args.revision, run_dir)
        report["aerogrid_source"] = source
        report["scheduler_mode"] = scheduler_support(prepared)

        seed = ROOT / "tests/fixtures/sdcard"
        initial_sd = run_dir / "initial-sd"
        sd = run_dir / "sdcard"
        shutil.copytree(seed, initial_sd)
        shutil.copytree(seed, sd)
        widget = sd / "WIDGETS/AeroGrid"
        widget.parent.mkdir(parents=True, exist_ok=True)
        if widget.exists():
            shutil.rmtree(widget)
        shutil.copytree(prepared, widget)
        shutil.copytree(
            ROOT / "tests/fixtures/layouts/development",
            widget / "layouts", dirs_exist_ok=True
        )
        if args.progress_hook:
            install_progress_hook(
                widget, "AEROGRID_RUNNER_PROGRESS.txt",
                ui_marker="AEROGRID_RUNNER_UI.txt",
            )
            (sd / "AEROGRID_RUNNER_PROGRESS.txt").unlink(missing_ok=True)
            (sd / "AEROGRID_RUNNER_UI.txt").unlink(missing_ok=True)
            report["isolated_instrumentation"] = {
                "progress_hook": (
                    "one-shot dashboard refresh marker and change-only editor-state marker "
                    "in the disposable SD widget copy"
                ),
                "instrumented_source_sha256": tree_sha256(widget),
            }
        report["sd"] = {
            "initial_snapshot": initial_sd.name,
            "working_copy": sd.name,
            "fixture": "tests/fixtures/sdcard",
        }

        ticks = max(1, round(args.duration * 100))
        actions = parse_actions(args.inputs, ticks) if args.inputs else []
        if any(action["type"] == "wait" for action in actions) and not args.progress_hook:
            raise ValueError("wait actions require --progress-hook")
        script_copy = run_dir / "inputs.txt"
        if args.inputs:
            shutil.copy2(args.inputs, script_copy)
        else:
            script_copy.write_text("# no input actions\n")
        report["input_script"] = {
            "file": script_copy.name,
            "sha256": sha256_file(script_copy),
            "actions": actions,
            "tick_duration_ms": 10,
        }
        if args.expect_file:
            marker = Path(args.expect_file)
            if marker.is_absolute() or ".." in marker.parts:
                raise ValueError("--expect-file must be a relative path inside the SD image")
            expected_marker = sd / marker
            if expected_marker.is_dir():
                raise ValueError("--expect-file names a directory")
            if marker.as_posix() == "AEROGRID_RUNNER_PROGRESS.txt":
                raise ValueError("--expect-file must be an action postcondition, not the runner heartbeat")
            if sd.resolve() not in expected_marker.resolve().parents:
                raise ValueError("--expect-file must resolve inside the disposable SD image")
            expected_marker.unlink(missing_ok=True)
            report["expected_progress_marker"] = marker.as_posix()

        executable = compile_native(library, identity["selected_architecture"], run_dir)
        frame = run_dir / "frame.rgb565"
        timeout = args.process_timeout or args.duration + 15
        unobserved_sd = None
        if args.measure_observation_overhead:
            unobserved_sd = run_dir / "sdcard-unobserved"
            shutil.copytree(sd, unobserved_sd)
        native = run_native(
            executable, library, sd, script_copy, frame, ticks, True,
            run_dir / "simulator.log", timeout
        )
        report["native_process"] = native
        if args.measure_observation_overhead:
            unobserved = run_native(
                executable, library, unobserved_sd, script_copy,
                run_dir / "unobserved.rgb565", ticks, False,
                run_dir / "simulator-unobserved.log", timeout
            )
            baseline = max(unobserved["elapsed_seconds"], 0.000001)
            report["observation_overhead"] = {
                "observed_run_seconds": native["elapsed_seconds"],
                "unobserved_run_seconds": unobserved["elapsed_seconds"],
                "wall_time_delta_percent": round(
                    (native["elapsed_seconds"] - baseline) / baseline * 100, 3
                ),
                "measured_scope": "host-side per-tick framebuffer copy versus no framebuffer copy",
                "budget_scope": "outside Lua callbacks; not an instruction-budget or telemetry-instrumentation measurement",
                "unobserved_process": unobserved,
            }
        logs = (run_dir / "simulator.log").read_text(errors="replace")
        report["log_signals"] = detect_log_signals(logs)
        if frame.is_file() and frame.stat().st_size == 480 * 272 * 2:
            png_from_rgb565(frame.read_bytes(), run_dir / "screenshot.png")
            report["artifacts"]["screenshot"] = "screenshot.png"
            report["artifacts"]["framebuffer_rgb565"] = frame.name

        marker_seen = bool(args.expect_file and expected_marker.is_file()
                           and expected_marker.stat().st_size > 0)
        heartbeat_marker = sd / "AEROGRID_RUNNER_PROGRESS.txt"
        heartbeat_seen = bool(args.progress_hook and heartbeat_marker.is_file()
                               and heartbeat_marker.stat().st_size > 0)
        if heartbeat_seen:
            marker_text = heartbeat_marker.read_text(errors="replace")
            match = re.search(r"\berrors=(\d+)\b", marker_text)
            report["aerogrid_context_error_count"] = int(match.group(1)) if match else None
            if report["aerogrid_context_error_count"] is None:
                report["log_signals"].append("invalid_progress_marker")
            elif report["aerogrid_context_error_count"] > 0:
                report["log_signals"].append("aerogrid_context_errors")
            report["last_confirmed_progress"] = {
                "heartbeat_marker": "AEROGRID_RUNNER_PROGRESS.txt",
                "content": marker_text[:2000],
            }
        if marker_seen:
            report["last_confirmed_progress"] = {
                "action_postcondition_marker": args.expect_file,
                "content": expected_marker.read_text(errors="replace")[:2000],
            }
        report["progress_marker_seen"] = heartbeat_seen
        report["action_postcondition_seen"] = marker_seen
        native_touch_events = logs.count("TE_PRESSED")
        native_release_events = logs.count("TE_RELEASED")
        report["input_delivery_observations"] = {
            "touch_pressed_log_events": native_touch_events,
            "touch_released_log_events": native_release_events,
            "note": "native event logs indicate dispatch, not that the intended UI postcondition occurred",
        }
        heap_path = Path(str(frame) + ".heap.json")
        heap = json.loads(heap_path.read_text()) if heap_path.is_file() else None
        if heap is not None:
            report["artifacts"]["lvgl_allocator_snapshot"] = heap_path.name
        report["resource_observations"] = {
            "lua_heap": "unavailable: live Lua heap sampling is not instrumented",
            "lvgl_heap": heap or "unavailable: lv_mem_monitor symbol not found",
            "lvgl_heap_scope": "peak is a lifetime high-water mark; free-space fields are sampled after shutdown",
            "instruction_usage": "unavailable: no instruction audit is enabled",
        }
        report["firmware_fidelity"] = {
            "firmware_commit": args.firmware_commit,
            "patch_build_identity": args.firmware_identity,
            "firmware_architecture": args.firmware_architecture,
            "firmware_build_flags": args.firmware_build_flags,
            "effective_budgets": args.firmware_budgets,
            "resource_caps": args.firmware_resource_caps or "unknown unless supplied by the user",
            "reproduction_status": "comparative only; matching radio build was not supplied",
        }
        report["artifacts"]["native_build_command"] = "build-command.json"
        report["detector_coverage"] = {
            "firmware_log_patterns": "parser verified; live delivery unverified",
            "native_exit_and_signal": "observed for this process",
            "deadline": "verified against a deliberately stuck child process",
            "scripted_state_wait": (
                "verified against test-only AeroGrid editor markers when --progress-hook is enabled"
            ),
            "progress_postcondition": "checked only when --expect-file is supplied",
            "visible_script_error_state": "unverified",
            "aerogrid_context_errors": (
                "one-shot count observed after refresh when --progress-hook is enabled; "
                "fault injection and failed-panel detection unverified"
            ),
            "instruction_and_resource_warnings": "unverified",
        }
        report["baseline_and_reproduction"] = {
            "simple_smoke": (
                "native run completed; dashboard heartbeat and touch dispatch are recorded, "
                "but this is not an action-level product assertion"
            ),
            "healthy_product_baseline": "not established without the matching firmware and an action-level postcondition",
            "luaRef_failure": "not reproduced; original sequence/build not provided",
            "instruction_limit_failure": "not reproduced; original sequence/build not provided",
            "observation_overhead": report.get("observation_overhead", {
                "measured": False,
                "reason": "rerun with --measure-observation-overhead for an observed/unobserved host-side framebuffer-copy comparison",
            }),
            "scheduler_audit": {
                "decision": "reject as the Phase 1 pass/fail counter; retain as a pinned diagnostic reference",
                "revision": "ed5f17feb1085bb104ea954ccd1a84286686f330",
                "reason": "audit-native patches luaSetInstructionsLimit, removes enforcement for measurement, and is x86_64-only; historical hook-check uses getUsage at 200-instruction resolution, but does not validate the current selected firmware/budgets.",
                "legacy_mixed_support": "the pinned revision exposes no scheduler-mode selector; comparisons require separate source revisions/builds and were not run.",
            },
        }
        report["product_health"] = (
            "unverified; run status reflects configured detectors and postconditions, "
            "not a reliable regression-gate result"
        )

        if native["timed_out"]:
            report["status"] = "failed"
            report["failure_category"] = "deadline"
        elif native["returncode"] != 0:
            report["status"] = "failed"
            report["failure_category"] = (
                "native_signal" if native["returncode"] < 0 else "native_exit"
            )
        elif report["log_signals"]:
            report["status"] = "failed"
            report["failure_category"] = "firmware_log"
        elif not report.get("artifacts", {}).get("screenshot"):
            report["status"] = "failed"
            report["failure_category"] = "display_capture"
        elif not progress_complete(heartbeat_seen, marker_seen, args.progress_hook):
            report["status"] = "incomplete"
            report["failure_category"] = (
                "unverified_action_postcondition" if not marker_seen else "missing_widget_progress"
            )
        else:
            report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["failure_category"] = "harness_error"
        report["error"] = f"{type(error).__name__}: {error}"
    finally:
        report["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        report["artifacts"]["report"] = report_path.name
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(run_dir)
    print(f"{report['status']}: {report.get('failure_category') or 'all configured checks passed'}")
    return 0 if report["status"] == "passed" else 1 if report["status"] == "failed" else 2


def tutorial_actions(recipe_path, destination):
    spec = importlib.util.spec_from_file_location("video_recipes", ROOT / "tools/video.py")
    video = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(video)
    recipe = video.load_recipe(recipe_path)
    actions = video.read_actions(recipe_path.parent / recipe["actions"], recipe["ticks"])
    lines = []
    for tick, x, y, down in actions:
        if recipe["id"] == "add-move-resize-panel" and tick == 2600:
            lines.extend((
                "2400 touch 200 234 down",
                "2420 touch 200 215 down",
                "2440 touch 200 196 down",
                "2460 touch 200 177 down",
                "2480 touch 200 158 down",
                "2500 touch 200 158 up",
            ))
        state = "down" if down else "up"
        if x < 0:
            if x != -2:
                raise ValueError(f"unsupported tutorial key marker: {x}")
            lines.append(f"{tick} key 1 {state}")
        else:
            lines.append(f"{tick} touch {x} {y} {state}")
    destination.write_text("\n".join(lines) + "\n")
    return recipe, parse_actions(destination, recipe["ticks"])


def metric_workflow_actions(recipe_path, destination):
    prelude_path = destination.with_name(destination.stem + "-prelude.txt")
    recipe, actions = tutorial_actions(recipe_path, prelude_path)
    lines = []
    for action in actions:
        if action["tick"] > 2620:
            break
        if action["type"] == "key":
            lines.append(
                f'{action["tick"]} key {action["button"]} {action["state"]}'
            )
        else:
            lines.append(
                f'{action["tick"]} touch {action["x"]} {action["y"]} {action["state"]}'
            )

    def tap(tick, x, y):
        lines.extend((f"{tick} touch {x} {y} down", f"{tick + 20} touch {x} {y} up"))

    def exit_key(tick):
        lines.extend((f"{tick} key 1 down", f"{tick + 20} key 1 up"))

    def wait_state(tick, token, timeout_ticks=1000):
        lines.append(f"{tick} wait {token} {timeout_ticks}")

    def scroll_sources(first_tick):
        for tick in range(first_tick, first_tick + 700, 50):
            lines.extend((
                f"{tick} touch 300 230 down",
                f"{tick + 10} touch 300 170 down",
                f"{tick + 20} touch 300 120 down",
                f"{tick + 30} touch 300 80 down",
                f"{tick + 40} touch 300 80 up",
            ))

    def enter_label(label, tick, clear_existing=0):
        tap(tick, 300, 80)
        tick += 50
        keyboard = {
            "qwertyuiop": (178, (64, 100, 138, 176, 213, 250, 290, 324, 359, 397)),
            "asdfghjkl": (204, (89, 127, 166, 204, 243, 281, 319, 357, 395)),
            "zxcvbnm": (230, (100, 139, 177, 216, 254, 293, 332)),
        }
        coordinates = {}
        for keys, (y, positions) in keyboard.items():
            coordinates.update({
                character: (x, y) for character, x in zip(keys, positions)
            })
        for _ in range(clear_existing):
            tap(tick, 447, 178)
            tick += 30
        for character in label:
            x, y = coordinates[character]
            lines.extend((f"{tick} touch {x} {y} down", f"{tick + 10} touch {x} {y} up"))
            tick += 30
        tap(tick, 447, 256)

    tap(2900, 280, 100)
    wait_state(2950, "panels=1")
    tap(3200, 280, 100)
    wait_state(3250, "drawer=metrics,1")
    tap(3400, 280, 116)
    scroll_sources(3550)
    tap(4250, 250, 171)
    wait_state(4300, "metric1-source=GSpd")
    enter_label("speed", 4400)
    wait_state(4650, "metric1-label=speed")
    exit_key(4800)
    wait_state(4850, "drawer=panel")

    tap(5000, 230, 136)
    wait_state(5050, "metrics-count=2")
    tap(5200, 280, 136)
    wait_state(5250, "drawer=metrics,2")
    tap(5400, 280, 116)
    scroll_sources(5550)
    tap(6250, 250, 241)
    wait_state(6300, "metric2-source=GSpd+")
    enter_label("max", 6400, clear_existing=len("speed"))
    wait_state(6750, "metric2-label=max")
    exit_key(6800)
    wait_state(6850, "drawer=panel")
    exit_key(7000)
    wait_state(7050, "drawer=none")

    spec = importlib.util.spec_from_file_location("video_recipes", ROOT / "tools/video.py")
    video = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(video)
    original = video.read_actions(recipe_path.parent / recipe["actions"], recipe["ticks"])
    for tick, x, y, down in original:
        if tick < 9600:
            continue
        state = "down" if down else "up"
        lines.append(
            f"{tick} key 1 {state}" if x < 0
            else f"{tick} touch {x} {y} {state}"
        )
    wait_state(9800, "geometry-moved=true")
    wait_state(10300, "geometry-resized=true")
    lines.sort(key=lambda line: int(line.split(maxsplit=1)[0]))
    destination.write_text("\n".join(lines) + "\n")
    return recipe, parse_actions(destination, recipe["ticks"])


def prepare_metric_workflow(sd, widget):
    spec = importlib.util.spec_from_file_location(
        "capture_editor", ROOT / "tools/capture-editor.py"
    )
    capture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(capture)
    capture.prepare(sd, "select-layout")
    prepared_widget = sd / "WIDGETS/AeroGrid"
    shutil.rmtree(prepared_widget)
    shutil.copytree(widget, prepared_widget)

    model = sd / "MODELS/model1.yml"
    model_text = model.read_text()
    empty_layout_option = re.compile(
        r"(widgetName: AeroGrid\n[ \t]+widgetData:\n[ \t]+options:\n"
        r"[ \t]+0:\n[ \t]+type: Unsigned\n[ \t]+value:\n"
        r"[ \t]+unsignedValue: )2\b"
    )
    model_text, replacements = empty_layout_option.subn(r"\g<1>1", model_text, count=1)
    if replacements != 1:
        raise RuntimeError("cannot set the initial dashboard to Empty")
    model.write_text(model_text)
    with model.open("a") as output:
        output.write("""telemetrySensors:
   0:
      id1:
         id: 2
      id2:
         instance: 2
      label: "GSpd"
      subId: 0
      type: TYPE_CUSTOM
      unit: 7
      prec: 1
      cfg:
         custom:
            ratio: 0
            offset: 0
""")
    (prepared_widget / "runner-inputs.lua").write_text("""
setTelemetryValue(2, 0, 2, 725, 7, 1, "GSpd")
local speed = assert(getFieldInfo("GSpd"))
local maximum = assert(getFieldInfo("GSpd+"))
return {
    getValue = function(id)
        if id == speed.id or id == "GSpd" then return 48 end
        if id == maximum.id or id == "GSpd+" then return 72 end
        return getValue(id)
    end,
    getRSSI = function() return 85 end,
}
""")
    loader = prepared_widget / "lib/dashboard_loader.lua"
    source = loader.read_text()
    needle = "support.environment()"
    if source.count(needle) != 1:
        raise RuntimeError("AeroGrid environment hook changed; cannot seed workflow telemetry")
    loader.write_text(source.replace(
        needle,
        'support.environment(assert(loadScript("/WIDGETS/AeroGrid/runner-inputs.lua"))())',
    ))
    registry = sd / "AEROGRID/layout-registry.txt"
    registry.write_text("Empty\nDefault\nDiagnostics\nPalette\n")


def select_saved_layout(model, layout_index):
    model_text = model.read_text()
    option = re.compile(
        r"(widgetName: AeroGrid\n[ \t]+widgetData:\n[ \t]+options:\n"
        r"[ \t]+0:\n[ \t]+type: Unsigned\n[ \t]+value:\n"
        r"[ \t]+unsignedValue: )1\b"
    )
    model_text, replacements = option.subn(rf"\g<1>{layout_index}", model_text, count=1)
    if replacements != 1:
        raise ValueError("cannot select the newly saved AeroGrid layout")
    model.write_text(model_text)


def parse_reload_marker(path):
    values = {"panels": [], "metrics": []}
    for line in path.read_text().splitlines():
        key, separator, value = line.partition("=")
        if not separator:
            raise ValueError("malformed reload marker")
        if key == "panel":
            fields = value.split(",")
            if len(fields) != 5:
                raise ValueError("malformed panel in reload marker")
            values["panels"].append({
                "type": fields[0],
                "col": int(fields[1]),
                "row": int(fields[2]),
                "colSpan": int(fields[3]),
                "rowSpan": int(fields[4]),
            })
        elif key == "metric":
            source, separator, label = value.partition(",")
            if not separator:
                raise ValueError("malformed metric in reload marker")
            values["metrics"].append({"source": source, "label": label})
        elif key in ("layout", "errors"):
            values[key] = value if key == "layout" else int(value)
        else:
            raise ValueError(f"unexpected reload marker field: {key}")
    return values


def execute_metric_workflow(args):
    run_root = args.output_root.resolve()
    run_root.mkdir(parents=True, exist_ok=True)
    run_dir = run_root / f"run-{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"
    run_dir.mkdir()
    report_path = run_dir / "report.json"
    report = {
        "schema_version": 1,
        "run_id": run_dir.name,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "status": "incomplete",
        "failure_category": None,
        "workflow": "add-move-resize-save-restart",
        "artifacts": {
            "run_directory": str(run_dir),
            "build_log": "build.log",
            "dirty_source_patch": "dirty-source.patch",
        },
    }
    try:
        if not args.library.is_file():
            raise FileNotFoundError(f"simulator library not found: {args.library}")
        library = args.library.resolve()
        identity = simulator_identity(library, args.architecture)
        report["simulator"] = identity
        source, prepared = resolve_source(args.revision, run_dir)
        report["aerogrid_source"] = source
        report["scheduler_mode"] = scheduler_support(prepared)

        sd = run_dir / "sdcard"
        prepare_metric_workflow(sd, prepared)
        initial_radio = sd / "RADIO/radio.yml"
        initial_model = sd / "MODELS/model1.yml"
        if not initial_radio.is_file() or not initial_model.is_file():
            raise RuntimeError("prepared SD image is missing radio settings or model1")
        radio_backup = run_dir / "initial-radio.yml"
        model_backup = run_dir / "initial-model1.yml"
        shutil.copy2(initial_radio, radio_backup)
        shutil.copy2(initial_model, model_backup)
        report["artifacts"]["restart_input_backups"] = [
            radio_backup.name, model_backup.name,
        ]
        install_progress_hook(
            sd / "WIDGETS/AeroGrid",
            "AEROGRID_RUNNER_PROGRESS.txt",
            "AEROGRID_RUNNER_RELOAD.txt",
            "AEROGRID_RUNNER_UI.txt",
        )
        report["isolated_instrumentation"] = {
            "telemetry": "deterministic GSpd/GSpd+ samples on the disposable SD image",
            "reload_assertion": "test-only refresh marker reports loaded layout, geometry, settings, and errors",
            "instrumented_source_sha256": tree_sha256(sd / "WIDGETS/AeroGrid"),
        }

        recipe_path = ROOT / "tools/video-recipes/add-move-resize-panel.json"
        inputs = run_dir / "workflow-inputs.txt"
        recipe, actions = metric_workflow_actions(recipe_path, inputs)
        report["input_script"] = {
            "file": inputs.name,
            "sha256": sha256_file(inputs),
            "actions": actions,
            "tick_duration_ms": 10,
        }
        executable = compile_native(library, identity["selected_architecture"], run_dir)
        first_frame = run_dir / "workflow.rgb565"
        first_timeout = args.process_timeout or recipe["ticks"] / 100 + 15
        checkpoint_ticks = (
            3000, 3300, 4300, 4700, 5300, 6300, 6750, 7100, 9000,
            9600, 9900, 11300,
        )
        snapshots = [
            (tick, run_dir / f"workflow-tick-{tick}.rgb565")
            for tick in checkpoint_ticks
        ]
        first = run_native(
            executable, library, sd, inputs, first_frame, recipe["ticks"], True,
            run_dir / "workflow.log", first_timeout, snapshots
        )
        report["workflow_process"] = first
        report["artifacts"]["workflow_checkpoints"] = [
            path.name for _, path in snapshots
        ]
        for _, path in snapshots:
            if path.is_file() and path.stat().st_size == 480 * 272 * 2:
                png_from_rgb565(path.read_bytes(), path.with_suffix(".png"))
        first_log = (run_dir / "workflow.log").read_text(errors="replace")
        report["log_signals"] = detect_log_signals(first_log)
        if first_frame.is_file() and first_frame.stat().st_size == 480 * 272 * 2:
            png_from_rgb565(first_frame.read_bytes(), run_dir / "workflow.png")
            report["artifacts"]["workflow_screenshot"] = "workflow.png"
        if first["timed_out"] or first["returncode"] != 0:
            report["status"] = "failed"
            report["failure_category"] = (
                "deadline" if first["timed_out"] else
                "action_deadline" if "Timed out waiting for UI state" in first_log else
                "native_process"
            )
            raise RuntimeError("workflow simulator process failed")
        if report["log_signals"]:
            report["status"] = "failed"
            report["failure_category"] = "firmware_log"
            raise RuntimeError("workflow produced a detected firmware error")

        import yaml

        user_layouts = sd / "AEROGRID/layouts"
        created = sorted(user_layouts.glob("*.yaml"))
        if len(created) != 1:
            raise ValueError(f"expected one Save as layout, found {len(created)}")
        saved_path = created[0]
        saved_document = yaml.safe_load(saved_path.read_text())
        panels = saved_document.get("panels") if isinstance(saved_document, dict) else None
        if not isinstance(panels, list) or len(panels) != 1:
            raise ValueError("saved layout must contain exactly one panel")
        placement = panels[0]
        if placement.get("type") != "metric":
            raise ValueError("saved panel is not a metric")
        metrics = placement.get("config", {}).get("metrics")
        if not isinstance(metrics, list) or len(metrics) != 2:
            raise ValueError("saved metric panel does not contain two configured readings")
        labels = {metric.get("label") for metric in metrics if isinstance(metric, dict)}
        if labels != {"speed", "max"}:
            raise ValueError(f"saved metric labels differ from workflow expectation: {labels}")
        saved_geometry = {
            key: placement.get(key) for key in ("col", "row", "colSpan", "rowSpan")
        }
        if saved_geometry == {"col": 0, "row": 0, "colSpan": 2, "rowSpan": 2}:
            raise ValueError("panel geometry was not changed before Save as")
        report["saved_layout"] = {
            "path": str(saved_path.relative_to(sd)),
            "sha256": sha256_file(saved_path),
            "geometry": saved_geometry,
            "panel_type": placement["type"],
            "metric_labels": sorted(labels),
        }

        registry_path = sd / "AEROGRID/layout-registry.txt"
        registry = registry_path.read_text().splitlines()
        if saved_path.stem not in registry:
            registry.append(saved_path.stem)
        registry_path.write_text("\n".join(registry) + "\n")
        model = sd / "MODELS/model1.yml"
        shutil.copy2(model_backup, model)
        select_saved_layout(model, registry.index(saved_path.stem) + 1)
        shutil.copy2(radio_backup, initial_radio)
        report["fresh_process_restart"] = {
            "layout_choice_index": registry.index(saved_path.stem) + 1,
            "selected_layout": saved_path.stem,
            "restored_isolated_inputs": [
                "original model1.yml plus selected AeroGrid Layout option",
                "original radio.yml to avoid Companion shutdown corruption",
            ],
        }

        restart_inputs = run_dir / "restart-inputs.txt"
        restart_inputs.write_text("# fresh-process persistence check\n")
        restart_frame = run_dir / "restart.rgb565"
        restart = run_native(
            executable, library, sd, restart_inputs, restart_frame, 600, True,
            run_dir / "restart.log", args.process_timeout or 30
        )
        report["restart_process"] = restart
        restart_log = (run_dir / "restart.log").read_text(errors="replace")
        report["log_signals"].extend(detect_log_signals(restart_log))
        if restart_frame.is_file() and restart_frame.stat().st_size == 480 * 272 * 2:
            png_from_rgb565(restart_frame.read_bytes(), run_dir / "restart.png")
            report["artifacts"]["restart_screenshot"] = "restart.png"
        marker = sd / "AEROGRID_RUNNER_RELOAD.txt"
        if restart["timed_out"] or restart["returncode"] != 0:
            report["status"] = "failed"
            report["failure_category"] = "restart_process"
            raise RuntimeError("fresh-process restart failed")
        if report["log_signals"]:
            report["status"] = "failed"
            report["failure_category"] = "firmware_log"
            raise RuntimeError("restart produced a detected firmware error")
        if not marker.is_file():
            raise ValueError("fresh-process reload assertion did not run")
        loaded = parse_reload_marker(marker)
        if loaded.get("layout") != saved_path.stem:
            raise ValueError(f"reloaded layout differs: {loaded.get('layout')}")
        if loaded.get("errors") != 0:
            raise ValueError(f"reloaded dashboard reported {loaded.get('errors')} errors")
        if len(loaded["panels"]) != 1 or loaded["panels"][0]["type"] != "metric":
            raise ValueError("fresh process did not load exactly one metric panel")
        loaded_geometry = {
            key: loaded["panels"][0].get(key)
            for key in ("col", "row", "colSpan", "rowSpan")
        }
        if loaded_geometry != saved_geometry:
            raise ValueError("fresh-process panel geometry differs from saved configuration")
        if {metric["label"] for metric in loaded["metrics"]} != labels:
            raise ValueError("fresh-process metric settings differ from saved configuration")
        report["fresh_process_restart"]["loaded_state"] = loaded
        report["progress_marker_seen"] = bool(
            (sd / "AEROGRID_RUNNER_PROGRESS.txt").is_file()
        )
        report["action_postcondition_seen"] = True
        report["workflow_result"] = {
            "name": "add-move-resize-save-restart",
            "status": "passed",
            "assertions": [
                "real touch/key input added and configured a two-reading Metric panel",
                "saved panel geometry differs from the initial placement",
                "fresh process loaded the selected saved layout with identical geometry and settings",
                "reloaded dashboard reported zero context.errors",
            ],
        }
        report["resource_observations"] = {
            "lvgl_workflow": (
                json.loads(Path(str(first_frame) + ".heap.json").read_text())
                if Path(str(first_frame) + ".heap.json").is_file() else "unavailable"
            ),
            "lvgl_restart": (
                json.loads(Path(str(restart_frame) + ".heap.json").read_text())
                if Path(str(restart_frame) + ".heap.json").is_file() else "unavailable"
            ),
            "lua_heap": "unavailable: live Lua heap sampling is not instrumented",
            "instruction_usage": "unavailable: no instruction audit is enabled",
        }
        report["status"] = "passed"
    except Exception as error:
        if report["status"] != "failed":
            report["status"] = "failed"
            report["failure_category"] = "workflow_assertion"
        report["error"] = f"{type(error).__name__}: {error}"
    finally:
        report["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        report["artifacts"]["report"] = report_path.name
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(run_dir)
    print(f"{report['status']}: {report.get('failure_category') or 'all workflow assertions passed'}")
    return 0 if report["status"] == "passed" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, default=DEFAULT_LIBRARY)
    parser.add_argument("--revision", default="HEAD", help="AeroGrid Git revision or branch")
    parser.add_argument("--architecture", choices=("arm64", "x86_64"))
    parser.add_argument("--inputs", type=Path, help="Real touch/key input script")
    parser.add_argument("--duration", type=float, default=30, help="Run length in seconds")
    parser.add_argument("--process-timeout", type=float,
                        help="Wall-clock deadline; defaults to duration plus a 15-second startup/shutdown margin")
    parser.add_argument("--expect-file", help="Required progress marker, relative to the disposable SD")
    parser.add_argument("--progress-hook", action="store_true",
                        help="Instrument only the disposable AeroGrid copy with a one-shot refresh marker")
    parser.add_argument("--measure-observation-overhead", action="store_true",
                        help="Run an additional unobserved copy of the same input plan")
    parser.add_argument(
        "--workflow", choices=("add-move-resize-save-restart",),
        help="Run a named fixed workflow with postconditions and a fresh-process reload check",
    )
    parser.add_argument("--output-root", type=Path, default=ROOT / "build/simulator-stress")
    parser.add_argument("--firmware-commit", help="Known EdgeTX firmware commit")
    parser.add_argument("--firmware-identity", help="Known firmware patch/build identity")
    parser.add_argument("--firmware-architecture", help="Known firmware target architecture")
    parser.add_argument("--firmware-build-flags", help="Known firmware build flags")
    parser.add_argument("--firmware-budgets", help="Known effective instruction budgets")
    parser.add_argument("--firmware-resource-caps", help="Known Lua/LVGL allocator limits")
    parser.add_argument("--self-test", action="store_true", help="Run detector self-tests without Companion")
    parser.add_argument("--self-test-abort", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--self-test-sleep", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.self_test_abort:
        os.abort()
    if args.self_test_sleep:
        time.sleep(30)
        return 0
    if args.self_test:
        result = detector_self_test()
        print(json.dumps(result, indent=2))
        return 0 if result["overall_passed"] else 1
    if args.duration <= 0 or args.duration > 3600:
        parser.error("--duration must be greater than 0 and at most 3600 seconds")
    if args.process_timeout is not None and args.process_timeout <= 0:
        parser.error("--process-timeout must be greater than 0")
    if args.inputs and not args.inputs.is_file():
        parser.error(f"input script not found: {args.inputs}")
    if args.workflow and (args.inputs or args.expect_file or args.progress_hook):
        parser.error("--workflow cannot be combined with --inputs, --expect-file, or --progress-hook")
    if args.workflow:
        return execute_metric_workflow(args)
    return execute(args)


if __name__ == "__main__":
    raise SystemExit(main())
