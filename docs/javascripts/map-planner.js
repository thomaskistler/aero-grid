// SPDX-License-Identifier: GPL-2.0-only
(function (root) {
    "use strict";

    const MAX_LATITUDE = 85.0511287798066;
    const MAX_TILES = 2000;
    const RADIO_PRESETS = Object.freeze([
        { id: "tx16s", name: "RadioMaster TX16S / TX16S MAX", width: 480, height: 272 },
        { id: "tx16s-mkii", name: "RadioMaster TX16S MKII / MKII MAX", width: 480, height: 272 },
        { id: "tx15", name: "RadioMaster TX15 / TX15 MAX", width: 480, height: 320 },
        { id: "tx16s-mk3", name: "RadioMaster TX16S MK3 / MK3 MAX", width: 800, height: 480 }
    ].map(Object.freeze));

    function radioFootprint(id) {
        const radio = RADIO_PRESETS.find(preset => preset.id === id);
        if (!radio) throw new Error("Choose a supported color-screen radio.");
        return { ...radio, columns: Math.ceil(radio.width / 256), rows: Math.ceil(radio.height / 256) };
    }

    function validateBounds(bounds) {
        const { south, north, west, east } = bounds;
        if (![south, north, west, east].every(Number.isFinite)) {
            throw new Error("Enter a number for each geographic bound.");
        }
        if (south < -MAX_LATITUDE || north > MAX_LATITUDE || south >= north) {
            throw new Error("South must be below north, within Web Mercator's latitude limits.");
        }
        if (west < -180 || west > 180 || east < -180 || east > 180 || west === east) {
            throw new Error("Use distinct longitudes between -180 and 180.");
        }
        const width = east > west ? east - west : 360 - west + east;
        if (width <= 0 || width >= 360) {
            throw new Error("Select an area narrower than the whole world.");
        }
        return bounds;
    }

    function stableTilePosition(value, count) {
        const integer = Math.round(value);
        return Math.abs(value - integer) <= count * Number.EPSILON * 32 ? integer : value;
    }

    function tileX(longitude, count) {
        return stableTilePosition((longitude + 180) / 360 * count, count);
    }

    function tileY(latitude, count) {
        const radians = latitude * Math.PI / 180;
        return stableTilePosition(
            Math.max(0, Math.min(count, (1 - Math.asinh(Math.tan(radians)) / Math.PI) / 2 * count)), count);
    }

    function geographicBounds(extent) {
        const [west, south, east, north] = extent;
        if (![west, south, east, north].every(Number.isFinite) ||
            east <= west || east - west >= 360) {
            throw new Error("Zoom in to select an area narrower than the whole world.");
        }
        const longitude = value => ((value + 180) % 360 + 360) % 360 - 180;
        const normalizedEast = longitude(east);
        return validateBounds({
            south: Math.max(-MAX_LATITUDE, south),
            north: Math.min(MAX_LATITUDE, north),
            west: longitude(west),
            east: normalizedEast === -180 ? 180 : normalizedEast
        });
    }

    function plan(bounds, zooms) {
        validateBounds(bounds);
        if (!Array.isArray(zooms) || zooms.length === 0 ||
            new Set(zooms).size !== zooms.length ||
            !zooms.every(z => Number.isInteger(z) && z >= 0 && z <= 20)) {
            throw new Error("Choose distinct integer zoom levels between 0 and 20.");
        }
        const levels = zooms.map(zoom => {
            const count = 2 ** zoom;
            const yMin = Math.min(count - 1, Math.floor(tileY(bounds.north, count)));
            const yMax = Math.max(yMin, Math.min(count - 1, Math.ceil(tileY(bounds.south, count)) - 1));
            const intervals = bounds.west < bounds.east
                ? [[bounds.west, bounds.east]]
                : [[bounds.west, 180], [-180, bounds.east]];
            const ranges = intervals.filter(([west, east]) => west < east).map(([west, east]) => ({
                min: Math.max(0, Math.min(count - 1, Math.floor(tileX(west, count)))),
                max: Math.max(0, Math.min(count - 1, Math.ceil(tileX(east, count)) - 1))
            })).sort((a, b) => a.min - b.min);
            // Date-line halves can address the same tile at overview zooms.
            const merged = [];
            for (const range of ranges) {
                const last = merged[merged.length - 1];
                if (last && range.min <= last.max + 1) {
                    last.max = Math.max(last.max, range.max);
                } else {
                    merged.push({ ...range });
                }
            }
            const tiles = merged.reduce((total, range) => total + range.max - range.min + 1, 0) *
                (yMax - yMin + 1);
            return { zoom, xRanges: merged, yMin, yMax, tiles };
        });
        const tileCount = levels.reduce((total, level) => total + level.tiles, 0);
        return { levels, tileCount, estimatedBytes: { min: tileCount * 10 * 1024, max: tileCount * 30 * 1024 } };
    }

    function overviewZoom(bounds, radioId) {
        validateBounds(bounds);
        const radio = radioFootprint(radioId);
        const east = bounds.east < bounds.west ? bounds.east + 360 : bounds.east;
        for (let zoom = 19; zoom >= 11; zoom--) {
            const count = 2 ** zoom;
            const width = (east - bounds.west) / 360 * count * 256;
            const height = (tileY(bounds.south, count) - tileY(bounds.north, count)) * 256;
            if (width <= radio.width && height <= radio.height) return zoom;
        }
        throw new Error("This area cannot fit the radio screen at zoom 11. Select a smaller flying area.");
    }

    function snapBounds(bounds, zooms, radioId = "tx16s-mk3") {
        const footprint = radioFootprint(radioId);
        const levels = plan(bounds, zooms).levels;
        const level = levels.reduce((lowest, current) => current.zoom < lowest.zoom ? current : lowest);
        const count = 2 ** level.zoom;
        let west = Math.floor(tileX(bounds.west, count));
        let east = Math.ceil(tileX(bounds.east < bounds.west ? bounds.east + 360 : bounds.east, count));
        const extraColumns = Math.max(0, footprint.columns - (east - west));
        west -= Math.floor(extraColumns / 2);
        east += Math.ceil(extraColumns / 2);
        if (east - west >= count) {
            throw new Error("Snapping would cover the whole world. Select a smaller area or a higher detail level.");
        }
        const rows = Math.max(footprint.rows, level.yMax - level.yMin + 1);
        const yMin = Math.max(0, Math.min(count - rows,
            level.yMin - Math.floor((rows - (level.yMax - level.yMin + 1)) / 2)));
        const longitude = index => ((index % count + count) % count) / count * 360 - 180;
        const latitude = index => Math.atan(Math.sinh(Math.PI * (1 - 2 * index / count))) * 180 / Math.PI;
        return validateBounds({
            west: longitude(west),
            east: east % count === 0 ? 180 : longitude(east),
            north: Math.min(MAX_LATITUDE, latitude(yMin)),
            south: Math.max(-MAX_LATITUDE, latitude(yMin + rows))
        });
    }

    function coveragePlan(area, zooms, radioId, compact = false) {
        const fullBounds = snapBounds(area, zooms, radioId);
        if (!compact) return { bounds: fullBounds, ...plan(fullBounds, zooms) };
        const levels = zooms.map(zoom => {
            const bounds = snapBounds(area, [zoom], radioId);
            return { ...plan(bounds, [zoom]).levels[0], bounds };
        });
        const tileCount = levels.reduce((total, level) => total + level.tiles, 0);
        const overview = levels.reduce((lowest, level) => level.zoom < lowest.zoom ? level : lowest);
        return { bounds: overview.bounds, levels, tileCount,
            estimatedBytes: { min: tileCount * 10 * 1024, max: tileCount * 30 * 1024 } };
    }

    function specification(name, bounds, zooms, radioId = "tx16s-mk3", coverage) {
        if (!name.trim() || name.trim().length > 80) {
            throw new Error("Enter a selection name between 1 and 80 characters.");
        }
        const estimate = coverage || plan(bounds, zooms);
        if (estimate.tileCount > MAX_TILES) {
            throw new Error("Selection exceeds 2,000 tiles. Reduce the area or detail level.");
        }
        return {
            format: "aerogrid-map-selection",
            version: 1,
            name: name.trim(),
            previewProvider: "google-maps",
            imageryIncluded: false,
            projection: "EPSG:3857",
            tileScheme: "XYZ",
            tileSize: 256,
            radio: radioFootprint(radioId),
            bounds: { ...bounds },
            ...estimate
        };
    }

    function tileUrl(zoom, x, y) {
        return `https://mt1.google.com/vt?lyrs=y&x=${x}&y=${y}&z=${zoom}`;
    }

    function sampleTiles(bounds, zooms, estimate = plan(bounds, zooms)) {
        const east = bounds.east < bounds.west ? bounds.east + 360 : bounds.east;
        const longitude = ((bounds.west + east) / 2 + 180) % 360;
        return estimate.levels.map(level => {
            const count = 2 ** level.zoom;
            const x = Math.min(count - 1, Math.floor(longitude / 360 * count));
            const y = Math.floor((level.yMin + level.yMax) / 2);
            return { zoom: level.zoom, x, y, tiles: level.tiles, url: tileUrl(level.zoom, x, y) };
        });
    }

    async function measureSamples(samples, source, signal) {
        const results = [];
        for (const sample of samples) {
            const image = await source.readTile(sample.zoom, sample.x, sample.y, signal);
            results.push({ ...sample, bytes: image.length });
        }
        return {
            samples: results,
            bytes: results.reduce((total, sample) => total + sample.bytes, 0),
            estimatedBytes: results.reduce((total, sample) => total + sample.bytes * sample.tiles, 0)
        };
    }

    root.AeroGridMapPlanner = { plan, snapBounds, specification, geographicBounds, sampleTiles, measureSamples,
        radioFootprint, overviewZoom, coveragePlan, RADIO_PRESETS, MAX_TILES };
    if (typeof document === "undefined" || !document.getElementById("ag-map-planner")) {
        return;
    }

    const element = name => document.getElementById(`ag-map-${name}`);
    const status = text => { element("status").textContent = text; };
    const radioId = () => element("radio").value;
    for (const radio of RADIO_PRESETS) {
        const option = document.createElement("option");
        option.value = radio.id;
        option.textContent = `${radio.name} (${radio.width} x ${radio.height})`;
        option.selected = radio.id === "tx16s-mk3";
        element("radio").appendChild(option);
    }
    function updateRadio() {
        const radio = radioFootprint(radioId());
        element("radio-summary").textContent =
            `${radio.width} x ${radio.height} screen: minimum ${radio.columns} columns by ${radio.rows} rows ` +
            "at the lowest selected zoom. Assumes a full-screen map. " +
            "Panning is clamped to the downloaded area; the plane need not stay centered.";
    }
    updateRadio();
    const zooms = () => {
        const min = minimumZoom;
        const max = Number(element("max-zoom").value);
        return Array.from({ length: max - min + 1 }, (_, index) => min + index);
    };
    let map;
    let extentInteraction;
    let coverageSource;
    let radioMap;
    let radioSelectionSource;
    let radioPreviewZoom;
    let radioPreviewKey;
    let bounds;
    let selectedBounds;
    let coverage;
    let minimumZoom = 16;
    let failed = false;
    let locationRequest = 0;
    let navigationRevision = 0;
    let measurement;
    let measuring = false;
    let settingExtent = false;
    let packController;
    const compactCoverage = () => element("compact").checked;
    const selectionKey = () => JSON.stringify([selectedBounds, radioId(), zooms(), compactCoverage()]);

    function showMeasurement() {
        element("measure").disabled = !bounds || !selectedBounds || measuring;
        if (measuring) return;
        if (measurement && measurement.key !== selectionKey()) measurement = undefined;
        if (!measurement) {
            element("measurement").textContent = bounds
                ? "Download one sample tile per selected zoom level into memory to estimate storage."
                : "Select an area to measure one sample tile per zoom level.";
            return;
        }
        const { samples, bytes, estimatedBytes } = measurement;
        element("measurement").textContent =
            samples.map(sample => `Zoom ${sample.zoom}: ${(sample.bytes / 1024).toFixed(1)} KiB`).join("; ") +
            `. ${samples.length} sample tiles, ${(bytes / 1024).toFixed(1)} KiB as radio JPEGs. ` +
            `Estimated selected-area JPEG storage: ${(estimatedBytes / (1024 * 1024)).toFixed(1)} MiB. ` +
            "Each zoom's sample size is multiplied by its tile count. One tile per zoom is only a rough sample, not a measured pack size.";
    }

    function locate(explicit = false) {
        const message = text => { element("location-status").textContent = text; };
        if (!root.isSecureContext || !root.navigator.geolocation) {
            message("Browser location is unavailable. Use HTTPS or localhost, or navigate manually.");
            return;
        }
        const request = ++locationRequest;
        const revision = navigationRevision;
        element("locate").disabled = true;
        message("Waiting for your browser's location permission...");
        root.navigator.geolocation.getCurrentPosition(position => {
            if (request !== locationRequest) return;
            element("locate").disabled = false;
            const { latitude, longitude } = position.coords;
            if (!Number.isFinite(latitude) || !Number.isFinite(longitude) ||
                Math.abs(latitude) > MAX_LATITUDE || Math.abs(longitude) > 180) {
                message("Your location is outside the supported map coverage. Navigate manually.");
                return;
            }
            if (revision !== navigationRevision || (!explicit && bounds)) {
                message("Location found, but the map was not moved because you already started navigating. Choose Use my location to recenter.");
                return;
            }
            map.getView().setCenter(root.ol.proj.fromLonLat([longitude, latitude]));
            map.getView().setZoom(16);
            message("Map centered near your browser-reported location. Select your flying area.");
        }, error => {
            if (request !== locationRequest) return;
            element("locate").disabled = false;
            const messages = {
                1: "Location permission was denied. Navigate manually or allow location in your browser settings and retry.",
                2: "Your browser could not determine your location. Navigate manually or retry.",
                3: "Location lookup timed out. Navigate manually or retry."
            };
            message(messages[error.code] || "Location lookup failed. Navigate manually or retry.");
        }, { enableHighAccuracy: false, timeout: 10000, maximumAge: 300000 });
    }

    function projectedExtent(value) {
        const east = value.east < value.west ? value.east + 360 : value.east;
        return root.ol.proj.transformExtent(
            [value.west, value.south, east, value.north], "EPSG:4326", "EPSG:3857"
        );
    }

    function readExtent(extent) {
        return geographicBounds(root.ol.proj.transformExtent(extent, "EPSG:3857", "EPSG:4326"));
    }

    function updateSummary() {
        if (packController) {
            packController.abort();
            element("pack-status").textContent = "Selection or export identity changed. Export cancelled.";
        }
        element("pack-export").disabled = true;
        element("satellite-export").disabled = true;
        drawCoverage();
        updateRadioPreview();
        showMeasurement();
        element("export").disabled = true;
        if (!bounds || !selectedBounds) {
            element("min-zoom-value").textContent = "Select an area";
            element("max-zoom").min = 11;
            element("summary").textContent = "No area selected.";
            return;
        }
        try {
            const estimate = coverage;
            element("summary").textContent =
                `${estimate.tileCount.toLocaleString()} planned tiles. Use sample measurement to estimate radio JPEG storage. ` +
                estimate.levels.map(level => `Zoom ${level.zoom}: ${level.tiles} tiles`).join("; ") +
                (estimate.tileCount > MAX_TILES ? ". Reduce the area or detail level (2,000-tile limit)." : ".");
            if (compactCoverage()) {
                const full = coveragePlan(selectedBounds, zooms(), radioId());
                const difference = full.tileCount - estimate.tileCount;
                element("summary").textContent +=
                    ` Per-zoom coverage saves ${difference.toLocaleString()} tiles versus full-area coverage.`;
            }
            specification(element("name").value, bounds, zooms(), radioId(), coverage);
            element("export").disabled = failed;
            root.AeroGridMapPack.identifier(element("area-id").value);
            element("pack-export").disabled = !!packController || failed;
            element("satellite-export").disabled = !!packController || failed;
        } catch (error) {
            element("summary").textContent = error.message;
        }
    }

    function syncBounds() {
        try {
            setSelection(readExtent(extentInteraction.getExtent()), false);
        } catch (error) {
            bounds = undefined;
            selectedBounds = undefined;
            updateSummary();
            status(error.message);
            return;
        }
    }

    function updateRadioPreview() {
        if (!radioMap) return;
        const frame = element("radio-preview-frame");
        radioSelectionSource.clear();
        if (!bounds || !selectedBounds) {
            frame.hidden = true;
            radioPreviewKey = undefined;
            element("preview-out").disabled = true;
            element("preview-in").disabled = true;
            element("preview-zoom").textContent = "No area selected";
            element("radio-preview-status").textContent =
                "Select a flying area to see how it fits on your radio.";
            return;
        }
        const ol = root.ol;
        const radio = radioFootprint(radioId());
        const selected = projectedExtent(selectedBounds);
        const key = JSON.stringify([selectedBounds, radioId()]);
        const reset = radioPreviewKey !== key;
        radioPreviewKey = key;
        radioPreviewZoom = reset ? minimumZoom :
            Math.max(minimumZoom, Math.min(Number(element("max-zoom").value), radioPreviewZoom));
        const level = coverage.levels.find(level => level.zoom === radioPreviewZoom);
        const availableExtent = projectedExtent(level.bounds || bounds);
        const worldWidth = ol.proj.get("EPSG:3857").getExtent()[2] * 2;
        const shift = Math.round(((selected[0] + selected[2]) -
            (availableExtent[0] + availableExtent[2])) / (2 * worldWidth)) * worldWidth;
        availableExtent[0] += shift;
        availableExtent[2] += shift;
        const resolution = worldWidth / (256 * 2 ** radioPreviewZoom);
        const halfWidth = radio.width * resolution / 2;
        const halfHeight = radio.height * resolution / 2;
        const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
        const previousCenter = reset ? undefined : radioMap.getView().getCenter();
        const center = [
            clamp(previousCenter ? previousCenter[0] : (selected[0] + selected[2]) / 2,
                availableExtent[0] + halfWidth, availableExtent[2] - halfWidth),
            clamp(previousCenter ? previousCenter[1] : (selected[1] + selected[3]) / 2,
                availableExtent[1] + halfHeight, availableExtent[3] - halfHeight)
        ];
        frame.hidden = false;
        const scale = Math.min(1, frame.parentElement.clientWidth / radio.width);
        frame.style.width = `${radio.width * scale}px`;
        frame.style.height = `${radio.height * scale}px`;
        element("radio-preview").style.width = `${radio.width}px`;
        element("radio-preview").style.height = `${radio.height}px`;
        element("radio-preview").style.transform = `scale(${scale})`;
        radioMap.setSize([radio.width, radio.height]);
        radioMap.setView(new ol.View({
            center, zoom: radioPreviewZoom, minZoom: radioPreviewZoom, maxZoom: radioPreviewZoom,
            extent: availableExtent, smoothExtentConstraint: false,
            enableRotation: false
        }));
        radioMap.getLayers().item(0).setExtent(availableExtent);
        element("preview-out").disabled = radioPreviewZoom <= minimumZoom;
        element("preview-in").disabled = radioPreviewZoom >= Number(element("max-zoom").value);
        element("preview-zoom").textContent = `Zoom ${radioPreviewZoom} (${minimumZoom}-${element("max-zoom").value})`;
        radioSelectionSource.addFeature(new ol.Feature(ol.geom.Polygon.fromExtent(selected)));
        const width = (selected[2] - selected[0]) / resolution;
        const height = (selected[3] - selected[1]) / resolution;
        element("radio-preview-status").textContent =
            `${radio.name}: ${radio.width} x ${radio.height} pixels at zoom ${radioPreviewZoom}. ` +
            `Your flying area occupies ${Math.ceil(width)} x ${Math.ceil(height)} screen pixels. ` +
            `Preview displayed at ${Math.round(scale * 100)}% scale.`;
    }

    function drawCoverage() {
        if (!coverageSource) return;
        coverageSource.clear();
        if (!bounds || !selectedBounds) {
            element("coverage-legend").textContent =
                "Solid blue: your flying area. Dashed amber: planned download coverage.";
            return;
        }
        const ol = root.ol;
        const extent = projectedExtent(bounds);
        const selectionExtent = extentInteraction.getExtent();
        if (selectionExtent) {
            // Keep coverage in the same wrapped world as the editable selection.
            const worldWidth = ol.proj.get("EPSG:3857").getExtent()[2] * 2;
            const offset = Math.round(((selectionExtent[0] + selectionExtent[2]) -
                (extent[0] + extent[2])) / (2 * worldWidth)) * worldWidth;
            extent[0] += offset;
            extent[2] += offset;
        }
        const [west, south, east, north] = extent;
        const level = plan(bounds, [minimumZoom]).levels[0];
        const columns = level.xRanges.reduce((total, range) => total + range.max - range.min + 1, 0);
        const rows = level.yMax - level.yMin + 1;
        const lines = [];
        for (let column = 1; column < columns; column++) {
            const x = west + (east - west) * column / columns;
            lines.push([[x, south], [x, north]]);
        }
        for (let row = 1; row < rows; row++) {
            const y = south + (north - south) * row / rows;
            lines.push([[west, y], [east, y]]);
        }
        const outline = new ol.Feature(ol.geom.Polygon.fromExtent(extent));
        outline.setStyle(new ol.style.Style({
            stroke: new ol.style.Stroke({ color: "#ffbf47", width: 3, lineDash: [8, 6] }),
            fill: new ol.style.Fill({ color: "rgba(255, 191, 71, 0.08)" })
        }));
        const grid = new ol.Feature(new ol.geom.MultiLineString(lines));
        grid.setStyle(new ol.style.Style({
            stroke: new ol.style.Stroke({ color: "rgba(255, 191, 71, 0.8)", width: 1 })
        }));
        coverageSource.addFeatures([outline, grid]);
        element("coverage-legend").textContent =
            `Solid blue: your flying area. Dashed amber: planned download coverage. ` +
            `Amber grid: zoom ${minimumZoom} tiles (${columns} columns by ${rows} rows). ` +
            (compactCoverage()
                ? "Overview coverage shown; higher zooms independently cover the blue area, with at least one screen of tiles."
                : "Higher zooms subdivide each grid cell.");
    }

    function setSelection(value, updateExtent = true) {
        const overview = overviewZoom(value, radioId());
        const maximum = Math.max(overview, Number(element("max-zoom").value));
        const levels = Array.from({ length: maximum - overview + 1 }, (_, index) => overview + index);
        const nextCoverage = coveragePlan(value, levels, radioId(), compactCoverage());
        const snapped = nextCoverage.bounds;
        coverage = nextCoverage;
        selectedBounds = { ...value };
        minimumZoom = overview;
        element("max-zoom").min = overview;
        element("max-zoom").value = maximum;
        element("min-zoom-value").textContent = overview;
        updateZoomRange();
        if (updateExtent) {
            element("canvas").style.cursor = "";
            extentInteraction.setActive(true);
            settingExtent = true;
            try {
                extentInteraction.setExtent(projectedExtent(value));
            } finally {
                settingExtent = false;
            }
        }
        bounds = snapped;
        updateSummary();
        status("Flying area kept as selected (blue). Planned download coverage and overview tile grid are amber. Shift-drag the blue rectangle to resize.");
    }

    function mapFailure(message) {
        failed = true;
        element("options").disabled = true;
        element("export").disabled = true;
        element("satellite-export").disabled = true;
        element("pack-export").disabled = true;
        if (packController) packController.abort();
        element("zoom-range").disabled = true;
        status(message);
    }

    async function initializeMap() {
        try {
            // Load the pinned viewer only on the planner page, not throughout the docs.
            await Promise.all([
                new Promise((resolve, reject) => {
                    const stylesheet = document.createElement("link");
                    stylesheet.rel = "stylesheet";
                    stylesheet.href = "https://cdn.jsdelivr.net/npm/ol@10.6.1/ol.css";
                    stylesheet.onload = resolve;
                    stylesheet.onerror = () => reject(new Error("Unable to load OpenLayers styles. Check your connection or content blocker, then reload."));
                    document.head.appendChild(stylesheet);
                }),
                new Promise((resolve, reject) => {
                    const script = document.createElement("script");
                    script.src = "https://cdn.jsdelivr.net/npm/ol@10.6.1/dist/ol.js";
                    script.onload = resolve;
                    script.onerror = () => reject(new Error("Unable to load OpenLayers. Check your connection or content blocker, then reload."));
                    document.head.appendChild(script);
                })
            ]);
            const ol = root.ol;
            const source = new ol.source.XYZ({
                url: tileUrl("{z}", "{x}", "{y}"),
                attributions: '&copy; <a href="https://www.google.com/maps" target="_blank" rel="noopener">Google</a> and imagery providers',
                attributionsCollapsible: false,
                maxZoom: 19
            });
            source.on("tileloaderror", () => {
                element("imagery-status").textContent =
                    "Some Google map tiles could not load. Check your connection; direct tile access may be blocked. Selection and JSON export still work.";
            });
            const previewLayer = new ol.layer.Tile({ source });
            coverageSource = new ol.source.Vector();
            const coverageLayer = new ol.layer.Vector({ source: coverageSource });
            map = new ol.Map({
                target: element("canvas"),
                layers: [previewLayer, coverageLayer],
                interactions: ol.interaction.defaults.defaults({ shiftDragZoom: false }),
                view: new ol.View({
                    center: ol.proj.fromLonLat([0, 20]), zoom: 3, maxZoom: 19,
                    enableRotation: false
                })
            });
            radioSelectionSource = new ol.source.Vector();
            radioMap = new ol.Map({
                target: element("radio-preview"),
                layers: [
                    new ol.layer.Tile({ source }),
                    new ol.layer.Vector({
                        source: radioSelectionSource,
                        style: new ol.style.Style({
                            stroke: new ol.style.Stroke({ color: "#3399ff", width: 2 }),
                            fill: new ol.style.Fill({ color: "rgba(51, 153, 255, 0.12)" })
                        })
                    })
                ],
                controls: [new ol.control.Attribution({ collapsible: false })],
                interactions: [new ol.interaction.DragPan()],
                view: new ol.View({ center: [0, 0], zoom: 16, maxZoom: 19, enableRotation: false })
            });
            new ResizeObserver(updateRadioPreview).observe(element("radio-preview-frame").parentElement);
            const updateZoom = () => {
                const zoom = map.getView().getZoom();
                element("zoom").textContent = `Zoom ${Number.isInteger(zoom) ? zoom : zoom.toFixed(1)}`;
            };
            map.getView().on("change:resolution", updateZoom);
            updateZoom();
            extentInteraction = new ol.interaction.Extent({
                condition: ol.events.condition.shiftKeyOnly,
                boxStyle: new ol.style.Style({
                    stroke: new ol.style.Stroke({ color: "#3399ff", width: 2 }),
                    fill: new ol.style.Fill({ color: "rgba(51, 153, 255, 0.08)" })
                }),
                pointerStyle: [],
                pixelTolerance: 12
            });
            map.addInteraction(extentInteraction);
            map.on("pointerdrag", () => { navigationRevision++; });
            element("canvas").addEventListener("wheel", () => { navigationRevision++; }, { passive: true });
            element("canvas").addEventListener("keydown", () => { navigationRevision++; });
            element("canvas").addEventListener("click", () => { navigationRevision++; });
            extentInteraction.on("extentchanged", event => {
                if (settingExtent) return;
                if (event.extent) {
                    syncBounds();
                }
                else {
                    bounds = undefined;
                    selectedBounds = undefined;
                    updateSummary();
                }
            });
            element("options").disabled = false;
            element("zoom-range").disabled = false;
            status("Map ready. Go to your field, then select an area. No account or API key required.");
            locate();
        } catch (error) {
            mapFailure(`Unable to initialize map: ${error.message}`);
        }
    }

    for (const [name, step] of [["preview-out", -1], ["preview-in", 1]]) {
        element(name).addEventListener("click", () => {
            if (!selectedBounds || radioPreviewZoom === undefined) return;
            radioPreviewZoom = Math.max(minimumZoom,
                Math.min(Number(element("max-zoom").value), radioPreviewZoom + step));
            updateRadioPreview();
        });
    }

    element("viewport").addEventListener("click", () => {
        navigationRevision++;
        try {
            setSelection(readExtent(map.getView().calculateExtent(map.getSize())));
        } catch (error) {
            status(error.message);
        }
    });
    element("clear").addEventListener("click", () => {
        extentInteraction.setExtent(undefined);
        extentInteraction.setActive(true);
        bounds = undefined;
        selectedBounds = undefined;
        element("canvas").style.cursor = "";
        updateSummary();
        status("Selection cleared.");
    });
    let zoomPreview;
    function previewZoom(input) {
        if (!map) return;
        const view = map.getView();
        if (!zoomPreview) {
            navigationRevision++;
            view.cancelAnimations();
            zoomPreview = { zoom: view.getZoom(), center: view.getCenter().slice() };
        }
        zoomPreview.input = input;
        view.setZoom(Number(input.value));
    }
    function restoreZoom() {
        if (!zoomPreview) return;
        const previous = zoomPreview;
        zoomPreview = undefined;
        const view = map.getView();
        view.setZoom(previous.zoom);
        view.setCenter(previous.center);
    }
    root.addEventListener("pointerup", restoreZoom);
    root.addEventListener("pointercancel", restoreZoom);
    root.addEventListener("blur", restoreZoom);
    function updateZoomRange() {
        const input = element("max-zoom");
        element("max-zoom-value").textContent = input.value;
        input.setAttribute("aria-valuetext", `Zoom ${input.value}`);
    }
    updateZoomRange();
    let previousRadio = radioId();
    element("compact").addEventListener("change", () => {
        try {
            if (selectedBounds) setSelection(selectedBounds);
            else updateSummary();
        } catch (error) {
            element("compact").checked = !element("compact").checked;
            updateSummary();
            status(error.message);
        }
        updateRadio();
    });
    element("radio").addEventListener("change", () => {
        try {
            if (selectedBounds) setSelection(selectedBounds);
            else updateSummary();
            previousRadio = radioId();
        } catch (error) {
            element("radio").value = previousRadio;
            updateSummary();
            status(error.message);
        }
        updateRadio();
    });
    {
        const input = element("max-zoom");
        input.addEventListener("pointerdown", () => previewZoom(input));
        const zoomKeys = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "PageUp", "PageDown"];
        input.addEventListener("keydown", event => {
            if (zoomKeys.includes(event.key)) previewZoom(input);
        });
        input.addEventListener("keyup", event => {
            if (zoomKeys.includes(event.key)) restoreZoom();
        });
        input.addEventListener("blur", () => {
            if (zoomPreview && zoomPreview.input === input) restoreZoom();
        });
        input.addEventListener("input", () => {
            try {
                if (selectedBounds) setSelection(selectedBounds);
                else updateSummary();
            } catch (error) {
                updateSummary();
                status(error.message);
            }
            updateZoomRange();
            if (zoomPreview) previewZoom(input);
        });
    }
    element("measure").addEventListener("click", async () => {
        if (measuring || !bounds || !selectedBounds) return;
        const key = selectionKey();
        const controller = new AbortController();
        const timeout = root.setTimeout(() => controller.abort(), 30000);
        let source;
        measuring = true;
        measurement = undefined;
        showMeasurement();
        element("measurement").textContent = "Downloading one sample tile per selected zoom level...";
        try {
            source = await root.AeroGridMapSources.googleHybrid();
            const result = await measureSamples(sampleTiles(selectedBounds, zooms(), coverage),
                source, controller.signal);
            measuring = false;
            if (key !== selectionKey()) {
                showMeasurement();
                element("measurement").textContent = "Selection changed during measurement. Measure again for the current selection.";
                return;
            }
            measurement = { ...result, key };
            showMeasurement();
        } catch (error) {
            element("measurement").textContent = controller.signal.aborted
                ? "Sample download timed out after 30 seconds. Try again."
                : `Unable to measure sample tiles: ${error.message} The provider may block cross-origin downloads, or your connection may be unavailable.`;
        } finally {
            if (source) source.close();
            root.clearTimeout(timeout);
            measuring = false;
            element("measure").disabled = !bounds || !selectedBounds;
        }
    });
    element("locate").addEventListener("click", () => locate(true));
    element("name").addEventListener("input", updateSummary);
    element("area-id").addEventListener("input", updateSummary);
    function currentSelection() {
        const selection = specification(element("name").value, bounds, zooms(), radioId(), coverage);
        selection.selectedBounds = { ...selectedBounds };
        selection.coverageMode = compactCoverage() ? "per-zoom-clamped" : "full-area-clamped";
        return selection;
    }
    function saveDownload(blob, filename) {
        const url = URL.createObjectURL(blob);
        const link = document.createElement("a");
        link.href = url;
        link.download = filename;
        document.body.appendChild(link);
        link.click();
        link.remove();
        root.setTimeout(() => URL.revokeObjectURL(url), 1000);
    }
    element("pack-cancel").addEventListener("click", () => {
        if (packController) packController.abort();
    });
    async function exportPack(synthetic) {
        if (packController) return;
        const controller = new AbortController();
        packController = controller;
        element("pack-export").disabled = true;
        element("satellite-export").disabled = true;
        element("pack-cancel").disabled = false;
        const label = synthetic ? "Synthetic" : "Google hybrid";
        let source;
        element("pack-status").textContent = synthetic ? "Generating synthetic test images..." :
            "Downloading Google hybrid images...";
        try {
            const selection = currentSelection();
            const id = element("area-id").value;
            const key = JSON.stringify([selection, id]);
            source = synthetic ? undefined : await root.AeroGridMapSources.googleHybrid();
            const bytes = await root.AeroGridMapPack.createArchive(selection, id, {
                source,
                signal: controller.signal,
                onProgress: ({ completed, total, bytes: size }) => {
                    element("pack-status").textContent =
                        `${label} tiles: ${completed}/${total}; ${(size / 1048576).toFixed(1)} MiB prepared.`;
                }
            });
            if (controller.signal.aborted || key !== JSON.stringify([currentSelection(), element("area-id").value])) {
                throw new Error("Selection changed or export cancelled.");
            }
            saveDownload(new Blob([bytes], { type: "application/zip" }),
                `${id}-${synthetic ? "synthetic" : "google-hybrid"}.zip`);
            element("pack-status").textContent =
                synthetic ? "Synthetic test ZIP downloaded. Extract at SD-card root; these images are not real terrain." :
                    "Google hybrid ZIP downloaded. Extract at SD-card root. Source terms and prototype limitations still apply.";
        } catch (error) {
            element("pack-status").textContent = `No ZIP downloaded: ${error.message}`;
        } finally {
            if (source && source.close) source.close();
            packController = undefined;
            element("pack-cancel").disabled = true;
            updateSummary();
        }
    }
    element("pack-export").addEventListener("click", () => exportPack(true));
    element("satellite-export").addEventListener("click", () => exportPack(false));
    element("export").addEventListener("click", () => {
        try {
            const selection = currentSelection();
            const blob = new Blob([JSON.stringify(selection, null, 2) + "\n"], { type: "application/json" });
            saveDownload(blob, `${selection.name.replace(/[^a-z0-9_-]+/gi, "-") || "map"}-selection.json`);
            status("Selection JSON downloaded. It contains no imagery and is not a radio-ready map pack.");
        } catch (error) {
            status(`Unable to export selection: ${error.message}`);
        }
    });
    initializeMap();
})(globalThis);
