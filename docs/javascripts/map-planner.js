// SPDX-License-Identifier: GPL-2.0-only
(function (root) {
    "use strict";

    const MAX_LATITUDE = 85.0511287798066;
    const MAX_TILES = 2000;
    const RADIO_PRESETS = Object.freeze([
        { id: "tx16s", name: "RadioMaster TX16S / TX16S MAX", width: 480, height: 272 },
        { id: "tx16s-mkii", name: "RadioMaster TX16S MKII / MKII MAX", width: 480, height: 272 },
        { id: "tx15", name: "RadioMaster TX15 / TX15 MAX", width: 480, height: 320 },
        { id: "nv14", name: "FrSky NV14 / Jumper T20 / RadioMaster GX12", width: 320, height: 480 },
        { id: "tx16s-mk3", name: "RadioMaster TX16S MK3 / MK3 MAX", width: 800, height: 480 }
    ].map(Object.freeze));

    const MONO_PRESETS = Object.freeze([
        { id: "mono-128x64", name: "Monochrome radio", width: 128, height: 64 },
        { id: "mono-212x64", name: "Monochrome radio", width: 212, height: 64 }
    ].map(Object.freeze));

    function radioFootprint(id) {
        const radio = [...RADIO_PRESETS, ...MONO_PRESETS].find(preset => preset.id === id);
        if (!radio) throw new Error("The connected radio's screen size is unknown. Coverage cannot be calculated without its dimensions.");
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
        throw new Error("Select a smaller flying area.");
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
        radioFootprint, overviewZoom, coveragePlan, tileUrl, RADIO_PRESETS, MAX_TILES };
    if (typeof document === "undefined" || !document.getElementById("ag-map-planner")) {
        return;
    }

    const element = name => document.getElementById(`ag-map-${name}`);
    const status = text => { element("status").textContent = text; };
    const radioId = () => element("radio").value;
    for (const radio of [...RADIO_PRESETS, ...MONO_PRESETS]) {
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
    let drawAreaInteraction;
    let areasSource;
    let areasLayer;
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
    let explicitAddMode = false;
    let areaEditingEnabled = !element("connect");
    let areaSelectionHandler = () => {};
    let areaRenameHandler = () => {};
    const areaTitles = new Map();
    let nameEditor;
    let areaBoundsHandler = () => {};
    let resolveMapReady;
    const mapReady = new Promise(resolve => { resolveMapReady = resolve; });
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
        message("Finding your location... If your browser asks, allow location access.");
        const waitingTimeout = root.setTimeout(() => {
            if (request !== locationRequest) return;
            locationRequest++;
            element("locate").disabled = false;
            message("The browser has not returned your location. Check this site's location permission in the address bar, then click the location icon to retry.");
        }, 12000);
        root.navigator.geolocation.getCurrentPosition(position => {
            root.clearTimeout(waitingTimeout);
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
            message("Select your flying area");
        }, error => {
            root.clearTimeout(waitingTimeout);
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
                `${estimate.tileCount.toLocaleString()} planned tiles · ` +
                estimate.levels.map(level => `Z${level.zoom}: ${level.tiles}`).join(" · ") +
                (estimate.tileCount > MAX_TILES ? ". Reduce the area or detail level (2,000-tile limit)." : ".");
            if (compactCoverage()) {
                const full = coveragePlan(selectedBounds, zooms(), radioId());
                const difference = full.tileCount - estimate.tileCount;
                element("summary").textContent +=
                    ` Storage optimization saves ${difference.toLocaleString()} tiles.`;
            }
            specification(element("name").value, bounds, zooms(), radioId(), coverage);
            element("export").disabled = failed;
        } catch (error) {
            element("summary").textContent = error.message;
        }
    }

    function syncBounds(origin = "edit") {
        try {
            setSelection(readExtent(extentInteraction.getExtent()), false, origin);
        } catch (error) {
            bounds = undefined;
            selectedBounds = undefined;
            updateSummary();
            status(error.message);
            return;
        }
    }

    function setSelection(value, updateExtent = true, origin = "planner") {
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
            extentInteraction.setActive(areaEditingEnabled);
            settingExtent = true;
            try {
                extentInteraction.setExtent(projectedExtent(value));
            } finally {
                settingExtent = false;
            }
        }
        bounds = snapped;
        updateSummary();
        status("");
        let selection;
        try {
            selection = currentSelection();
        } catch (error) {
            areaBoundsHandler({ origin, bounds: { ...selectedBounds }, selection: null, error });
            return;
        }
        areaBoundsHandler({ origin, bounds: { ...selectedBounds }, selection });
    }

    function mapFailure(message) {
        resolveMapReady(null);
        failed = true;
        element("options").disabled = true;
        element("export").disabled = true;
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
                    "Map imagery could not load. Check your connection; direct tile access may be blocked.";
            });
            const previewLayer = new ol.layer.Tile({ source });
            areasSource = new ol.source.Vector();
            areasLayer = new ol.layer.Vector({ source: areasSource });
            const controlIcon = (path) => {
                const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
                svg.setAttribute("viewBox", "0 0 24 24");
                svg.setAttribute("aria-hidden", "true");
                const shape = document.createElementNS("http://www.w3.org/2000/svg", "path");
                shape.setAttribute("d", path);
                svg.append(shape);
                return svg;
            };
            map = new ol.Map({
                target: element("canvas"),
                controls: ol.control.defaults.defaults({
                    zoomOptions: {
                        zoomInLabel: controlIcon("M12 5v14M5 12h14"),
                        zoomOutLabel: controlIcon("M5 12h14"),
                    },
                }),
                layers: [previewLayer, areasLayer],
                interactions: ol.interaction.defaults.defaults({ shiftDragZoom: false }),
                view: new ol.View({
                    center: ol.proj.fromLonLat([0, 20]), zoom: 3, maxZoom: 19,
                    enableRotation: false
                })
            });
            const updateZoom = () => {
                const zoom = map.getView().getZoom();
                element("zoom").textContent = `Zoom ${Number.isInteger(zoom) ? zoom : zoom.toFixed(1)}`;
            };
            map.getView().on("change:resolution", updateZoom);
            updateZoom();
            extentInteraction = new ol.interaction.Extent({
                condition: event => {
                    if (explicitAddMode || ol.events.condition.shiftKeyOnly(event)) return false;
                    if (extentInteraction?.handlingDownUpSequence) return true;
                    const extent = extentInteraction?.getExtent();
                    if (!extent) return false;
                    const corners = [[extent[0], extent[1]], [extent[0], extent[3]],
                        [extent[2], extent[1]], [extent[2], extent[3]]];
                    return corners.some(corner => {
                        const pixel = map.getPixelFromCoordinate(corner);
                        return Math.hypot(pixel[0] - event.pixel[0], pixel[1] - event.pixel[1]) <= 16;
                    });
                },
                boxStyle: new ol.style.Style({
                    stroke: new ol.style.Stroke({ color: "#258cc7", width: 3 }),
                    fill: new ol.style.Fill({ color: "rgba(37, 140, 199, 0.08)" })
                }),
                pointerStyle: [],
                pixelTolerance: 12
            });
            map.addInteraction(extentInteraction);
            extentInteraction.setActive(areaEditingEnabled);
            drawAreaInteraction = new ol.interaction.DragBox({
                className: "ag-map-drawing-area",
                condition: event => explicitAddMode || ol.events.condition.shiftKeyOnly(event)
            });
            drawAreaInteraction.on("boxstart", () => {
                root.AeroGridMapPlannerView.startAddingArea();
                areaBoundsHandler({ origin: "drawing-start", selection: null });
            });
            drawAreaInteraction.on("boxcancel", () => {
                root.AeroGridMapPlannerView.cancelAddingArea();
                areaBoundsHandler({ origin: "drawing-cancel", selection: null });
            });
            drawAreaInteraction.on("boxend", () => {
                try {
                    const value = readExtent(drawAreaInteraction.getGeometry().getExtent());
                    explicitAddMode = false;
                    setSelection(value, true, "new-area");
                } catch (error) {
                    status(error.message);
                    areaBoundsHandler({ origin: "new-area", selection: null, error });
                }
            });
            map.addInteraction(drawAreaInteraction);
            drawAreaInteraction.setActive(areaEditingEnabled);
            element("viewport").disabled = !areaEditingEnabled;
            map.on("pointerdrag", () => { navigationRevision++; });
            element("canvas").addEventListener("wheel", () => { navigationRevision++; }, { passive: true });
            element("canvas").addEventListener("keydown", () => { navigationRevision++; });
            element("canvas").addEventListener("click", () => { navigationRevision++; });
            extentInteraction.on("extentchanged", event => {
                if (settingExtent) return;
                if (event.extent) {
                    syncBounds("edit");
                }
                else {
                    bounds = undefined;
                    selectedBounds = undefined;
                    updateSummary();
                    areaBoundsHandler({ origin: "clear", bounds: null, selection: null });
                }
            });
            map.on("singleclick", event => {
                if (explicitAddMode) return;
                if (areaEditingEnabled) {
                    for (const [id, title] of [...areaTitles].reverse()) {
                        if (event.pixel[0] < title.left || event.pixel[0] > title.right
                            || event.pixel[1] < title.top || event.pixel[1] > title.bottom) continue;
                        nameEditor?.cancel();
                        const input = document.createElement("input");
                        input.className = "ag-map-name-editor";
                        input.dataset.selected = String(title.selected);
                        input.value = title.name;
                        input.maxLength = 80;
                        input.setAttribute("aria-label", "Area name");
                        const overlay = new ol.Overlay({
                            element: input, position: title.coordinate, positioning: "bottom-left",
                            offset: [0, -2], stopEvent: true,
                        });
                        let finished = false;
                        const finish = (save) => {
                            if (finished) return;
                            const name = input.value.trim();
                            if (save && (!name || name.length > 80)) {
                                input.setCustomValidity("Enter an area name between 1 and 80 characters.");
                                input.reportValidity();
                                return;
                            }
                            finished = true;
                            nameEditor = undefined;
                            map.removeOverlay(overlay);
                            map.render();
                            if (save) areaRenameHandler(id, name);
                            element("canvas").focus({ preventScroll: true });
                        };
                        nameEditor = { id, cancel: () => finish(false) };
                        input.addEventListener("input", () => input.setCustomValidity(""));
                        input.addEventListener("keydown", event => {
                            event.stopPropagation();
                            if (event.key === "Enter" || event.key === "Escape") {
                                event.preventDefault();
                                finish(event.key === "Enter");
                            }
                        });
                        input.addEventListener("blur", () => finish(true));
                        map.addOverlay(overlay);
                        map.render();
                        input.focus();
                        input.select();
                        return;
                    }
                }
                const areaIds = new Set();
                map.forEachFeatureAtPixel(event.pixel, candidate => {
                    const id = candidate.get("areaId");
                    if (id) areaIds.add(id);
                }, {
                    layerFilter: layer => layer === areasLayer
                });
                if (areaIds.size) areaSelectionHandler([...areaIds]);
            });
            element("options").disabled = false;
            element("zoom-range").disabled = false;
            status("");
            resolveMapReady(map);
            locate();
        } catch (error) {
            mapFailure(`Unable to initialize map: ${error.message}`);
        }
    }

    element("viewport").addEventListener("click", () => {
        if (!areaEditingEnabled) return;
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
    function renderAreas(areas, selectedId) {
        if (!map || !areasSource) return;
        const ol = root.ol;
        const worldWidth = ol.proj.get("EPSG:3857").getExtent()[2] * 2;
        const centerX = map.getView().getCenter()?.[0] || 0;
        areasSource.clear();
        areaTitles.clear();
        for (const area of areas) {
            if (area.deleted) continue;
            let extent = projectedExtent(area.selection.selectedBounds);
            const shift = Math.round((centerX - (extent[0] + extent[2]) / 2) / worldWidth) * worldWidth;
            extent = extent.map((coordinate, index) => coordinate + (index % 2 === 0 ? shift : 0));
            const feature = new ol.Feature(ol.geom.Polygon.fromExtent(extent));
            feature.set("areaId", area.id);
            feature.setStyle([new ol.style.Style({
                stroke: new ol.style.Stroke({
                    color: area.id === selectedId ? "#258cc7" : "#f3f7fa",
                    width: 3,
                }),
                fill: new ol.style.Fill({
                    color: area.id === selectedId ? "rgba(37, 140, 199, 0.08)" : "rgba(255, 255, 255, 0.12)"
                })
            }), new ol.style.Style({
                geometry: new ol.geom.Point([extent[0], extent[3]]),
                renderer: ([x, y], state) => {
                    if (nameEditor?.id === area.id) return;
                    const context = state.context;
                    const scale = state.pixelRatio;
                    const padding = 8 * scale;
                    const height = 26 * scale;
                    const availableWidth = (extent[2] - extent[0]) / state.resolution * scale + 3 * scale;
                    const left = x - 1.5 * scale;
                    context.save();
                    context.font = `600 ${14 * scale}px sans-serif`;
                    const titleWidth = context.measureText(area.selection.name).width + padding * 2;
                    const bubble = titleWidth > availableWidth;
                    const width = Math.min(titleWidth, bubble ? 240 * scale : availableWidth);
                    const bottom = y - (bubble ? 9 : 1.5) * scale;
                    areaTitles.set(area.id, {
                        name: area.selection.name, selected: area.id === selectedId,
                        coordinate: [extent[0], extent[3]],
                        left: left / scale, right: (left + width) / scale,
                        top: (bottom - height) / scale, bottom: bottom / scale,
                    });
                    let title = area.selection.name;
                    if (context.measureText(title).width > width - padding * 2) {
                        const characters = Array.from(title);
                        while (characters.length
                            && context.measureText(`${characters.join("")}\u2026`).width > width - padding * 2) {
                            characters.pop();
                        }
                        title = `${characters.join("")}\u2026`;
                    }
                    context.fillStyle = area.id === selectedId
                        ? "rgba(22, 119, 174, 0.7)" : "rgba(67, 79, 89, 0.7)";
                    context.beginPath();
                    context.roundRect(left, bottom - height, width, height,
                        bubble ? 5 * scale : [5 * scale, 5 * scale, 0, 0]);
                    if (bubble) {
                        context.moveTo(left + 7 * scale, bottom);
                        context.lineTo(left + 7 * scale, y - 1.5 * scale);
                        context.lineTo(left + 15 * scale, bottom);
                        context.closePath();
                    }
                    context.fill();
                    context.fillStyle = "#ffffff";
                    context.textAlign = "left";
                    context.textBaseline = "middle";
                    context.fillText(title, left + padding, bottom - height / 2);
                    context.restore();
                },
            })]);
            areasSource.addFeature(feature);
        }
    }
    root.AeroGridMapPlannerView = {
        ready: mapReady,
        resize() { map?.updateSize(); },
        renderAreas,
        onSelectArea(handler) { areaSelectionHandler = handler; },
        onRenameArea(handler) { areaRenameHandler = handler; },
        onBoundsChanged(handler) { areaBoundsHandler = handler; },
        startAddingArea() {
            if (!areaEditingEnabled) return;
            explicitAddMode = true;
            element("canvas").style.cursor = "crosshair";
            extentInteraction.setActive(false);
            settingExtent = true;
            try {
                extentInteraction.setExtent(undefined);
            } finally {
                settingExtent = false;
            }
        },
        cancelAddingArea() {
            explicitAddMode = false;
            element("canvas").style.cursor = "";
            settingExtent = true;
            try {
                extentInteraction.setExtent(selectedBounds ? projectedExtent(selectedBounds) : undefined);
            } finally {
                settingExtent = false;
            }
            extentInteraction.setActive(areaEditingEnabled);
            updateSummary();
        },
        selectBounds(value, radio, maximumZoom) {
            element("radio").value = radio;
            element("max-zoom").value = String(maximumZoom);
            updateRadio();
            setSelection(value, true, "load");
            if (map) {
                const extent = projectedExtent(value);
                map.getView().fit(extent, { padding: [32, 32, 32, 32], duration: 250, maxZoom: 16 });
            }
        },
        clearBounds() {
            extentInteraction.setExtent(undefined);
            bounds = undefined;
            selectedBounds = undefined;
            updateSummary();
            areaBoundsHandler({ origin: "clear", bounds: null, selection: null });
        },
        currentSelection,
        setMaximumZoom(value) {
            element("max-zoom").value = String(value);
            element("max-zoom").dispatchEvent(new Event("input", { bubbles: true }));
        },
        setAreaEditMode(enabled) {
            if (!enabled) nameEditor?.cancel();
            areaEditingEnabled = enabled;
            extentInteraction?.setActive(enabled && !explicitAddMode);
            drawAreaInteraction?.setActive(enabled);
            element("viewport").disabled = !enabled;
        },
    };
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
