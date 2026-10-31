# SPDX-License-Identifier: GPL-2.0-only
"""Refresh the stored Companion NAIP aerial-imagery fixture."""
import argparse
import importlib.util
from io import BytesIO
import json
import math
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen

from PIL import Image


SERVICE = "https://imagery.nationalmap.gov/arcgis/rest/services/USGSNAIPImagery/ImageServer"
IMAGERY_SET = "companion-naip-20261024"


def fetch(output):
    spec = importlib.util.spec_from_file_location(
        "synthetic", Path(__file__).with_name("generate-map-test-pack.py"))
    synthetic = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(synthetic)
    n = 2 ** synthetic.ZOOM
    west = math.floor((synthetic.LONGITUDE + 180) / 360 * n + .5) - 1
    north = math.floor((1 - math.asinh(math.tan(math.radians(synthetic.LATITUDE))) / math.pi) / 2 * n + .5) - 1
    world = 2 * math.pi * 6378137
    bounds = (
        west / n * world - world / 2,
        world / 2 - (north + 2) / n * world,
        (west + 2) / n * world - world / 2,
        world / 2 - north / n * world,
    )
    parameters = {
        "f": "image", "bbox": ",".join(map(str, bounds)),
        "bboxSR": 3857, "imageSR": 3857, "size": "1024,1024",
        "format": "png", "pixelType": "U8", "bandIds": "0,1,2",
        "interpolation": "RSP_BilinearInterpolation",
    }
    with urlopen(SERVICE + "/exportImage?" + urlencode(parameters), timeout=120) as response:
        image = Image.open(BytesIO(response.read()))
        image.load()
    if image.size != (1024, 1024):
        raise ValueError(f"Unexpected imagery dimensions: {image.size}")
    if "A" in image.getbands() and image.getchannel("A").getextrema() != (255, 255):
        raise ValueError("NAIP coverage contains missing imagery")
    image = image.convert("RGB")
    output.mkdir(parents=True, exist_ok=True)
    # Reuse the deterministic projection and manifest contract, replacing pixels.
    import tempfile
    with tempfile.TemporaryDirectory() as temporary:
        synthetic.generate(temporary)
        manifest = (Path(temporary) / "areas/synthetic.yaml").read_text()
    manifest = manifest.replace("id: synthetic", "id: companion-naip").replace(
        '"Synthetic test area"', '"Companion NAIP aerial imagery"').replace(
        synthetic.IMAGERY_SET, IMAGERY_SET)
    for zoom in (16, 17):
        factor = 2 ** (zoom - 16)
        level = image if zoom == 17 else image.resize((512, 512), Image.Resampling.LANCZOS)
        for dx in range(2 * factor):
            directory = output / "tiles" / IMAGERY_SET / str(zoom) / str(west * factor + dx)
            directory.mkdir(parents=True, exist_ok=True)
            for dy in range(2 * factor):
                tile = level.crop((dx * 256, dy * 256, (dx + 1) * 256, (dy + 1) * 256))
                tile.save(directory / f"{north * factor + dy}.jpg", quality=90, subsampling=0)
    (output / "areas").mkdir(exist_ok=True)
    (output / "areas/companion-naip.yaml").write_text(manifest, encoding="ascii")
    (output / "source.json").write_text(json.dumps({
        "source": "USGS / USDA NAIP, The National Map",
        "service": SERVICE,
        "description": "Public-domain natural-color aerial imagery",
        "retrieved": "2026-10-24",
        "imagerySet": IMAGERY_SET,
        "export": parameters,
        "conversion": "RGB JPEG quality 90, no chroma subsampling; zoom 16 downsampled from zoom 17",
    }, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("tests/fixtures/map-imagery"))
    fetch(parser.parse_args().output)
