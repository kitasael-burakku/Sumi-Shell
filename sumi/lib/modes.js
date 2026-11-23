// El coordinador conserva intención, snapshot y resultado observado por efecto.
// Los adaptadores son asíncronos; guardar precede siempre a cualquier escritura.
function same(a, b) {
    if (a === b) return true;
    if (!a || !b || typeof a !== "object" || typeof b !== "object") return false;
    var ak = Object.keys(a).sort(), bk = Object.keys(b).sort();
    return ak.length === bk.length && ak.every(function (k, i) { return k === bk[i] && same(a[k], b[k]); });
}
function copy(a) { return JSON.parse(JSON.stringify(a)); }
function targets(mode) {
    if (mode === 'focus') return {dnd: true, motion: 'reduced', cursors: false};
    if (mode === 'gaming') return {dnd: true, motion: 'off', blur: false, animations: false,
        glass: {enabled: 0, blur: 0}, cursors: false, power: 'performance', video: true, idle: true};
    if (mode === 'cinema') return {dnd: true, cursors: false, video: true, idle: true};
    return {};
}
function Engine(io, initial) {
    this.io = io;
    this.data = initial || {version: 1, mode: 'normal', state: 'applied', effects: {}, checkedAt: 0};
    this.busy = false;
}
Engine.prototype.publish = function () { this.io.publish(copy(this.data), this.busy); };
Engine.prototype.save = function (next) {
    var self = this;
    // FileView omite setText si repite su caché, incluso después de un fallo.
    // La revisión hace que cada intento requiera una escritura y su confirmación.
    this.data.revision = (this.data.revision || 0) + 1;
    this.io.save(copy(this.data), function (ok) {
        if (!ok) { self.data.progress = null; self.data.state = 'error'; self.data.reason = 'Could not save the mode snapshot';
            self.busy = false; self.publish(); return; }
        self.publish(); next();
    });
};
Engine.prototype.finish = function () {
    var self = this, rows = Object.keys(this.data.effects).map(function (k) { return self.data.effects[k]; });
    var failed = rows.some(function (r) { return r.status === 'error' || r.status === 'unknown'; });
    var available = rows.some(function (r) { return r.status !== 'unavailable'; });
    this.data.state = failed ? 'partial' : rows.length && !available ? 'unavailable' : 'applied';
    this.data.checkedAt = Date.now();
    this.data.progress = null;
    if (this.data.mode === 'normal' && !failed) this.data.effects = {};
    this.save(function () { self.busy = false; self.publish(); });
};
Engine.prototype.run = function (mode, checkOnly, restarting) {
    if (this.busy || ['normal','focus','gaming','cinema'].indexOf(mode) < 0) return false;
    var self = this, wanted = targets(mode), keys = Object.keys(this.data.effects);
    Object.keys(wanted).forEach(function (k) { if (keys.indexOf(k) < 0) keys.push(k); });
    this.data.progress = {mode: mode, stage: 'read', done: 0, total: keys.length};
    this.busy = true; this.data.state = checkOnly ? 'checking' : 'applying'; this.data.reason = '';
    // Una lectura de toda la unión precede al snapshot y a todas las escrituras.
    var observed = {}, index = 0, oldMode = this.data.mode;
    this.publish();
    function readNext() {
        self.data.progress = {mode: mode, stage: 'read', done: index, total: keys.length}; self.publish();
        if (index === keys.length) { prepare(); return; }
        var key = keys[index++];
        self.io.read(key, function (r) { observed[key] = r; readNext(); });
    }
    function prepare() {
        keys.forEach(function (key) {
            var got = observed[key], row = self.data.effects[key];
            if (!row) row = self.data.effects[key] = {owned: false, manual: false};
            if (!got.ok) {
                row.status = got.unavailable && !row.owned ? 'unavailable' : 'unknown';
                row.reason = got.reason || 'Could not read this effect'; return;
            }
            row.observed = got.value;
            if (Object.prototype.hasOwnProperty.call(wanted, key) && got.allowed && got.allowed.indexOf(wanted[key]) < 0) {
                row.status = row.owned ? 'error' : 'unavailable';
                row.reason = 'The requested capability is unavailable'; observed[key] = {ok: false}; return;
            }
            // En un reinicio sólo estas dos reclamaciones en memoria se recrean.
            var ephemeral = restarting && (key === 'idle' || key === 'motion') && row.owned;
            if (ephemeral && key === 'motion' && row.last && got.value.preference !== row.last.preference)
                ephemeral = false;
            if ((row.owned || row.last !== undefined) && key !== "idle" && !ephemeral && !same(got.value, row.last)) {
                // Una escritura que quedó en vuelo puede haber llegado antes de caer.
                if (row.pending !== undefined && same(got.value, row.pending)) row.last = got.value;
                else if (row.pending === undefined || !same(got.value, row.before)) {
                    if ((key === 'glass' || key === 'video') && row.last && typeof got.value === 'object') {
                        // Cada salida de vídeo y cada opción del plugin conserva su edición propia.
                        row.manualParts = row.manualParts || {};
                        Object.keys(got.value).forEach(function (part) {
                            if (!same(got.value[part], row.last[part])) row.manualParts[part] = got.value[part];
                        });
                        Object.keys(row.before || {}).forEach(function (part) {
                            if (!Object.prototype.hasOwnProperty.call(got.value, part)) delete row.before[part];
                        });
                    } else { row.manual = true; row.owned = false; }
                }
            }
            if (row.manual) { row.status = 'modified'; row.reason = 'Changed manually'; return; }
            var has = Object.prototype.hasOwnProperty.call(wanted, key);
            if (has && row.before === undefined) row.before = copy(got.value);
            row.target = has ? self.io.desired(key, wanted[key], got.value) : row.before;
            if (row.manualParts) {
                row.target = copy(row.target);
                Object.keys(row.manualParts).forEach(function (part) {
                    if (Object.prototype.hasOwnProperty.call(got.value, part)) row.target[part] = got.value[part];
                });
            }
            row.status = 'ready'; row.reason = '';
            row.recreate = ephemeral;
        });
        self.data.mode = mode;
        self.save(function () { index = 0; applyNext(); });
    }
    function applyNext() {
        self.data.progress = {mode: mode, stage: 'apply', done: index, total: keys.length}; self.publish();
        if (index === keys.length) { self.finish(); return; }
        var key = keys[index++], row = self.data.effects[key], got = observed[key];
        if (!got.ok || row.manual) { applyNext(); return; }
        var has = Object.prototype.hasOwnProperty.call(wanted, key);
        if (!has && !row.owned) { delete self.data.effects[key]; applyNext(); return; }
        if (checkOnly && !row.recreate) {
            row.status = same(got.value, row.target) ? 'applied' : 'error';
            row.reason = row.status === 'error' ? 'The requested effect is not applied' : '';
            applyNext(); return;
        }
        if (same(got.value, row.target)) {
            row.status = row.manualParts ? 'modified' : 'applied'; row.last = copy(got.value); delete row.pending;
            if (!has) delete self.data.effects[key];
            applyNext(); return;
        }
        // Última lectura justo antes de escribir: no pisar una edición durante otra espera.
        self.io.read(key, function (fresh) {
            if (!fresh.ok) { row.status = 'unknown'; row.reason = fresh.reason; applyNext(); return; }
            if (!same(fresh.value, got.value)) {
                row.observed = fresh.value; row.manual = true; row.owned = false;
                row.status = 'modified'; row.reason = 'Changed manually'; applyNext(); return;
            }
            row.pending = copy(row.target); row.owned = true;
            self.save(function () {
                self.io.write(key, row.target, function (written) {
                    self.io.read(key, function (after) {
                        row.observed = after.ok ? after.value : null;
                        if (after.ok && same(after.value, row.target)) {
                            row.last = copy(after.value); delete row.pending;
                            row.status = row.manualParts ? 'modified' : 'applied'; row.reason = row.manualParts ? 'Changed manually' : '';
                            if (!has) delete self.data.effects[key];
                        } else {
                            row.status = after.ok ? 'error' : 'unknown';
                            row.reason = written.reason || after.reason || 'The requested effect was not applied';
                            // Falló sin cambiar el dato: sigue siendo nuestro intento, no una edición manual.
                            if (after.ok && same(after.value, got.value)) row.last = copy(got.value);
                        }
                        self.save(applyNext);
                    });
                });
            });
        });
    }
    readNext(); return true;
};
