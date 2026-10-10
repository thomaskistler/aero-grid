# SPDX-License-Identifier: GPL-2.0-only
"""Validated YAML recipes and panel-specific native model/readiness adapters."""
import json
import math
from pathlib import Path
import re

import yaml


RECIPE_DIR = Path(__file__).with_name("capture-recipes")
PANELS = ("trim-panel", "flight-timer", "metric", "flight-mode", "tx-battery",
              "model-identity", "cell-battery", "link-status", "navigation", "text", "flight-counter")
SYNTHETIC_PANELS = ("metric", "tx-battery", "cell-battery", "link-status", "navigation", "text",
                    "flight-counter")


class RecipeLoader(yaml.SafeLoader):
    pass


def mapping(loader, node):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        if not isinstance(key, str) or key in result:
            raise ValueError("Recipe keys must be unique strings")
        result[key] = loader.construct_object(value_node)
    return result


RecipeLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)


def fields(value, required, optional=()):
    if not isinstance(value, dict):
        raise ValueError("Expected a mapping")
    missing = set(required) - value.keys()
    unknown = value.keys() - set(required) - set(optional)
    if missing or unknown:
        raise ValueError(f"Missing keys: {sorted(missing)}; unknown keys: {sorted(unknown)}")


def integer(value, minimum, maximum, name):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be an integer from {minimum} to {maximum}")


def number(value, minimum, maximum, name):
    if type(value) not in (int, float) or not math.isfinite(value) or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be a finite number from {minimum} to {maximum}")


def short_name(value, name):
    if (not isinstance(value, str) or not value or len(value) > 10
            or any(ord(c) < 32 or ord(c) > 126 for c in value)):
        raise ValueError(f"{name} must be 1 to 10 printable ASCII characters")


def config_value(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str) or not re.fullmatch(r"[a-zA-Z][a-zA-Z0-9]*", key):
                raise ValueError(f"Invalid config key: {key}")
            config_value(item)
    elif isinstance(value, list):
        for item in value:
            config_value(item)
    elif type(value) not in (str, int, float, bool):
        raise ValueError("Config values must be scalars, lists, or mappings")
    elif isinstance(value, float) and not math.isfinite(value):
        raise ValueError("Config numbers must be finite")


def source_names(recipe):
    config, panel = recipe["config"], recipe["panel"]
    if panel == "metric":
        if "metrics" in config:
            entries = config["metrics"]
            if not isinstance(entries, list) or not 1 <= len(entries) <= 3:
                raise ValueError("config.metrics must contain 1 to 3 readings")
            names = []
            for entry in entries:
                if not isinstance(entry, dict) or not isinstance(entry.get("source"), str):
                    raise ValueError("Each metric must name a source")
                names.append(entry["source"])
            return names
        return [config.get("source", "")]
    if panel == "cell-battery":
        return [config.get("source", "Cels")] + (
            [config["lowestSource"]] if config.get("lowestSource") else [])
    if panel == "navigation":
        return [config.get("source", "GPS")]
    if panel == "link-status":
        return [config.get("rssiSource", "RSSI")] + [
            config[key] for key in ("qualitySource", "modeSource", "snrSource", "powerSource")
            if config.get(key)]
    return []


def validate_sources(recipe):
    sample = recipe["sample"]
    fields(sample, ("sources", "rssi"))
    number(sample["rssi"], 1, 100, "sample.rssi")
    sources = sample["sources"]
    if not isinstance(sources, dict) or not 1 <= len(sources) <= 16:
        raise ValueError("sample.sources must contain 1 to 16 named sources")
    for name, source in sources.items():
        if not name or any(ord(c) < 32 or ord(c) > 126 for c in name):
            raise ValueError("Source names must be printable ASCII")
        fields(source, ("value", "unit", "precision"))
        integer(source["unit"], 0, 40, f"{name}.unit")
        integer(source["precision"], 0, 3, f"{name}.precision")
        value = source["value"]
        if source["unit"] == 38:
            if not isinstance(value, list) or not 1 <= len(value) <= 16:
                raise ValueError("Cells samples must contain 1 to 16 voltages")
            for cell in value:
                number(cell, 0.1, 6, f"{name} cell")
        elif source["unit"] == 40:
            fields(value, ("lat", "lon", "pilot-lat", "pilot-lon", "delay"))
            for key in ("lat", "pilot-lat"):
                number(value[key], -90, 90, key)
            for key in ("lon", "pilot-lon"):
                number(value[key], -180, 180, key)
            number(value["delay"], 0, 1, "GPS delay")
            for lat, lon in (("lat", "lon"), ("pilot-lat", "pilot-lon")):
                if abs(value[lat]) < 0.0000005 and abs(value[lon]) < 0.0000005:
                    raise ValueError("GPS sample must have a valid model and home position")
        else:
            if source["unit"] == 39:
                raise ValueError("Datetime sample sources are not supported")
            number(value, -1e9, 1e9, f"{name}.value")
    for name in source_names(recipe):
        if not isinstance(name, str) or name not in sources:
            raise ValueError(f"Missing sample for configured source: {name}")
    panel, config = recipe["panel"], recipe["config"]
    if panel in ("metric", "link-status"):
        if any(not isinstance(sources[name]["value"], (int, float)) for name in source_names(recipe)):
            raise ValueError(f"{panel} requires numeric source samples")
    elif panel == "cell-battery":
        unit = sources[config.get("source", "Cels")]["unit"]
        if unit != (38 if config.get("sourceType", "cells") == "cells" else 1):
            raise ValueError("Cell battery sample unit must match sourceType (cells or volts)")
    elif panel == "navigation" and sources[config.get("source", "GPS")]["unit"] != 40:
        raise ValueError("Navigation requires a GPS sample")


def load_recipe(path):
    try:
        recipe = yaml.load(Path(path).read_text(), Loader=RecipeLoader)
    except yaml.YAMLError as error:
        raise ValueError(f"Invalid YAML recipe {path}: {error}") from error
    fields(recipe, ("version", "panel", "theme", "border", "panels", "config", "sample"),
           ("hide_bottom_bar", "brighten_supporting_text"))
    if "hide_bottom_bar" in recipe and type(recipe["hide_bottom_bar"]) is not bool:
        raise ValueError("hide_bottom_bar must be a boolean")
    if "brighten_supporting_text" in recipe and type(recipe["brighten_supporting_text"]) is not bool:
        raise ValueError("brighten_supporting_text must be a boolean")
    integer(recipe["version"], 1, 1, "version")
    if recipe["panel"] not in PANELS:
        raise ValueError(f"Unsupported capture adapter: {recipe['panel']}")
    if recipe["theme"] not in ("modern", "modern-light"):
        raise ValueError("Capture theme must be modern or modern-light")
    border = recipe["border"]
    fields(border, ("pixels", "rgb"))
    integer(border["pixels"], 0, 100, "border.pixels")
    if not isinstance(border["rgb"], list) or len(border["rgb"]) != 3:
        raise ValueError("border.rgb must contain three channels")
    for channel in border["rgb"]:
        integer(channel, 0, 255, "border.rgb channel")
    panels = recipe["panels"]
    if not isinstance(panels, dict) or not 1 <= len(panels) <= 16:
        raise ValueError("panels must contain 1 to 16 named placements")
    occupied = set()
    for name, placement in panels.items():
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]*", name):
            raise ValueError(f"Invalid panel name: {name}")
        fields(placement, ("col", "row", "colSpan", "rowSpan"))
        span_name = re.fullmatch(r"([1-4])x([1-4])", name)
        if span_name and (placement["colSpan"], placement["rowSpan"]) != tuple(
                map(int, span_name.groups())):
            raise ValueError(f"Panel {name} label does not match its span")
        for key in ("col", "row"):
            integer(placement[key], 0, 3, key)
        integer(placement["colSpan"], 1, 4, "colSpan")
        integer(placement["rowSpan"], 1, 2, "rowSpan")
        if placement["col"] + placement["colSpan"] > 4 or placement["row"] + placement["rowSpan"] > 4:
            raise ValueError(f"Panel {name} exceeds the grid")
        cells = {(x, y) for x in range(placement["col"], placement["col"] + placement["colSpan"])
                 for y in range(placement["row"], placement["row"] + placement["rowSpan"])}
        if cells & occupied:
            raise ValueError(f"Panel {name} overlaps another panel")
        occupied |= cells
    config, sample = recipe["config"], recipe["sample"]
    if not isinstance(config, dict):
        raise ValueError("config must be a mapping")
    config_value(config)
    if recipe["panel"] == "trim-panel":
        fields(sample, ("aileron", "elevator", "rudder"))
        for key, value in sample.items():
            integer(value, -512, 512, f"sample.{key}")
        for key, expected in {"trim1": "trim-ail", "trim2": "trim-ele", "trim4": "trim-rud"}.items():
            if config.get(key, expected) != expected:
                raise ValueError(f"The trim adapter requires {key}: {expected}")
    elif recipe["panel"] == "flight-timer":
        fields(sample, ("name", "start_seconds", "remaining_seconds"))
        integer(config.get("timer", 0), 0, 2, "config.timer")
        integer(sample["start_seconds"], 1, 8388607, "sample.start_seconds")
        integer(sample["remaining_seconds"], -8388607, 8388607, "sample.remaining_seconds")
        if (not isinstance(sample["name"], str) or len(sample["name"]) > 10
                or any(ord(c) < 32 or ord(c) > 126 for c in sample["name"])):
            raise ValueError("sample.name must be at most 10 printable ASCII characters")
    elif recipe["panel"] == "flight-mode":
        fields(sample, ("name",))
        short_name(sample["name"], "sample.name")
    elif recipe["panel"] == "model-identity":
        fields(sample, ("name",), ("bitmap",))
        short_name(sample["name"], "sample.name")
        if "bitmap" in sample:
            if not isinstance(sample["bitmap"], str) or not sample["bitmap"]:
                raise ValueError("sample.bitmap must be an image path relative to the recipe")
            bitmap = Path(path).resolve().parent / sample["bitmap"]
            if (not bitmap.is_file() or bitmap.suffix.lower() != ".png"
                    or not re.fullmatch(r"[a-zA-Z0-9_-]{1,10}\.png", bitmap.name)):
                raise ValueError("sample.bitmap must be an existing PNG with a firmware-safe filename")
    elif recipe["panel"] == "flight-counter":
        fields(sample, ("count", "rssi"))
        integer(sample["count"], len(panels), 999, "sample.count")
        number(sample["rssi"], 1, 100, "sample.rssi")
        if (config.get("armSwitch") != "SFv" or config.get("motorSource") != "ch3"
                or config.get("motorReversed", False) or config.get("history") is not False
                or config.get("announcements") is not False):
            raise ValueError("Flight counter capture requires SFv armSwitch, ch3 motor, "
                             "non-reversed motor, and disabled history/announcements")
        number(config.get("minFlightDuration"), 0.2, 2, "config.minFlightDuration")
    elif recipe["panel"] == "text":
        fields(sample, ("switches",))
        switches = sample["switches"]
        entries = config.get("texts")
        if not isinstance(entries, list) or not 1 <= len(entries) <= 3:
            raise ValueError("config.texts must contain 1 to 3 readings")
        if not isinstance(switches, dict) or not 1 <= len(switches) <= 3:
            raise ValueError("sample.switches must contain 1 to 3 switches")
        for name, position in switches.items():
            if not re.fullmatch(r"s[a-z]", name) or position not in ("up", "middle", "down"):
                raise ValueError("Switch samples require lowercase switch names and up/middle/down positions")
        for entry in entries:
            fields(entry, ("source", "label", "positions"))
            positions = entry["positions"]
            fields(positions, ("up", "down"), ("middle",))
            for value in [entry["label"], *positions.values()]:
                if not isinstance(value, str) or not value or any(ord(c) < 32 or ord(c) > 126 for c in value):
                    raise ValueError("Text labels and mappings must be nonempty single-line ASCII strings")
            if (not isinstance(entry["source"], str) or entry["source"] not in switches
                    or switches[entry["source"]] not in positions):
                raise ValueError("Missing mapped switch sample")
    elif recipe["panel"] == "tx-battery":
        fields(sample, ("voltage",))
        number(sample["voltage"], 3, 16, "sample.voltage")
        if "packEmpty" not in config or "packFull" not in config:
            raise ValueError("TX battery capture must specify packEmpty and packFull")
        number(config["packEmpty"], 3, 16, "config.packEmpty")
        number(config["packFull"], config["packEmpty"] + 0.1, 16, "config.packFull")
    else:
        validate_sources(recipe)
    return recipe


def configure_model(prefix, recipe):
    sample = recipe["sample"]
    if recipe["panel"] == "model-identity":
        bitmap = Path(sample["bitmap"]).name if "bitmap" in sample else "agplane.png"
        header = (f"header:\n   name: {json.dumps(sample['name'])}\n"
                  f"   bitmap: {json.dumps(bitmap)}\n" + '   labels: ""\n')
        if not re.search(r"(?m)^header:", prefix):
            raise RuntimeError("Fixture has no model header")
        return re.sub(r"(?m)^header:[^\n]*\n(?:[ \t]+[^\n]*\n)*", lambda _: header, prefix)
    if recipe["panel"] == "flight-mode":
        if "flightModeData:" in prefix:
            raise RuntimeError("Fixture now contains flight modes; update mode setup explicitly.")
        return prefix + f"flightModeData:\n   0:\n      name: {json.dumps(sample['name'])}\n"
    if recipe["panel"] not in ("trim-panel", "flight-timer"):
        return prefix
    if recipe["panel"] == "trim-panel":
        if "flightModeData:" in prefix:
            raise RuntimeError("Fixture now contains flight modes; update trim setup explicitly.")
        values = [sample["rudder"], sample["elevator"], 0, sample["aileron"]]
        return prefix + "flightModeData:\n   0:\n      trim:\n" + "".join(
            f"         {i}:\n            value: {value}\n            mode: 0\n"
            for i, value in enumerate(values))
    timer = (f"timers:\n   {recipe['config'].get('timer', 0)}:\n"
             f"      start: {sample['start_seconds']}\n"
             f"      value: {sample['remaining_seconds']}\n"
             "      mode: OFF\n      countdownBeep: 0\n      minuteBeep: 0\n"
             "      persistent: 1\n      countdownStart: 0\n      showElapsed: 0\n"
             f"      extraHaptic: 0\n      name: {json.dumps(sample['name'])}\n")
    if not re.search(r"(?m)^timers:", prefix):
        return prefix + timer
    return re.sub(r"(?m)^timers:[^\n]*\n(?:[ \t]+[^\n]*\n)*", lambda _: timer, prefix)


def readiness(recipe):
    sample = recipe["sample"]
    if recipe["panel"] == "flight-counter":
        return f"""            local feed = entry.instance.feed
            if not feed or not feed.available or feed.raw ~= {sample['count']}
                or feed.precision ~= 0 or entry.instance.text ~= "{sample['count']}"
                or entry.instance.phase ~= "active" or entry.instance.stateName ~= "active"
                or entry.instance.badgeText ~= "IN-FLIGHT" then return end
"""
    if recipe["panel"] == "text":
        result = ""
        for index, item in enumerate(recipe["config"]["texts"], 1):
            position = sample["switches"][item["source"]]
            value = {"up": -1024, "middle": 0, "down": 1024}[position]
            result += f"""            do
                local feed = entry.instance.feeds[{index}]
                if not feed or not feed.available or feed.telemetry or feed.value ~= {value} then return end
            end
"""
            expected = item["positions"][position]
            if index == 1:
                result += f"            if entry.instance.text ~= {json.dumps(expected)} then return end\n"
        return result
    if recipe["panel"] == "trim-panel":
        expected = ", ".join(str(sample[key]) for key in ("aileron", "elevator", "rudder"))
        return """            local indicators = entry.instance.indicators
            if not indicators or #indicators ~= 3 then return end
            local expected = { """ + expected + """ }
            for i, indicator in ipairs(indicators) do
                if not indicator.feed or not indicator.feed.available
                    or indicator.feed.value ~= expected[i] then return end
            end
"""
    if recipe["panel"] == "flight-timer":
        return f"""            local feed = entry.instance.feed
            if not feed or not feed.available or feed.value ~= {sample['remaining_seconds']}
                or feed.start ~= {sample['start_seconds']}
                or feed.name ~= {json.dumps(sample['name'])} then return end
"""
    if recipe["panel"] in ("flight-mode", "model-identity"):
        extra = ('            if feed.index ~= 0 then return end\n'
                 if recipe["panel"] == "flight-mode" else
                 '            if entry.instance.area.showImage and not entry.instance.image then return end\n')
        return f"""            local feed = entry.instance.feed
            if not feed or not feed.available or feed.name ~= {json.dumps(sample['name'])} then return end
""" + extra
    if recipe["panel"] == "tx-battery":
        return f"""            local feed = entry.instance.feed
            if not feed or not feed.available or feed.value ~= {sample['voltage']} then return end
"""
    result = """            local telemetry = context.serviceRuntime.byId.telemetry
            if not telemetry then return end
"""
    for name, source in sample["sources"].items():
        result += f"""            do
                local feed = telemetry:reading({json.dumps(name)})
                if not feed or not feed.available or feed.stale
                    or feed.unit ~= {source['unit']} or feed.precision ~= {source['precision']} then return end
                if not captureEqual(feed.raw, {lua_value(source['value'])}) then return end
            end
"""
    if recipe["panel"] == "navigation":
        result += """            local feed = entry.instance.feed
            if not feed or not feed.fix or not feed.home or feed.state ~= "normal"
                or not feed.distance or not feed.bearing then return end
"""
    if recipe["panel"] == "link-status":
        result += """            if not entry.instance.link or not entry.instance.link.live then return end
"""
    return result


def config_yaml(config):
    def emit(value, indent):
        lines = []
        for key, item in value.items():
            prefix = " " * indent + key + ":"
            if isinstance(item, list):
                lines.append(prefix + "\n")
                for entry in item:
                    if not isinstance(entry, dict):
                        raise ValueError("Layout config lists must contain mappings")
                    block = emit(entry, indent + 4)
                    lines.append(" " * (indent + 2) + "- " + block.lstrip())
            elif isinstance(item, dict):
                lines.append(prefix + "\n" + emit(item, indent + 2))
            else:
                lines.append(prefix + " " + json.dumps(item, ensure_ascii=True, allow_nan=False) + "\n")
        return "".join(lines)
    return emit(config, 6)


def lua_value(value):
    if isinstance(value, dict):
        return "{ " + ", ".join(f"[{json.dumps(key)}] = {lua_value(item)}"
                                for key, item in value.items()) + " }"
    if isinstance(value, list):
        return "{ " + ", ".join(lua_value(item) for item in value) + " }"
    return json.dumps(value, ensure_ascii=True, allow_nan=False)


def fixture_inputs(recipe):
    """Synthetic firmware API inputs, installed only in the isolated service environment."""
    if recipe["panel"] not in SYNTHETIC_PANELS:
        return None
    if recipe["panel"] == "flight-counter":
        # Each gallery instance qualifies once against the isolated real GV9.
        initial = recipe["sample"]["count"] - len(recipe["panels"])
        return f"""model.setGlobalVariable(8, 0, {initial})
assert(model.getGlobalVariable(8, 0) == {initial}, "capture could not initialize GV9")
local armIndex = assert(getSwitchIndex("SF" .. CHAR_DOWN))
return {{
    getSwitchValue = function(index)
        if index == armIndex then return true end
        return getSwitchValue(index)
    end,
    getFieldInfo = function(name)
        if name == "sf" then return {{ id = 300, name = name }} end
        if name == "ch3" then return {{ id = 301, name = name }} end
        return getFieldInfo(name)
    end,
    getValue = function(id)
        if id == "sf" or id == 300 or id == "ch3" or id == 301 then return 1024 end
        return getValue(id)
    end,
    getRSSI = function() return {recipe['sample']['rssi']} end,
}}
"""
    if recipe["panel"] == "text":
        switches = {name: {"id": 300 + index,
                          "value": {"up": -1024, "middle": 0, "down": 1024}[position]}
                    for index, (name, position) in enumerate(recipe["sample"]["switches"].items())}
        return """local switches = """ + lua_value(switches) + """
return {
    getFieldInfo = function(name)
        local switch = switches[name]
        if switch then return { id = switch.id, name = name } end
        return getFieldInfo(name)
    end,
    getValue = function(id)
        for name, switch in pairs(switches) do
            if id == name or id == switch.id then return switch.value end
        end
        return getValue(id)
    end,
}
"""
    if recipe["panel"] == "tx-battery":
        return f"""return {{
    getValue = function(source)
        if source == "tx-voltage" then return {recipe['sample']['voltage']} end
        return getValue(source)
    end,
}}
"""
    sources = recipe["sample"]["sources"]
    rows = []
    for index, (name, source) in enumerate(sources.items()):
        rows.append(f"    {{name = {json.dumps(name)}, id = {30000 + index}, "
                    f"unit = {source['unit']}, prec = {source['precision']}, "
                    f"value = {lua_value(source['value'])}}}")
    return """local sources = {
""" + ",\n".join(rows) + """
}
return {
    getFieldInfo = function(name)
        for _, source in ipairs(sources) do
            if source.name == name then return source end
        end
        return getFieldInfo(name)
    end,
    getValue = function(id)
        for _, source in ipairs(sources) do
            if source.id == id or source.name == id then return source.value end
        end
        return getValue(id)
    end,
    getRSSI = function() return """ + str(recipe["sample"]["rssi"]) + """ end,
    model = {
        getInfo = model.getInfo,
        getTimer = model.getTimer,
        getGlobalVariable = model.getGlobalVariable,
        getGlobalVariableDetails = model.getGlobalVariableDetails,
        getSensor = function(index)
            return sources[index + 1]
        end,
    },
}
"""
