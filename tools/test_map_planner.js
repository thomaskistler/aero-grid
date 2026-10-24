// SPDX-License-Identifier: GPL-2.0-only
"use strict";

if (typeof require === "function") {
    require("../docs/javascripts/map-pack.js");
    require("../docs/javascripts/map-planner.js");
}

(async function () {
    const { plan, snapBounds, specification, geographicBounds,
        radioFootprint, overviewZoom, coveragePlan, RADIO_PRESETS, MAX_TILES } = globalThis.AeroGridMapPlanner;
    let assertions = 0;
    function equal(actual, expected) {
        assertions++;
        if (JSON.stringify(actual) !== JSON.stringify(expected)) {
            throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
        }
    }
    function rejects(callback) {
        assertions++;
        let rejected = false;
        try { callback(); } catch (error) { rejected = true; }
        if (!rejected) throw new Error("Expected invalid input to be rejected.");
    }

    const bounds = { south: -1, north: 1, west: -1, east: 1 };
    equal(plan(bounds, [1]).levels, [{
        zoom: 1, xRanges: [{ min: 0, max: 1 }], yMin: 0, yMax: 1, tiles: 4
    }]);
    equal(plan({ south: 1, north: 2, west: 1, east: 2 }, [1]).tileCount, 1);
    equal(plan({ south: 0, north: 1, west: 0, east: 1 }, [1]).tileCount, 1);
    equal(plan({ south: -1, north: 0, west: -1, east: 0 }, [1]).tileCount, 1);
    const crossing = { south: -1, north: 1, west: 179, east: -179 };
    equal(plan(crossing, [2]).levels[0].xRanges, [{ min: 0, max: 0 }, { min: 3, max: 3 }]);
    equal(plan(crossing, [0]).tileCount, 1);
    equal(plan(crossing, [0, 1]).tileCount, 5);
    equal(plan({ south: -1, north: 1, west: 180, east: -179 }, [2]).levels[0].xRanges, [{ min: 0, max: 0 }]);
    equal(plan(bounds, [0]).estimatedBytes, { min: 10240, max: 30720 });
    rejects(() => plan({ ...bounds, south: NaN }, [1]));
    rejects(() => plan({ ...bounds, north: Infinity }, [1]));
    rejects(() => plan({ ...bounds, south: 86, north: 87 }, [1]));
    rejects(() => plan({ ...bounds, south: -90 }, [1]));
    rejects(() => plan({ ...bounds, south: 1, north: 1 }, [1]));
    rejects(() => plan({ ...bounds, west: -181 }, [1]));
    rejects(() => plan({ ...bounds, west: -180, east: 180 }, [1]));
    rejects(() => plan({ ...bounds, west: 180, east: -180 }, [1]));
    rejects(() => plan(bounds, []));
    rejects(() => plan(bounds, [1, 1]));
    rejects(() => plan(bounds, [1.5]));
    rejects(() => plan(bounds, [21]));
    rejects(() => specification("field", bounds, [18]));
    rejects(() => specification(" ", bounds, [1]));
    rejects(() => specification("a".repeat(81), bounds, [1]));
    const selection = specification(" My field ", crossing, [1]);
    equal(selection.name, "My field");
    equal(selection.imageryIncluded, false);
    equal(selection.format, "aerogrid-map-selection");
    equal(selection.bounds, crossing);
    equal(Object.prototype.hasOwnProperty.call(selection, "key"), false);
    equal(MAX_TILES, 2000);
    const limitBounds = {
        south: 0.01, north: 0.02, west: -180,
        east: -180 + 2000 * 360 / 4096
    };
    equal(specification("at-limit", limitBounds, [12]).tileCount, 2000);
    rejects(() => specification("over-limit", {
        ...limitBounds, east: -180 + 2001 * 360 / 4096
    }, [12]));
    equal(geographicBounds([179, -1, 181, 1]), crossing);
    equal(geographicBounds([-181, -1, -179, 1]), crossing);
    equal(geographicBounds([539, -1, 541, 1]), crossing);
    equal(geographicBounds([179, -1, 180, 1]), { south: -1, north: 1, west: 179, east: 180 });
    rejects(() => geographicBounds([-180, -1, 180, 1]));
    rejects(() => geographicBounds([1, -1, 1, 1]));
    rejects(() => geographicBounds([NaN, -1, 1, 1]));
    const snapped = snapBounds({ south: 1, north: 2, west: 1, east: 2 }, [4, 3]);
    equal(snapped.west, -45);
    equal(snapped.east, 135);
    equal(Math.abs(snapped.south + 40.97989806962013) < 1e-12, true);
    equal(Math.abs(snapped.north - 40.97989806962013) < 1e-12, true);
    rejects(() => snapBounds(bounds, [0]));
    rejects(() => snapBounds(bounds, [2]));
    rejects(() => snapBounds(bounds, [3, 2]));
    rejects(() => snapBounds(bounds, []));
    rejects(() => snapBounds({ ...bounds, north: NaN }, [18]));
    const areas = [bounds, crossing, limitBounds,
        { south: 47.376, north: 47.378, west: 8.54, east: 8.542 },
        { south: -85.0511287798066, north: -85, west: -180, east: -179.999 },
        { south: 85, north: 85.0511287798066, west: 179.999, east: 180 },
        { south: -1, north: 1, west: 180, east: -179 },
        { south: 1, north: 1.00001, west: 1, east: 1.00001 },
        { south: 1, north: 1.00001, west: 179.99999, east: -179.99999 }];
    for (const area of areas) {
        for (const detail of [[15, 16], [16, 17, 18], [17, 18, 19]]) {
            const result = snapBounds(area, detail);
            const original = plan(area, detail).levels;
            const expanded = plan(result, detail).levels;
            const lowest = expanded[0];
            equal(lowest.xRanges.reduce((total, range) => total + range.max - range.min + 1, 0) >= 4, true);
            equal(lowest.yMax - lowest.yMin + 1 >= 2, true);
            for (let index = 0; index < original.length; index++) {
                const before = original[index];
                const after = expanded[index];
                equal(after.yMin <= before.yMin && after.yMax >= before.yMax, true);
                equal(before.xRanges.every(range => after.xRanges.some(
                    larger => larger.min <= range.min && larger.max >= range.max)), true);
            }
            const before = original[0];
            if (before.xRanges.reduce((total, range) => total + range.max - range.min + 1, 0) >= 4 &&
                before.yMax - before.yMin + 1 >= 2) equal(lowest, before);
            equal(snapBounds(result, detail), result);
            equal(result.south <= area.south + 1e-12 && result.north >= area.north - 1e-12, true);
            const count = 2 ** Math.min(...detail);
            for (const longitude of [result.west, result.east]) {
                const x = (longitude + 180) / 360 * count;
                equal(Math.abs(x - Math.round(x)) < 1e-7, true);
            }
        }
    }
    const tinyField = { south: 47.376, north: 47.37601, west: 8.54, east: 8.54001 };
    for (const radio of RADIO_PRESETS) {
        for (const area of [tinyField,
            { south: 37.4, north: 37.405, west: -122.1, east: -122.09 },
            { south: -10.001, north: -10, west: 179.999, east: -179.999 },
            { south: 85.05112, north: 85.051128, west: 1, east: 1.001 },
            { south: -85.051128, north: -85.05112, west: -180, east: -179.99999 }]) {
            const zooms = [15, 16, 17, 18, 19];
            const full = coveragePlan(area, zooms, radio.id);
            equal(full, { bounds: snapBounds(area, zooms, radio.id),
                ...plan(snapBounds(area, zooms, radio.id), zooms) });
            const compact = coveragePlan(area, zooms, radio.id, true);
            equal(compact.bounds, full.bounds);
            equal(coveragePlan(area, [16], radio.id, true).tileCount,
                coveragePlan(area, [16], radio.id).tileCount);
            equal(compact.tileCount, compact.levels.reduce((total, level) => total + level.tiles, 0));
            equal(compact.estimatedBytes, { min: compact.tileCount * 10240, max: compact.tileCount * 30720 });
            equal(compact.tileCount < full.tileCount, true);
            compact.levels.forEach((level, index) => {
                equal(plan(level.bounds, [level.zoom]).levels[0], {
                    zoom: level.zoom, xRanges: level.xRanges, yMin: level.yMin,
                    yMax: level.yMax, tiles: level.tiles
                });
                equal(level.bounds, snapBounds(area, [level.zoom], radio.id));
                const columns = level.xRanges.reduce((total, range) => total + range.max - range.min + 1, 0);
                equal(columns * 256 >= radio.width, true);
                equal((level.yMax - level.yMin + 1) * 256 >= radio.height, true);
                equal(level.tiles <= full.levels[index].tiles, true);
                const count = 2 ** level.zoom;
                const x = lon => (lon + 180) / 360 * count;
                const y = lat => (1 - Math.asinh(Math.tan(lat * Math.PI / 180)) / Math.PI) / 2 * count;
                let west = level.bounds.west;
                // Unwrap download bounds into the flying area's world.
                if (west > area.west) west -= 360;
                const east = level.bounds.east + (level.bounds.east <= west ? 360 : 0);
                const unwrappedEast = east < area.west ? east + 360 : east;
                const areaEast = area.east < area.west ? area.east + 360 : area.east;
                equal(x(west) <= x(area.west) + 1e-7, true);
                equal(x(unwrappedEast) >= x(areaEast) - 1e-7, true);
                equal(y(level.bounds.north) <= y(area.north) + 1e-7, true);
                equal(y(level.bounds.south) >= y(area.south) - 1e-7, true);
            });
            equal(specification("field", compact.bounds, zooms, radio.id, compact).levels, compact.levels);
        }
    }
    equal(overviewZoom(tinyField, "tx16s-mk3"), 19);
    rejects(() => overviewZoom(bounds, "tx16s-mk3"));
    rejects(() => overviewZoom(tinyField, "unknown"));
    rejects(() => overviewZoom({ ...tinyField, north: NaN }, "tx15"));
    for (const radio of RADIO_PRESETS) {
        for (const zoom of [11, 15, 18, 19]) {
            const count = 2 ** zoom;
            const latitude = y => Math.atan(Math.sinh(Math.PI * (1 - 2 * y / count))) * 180 / Math.PI;
            const halfWidth = radio.width * 0.99 / 256 / count * 180;
            const halfHeight = radio.height * 0.99 / 256 / 2;
            const area = { west: -halfWidth, east: halfWidth,
                north: latitude(count / 2 - halfHeight), south: latitude(count / 2 + halfHeight) };
            equal(overviewZoom(area, radio.id), zoom);
            const crossing = { ...area, west: 180 - halfWidth, east: -180 + halfWidth };
            equal(overviewZoom(crossing, radio.id), zoom);
            equal(overviewZoom({ ...area, south: area.south / 10, north: area.north / 10 }, radio.id), zoom);
            equal(overviewZoom({ ...area, west: area.west / 10, east: area.east / 10 }, radio.id), zoom);
        }
    }
    equal(RADIO_PRESETS.map(radio => radio.id), ["tx16s", "tx16s-mkii", "tx15", "nv14", "tx16s-mk3"]);
    rejects(() => radioFootprint("boxer"));
    equal(radioFootprint("mono-128x64"), {
        id: "mono-128x64", name: "Monochrome radio", width: 128, height: 64, columns: 1, rows: 1
    });
    equal(radioFootprint("mono-212x64"), {
        id: "mono-212x64", name: "Monochrome radio", width: 212, height: 64, columns: 1, rows: 1
    });
    for (const id of ["mono-128x64", "mono-212x64"]) {
        equal(coveragePlan(tinyField, [17], id).tileCount, 1);
    }
    rejects(() => snapBounds(tinyField, [16], "unknown"));
    rejects(() => specification("field", tinyField, [16], "unknown"));
    for (const radio of RADIO_PRESETS) {
        const footprint = radioFootprint(radio.id);
        equal(footprint.columns, radio.id === "tx16s-mk3" ? 4 : 2);
        equal(footprint.rows, 2);
        for (const area of [tinyField,
            { south: 85.05112, north: 85.051128, west: 179.99999, east: -179.99999 },
            { south: -85.051128, north: -85.05112, west: -180, east: -179.99999 }]) {
            const snapped = snapBounds(area, [16, 17], radio.id);
            const estimate = plan(snapped, [16, 17]);
            equal(estimate.levels[0].tiles, footprint.columns * footprint.rows);
            equal(estimate.tileCount, radio.id === "tx16s-mk3" ? 40 : 20);
            equal(snapBounds(snapped, [16, 17], radio.id), snapped);
            equal(specification("field", snapped, [16, 17], radio.id).radio, footprint);
        }
    }
    for (const [detail, tiles] of [
        [[16, 17], 40], [[16, 17, 18], 168],
        [[16, 17, 18, 19], 680], [[15, 16, 17, 18, 19], 2728]
    ]) {
        const result = snapBounds(tinyField, detail);
        equal(plan(result, detail).tileCount, tiles);
        if (tiles <= MAX_TILES) equal(specification("field", result, detail).tileCount, tiles);
        else rejects(() => specification("field", result, detail));
    }
    if (typeof console !== "undefined") console.log(`${assertions} map planner assertions passed.`);
})().catch(error => {
    if (typeof process !== "undefined") process.exitCode = 1;
    console.error(error);
    throw error;
});
