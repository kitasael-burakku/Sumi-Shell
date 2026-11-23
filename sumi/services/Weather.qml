pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/xdg.js" as Xdg

/**
 * El clima (rediseño, fase 7D; spec de Calendar «Clima opcional» y de Lock
 * «WeatherSummary»). Una sola lectura compartida por quien la necesite: hoy
 * Calendar; en la fase 15, el Lock.
 *
 *   · OPT-IN. Apagado por defecto (`Settings.weatherEnabled`). Sin ciudad elegida
 *     no hay consulta de red: ni geolocalización por IP ni nada «para probar».
 *   · Fuente: Open-Meteo por HTTPS (`XMLHttpRequest`, como `Web`), con la zona
 *     horaria de la ciudad elegida: las fechas del pronóstico son las civiles de
 *     esa ciudad. La búsqueda de ciudad es su API de geocodificación, y sólo
 *     corre cuando el usuario la pide (Settings).
 *   · RECLAMACIONES (fase 6A): `claim(quien, true|false)`, con `components/Claim`.
 *     Sin reclamaciones no hay reloj; con alguna, se actualiza si el dato está
 *     vencido (`refreshMs`) y después cada `refreshMs`. Cerrar una vista no
 *     interrumpe a otra: la lectura es del servicio.
 *   · CACHÉ en `~/.cache/sumi-weather.json`: al abrir se enseña al instante lo
 *     guardado (si es de la misma ciudad y unidades) y sólo se pide si está vencido.
 *   · REVISIÓN POR PETICIÓN (patrón de la 6C, `services/Ops`): una respuesta que
 *     llega cuando ya se pidió otra (cambio de ciudad o de unidades a mitad) se
 *     descarta; `ops` guarda lo pedido y cómo acabó.
 *
 * Estados (`state`): off · unconfigured · loading (sin dato aún) · ok · stale
 * (hay dato, pero la última actualización falló o tiene más de `oldMs`) ·
 * unavailable (nunca hubo dato válido y la consulta falló). «Antiguo» nunca se
 * confunde con «sin pronóstico»: `forecast(fecha)` devuelve null para una fecha
 * pasada o fuera del rango, y la vista no inventa cifras.
 *
 * Pruebas: `testBase` (sólo `http://127.0.0.1:…`) sustituye a la API — un puerto
 * cerrado simula que no hay red sin tocar la red de la máquina.
 */
Singleton {
    id: root

    readonly property bool enabled: Settings.weatherEnabled
    readonly property var location: Settings.weatherLocation
    readonly property string units: Settings.weatherUnits
    readonly property bool configured: root.enabled && root.location && typeof root.location.lat === "number"
    /** Identidad del dato: ciudad y unidades. Un dato de otra clave no se enseña. */
    readonly property string dataKey: root.configured
        ? root.location.lat.toFixed(3) + "," + root.location.lon.toFixed(3) + "," + root.units : ""

    readonly property int refreshMs: 30 * 60 * 1000
    /** A partir de aquí el dato se marca como posiblemente desactualizado. */
    readonly property int oldMs: 3 * 60 * 60 * 1000
    readonly property int timeoutMs: 10000

    property string testBase: ""
    readonly property string forecastBase: root.testBase.length > 0 ? root.testBase : "https://api.open-meteo.com"
    readonly property string geoBase: root.testBase.length > 0 ? root.testBase : "https://geocoding-api.open-meteo.com"

    // ---- el dato ------------------------------------------------------------------

    /** { key, fetchedAt, current: { temp, code, humidity }, daily: [{ date, max, min, rain, code }] } */
    property var data: null
    property string lastError: ""
    property real lastAttempt: 0
    property bool fetching: false
    /** Consultas lanzadas (para medir que dos consumidores no duplican nada). */
    property int requests: 0
    property real now: Date.now()

    readonly property bool hasData: root.data !== null && root.data.key === root.dataKey
    readonly property real ageMs: root.hasData ? Math.max(0, root.now - root.data.fetchedAt) : -1
    readonly property string state: {
        if (!root.enabled) return "off";
        if (!root.configured) return "unconfigured";
        if (!root.hasData) return root.lastError.length > 0 && !root.fetching ? "unavailable" : "loading";
        if (root.lastError.length > 0 || root.ageMs > root.oldMs) return "stale";
        return "ok";
    }

    Ops { id: opsTable; name: "weather" }
    readonly property alias ops: opsTable

    // ---- reclamaciones ---------------------------------------------------------------

    property var claims: ({})
    readonly property int consumers: Object.keys(root.claims).length
    function claim(who, on) {
        const next = Object.assign({}, root.claims);
        if (on) next[who] = true; else delete next[who];
        root.claims = next;
        return root.consumers;
    }
    readonly property bool wanted: root.consumers > 0 && root.configured
    onWantedChanged: if (root.wanted) root.refreshIfDue()
    onDataKeyChanged: {
        root.lastError = "";
        if (root.wanted) root.refresh();   // otra ciudad o unidades: lo guardado ya no vale
    }

    Timer {
        interval: 60000
        repeat: true
        running: root.wanted
        onTriggered: { root.now = Date.now(); root.refreshIfDue(); }
    }

    function refreshIfDue() {
        root.now = Date.now();
        if (!root.wanted || root.fetching) return;
        if (!root.hasData || root.ageMs >= root.refreshMs) {
            // Tras un fallo, no reintentar en cada minuto: esperar 5 min.
            if (root.lastError.length > 0 && root.now - root.lastAttempt < 5 * 60 * 1000) return;
            root.refresh();
        }
    }

    // ---- la petición -------------------------------------------------------------

    property var xhr: null
    function refresh() {
        if (!root.configured) return 0;
        const loc = root.location;
        const key = root.dataKey;
        const rev = opsTable.request("forecast", key);
        if (root.xhr) { try { root.xhr.abort(); } catch (e) {} }
        const x = new XMLHttpRequest();
        root.xhr = x;
        root.fetching = true;
        root.requests++;
        root.lastAttempt = Date.now();
        const url = root.forecastBase + "/v1/forecast?latitude=" + loc.lat + "&longitude=" + loc.lon
            + "&current=temperature_2m,relative_humidity_2m,weather_code"
            + "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
            + "&forecast_days=10"
            + "&timezone=" + encodeURIComponent(loc.tz && loc.tz.length > 0 ? loc.tz : "auto")
            + (root.units === "fahrenheit" ? "&temperature_unit=fahrenheit" : "");
        x.onreadystatechange = function () {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            if (x !== root.xhr) return;   // abortada por una más nueva
            forecastDeadline.stop();
            root.xhr = null;
            root.fetching = false;
            let parsed = null;
            if (x.status === 200) parsed = root.parse(x.responseText, key);
            if (!opsTable.isLatest("forecast", rev) || key !== root.dataKey) {
                opsTable.resolve("forecast", rev, "error", "superseded");
                return;   // se pidió otra cosa entretanto: esta respuesta ya no vale
            }
            if (!parsed) {
                root.lastError = x.status === 0 ? "No connection" : ("Weather service error (HTTP " + x.status + ")");
                opsTable.resolve("forecast", rev, "error", root.lastError);
                return;
            }
            root.data = parsed;
            root.lastError = "";
            root.now = Date.now();
            opsTable.resolve("forecast", rev, "ok", "", key);
            cache.setText(JSON.stringify(parsed));
        };
        x.open("GET", url);
        x.send();
        forecastDeadline.restart();
        return rev;
    }

    Timer {
        id: forecastDeadline
        interval: root.timeoutMs
        onTriggered: {
            const x = root.xhr;
            if (!x) return;
            root.xhr = null;
            root.fetching = false;
            try { x.abort(); } catch (e) {}
            root.lastError = "The weather service did not answer";
            opsTable.resolve("forecast", opsTable.latest("forecast"), "error", root.lastError);
        }
    }

    function num(v) { return typeof v === "number" && isFinite(v) ? v : null; }

    /** La respuesta de Open-Meteo a nuestro formato; null si no sirve. */
    function parse(text, key) {
        let j = null;
        try { j = JSON.parse(text); } catch (e) { return null; }
        if (!j || !j.current || !j.daily || !Array.isArray(j.daily.time)) return null;
        const c = j.current;
        if (root.num(c.temperature_2m) === null) return null;
        const d = j.daily;
        const daily = [];
        for (let i = 0; i < d.time.length && i < 16; i++) {
            daily.push({ date: String(d.time[i]).substring(0, 10),
                         max: root.num(d.temperature_2m_max ? d.temperature_2m_max[i] : null),
                         min: root.num(d.temperature_2m_min ? d.temperature_2m_min[i] : null),
                         rain: root.num(d.precipitation_probability_max ? d.precipitation_probability_max[i] : null),
                         code: root.num(d.weather_code ? d.weather_code[i] : null) });
        }
        return { key: key, fetchedAt: Date.now(),
                 current: { temp: c.temperature_2m, code: root.num(c.weather_code),
                            humidity: root.num(c.relative_humidity_2m) },
                 daily: daily };
    }

    // ---- caché ------------------------------------------------------------------------

    FileView {
        id: cache
        path: Xdg.base(Quickshell.env("XDG_CACHE_HOME"), Quickshell.env("HOME") + "/.cache") + "/sumi-weather.json"
        blockLoading: true
        printErrors: false
        onLoaded: {
            try {
                const d = JSON.parse(cache.text());
                if (d && typeof d.key === "string" && typeof d.fetchedAt === "number" && d.current && Array.isArray(d.daily))
                    root.data = d;
            } catch (e) {}
        }
    }

    // ---- lo que leen las vistas -------------------------------------------------------

    /** El pronóstico de un día (AAAA-MM-DD, fecha civil de la ciudad), o null si no lo hay. */
    function forecast(date) {
        if (!root.hasData) return null;
        const list = root.data.daily;
        for (let i = 0; i < list.length; i++)
            if (list[i].date === date) return list[i].max === null && list[i].min === null ? null : list[i];
        return null;
    }

    function temp(v) { return v === null || v === undefined ? "—" : Math.round(v) + "°"; }
    readonly property string unitLabel: root.units === "fahrenheit" ? "°F" : "°C"

    /** «Updated 12 min ago» / «2 h ago»: la antigüedad dicha en claro. */
    function ageText() {
        if (!root.hasData) return "";
        const m = Math.round(root.ageMs / 60000);
        if (m < 1) return "just now";
        if (m < 60) return m + " min ago";
        const h = Math.round(m / 60);
        if (h < 48) return h + " h ago";
        return Math.round(h / 24) + " d ago";
    }

    /** Código WMO → texto y glifo (`components/Icon`). */
    function condition(code, night) {
        const c = code === null || code === undefined ? -1 : code;
        if (c === 0) return { text: "Clear", icon: night ? "weather-night" : "weather-sunny" };
        if (c === 1 || c === 2) return { text: c === 1 ? "Mainly clear" : "Partly cloudy",
                                         icon: night ? "weather-night-partly" : "weather-partly" };
        if (c === 3) return { text: "Overcast", icon: "weather-cloudy" };
        if (c === 45 || c === 48) return { text: "Fog", icon: "weather-fog" };
        if (c >= 51 && c <= 57) return { text: "Drizzle", icon: "weather-rain" };
        if (c >= 61 && c <= 67) return { text: c >= 65 ? "Heavy rain" : "Rain", icon: c >= 65 ? "weather-pouring" : "weather-rain" };
        if (c >= 71 && c <= 77) return { text: "Snow", icon: "weather-snow" };
        if (c >= 80 && c <= 82) return { text: "Showers", icon: "weather-pouring" };
        if (c === 85 || c === 86) return { text: "Snow showers", icon: "weather-sleet" };
        if (c >= 95) return { text: "Thunderstorm", icon: "weather-storm" };
        return { text: "Unknown", icon: "weather-cloudy" };
    }

    // ---- búsqueda de ciudad (sólo cuando la pide Settings) -------------------------------

    property string searchState: "idle"   // idle · searching · ok · empty · error
    property var results: []
    property string searchError: ""
    property var searchXhr: null
    function search(query) {
        const q = String(query || "").trim();
        if (q.length < 2) { root.results = []; root.searchState = "idle"; return false; }
        if (root.searchXhr) { try { root.searchXhr.abort(); } catch (e) {} }
        const x = new XMLHttpRequest();
        root.searchXhr = x;
        root.searchState = "searching";
        root.searchError = "";
        root.requests++;
        x.onreadystatechange = function () {
            if (x.readyState !== XMLHttpRequest.DONE || x !== root.searchXhr) return;
            searchDeadline.stop();
            root.searchXhr = null;
            if (x.status !== 200) {
                root.results = [];
                root.searchState = "error";
                root.searchError = x.status === 0 ? "No connection" : "Search failed (HTTP " + x.status + ")";
                return;
            }
            const out = [];
            try {
                const j = JSON.parse(x.responseText);
                const list = j && Array.isArray(j.results) ? j.results : [];
                for (let i = 0; i < list.length && i < 6; i++) {
                    const r = list[i];
                    if (typeof r.latitude !== "number" || typeof r.longitude !== "number") continue;
                    out.push({ name: String(r.name || "").substring(0, 128), admin: String(r.admin1 || "").substring(0, 128),
                               country: String(r.country || "").substring(0, 128),
                               lat: r.latitude, lon: r.longitude, tz: String(r.timezone || "").substring(0, 64) });
                }
            } catch (e) {}
            root.results = out;
            root.searchState = out.length > 0 ? "ok" : "empty";
        };
        x.open("GET", root.geoBase + "/v1/search?count=6&language=en&format=json&name=" + encodeURIComponent(q));
        x.send();
        searchDeadline.restart();
        return true;
    }
    Timer {
        id: searchDeadline
        interval: root.timeoutMs
        onTriggered: {
            const x = root.searchXhr;
            if (!x) return;
            root.searchXhr = null;
            try { x.abort(); } catch (e) {}
            root.results = [];
            root.searchState = "error";
            root.searchError = "The search did not answer";
        }
    }
    function clearSearch() {
        if (root.searchXhr) { try { root.searchXhr.abort(); } catch (e) {} }
        root.searchXhr = null;
        searchDeadline.stop();
        root.results = [];
        root.searchState = "idle";
        root.searchError = "";
    }
    /** Elige un resultado: se guarda en Settings (el ConfigStore valida). */
    function choose(r) {
        if (!r) return false;
        Settings.weatherLocation = { name: r.name, admin: r.admin, country: r.country, lat: r.lat, lon: r.lon, tz: r.tz };
        root.clearSearch();
        return true;
    }

    function placeName() {
        const l = root.location;
        if (!l || !l.name) return "";
        return l.name + (l.country ? ", " + l.country : "");
    }

    function summary() {
        return { state: root.state, enabled: root.enabled, configured: root.configured, place: root.placeName(),
                 units: root.units, consumers: Object.keys(root.claims), wanted: root.wanted, fetching: root.fetching,
                 requests: root.requests, hasData: root.hasData, ageMin: root.hasData ? Math.round(root.ageMs / 60000) : null,
                 lastError: root.lastError, current: root.hasData ? root.data.current : null,
                 days: root.hasData ? root.data.daily.length : 0, testBase: root.testBase,
                 search: { state: root.searchState, results: root.results.length, error: root.searchError },
                 ops: root.ops.snapshot() };
    }
}
