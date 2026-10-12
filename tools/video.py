# SPDX-License-Identifier: GPL-2.0-only
"""Recipe-driven native TX16S capture, cached Azure narration and FFmpeg rendering."""
import argparse
import hashlib
import importlib.util
import io
import json
import math
import mmap
import os
from pathlib import Path
import re
import struct
import subprocess
import urllib.error
import urllib.request
import wave
from xml.sax.saxutils import escape
import zlib

ROOT = Path(__file__).resolve().parents[1]
RECIPES = ROOT / "tools/video-recipes"
DEFAULT_LIBRARY = Path(
    "/Applications/EdgeTX Companion 2.12.app/Contents/Resources/libedgetx-tx16s-simulator.dylib")
VOICE = "en-US-CoraMultilingualNeural"
FPS = 20
FRAME_BYTES = 480 * 272 * 2


def fields(value, required, optional=()):
    if not isinstance(value, dict) or set(value) - set(required) - set(optional) or set(required) - set(value):
        raise ValueError(f"Expected fields {', '.join(required)}; optional: {', '.join(optional)}")


def number(value, minimum=0):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < minimum:
        raise ValueError(f"Expected finite number >= {minimum}")
    return value


def integers(value, count, minimum=0):
    if not isinstance(value, list) or len(value) != count:
        raise ValueError(f"Expected {count} integers")
    for item in value:
        if type(item) is not int or item < minimum:
            raise ValueError(f"Expected integers >= {minimum}")
    return value


def read_actions(path, ticks):
    actions = []
    previous = -1
    contact = None
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        row = list(map(int, line.split()))
        if len(row) != 4:
            raise ValueError("Action must contain tick x y down")
        tick, x, y, down = row
        if not previous <= tick < ticks or tick < 0 or not -32 <= x < 480 or not 0 <= y < 272 or down not in (0, 1):
            raise ValueError(f"Invalid action: {line}")
        # Repeated touch-down positions describe a drag; key/touch streams cannot overlap.
        kind = x if x < 0 else "touch"
        if down:
            if contact is not None and (contact != kind or kind != "touch"):
                raise ValueError("Overlapping contacts")
            contact = kind
        elif contact != kind:
            raise ValueError("Release without matching press")
        else:
            contact = None
        actions.append(row)
        previous = tick
    if not actions or contact is not None:
        raise ValueError("Actions must be nonempty and end with release")
    return actions


def load_recipe(path):
    recipe = json.loads(path.read_text())
    fields(recipe, ("version", "id", "initial", "ticks", "warmup_ticks", "trim_start",
                    "duration", "actions", "narration", "radio", "provenance"), ("sample_telemetry",))
    if type(recipe["version"]) is not int or recipe["version"] != 1:
        raise ValueError("Only recipe version 1 is supported")
    if not isinstance(recipe["id"], str) or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", recipe["id"]):
        raise ValueError("Invalid recipe id")
    if recipe["initial"] not in ("fresh-model", "empty-dashboard"):
        raise ValueError("Unknown initial state")
    for key in ("ticks", "warmup_ticks"):
        if type(recipe[key]) is not int or recipe[key] < 0 or recipe[key] % 5:
            raise ValueError(f"{key} must be a nonnegative multiple of 5")
    if recipe["ticks"] <= recipe["warmup_ticks"]:
        raise ValueError("Capture must extend beyond warmup")
    number(recipe["duration"], .05)
    number(recipe["trim_start"])
    if recipe["trim_start"] >= (recipe["ticks"] - recipe["warmup_ticks"]) / 100:
        raise ValueError("Trim removes the whole capture")
    if type(recipe.get("sample_telemetry", False)) is not bool:
        raise ValueError("sample_telemetry must be boolean")
    if recipe.get("sample_telemetry") and recipe["initial"] != "empty-dashboard":
        raise ValueError("Sample telemetry is only supported for empty-dashboard")
    if not isinstance(recipe["actions"], str) or Path(recipe["actions"]).is_absolute() or ".." in Path(recipe["actions"]).parts:
        raise ValueError("Actions must be a recipe-relative path")
    read_actions(path.parent / recipe["actions"], recipe["ticks"])
    if not isinstance(recipe["narration"], list) or not recipe["narration"]:
        raise ValueError("Nonempty narration list required")
    previous = 0
    for clip in recipe["narration"]:
        fields(clip, ("start", "end", "text", "rate"), ("legacy_cache",))
        number(clip["start"])
        number(clip["end"], .05)
        number(clip["rate"])
        if clip["start"] < previous or clip["end"] <= clip["start"] + .3 or clip["end"] > recipe["duration"]:
            raise ValueError("Narration slots must be ordered, nonoverlapping and within duration")
        if not isinstance(clip["text"], str) or not clip["text"].strip():
            raise ValueError("Narration text required")
        if "legacy_cache" in clip and (not isinstance(clip["legacy_cache"], str) or
                                      Path(clip["legacy_cache"]).name != clip["legacy_cache"]):
            raise ValueError("legacy_cache must be a filename")
        previous = clip["end"]
    radio = recipe["radio"]
    fields(radio, ("crop", "canvas", "screen", "return_button", "source", "mask_threshold"))
    integers(radio["crop"], 4)
    integers(radio["canvas"], 2, 2)
    integers(radio["screen"], 4)
    integers(radio["return_button"], 2)
    integers(radio["mask_threshold"], 2)
    cw, ch, _, _ = radio["crop"]
    width, height = radio["canvas"]
    x, y, sw, sh = radio["screen"]
    if not cw or not ch or width % 2 or height % 2 or not sw or not sh or x + sw > width or y + sh > height:
        raise ValueError("Invalid crop/canvas/screen geometry")
    if not (radio["return_button"][0] < width and radio["return_button"][1] < height):
        raise ValueError("Return button outside canvas")
    low, high = radio["mask_threshold"]
    if not 0 <= low < high <= 255 or not isinstance(radio["source"], str):
        raise ValueError("Invalid radio source or mask thresholds")
    fields(recipe["provenance"], ("status", "notes"))
    if not all(isinstance(recipe["provenance"][k], str) for k in ("status", "notes")):
        raise ValueError("Provenance requires status and notes strings")
    return recipe


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def run(arguments, **kwargs):
    subprocess.run([str(a) for a in arguments], check=True, **kwargs)


def ffmpeg():
    import imageio_ffmpeg
    return [imageio_ffmpeg.get_ffmpeg_exe(), "-hide_banner", "-loglevel", "error", "-y"]


def capture_module():
    spec = importlib.util.spec_from_file_location("capture_editor", ROOT / "tools/capture-editor.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prepare(recipe, directory):
    sd = directory / "sdcard"
    if sd.exists():
        raise ValueError(f"{sd} already exists; use a new --output directory")
    capture_module().prepare(sd, "select-layout")
    model = """semver: 3.0.0
header:
   name: "AEROGRID DEMO"
   bitmap: ""
   labels: ""
disableThrottleWarning: 1
"""
    if recipe["initial"] == "empty-dashboard":
        model += """screenData:
   0:
      LayoutId: Layout1x1AM
      layoutData:
         zones:
            0:
               widgetName: AeroGrid
               widgetData:
                  options:
                     0:
                        type: Unsigned
                        value:
                           unsignedValue: 1
                     1:
                        type: Unsigned
                        value:
                           unsignedValue: 1
"""
    widget = sd / "WIDGETS/AeroGrid"
    if recipe.get("sample_telemetry"):
        model += """telemetrySensors:
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
"""
        main = widget / "main.lua"
        source = main.read_text()
        needle = "    refresh = refresh,"
        if source.count(needle) != 1:
            raise ValueError("Refresh hook changed; update telemetry injection")
        main.write_text(source.replace(needle, """
    refresh = function(context, event, touch)
        if not context.videoTelemetrySeeded then
            setTelemetryValue(2, 0, 2, 725, 7, 1, "GSpd")
            context.videoTelemetrySeeded = true
        end
        setTelemetryValue(2, 0, 2, 486, 7, 1, "GSpd")
        refresh(context, event, touch)
    end,
"""))
        (widget / "video-inputs.lua").write_text("""
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
        loader = widget / "lib/dashboard_loader.lua"
        source = loader.read_text()
        if source.count("support.environment()") != 1:
            raise ValueError("Environment hook changed; update telemetry injection")
        loader.write_text(source.replace(
            "support.environment()",
            'support.environment(assert(loadScript("/WIDGETS/AeroGrid/video-inputs.lua"))())'))
    (sd / "MODELS/model1.yml").write_text(model)
    (sd / "AEROGRID/layout-registry.txt").write_text("Empty\nDefault\nDiagnostics\nPalette\n")
    (sd / "capture-ready.txt").unlink(missing_ok=True)
    return sd


def compile_native(directory, library, architecture=None):
    if not library.is_file():
        raise ValueError(f"Simulator not found: {library}")
    architectures = subprocess.check_output(["lipo", "-archs", str(library)], text=True).split()
    if architecture is None:
        if len(architectures) != 1:
            raise ValueError("Universal library: select --architecture explicitly")
        architecture = architectures[0]
    if architecture not in architectures:
        raise ValueError("Requested architecture not present in simulator library")
    executable = directory / "video-native"
    frameworks = library.parent.parent / "Frameworks"
    run(["clang++", "-std=c++11", "-arch", architecture, ROOT / "tools/video-native.cpp",
         f"-Wl,-rpath,{frameworks}", "-o", executable])
    return executable


def accepted_touches(recipe, actions, log):
    """Match each touch press in the rendered timeline to a firmware TE_PRESSED log entry."""
    pressed = [int(m) for m in re.findall(r"^(\d+)ms: TE_PRESSED$", log, re.M)]
    visible = recipe["warmup_ticks"] + recipe["trim_start"] * 100
    missing = []
    contact = False
    for tick, x, _, down in actions:
        if x >= 0 and down and not contact and tick >= visible:
            if not any(tick * 10 <= time <= tick * 10 + 150 for time in pressed):
                missing.append(tick)
        if x >= 0:
            contact = bool(down)
    return missing


def frames(raw, directory, times, trim_start=0):
    size = raw.stat().st_size
    if not size or size % FRAME_BYTES:
        raise ValueError("Raw capture must contain complete 480x272 RGB565LE frames")
    written = []
    with raw.open("rb") as file:
        for time in times:
            index = round((number(time) + trim_start) * FPS)
            if index >= size // FRAME_BYTES:
                raise ValueError(f"No frame at {time:g} seconds")
            file.seek(index * FRAME_BYTES)
            target = directory / f"frame-{time:07.2f}s.png"
            capture_module().write_png(target, file.read(FRAME_BYTES))
            written.append(target)
    return written


def contact_sheet(images, output, columns=4):
    """Tile exported frames (in order) for quick visual review; no text overlays needed."""
    inputs = []
    for image in images:
        inputs += ["-i", str(image)]
    layout = "|".join(f"{i % columns * 480}_{i // columns * 272}" for i in range(len(images)))
    graph = "".join(f"[{i}:v]" for i in range(len(images)))
    graph += f"xstack=inputs={len(images)}:layout={layout}:fill=black" if len(images) > 1 else "null"
    run(ffmpeg() + inputs + ["-filter_complex", graph, "-frames:v", "1", output], timeout=60)
    return output


def capture(recipe, path, directory, library, architecture):
    executable = compile_native(directory, library, architecture)
    sd = prepare(recipe, directory)
    raw = directory / "frames.rgb565"
    with (directory / "simulator.log").open("w") as log:
        run([executable, library, sd, path.parent / recipe["actions"], raw,
             recipe["ticks"], recipe["warmup_ticks"]],
            stdout=log, stderr=subprocess.STDOUT, timeout=recipe["ticks"] / 100 + 30)
    expected = (recipe["ticks"] - recipe["warmup_ticks"]) // 5 * FRAME_BYTES
    if raw.stat().st_size != expected:
        raise ValueError("Unexpected recorder frame count")
    with raw.open("rb") as file:
        file.seek(-FRAME_BYTES, 2)
        capture_module().write_png(directory / "last-frame.png", file.read())
    actions = read_actions(path.parent / recipe["actions"], recipe["ticks"])
    missing = accepted_touches(recipe, actions, (directory / "simulator.log").read_text(errors="replace"))
    sources = {str(file.relative_to(ROOT)): digest(file)
               for file in sorted((ROOT / "src/WIDGETS/AeroGrid").rglob("*")) if file.is_file()}
    report = {
        "recipe": recipe, "recipe_sha256": digest(path),
        "actions_sha256": digest(path.parent / recipe["actions"]),
        "simulator": str(library), "simulator_sha256": digest(library),
        "recorder_sha256": digest(ROOT / "tools/video-native.cpp"),
        "driver_sha256": digest(Path(__file__)),
        "sd_preparer_sha256": digest(ROOT / "tools/capture-editor.py"),
        "sources": sources, "raw_sha256": digest(raw),
        "unaccepted_touch_ticks": missing,
        "verification": "Frame count and firmware touch acceptance only; inspect frames and the "
                        "complete recording for UI success.",
    }
    (directory / "capture-provenance.json").write_text(json.dumps(report, indent=2) + "\n")
    if missing:
        raise ValueError(f"Firmware did not report presses for touch ticks {missing}; see simulator.log")
    print(f"Recorded {raw}; inspect last-frame.png and the full video before publishing.", flush=True)


def cache_path(cache, clip):
    identity = {"voice": VOICE, "text": clip["text"], "rate": clip["rate"],
                "format": "riff-48khz-16bit-mono-pcm"}
    key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    return cache / f"{key}.wav"


def check_speech(data, clip):
    with wave.open(io.BytesIO(data)) as recording:
        if (recording.getframerate(), recording.getnchannels(), recording.getsampwidth()) != (48000, 1, 2):
            raise ValueError("Speech cache must be 48 kHz mono 16-bit PCM WAV")
        frames = recording.getnframes()
        if frames <= 0 or len(recording.readframes(frames)) != frames * 2:
            raise ValueError("Empty or truncated speech WAV")
        duration = frames / 48000
    if duration > clip["end"] - clip["start"] - .3:
        raise ValueError("Speech exceeds slot; shorten text or increase recipe rate, then synthesize again")
    return duration


def speech(recipe, cache, online=False, source=None):
    cache.mkdir(parents=True, exist_ok=True)
    clips = []
    for clip in recipe["narration"]:
        target = cache_path(cache, clip)
        if target.exists():
            data = target.read_bytes()
        elif source and clip.get("legacy_cache"):
            legacy = source / clip["legacy_cache"]
            data = legacy.read_bytes()
            check_speech(data, clip)
            target.write_bytes(data)
            target.with_suffix(".json").write_text(json.dumps({
                "origin": "explicitly trusted legacy import", "source": str(legacy),
                "source_sha256": digest(legacy), "voice": VOICE, "text": clip["text"],
                "requested_rate": clip["rate"],
                "actual_rate": "unknown; historical prototype may have adjusted rate",
            }, indent=2) + "\n")
        elif online:
            region, key = os.environ.get("AZURE_SPEECH_REGION", ""), os.environ.get("AZURE_SPEECH_KEY", "")
            if not key or not re.fullmatch(r"[a-z0-9-]+", region):
                raise ValueError("Set AZURE_SPEECH_KEY and AZURE_SPEECH_REGION for paid synthesis")
            ssml = ('<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="en-US">'
                    f'<voice name="{VOICE}"><prosody rate="+{clip["rate"]}%">'
                    f'{escape(clip["text"])}</prosody></voice></speak>')
            request = urllib.request.Request(
                f"https://{region}.tts.speech.microsoft.com/cognitiveservices/v1",
                data=ssml.encode(), headers={
                    "Ocp-Apim-Subscription-Key": key, "Content-Type": "application/ssml+xml",
                    "X-Microsoft-OutputFormat": "riff-48khz-16bit-mono-pcm",
                    "User-Agent": "AeroGridVideo"})
            with urllib.request.urlopen(request, timeout=60) as response:
                data = response.read()
            check_speech(data, clip)
            target.write_bytes(data)
            target.with_suffix(".json").write_text(json.dumps({
                "origin": "Azure synthesis", "voice": VOICE, "text": clip["text"],
                "requested_rate": clip["rate"], "actual_rate": clip["rate"],
            }, indent=2) + "\n")
        else:
            raise ValueError(f"Missing cached speech: {target.name}; use speech --online or --cache-source")
        check_speech(data, clip)
        clips.append(target)
    return clips


def gestures(recipe, actions):
    offset = recipe["warmup_ticks"] / 100 + recipe["trim_start"]
    result = []
    points = []
    for tick, x, y, down in actions:
        time = tick / 100 - offset
        if down:
            points.append((time, x, y))
        else:
            if points and time >= 0:
                result.append((points[0][0], time, points))
            points = []
    return result


def luminance(frame, x, y):
    values = []
    for sy in range(max(0, y - 16), min(272, y + 17), 4):
        for sx in range(max(0, x - 16), min(480, x + 17), 4):
            pixel = struct.unpack_from("<H", frame, (sy * 480 + sx) * 2)[0]
            values.append(.2126 * ((pixel >> 11) & 31) / 31 +
                          .7152 * ((pixel >> 5) & 63) / 63 + .0722 * (pixel & 31) / 31)
    return sum(values) / len(values) if values else 0


def feedback(recipe, actions, raw, output, duration, radio):
    width, height = recipe["radio"]["canvas"] if radio else (480, 272)
    origin_x, origin_y, sw, sh = recipe["radio"]["screen"] if radio else (0, 0, 480, 272)
    contacts = gestures(recipe, actions)
    process = subprocess.Popen(ffmpeg() + [
        "-f", "rawvideo", "-pixel_format", "rgba", "-video_size", f"{width}x{height}",
        "-framerate", str(FPS), "-i", "-", "-c:v", "qtrle", str(output)], stdin=subprocess.PIPE)
    try:
        with raw.open("rb") as file, mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as frames:
            for index in range(math.ceil(duration * FPS)):
                time = index / FPS
                pixels = bytearray(width * height * 4)
                offset = min(int((time + recipe["trim_start"]) * FPS),
                             len(frames) // FRAME_BYTES - 1) * FRAME_BYTES
                frame = frames[offset:offset + FRAME_BYTES]
                for beginning, release, points in contacts:
                    if not beginning <= time < max(beginning + 1.2, release):
                        continue
                    point = next(p for p in reversed(points) if p[0] <= time)
                    _, x, y = point
                    if x < 0:
                        # Only RTN has a photo-space location; do not fake other keys.
                        if not radio or x != -2:
                            continue
                        cx, cy = recipe["radio"]["return_button"]
                        color = 255
                    else:
                        cx, cy = origin_x + x * sw / 480, origin_y + y * sh / 272
                        color = 255 if luminance(frame, x, y) < .45 else 0
                    progress = min(1, (time - beginning) / 1.2)
                    dragging = len(points) > 1 and time <= release
                    scale = sw / 930
                    radius = (12 if dragging else 8 + 57 * (1 - (1 - progress) ** 2)) * scale
                    opacity = 1 if dragging else min(1, (1 - progress) / .45)
                    for py in range(max(0, int(cy - radius - 6)), min(height, int(cy + radius + 7))):
                        for px in range(max(0, int(cx - radius - 6)), min(width, int(cx + radius + 7))):
                            distance = math.hypot(px - cx, py - cy)
                            ring = max(0, min(1, 5.5 * scale - abs(distance - radius)))
                            alpha = round(255 * .15 * ring * opacity)
                            if alpha:
                                i = (py * width + px) * 4
                                pixels[i:i + 4] = bytes((color, color, color, alpha))
                process.stdin.write(pixels)
        process.stdin.close()
        if process.wait(timeout=60):
            raise ValueError("Feedback encoder failed")
    except BaseException:
        try:
            process.stdin.close()
        except OSError:
            pass
        if process.poll() is None:
            process.kill()
        process.wait()
        raise


def png_rgba(path, width, height, rgba):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\0" + rgba[y * width * 4:(y + 1) * width * 4] for y in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" +
                     chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) +
                     chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def radio_assets(recipe, photo, directory):
    radio = recipe["radio"]
    width, height = radio["canvas"]
    cw, ch, cx, cy = radio["crop"]
    pixels = subprocess.check_output(ffmpeg() + [
        "-i", str(photo), "-vf", f"crop={cw}:{ch}:{cx}:{cy},scale={width}:{height}:flags=lanczos",
        "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgba", "-"])
    if len(pixels) != width * height * 4:
        raise ValueError("Photo cannot produce expected crop")
    base, bezel = directory / "radio.png", directory / "bezel.png"
    png_rgba(base, width, height, pixels)
    mask = bytearray(pixels)
    x, y, sw, sh = radio["screen"]
    low, high = radio["mask_threshold"]
    for py in range(y, y + sh):
        for px in range(x, x + sw):
            offset = (py * width + px) * 4
            brightness = sum(pixels[offset:offset + 3]) / 3
            coverage = max(0, min(1, (brightness - low) / (high - low)))
            mask[offset + 3] = round(255 * (1 - coverage))
    png_rgba(bezel, width, height, mask)
    return base, bezel


def render(recipe, path, directory, raw, photo, cache, silent, limit):
    size = raw.stat().st_size
    if not size or size % FRAME_BYTES:
        raise ValueError("Raw capture must contain complete 480x272 RGB565LE frames")
    if recipe["trim_start"] >= size / FRAME_BYTES / FPS:
        raise ValueError("Raw capture is shorter than trim_start")
    duration = recipe["duration"] if limit is None else number(limit, .05)
    if duration > recipe["duration"]:
        raise ValueError("--limit cannot exceed recipe duration")
    clips = [] if silent else speech(recipe, cache)
    overlay = directory / "feedback.mov"
    actions = read_actions(path.parent / recipe["actions"], recipe["ticks"])
    feedback(recipe, actions, raw, overlay, duration, bool(photo))
    inputs = ["-f", "rawvideo", "-pixel_format", "rgb565le", "-video_size", "480x272",
              "-framerate", str(FPS), "-i", str(raw)]
    graph = (f"[0:v]trim=start={recipe['trim_start']},setpts=PTS-STARTPTS,"
             f"tpad=stop_mode=clone:stop_duration={duration}")
    if photo:
        base, bezel = radio_assets(recipe, photo, directory)
        x, y, sw, sh = recipe["radio"]["screen"]
        inputs += ["-loop", "1", "-framerate", str(FPS), "-i", str(base),
                   "-loop", "1", "-framerate", str(FPS), "-i", str(bezel), "-i", str(overlay)]
        graph += (f",scale={sw}:{sh}:flags=lanczos,setsar=1[screen];"
                  f"[1:v][screen]overlay=x={x}:y={y}[underlay];"
                  "[underlay][2:v]overlay[framed];[framed][3:v]overlay[video]")
        audio_start = 4
    else:
        inputs += ["-i", str(overlay)]
        graph += ",setsar=1[screen];[screen][1:v]overlay[video]"
        audio_start = 2
    maps = ["-map", "[video]"]
    if clips:
        for index, (clip, segment) in enumerate(zip(clips, recipe["narration"])):
            inputs += ["-i", str(clip)]
            graph += f";[{audio_start + index}:a]adelay={round(segment['start'] * 1000)}:all=1[a{index}]"
        graph += ";" + "".join(f"[a{i}]" for i in range(len(clips)))
        graph += f"amix=inputs={len(clips)}:normalize=0,apad,alimiter=limit=0.95[audio]"
        maps += ["-map", "[audio]", "-c:a", "aac", "-b:a", "192k"]
    output = directory / f"{recipe['id']}.mp4"
    run(ffmpeg() + ["-filter_complex_threads", "1", *inputs, "-filter_complex", graph, *maps,
                    "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p",
                    "-sn", "-t", str(duration), "-movflags", "+faststart", output], timeout=900)
    run(ffmpeg() + ["-i", output, "-f", "null", "-"], timeout=300)
    report = {
        "recipe": recipe, "recipe_sha256": digest(path),
        "actions_sha256": digest(path.parent / recipe["actions"]),
        "driver_sha256": digest(Path(__file__)),
        "raw": str(raw), "raw_sha256": digest(raw),
        "photo": str(photo) if photo else None, "photo_sha256": digest(photo) if photo else None,
        "speech": {clip.name: digest(clip) for clip in clips}, "voice": VOICE if clips else None,
        "speech_origins": {
            clip.name: json.loads(clip.with_suffix(".json").read_text())
            if clip.with_suffix(".json").is_file() else {"origin": "unannotated existing cache"}
            for clip in clips
        },
        "duration": duration, "fps": FPS,
        "held_tail_seconds": max(0, duration - (size / FRAME_BYTES / FPS - recipe["trim_start"])),
        "verification": "FFmpeg decode succeeded; UI steps still require human review.",
    }
    (directory / "render-provenance.json").write_text(json.dumps(report, indent=2) + "\n")
    (directory / "transcript.txt").write_text("\n\n".join(
        f"{s['start']:g}s: {s['text']}" for s in recipe["narration"]) + "\n")
    print(output)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("validate", "prepare", "compile", "capture", "frames", "speech", "render"))
    parser.add_argument("--recipe", type=Path, default=RECIPES / "add-move-resize-panel.json")
    parser.add_argument("--output", type=Path, help="Working directory (default build/video/<recipe id>)")
    parser.add_argument("--library", type=Path, default=DEFAULT_LIBRARY)
    parser.add_argument("--architecture", choices=("arm64", "x86_64"))
    parser.add_argument("--raw", type=Path, help="External RGB565LE capture; default <output>/frames.rgb565")
    parser.add_argument("--photo", type=Path, help="User-supplied photo matching recipe crop")
    parser.add_argument("--cache", type=Path, default=ROOT / "build/video/speech-cache")
    parser.add_argument("--cache-source", type=Path, help="Explicitly trust/import legacy WAV filenames from recipe")
    parser.add_argument("--online", action="store_true", help="Allow paid Azure synthesis (speech command only)")
    parser.add_argument("--silent", action="store_true", help="Render without speech; no network")
    parser.add_argument("--times", type=lambda text: [float(t) for t in text.split(",")],
                        help="frames: comma-separated rendered-timeline seconds to export as PNG")
    parser.add_argument("--limit", type=float, help="Render only the first N seconds for validation")
    args = parser.parse_args(argv)
    try:
        if args.online and args.command != "speech":
            raise ValueError("--online is only allowed with speech")
        recipe = load_recipe(args.recipe)
        if args.command == "validate":
            print(f"Valid recipe: {recipe['id']}")
            return
        directory = (args.output or ROOT / "build/video" / recipe["id"]).resolve()
        if directory == ROOT or directory in ROOT.parents or directory == ROOT / "src" or ROOT / "src" in directory.parents:
            raise ValueError("Output cannot be the repository root, a parent, or source tree")
        directory.mkdir(parents=True, exist_ok=True)
        if args.command == "prepare":
            print(prepare(recipe, directory))
        elif args.command == "compile":
            print(compile_native(directory, args.library.resolve(), args.architecture))
        elif args.command == "capture":
            capture(recipe, args.recipe, directory, args.library.resolve(), args.architecture)
        elif args.command == "frames":
            if not args.times:
                raise ValueError("frames requires --times")
            images = frames((args.raw or directory / "frames.rgb565").resolve(), directory,
                            args.times, recipe["trim_start"])
            print("\n".join(map(str, images)))
            print(contact_sheet(images, directory / "frames-sheet.png"))
        elif args.command == "speech":
            print(f"Verified {len(speech(recipe, args.cache, args.online, args.cache_source))} cached clips")
        elif args.command == "render":
            render(recipe, args.recipe, directory, (args.raw or directory / "frames.rgb565").resolve(),
                   args.photo.resolve() if args.photo else None, args.cache, args.silent, args.limit)
    except (ValueError, OSError, wave.Error, subprocess.SubprocessError, urllib.error.URLError) as error:
        parser.exit(1, f"video: {error}\n")


if __name__ == "__main__":
    main()
