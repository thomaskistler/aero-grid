# SPDX-License-Identifier: GPL-2.0-only
"""Regenerate categorized EdgeTX models from model1's shared setup."""
import argparse
import io
import math
from pathlib import Path
import re
import struct
import wave


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/fixtures/sdcard"
CATEGORIES = (
    ("AG Overview", ("Default", "sim", "sim2")),
    ("AG Flight", ("review-model-identity", "review-flight-mode",
                   "review-flight-timer", "review-flight-counter", "review-chart")),
    ("AG Power-Link", ("review-rx-battery", "review-cell-sources",
                       "review-tx-battery", "review-link-status", "review-metric")),
    ("AG Navigation", ("review-navigation", "review-map")),
    ("AG Controls", ("review-output", "review-trim-panel")),
    ("AG System", ("Diagnostics", "services", "services2", "review-state",
                   "states", "Palette", "Empty")),
)
FLIGHT_ANNOUNCEMENTS = """logicalSw:
   0:
      func: FUNC_STICKY
      def: NONE,NONE
      delay: 0
      duration: 0
      andsw: NONE
      lsPersist: 0
      lsState: 0
customFn:
   0:
      swtch: "L1"
      func: PLAY_TRACK
      def: agstart,1,!1x
   1:
      swtch: "!L1"
      func: PLAY_TRACK
      def: agend,1,!1x
"""


def beep_track(count):
    """Sequence EdgeTX Beep 1's default 2250 Hz, 60 ms tone / 20 ms pause."""
    rate = 32000
    tone = b"".join(struct.pack("<h", round(
        8192 * math.sin(2 * math.pi * 2250 * sample / rate)))
        for sample in range(rate * 60 // 1000))
    pause = b"\0\0" * (rate * 20 // 1000)
    recording = io.BytesIO()
    with wave.open(recording, "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes((tone + pause) * count)
    return recording.getvalue()


def screen(index, position):
    return f"""   {index}:
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
                           unsignedValue: {position}
                     1:
                        type: Unsigned
                        value:
                           unsignedValue: 1
"""


def generated_files(fixture=FIXTURE):
    registry = (fixture / "AEROGRID/layout-registry.txt").read_text().splitlines()
    layouts = [layout for _, screens in CATEGORIES for layout in screens]
    if len(registry) != len(set(registry)) or sorted(layouts) != sorted(registry):
        raise ValueError("Categories must cover every registered layout exactly once")
    common = "".join(line.rstrip() + "\n" for line in
                     (fixture / "MODELS/model1.yml").read_text().splitlines())
    prefix, rest = common.split("screenData:", 1)
    _, suffix = rest.split("topbarData:", 1)
    # EdgeTX ModelsSortBy.NO_SORT keeps the category order instead of name order.
    labels = 'Labels:\n  "Favorites":\nSort: 0\nModels:\n'
    files = {}
    for number, (name, screens) in enumerate(CATEGORIES, 1):
        header, count = re.subn(r'(?m)^   name: "[^"]*"$',
                               f'   name: "{name}"', prefix, count=1)
        if count != 1:
            raise ValueError("Expected a model name in the common fixture header")
        filename = f"model{number}.yml"
        files[fixture / "MODELS" / filename] = (
            header + (FLIGHT_ANNOUNCEMENTS if name == "AG Flight" else "")
            + "screenData:\n"
            + "".join(screen(index, registry.index(layout) + 1)
                      for index, layout in enumerate(screens))
            + "topbarData:" + suffix
        )
        labels += (f'  {filename}:\n    name: "{name}"\n'
                   '    labels: ""\n    bitmap: "04530_x10.png"\n')
    files[fixture / "MODELS/labels.yml"] = labels
    for name, count in (("agstart", 3), ("agend", 4)):
        files[fixture / "SOUNDS/en" / f"{name}.wav"] = beep_track(count)
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="Fail if tracked fixtures need regeneration")
    args = parser.parse_args()
    stale = []
    for path, content in generated_files().items():
        data = content.encode() if isinstance(content, str) else content
        if args.check:
            if not path.is_file() or path.read_bytes() != data:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    if stale:
        parser.exit(1, "Stale simulator fixtures; regenerate with "
                    "python3 tools/generate-simulator-models.py:\n"
                    + "\n".join(stale) + "\n")


if __name__ == "__main__":
    main()
