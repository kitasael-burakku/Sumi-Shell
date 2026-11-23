import QtQuick
import Quickshell
import Quickshell.Io
import "../services"
import "../theme"

/**
 * IPC surface (docs/IPC.md). Verbs are explicit and idempotent where a script
 * could repeat them; `toggle` exists for keybinds. Every name is checked
 * against the surface registry and every monitor argument goes through the
 * Hypr fallback chain, so an early or sloppy call fails loudly (false) instead
 * of silently doing nothing.
 *
 *   qs -c sumi ipc call sumi toggle dashboard ""
 */
Scope {
    id: root
    property var f8cModeOutcome: null

    /**
     * Portabilidad F6b (2026-10-12): la versión y la del contrato público salen de UNA fuente, `version.json` en la raíz
     * del árbol (la leen también capabilities.py y, más adelante, el instalador y el paquete). Sin el archivo o ilegible:
     * "unknown" y apiVersion 0, para que un cliente vea una instalación rota en vez de suponer un contrato.
     */
    readonly property var versionInfo: {
        try {
            const d = JSON.parse(versionFile.text());
            if (typeof d.version === "string" && Number.isInteger(d.apiVersion)) return d;
        } catch (e) {}
        return { version: "unknown", apiVersion: 0 };
    }
    readonly property string version: root.versionInfo.version
    readonly property int apiVersion: root.versionInfo.apiVersion
    /**
     * Portabilidad F6f (2026-10-14): la identidad de construcción, distinta de la versión pública. `build.json` lo escribe el
     * instalador (y el paquete) a partir del CONTENIDO del árbol distribuido: dos revisiones con la misma versión tienen
     * identidades distintas. Se lee una vez al cargar, como version.json: la instancia dice lo que CARGÓ, no lo que hay en
     * disco tras un intercambio. Sin el archivo (un árbol de desarrollo) → "".
     */
    readonly property string build: {
        try {
            const d = JSON.parse(buildFile.text());
            if (typeof d.buildId === "string") return d.buildId;
        } catch (e) {}
        return "";
    }

    FileView {
        id: versionFile
        path: Quickshell.shellPath("version.json")
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }

    FileView {
        id: buildFile
        path: Quickshell.shellPath("build.json")
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }

    // ── 15D: el LockData de prueba de `lockDataTest` (ver allí) ──────────────
    property var lockDataProbe: null
    Component { id: lockDataComponent; LockData {} }
    Timer { id: lockDataLease; interval: 10000; onTriggered: root.dropLockData() }
    function dropLockData() {
        lockDataLease.stop();
        if (root.lockDataProbe) { root.lockDataProbe.active = false; root.lockDataProbe.destroy(); root.lockDataProbe = null; }
    }
    /** Nunca con la sesión bloqueada: el Lock real tendrá el suyo (15G-2). */
    Connections { target: Lock; function onEngagedChanged() { if (Lock.engaged) root.dropLockData(); } }

    FileView {
        id: procStatus
        path: "/proc/self/status"
        blockLoading: true
        // Fase 9.a: sin esto, `reload()` es asincrono y `text()` sirve el
        // contenido ANTERIOR, asi que la primera llamada a status() tras
        // arrancar devolvia el RSS de la construccion del FileView: medido
        // 198844 kB cuando /proc decia 394748 (50,4 % por debajo).
        // `blockAllReads` hace sincrono tambien el reload.
        blockAllReads: true
        printErrors: false
    }

    IpcHandler {
        target: "sumi"

        function open(name: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc) { console.warn("ipc open: no screen for", mon); return false; }
            if (!sc.hasSurface(name)) { console.warn("ipc open: unknown surface", name); return false; }
            return sc.openSurface(name);
        }

        function close(name: string): bool {
            let any = false;
            const list = Screens.list;
            for (let i = 0; i < list.length; i++) {
                const sc = list[i];
                if (sc && sc.open.length > 0 && (name.length === 0 || Screens.familyOf(sc.open) === Screens.familyOf(name))) {
                    sc.closeSurface();
                    any = true;
                }
            }
            // Settings UI (2026-11-07): la ventana flotante responde a los mismos nombres (y a "")
            if (SettingsUi.open && (name.length === 0 || Screens.isSettings(name)) && SettingsUi.close(false))
                any = true;
            // Login screen (2026-11-23): con pkexec esperando la contraseña no se cierra (queda pedido)
            if (LoginUi.open && (name.length === 0 || Screens.isLogin(name)) && LoginUi.close(false))
                any = true;
            return any;
        }

        function toggle(name: string, mon: string): bool {
            return Screens.toggleSurfaceOn(name, mon, "ipc");
        }

        /**
         * Volver desde la ficha abierta, por el mismo camino que Esc: la
         * superficie limpia lo suyo y la pila del host decide a donde
         * (QS-FUNC-004). `false` si lo abierto no es una ficha con vuelta.
         */
        function back(mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc) { console.warn("ipc back: no screen for", mon); return false; }
            return sc.backSurface();
        }

        /**
         * API PÚBLICA (F6b, `API.md`): la versión de la shell y la del contrato público, para que un cliente compruebe
         * la compatibilidad antes de usar otros verbos. Sólo lectura.
         */
        function api(): string {
            return JSON.stringify({ apiVersion: root.apiVersion, version: root.version, build: root.build });
        }

        function status(): string {
            const list = Screens.list;
            const screens = [];
            let names = [];
            for (let i = 0; i < list.length; i++) {
                const sc = list[i];
                if (!sc) continue;
                names = sc.surfaceNames();
                screens.push({ name: sc.name, open: sc.open, hold: sc.holdReason,
                               hidden: sc.hidden, fullscreen: sc.fullscreen, scale: sc.s,
                               menuOpen: sc.menuOpen, island: sc.islandSize(),
                               presentation: sc.barMode ? "bar" : (sc.dockMode ? "dock" : "island"),
                               fsReveal: sc.fsReveal, concealed: sc.concealed,
                               // Que mira cada ficha EN ESTA pantalla (2026-09-22).
                               // Antes vivia en los servicios y era una sola para
                               // todo el shell: `network.detail`, `bluetooth.detail`,
                               // `units.detail`. Aqui es por pantalla, que es lo que
                               // de verdad es.
                               sel: sc.surfaceSelAll(),
                               nav: sc.navStack() });
            }
            procStatus.reload();
            const m = /VmRSS:\s+(\d+)/.exec(procStatus.text());
            return JSON.stringify({
                version: root.version,
                apiVersion: root.apiVersion,
                pid: Quickshell.processId,
                rssKb: m ? parseInt(m[1], 10) : -1,
                focused: Hypr.focusedName,
                palette: { source: Colors.source, path: Colors.activePath, primary: String(Colors.primary), surface: String(Colors.surface) },
                screens: screens,
                // Settings UI (2026-11-07): sus tres nombres ya no son del island, pero se siguen abriendo igual
                // etapa B del Dashboard (2026-11-09): `tasks` es la ventana flotante, también un nombre de `open`;
                // `login` (2026-11-23), la ventana Login screen
                surfaces: names.concat(["settings", "settingsTheme", "settingsSystem", "tasks", "login"].filter(n => names.indexOf(n) < 0)),
                settingsUi: { open: SettingsUi.open, screen: SettingsUi.screen },
                session: { keepAwake: Session.keepAwake, keepAwakeEffective: Session.keepAwakeEffective,
                           keepAwakeError: Session.keepAwakeError, powerBackend: Session.powerBackend,
                           modeInhibited: Session.modeInhibited, resumeCount: Session.resumeCount,
                           // QS-FUNC-002: el vigilante de PrepareForSleep y su presupuesto.
                           sleepWatcher: Session.watchingSleep, sleepRestarts: Session.sleepRestarts,
                           // QS-FUNC-018: ¿hay alguien delante? (`forced` = gancho de prueba)
                           idle: Session.idle, idleForced: Session.forceIdle, idleTimeoutSec: Session.idleTimeoutSec },
                audio: { volume: Audio.volume, muted: Audio.muted, sink: Audio.sinkName },
                // No art url here: a player may publish it as a multi-hundred-KB data: URI.
                media: { has: Media.has, playing: Media.playing, source: Media.sourceName,
                         title: Media.title, artist: Media.artist,
                         position: Math.round(Media.positionSec), length: Math.round(Media.lengthSec),
                         live: Media.live, players: Media.players.length, pickable: Media.pickable.length,
                         // Quien está pidiendo la posición: MPRIS no la empuja y sin
                         // suscriptor el tiempo se congela (2026-09-16).
                         subscribers: Media.subscribers },
                // Fase 9.b: los tres avisos del island, para poder comprobarlos
                // sin depender de mirar la pantalla.
                avisos: {
                    // ADR-29: del servidor propio (count = no leidas). Las cuatro claves
                    // se conservan; desde la Fase 4 no hay segunda fuente que las llene.
                    notifications: { own: Notifs.enabled, alive: Notifs.enabled,
                                     count: Notifs.enabled ? NotifHistory.unread : 0,
                                     dnd: Notifs.enabled && NotifHistory.dnd },
                    privacy: { mic: Privacy.micActive, camera: Privacy.cameraActive, screen: Privacy.screenActive,
                               micStreams: Privacy.micStreams, cameraStreams: Privacy.cameraStreams,
                               screenStreams: Privacy.screenStreams,
                               screencopy: Privacy.screencopyActive, screencopyClients: Privacy.screencopyClients,
                               capturing: Privacy.capturing() },
                    updates: { count: Updates.count, state: Updates.state, failed: Updates.failed, stale: Updates.stale }
                },
                tray: { count: Tray.count, needsAttention: Tray.needsAttention, items: Tray.summary() },
                // Fase 9.d: la puerta de muestreo de los sensores. Con la
                // superficie cerrada tiene que quedarse en 0 y no correr nada.
                sysmon: { watchers: Sysmon.watchers, active: Sysmon.active, level: Sysmon.level,
                          cpuPct: Math.round(Sysmon.cpuPct), cpuTempC: Math.round(Sysmon.cpuTempC),
                          memPct: Math.round(Sysmon.memPct), diskPct: Math.round(Sysmon.diskPct),
                          diskAvailGb: Math.round(Sysmon.diskAvailB / 1073741824),
                          gpuPct: Math.round(Sysmon.gpuPct), gpuTempC: Math.round(Sysmon.gpuTempC),
                          gpuOk: Sysmon.gpuOk, gpuVramUsedGb: Math.round(Sysmon.gpuVramUsedGb * 10) / 10,
                          gpuVramTotalGb: Math.round(Sysmon.gpuVramTotalGb * 10) / 10,
                          gpuPowerW: Math.round(Sysmon.gpuPowerW), gpuPowerCapW: Math.round(Sysmon.gpuPowerCapW),
                          gpuFan: Sysmon.gpuFan, gpuName: Sysmon.gpuName,
                          historyCount: Sysmon.history.length },
                // Antes `power:`, y la clave `power: Power.summary()` de 9.h, mas
                // abajo, la pisaba: el perfil no salia en status() desde 9.h.
                powerProfile: { current: PowerProfile.current, available: PowerProfile.available,
                                present: PowerProfile.present, degradation: PowerProfile.degradation,
                                holds: PowerProfile.holds },
                // QS-FUNC-014: baterias de perifericos (UPower.devices), sin repetir las de Bt.
                peripherals: Battery.peripherals,
                // Parada tecnica: `commands` es 0 hasta que el launcher se abre
                // por primera vez (el escaneo de PATH es perezoso, ADR-9).
                launcher: { apps: Apps.count, commands: Apps.commandCount,
                            terminal: Apps.terminal },
                mixer: Mixer.summary(),
                // Fase 9.f.1: los dos indicadores nuevos. `ready` y `settled`
                // van a proposito -- distinguen "aun no se sabe" (los 55 ms
                // medidos hasta que se pueblan los modelos) de "no hay
                // hardware", que es la distincion que el script de bluetooth
                // del rice tuvo que arreglar a mano.
                network: Net.summary(),
                speedtest: SpeedTest.summary(),
                bluetooth: Bt.summary(),
                clipboard: Clip.summary(),
                emoji: Emoji.summary(),   // selector de emojis (2026-11-17): pestañas cargadas, uso, último pegado
                power: Power.summary(),
                polkit: Polkit.summary(),   // QS-FUNC-017
                notifs: Notifs.summary(),   // ADR-29: el servidor propio (apagado hasta la Fase 3)
                web: Web.summary(),
                wallpaper: { current: Wallpaper.current, outputs: Wallpaper.outputs, count: Wallpaper.count,
                             busy: Wallpaper.busy, queued: Wallpaper.queuedPath.length > 0,
                             bag: Wallpaper.bag.length, error: Wallpaper.lastError },
                settings: { autoHide: Settings.autoHide, reserveSpace: Settings.reserveSpace,
                            uiScale: Settings.uiScale, reduceMotion: Settings.reduceMotion,
                            minimizerThumbs: Settings.minimizerThumbs,
                            notificationServer: Settings.notificationServer,
                            polkitAgent: Settings.polkitAgent, motionMode: Settings.motionMode,
                            stateDir: Settings.stateDir, store: Settings.summary() },
                // docs/lock/SERVICIOS.md §4: fase, secure, since, motivo, fallos, calma y pantalla con foco.
                // Nada del texto tecleado (I-8).
                lock: Lock.summary()
            });
        }

        /**
         * Pedir el bloqueo como el botón Lock: por logind o directo según `shell.lock.entry` y quién atiende la señal
         * (F5d, services/LockEntry). En la máquina del autor, logind → hypridle → el helper de la shell.
         */
        function lock(): void { Session.lock(); }

        /** F5d, sólo lectura: el ajuste, el camino efectivo, quién atiende `lock-session` y la última petición. */
        function lockEntry(): string { return JSON.stringify(LockEntry.summary()); }

        /** F5e (HC-05), sólo lectura: el fondo quieto de la vista previa del Lock y de dónde sale. */
        function lockStill(): string {
            const declared = Providers.pathOf("wallpaper", "lockStill");
            return JSON.stringify({ path: Wallpaper.lockStillPath, from: declared ? "provider" : (Wallpaper.lockStillPath ? "state" : "none"),
                                    current: Wallpaper.current });
        }

        /** F5e, sólo lectura: la pila PAM (ajuste, servicio, dónde, si falta, pam_faillock), candidatas y la última prueba. */
        function lockPam(): string { return JSON.stringify(LockPam.summary()); }

        /**
         * F5e, SÓLO BANCO: probar `service` como lo hace Settings («Test and use»: si autentica, se guarda). Misma guarda que
         * `logoutTest` (SUMI_TEST_HYPR_SIG): en la sesión real se niega, para que nunca viaje una contraseña por argv;
         * el banco usa pilas de prueba (SUMI_PAM_DIRS) y una contraseña de mentira.
         */
        function lockPamTest(service: string, password: string): bool {
            const want = Quickshell.env("SUMI_TEST_HYPR_SIG") || "";
            if (!want.length || want !== (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "")) {
                console.warn("lockPamTest: only inside the nested test bench");
                return false;
            }
            LockPam.choose(service);
            return LockPam.test(password);
        }

        /**
         * LOCK (docs/lock/SERVICIOS.md §4). `lockNow` bloquea YA, sin pasar por
         * logind: lo usa `lock.sh` (L5). `reason` ∈ session · instant; cualquier
         * otro valor se trata como `session`. Idempotente.
         *
         * No existe, y no existirá, un verbo `unlock` (I-3): sólo
         * `PamResult.Success`, dentro de `LockAuth`, suelta el bloqueo.
         */
        function lockNow(reason: string): bool { return Lock.request(reason); }

        function lockStatus(): string { return JSON.stringify(Lock.summary()); }

        /**
         * 15D (fase 15): un `LockData` DE PRUEBA en el shell real, sin bloquear nada, para probar las
         * reclamaciones y los datos del panel antes de la 15G-2, y para la preview en `LOCK_PREVIEW_DATA=live`
         * (que así no levanta sus propios servicios: ni un segundo servidor de notificaciones ni otra
         * escritura de la caché del clima). Concesión de 10 s: cada `lockDataState` la renueva; si quien la
         * pidió muere, se suelta sola. `lockDataTest false` la suelta ya. Con la sesión bloqueada se niega.
         */
        function lockDataTest(on: bool): bool {
            if (!on) { root.dropLockData(); return true; }
            if (Lock.engaged) return false;
            if (!root.lockDataProbe) root.lockDataProbe = lockDataComponent.createObject(root, { who: "ipc-test", active: true });
            lockDataLease.restart();
            return root.lockDataProbe !== null;
        }
        /** El contrato completo (lo que vería el panel) de la instancia de prueba; renueva la concesión. */
        function lockDataState(): string {
            const d = root.lockDataProbe;
            if (!d) return JSON.stringify({ active: false });
            lockDataLease.restart();
            return JSON.stringify({ summary: d.summary(), fetch: d.fetch, weather: d.weather, metrics: d.metrics,
                                    notifs: d.notifs, music: d.music, privacy: d.privacy,
                                    avatarSource: d.avatarSource, fetchImageSource: d.fetchImageSource });
        }

        /** Idempotent, for scripts. Returns the resulting state. */
        function keepAwake(on: bool): bool { return Session.setKeepAwake(on); }

        /** For a keybind. Returns the resulting state. */
        function keepAwakeToggle(): bool { return Session.toggleKeepAwake(); }

        /**
         * Apply a wallpaper through the wallpaper provider (F4b: the author's apply-wallpaper.sh as `script`,
         * or the shell's own). mon "" = every output.
         */
        function wallSet(path: string, mon: string): bool {
            // Cheap rejections up front so an obvious mistake comes back as
            // false instead of as a script exit code nobody reads. Whether the
            // file exists is apply-wallpaper.sh's answer; it lands in
            // status().wallpaper.error.
            if (path.length === 0 || path.charAt(0) !== "/") {
                console.warn("ipc wallSet: needs an absolute path, got", JSON.stringify(path));
                return false;
            }
            if (!/\.(jpg|jpeg|png|webp|gif|mp4|mkv|mov|webm)$/i.test(path)) {
                console.warn("ipc wallSet: unsupported extension:", path);
                return false;
            }
            return Wallpaper.apply(path, mon);
        }

        /** Next one out of the shuffled bag. kind: all | images | videos. */
        function wallRandom(kind: string): bool { return Wallpaper.random(kind); }

        function wallCurrent(): string { return Wallpaper.current; }
        /** 9D-1, sólo lectura: Recent y Favorites (`WallpaperMeta`), y si la referencia del arranque ya se tomó. */
        function wallMeta(): string { return JSON.stringify(WallpaperMeta.summary()); }
        /**
         * 9D-1, pruebas: como si se hubiera OBSERVADO un cambio de fondo a `path` (el camino de
         * `Wallpaper.current`). Sólo escribe los metadatos: no aplica ningún fondo ni corre matugen.
         */
        function wallMetaNote(path: string): bool {
            if (path.length === 0 || path.charAt(0) !== "/") return false;
            WallpaperMeta.noteApplied(path);
            return true;
        }

        /** What one output shows: its own pick, or the wallpaper of every screen. */
        function wallCurrentOn(mon: string): string { return Wallpaper.currentFor(mon); }

        /**
         * 10A, sólo lectura: la biblioteca con tipo (all · images · videos), conjunto (library ·
         * recent · favorites) y texto — la MISMA consulta que la tira. Cuenta, los 20 primeros
         * nombres, el aplicado y si está entre los resultados.
         */
        function wallLibrary(kind: string, set: string, query: string): string {
            const l = Wallpaper.query(kind, set, query);
            return JSON.stringify({ count: l.length, total: Wallpaper.count,
                                    names: l.slice(0, 20).map(e => e.name),
                                    applied: Wallpaper.baseName(Wallpaper.current),
                                    appliedShown: Wallpaper.indexOfPath(l, Wallpaper.current) >= 0 });
        }
        /** 10A, sólo lectura: Sources con su estado, la carpeta de descargas y los nombres repetidos. */
        function wallSources(): string {
            return JSON.stringify({ configured: Settings.wallpaperSources, info: Wallpaper.sourceInfo,
                                    downloadDir: Settings.wallpaperDownloadDir,
                                    downloadDirState: Wallpaper.downloadDirState,
                                    collisions: Wallpaper.collisions, note: Wallpaper.sourceNote,
                                    listFile: Wallpaper.sourcesListPath,
                                    // W4: miniaturas que faltan y escaneos de vigilancia que quedan
                                    thumbsMissing: Wallpaper.entries.filter(e => !e.hasThumb).map(e => e.name),
                                    thumbPollLeft: Wallpaper.thumbPollLeft });
        }
        /** 10A: añadir una carpeta a Sources por el MISMO camino que Settings (validación incluida). */
        function wallSourceAdd(path: string): bool { return Wallpaper.addSource(path); }
        /** 10A: quitar una carpeta de Sources (no toca el disco). */
        function wallSourceRemove(path: string): bool { return Wallpaper.removeSource(path); }
        /** 10A: la carpeta de descargas (tiene que ser de Sources y escribible). */
        function wallDownloadDir(path: string): bool { return Wallpaper.setDownloadDir(path); }
        /**
         * 10B: Restore previous — el fondo anterior de Recent con su contexto de tema, por el mismo
         * apply. APLICA DE VERDAD salvo con `wallTestRoot` puesto. `true` = aceptado; el resultado
         * observado, en `wallApplyState`.
         */
        function wallRestore(): bool { return Wallpaper.restorePrevious(); }
        /** F4b: la pantalla `mon` vuelve al fondo de todas (lo mismo que «Use shared»). */
        function wallClear(mon: string): bool { return Wallpaper.clearOutput(mon); }
        /** F4e: «Check now» (lo mismo que el botón del Overview). */
        function updatesCheck(): bool { Updates.recheck(); return Updates.checking; }
        /** F4e, sólo lectura: la fuente de actualizaciones, su proveedor y los argv de Upgrade y de la lista (en seco). */
        function updatesState(): string { return JSON.stringify(Updates.summary()); }
        /** F4d (PL-04): devolver lo que la shell cambió en el escritorio (no pisa lo que cambió el usuario). */
        function themeDesktopRestore(): bool { return ThemePreview.restoreDesktop(); }
        function themeDesktopLedger(): string { ThemePreview.refreshDesktopLedger(); return JSON.stringify(ThemePreview.desktopLedger); }
        /** 10B, sólo lectura: el último apply observado (estado, origen, motivo, colores, anterior). */
        function wallApplyState(): string { return JSON.stringify(Wallpaper.applySummary()); }
        /**
         * 10B, PRUEBAS: carpeta con `apply-wallpaper.sh`, `matugen_reload.sh` y `apply-scheme` falsos
         * y sus archivos de estado (sólo bajo /tmp/). Con ella, apply, Restore, la bolsa, Recent y
         * los colores son de esa carpeta. "" vuelve a lo real (y a la rotación sin intervalo de prueba).
         */
        function wallTestRoot(path: string): bool {
            const ok = Wallpaper.setTestRoot(path);
            if (ok && path.length === 0) WallpaperRotation.testIntervalMs = 0;
            return ok;
        }
        /** 10B, sólo lectura: la rotación (estado, pausa y por qué, cuándo toca, cuántas van). */
        function wallRotation(): string { return JSON.stringify(WallpaperRotation.summary()); }
        /** 10B, PRUEBAS: intervalo de la rotación en ms (0 = el de Settings). Se niega sin `wallTestRoot`. */
        function wallRotationTest(ms: int): bool {
            if (!Wallpaper.testing || ms < 0) return false;
            WallpaperRotation.testIntervalMs = ms;
            return true;
        }

        /**
         * La tienda de Wallhaven (antes de la fase 11): alterna en `mon` ("" = la enfocada); si está en
         * otra pantalla, la trae. Lo mismo que Super+Ctrl+W y el botón de Wallpaper List.
         */
        function whStore(mon: string): bool { return Screens.wallhavenOn(mon, "ipc"); }
        function whStoreClose(): bool { return WallhavenStore.close(); }
        /** Sólo lectura: abierta, pantalla, aperturas, posiciones de la sesión y geometría de la capa. */
        function whStoreState(): string { return JSON.stringify(WallhavenStore.summary()); }
        /** Pruebas: lo mismo que soltar un arrastre con la esquina en (x, y); se acota al monitor. */
        /** Pruebas (capturas): pinta la tarjeta de `id` como con el puntero encima ("" = ninguna). */
        function whStoreHover(id: string): bool { WallhavenStore.testHot = id; return true; }
        /** Pruebas: seleccionar como con un clic (`""` = nada) y abrir/cerrar el panel Filters. */
        function whStoreSelect(id: string): bool { WallhavenStore.selectedId = id; return true; }
        function whStoreFilters(on: bool): bool { WallhavenStore.filtersOpen = on; return true; }
        /** W3, pruebas: abrir la ficha de `id` como con un clic en su tarjeta ("" = cerrarla). */
        function whStoreDetail(id: string): bool {
            if (id.length === 0) { WallhavenStore.detailOpen = false; return true; }
            if (!Wallhaven.results.some(r => r.id === id)) return false;
            WallhavenStore.openDetail(id);
            return true;
        }
        /**
         * W3, pruebas: una acción de la ficha abierta por su tipo (download · cancel · retry · apply ·
         * show · similar · open), como con su botón. `apply` aplica DE VERDAD salvo con `wallTestRoot`:
         * se niega sin él.
         */
        function whStoreAct(kind: string): bool {
            const l = WallhavenStore.layer;
            // pruebas: nada real — sin la API falsa no se baja, sin wallTestRoot no se aplica
            if (!l || !Wallhaven.testing || (kind === "apply" && !Wallpaper.testing) || kind === "open") return false;
            return l.catalogAct(kind);
        }
        /** W3, pruebas: la acción de la tarjeta (descarga rápida) de `id`, como con su botón. */
        function whStoreGet(id: string): bool {
            const it = WallhavenStore.layer;
            const r = Wallhaven.results.find(x => x.id === id);
            if (!it || !r || !Wallhaven.testing) return false;
            it.catalogDownload(r);
            return true;
        }
        function whStorePlace(x: int, y: int): bool {
            const l = WallhavenStore.layer;
            return !!(l && l.shown) && l.placeAt(x, y);
        }

        /** 10C-1, sólo lectura: la búsqueda de Wallhaven (estado, motivo, página, seed, peticiones, última URL). */
        function wallhaven(): string { return JSON.stringify(Wallhaven.summary()); }
        /**
         * 10C-1: buscar en Wallhaven (página 1). `sorting` "" = relevancia con texto, fecha sin él.
         * HACE UNA PETICIÓN A LA RED salvo con `whTestBase` puesto. No toca la biblioteca.
         */
        function whSearch(query: string, sorting: string): bool { return Wallhaven.search(query, sorting); }
        /** 10C-1: otra página de la misma búsqueda (con su seed si es aleatoria). */
        function whPage(n: int): bool { return Wallhaven.goPage(n); }
        /**
         * 10C-2: un filtro del BORRADOR (no pide nada; Search lo manda). `categories`/`purity`: tres
         * bits («110»); `sorting` (""·date_added·random·views·favorites·toplist); `order` asc|desc;
         * `topRange`; `atleast` ("" o «2560x1440»); `resolutions`/`ratios`: ALTERNA ese valor;
         * `color` ("" o hex de la paleta); `format` (""·png·jpg). `false` si no se admite.
         */
        function whFilter(key: string, value: string): bool {
            const W = Wallhaven;
            switch (key) {
            case "categories": case "purity":
                if (!/^[01]{3}$/.test(value)) return false;
                W.setDraft(key, value); return true;
            case "sorting":
                if (W.sortings.map(o => o.key).indexOf(value) < 0) return false;
                W.setDraft(key, value); return true;
            case "order":
                if (value !== "asc" && value !== "desc") return false;
                W.setDraft(key, value); return true;
            case "topRange":
                if (W.topRanges.indexOf(value) < 0) return false;
                W.setDraft(key, value); return true;
            case "atleast":
                if (value.length > 0 && !W.validCustom(value)) return false;
                W.setAtleast(value); return true;
            case "resolutions":
                if (W.exactResolutions.indexOf(value) < 0) return false;
                W.toggleIn(key, value); return true;
            case "ratios":
                if (W.ratioOptions.indexOf(value) < 0) return false;
                W.toggleIn(key, value); return true;
            case "color":
                if (value.length > 0 && W.colorOptions.indexOf(value) < 0) return false;
                W.setDraft(key, value); return true;
            case "format":
                if (["", "png", "jpg"].indexOf(value) < 0) return false;
                W.setDraft(key, value); return true;
            }
            return false;
        }
        function whRemoveFilter(key: string, value: string): bool { Wallhaven.removeFilter(key, value); return true; }
        function whResetFilters(): bool { Wallhaven.resetFilters(); return true; }
        /** 10C-2: etiquetas y autor de un resultado (una petición por id; caché). Red salvo con whTestBase. */
        function whInfo(id: string): string {
            Wallhaven.info(id);
            return JSON.stringify(Wallhaven.infos[id] || { pending: true });
        }
        function whRetry(): bool { return Wallhaven.retry(); }
        /** 10C-1, pruebas: otra API (`tools/kt-wallhaven.py`). Sólo `http://127.0.0.1:…`; "" = Wallhaven. */
        function whTestBase(url: string): bool {
            if (url.length > 0 && !/^http:\/\/127\.0\.0\.1:[0-9]{2,5}$/.test(url)) return false;
            Wallhaven.testBase = url;
            return true;
        }

        /**
         * 10E-1a, sólo lectura: la cuenta de Wallhaven — si HAY clave (nunca cuál), estado, motivo,
         * cuándo se comprobó, usuario y filtros de la cuenta. La clave no se puede poner por IPC:
         * iría en los argumentos (visibles en `ps`); se escribe en Settings.
         */
        function whAccount(): string { return JSON.stringify(WallhavenAccount.summary()); }
        /**
         * 10E-1b: My collections — abrir la lista (una petición; hacen falta clave comprobada y
         * usuario), abrir una por id, volver. Red real salvo con whTestBase.
         */
        function whOpenCollections(): bool { return Wallhaven.openCollections(); }
        function whOpenCollection(id: string): bool {
            const c = Wallhaven.collections.find(x => x.id === id);
            return c ? Wallhaven.openCollection(c) : false;
        }
        function whBackToCollections(): bool { return Wallhaven.backToCollections(); }
        function whBackToSearch(): bool { return Wallhaven.backToSearch(); }
        /** 10E-1b, sólo lectura: el índice privado (asociaciones y nombres; sin la clave). */
        function whIndex(): string { return JSON.stringify(WallhavenIndex.summary()); }
        /** 10E-1b, sólo lectura: la biblioteca filtrada por una colección del índice (y texto). */
        function wallLibraryCollection(collection: string, query: string): string {
            const l = Wallpaper.query("all", "library", query, collection);
            return JSON.stringify({ count: l.length, names: l.slice(0, 20).map(e => e.name) });
        }

        /** 10E-1a: Test connection (una petición a /settings). Red real salvo con whTestBase. */
        function whKeyTest(): bool { return WallhavenAccount.test(); }
        function whKeyRemove(): bool { return WallhavenAccount.remove(); }
        /** 10E-1a, pruebas: la carpeta de secretos bajo /tmp/… ("" = la real). */
        function whTestAccountDir(dir: string): bool { return WallhavenAccount.setTestDir(dir); }

        /** 10D-1, sólo lectura: descargas (trabajos, archivos con estado y bytes, bloqueo, límite). */
        function downloads(): string { return JSON.stringify(Downloads.summary()); }
        /**
         * 10D-1: descargar el resultado `id` de la página de Wallhaven a la vista. BAJA DE VERDAD de
         * Wallhaven salvo con `whTestBase` (y entonces sólo a una carpeta bajo /tmp/). Nunca aplica.
         */
        function dlStart(id: string): string {
            const r = Wallhaven.results.find(x => x.id === id);
            // 10E-1b: con una colección abierta, la descarga lleva su contexto (para el índice)
            return JSON.stringify(r ? Downloads.download(r, Wallhaven.collectionCtx()) : { ok: false, reason: "Not on the current page" });
        }
        /**
         * 10E-2: Download collection — preparar (recorre TODAS las páginas de esa colección con el
         * Content del borrador; nada se baja), confirmar (un trabajo), o dejarlo. `downloads.prep`
         * dice el estado. Red real salvo con whTestBase; en pruebas, sólo a /tmp.
         */
        function dlPrepareCollection(id: string): bool {
            const c = Wallhaven.collections.find(x => x.id === id)
                || (Wallhaven.collection && Wallhaven.collection.id === id ? Wallhaven.collection : null);
            return c ? Downloads.prepareCollection(c) : false;
        }
        function dlConfirmCollection(): string { return Downloads.confirmCollection(); }
        function dlCancelPrepare(): bool { Downloads.cancelPrep(); return true; }
        function dlCancel(job: string): bool { return Downloads.cancel(job); }
        function dlRetry(job: string): bool { return Downloads.retry(job); }
        function dlClearFinished(): bool { Downloads.clearFinished(); return true; }
        /** 10D-1, pruebas: registro y temporales en esa carpeta (sólo /tmp/…); "" = los reales. */
        function dlTestDir(dir: string): bool { return Downloads.setTestDir(dir); }
        /** 10D-1, pruebas: el espacio libre que se mide (-1 = el real). Se niega sin dlTestDir. */
        function dlTestFreeBytes(n: string): bool {
            if (Downloads.testDir.length === 0) return false;
            Downloads.testFreeBytes = parseFloat(n);
            return true;
        }

        /**
         * El grabador de pantalla (2026-10-29), sólo lectura: estado, reloj, lo elegido, fuentes de audio,
         * carpeta, último archivo y el último error.
         */
        function recorder(): string { return JSON.stringify(ScreenRecorder.summary()); }
        /**
         * Grabar con lo elegido: `mode` screen · region · output ("" = el último), en `mon` ("" = la
         * enfocada). Lo mismo que Enter en una tarjeta del grabador (sin abrirlo).
         */
        function recorderStart(mode: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            const m = mode.length > 0 ? mode : ScreenRecorder.mode;
            if (!sc || ["screen", "region", "output"].indexOf(m) < 0) return false;
            return ScreenRecorder.start(m, sc.name);
        }
        /**
         * pause · resume · toggle · stop · cancel · copy: lo mismo que los botones de la pieza o la barra
         * (copy: la última grabación al portapapeles como archivo). Grabador 2.0, lo de las vistas Completed y
         * Error de la surface: copyPath (la ruta como texto) · new (cerrar Completed) · recover (unir los tramos que
         * quedaron) · retry (lo mismo que la última vez, en la pantalla enfocada) · dismiss (cerrar el error).
         */
        function recorderControl(verb: string): bool {
            if (verb === "copy") return ScreenRecorder.copyLast();
            if (verb === "copyPath") return ScreenRecorder.copyPath();
            if (verb === "new") { ScreenRecorder.dismissResult(); return true; }
            if (verb === "dismiss") { ScreenRecorder.dismissError(); return true; }
            if (verb === "recover") return ScreenRecorder.recover();
            if (verb === "retry") { const sc = Screens.resolve(""); return ScreenRecorder.retry(sc ? sc.name : ""); }
            if (verb === "toggle") return ScreenRecorder.togglePause();
            if (verb === "stop") return ScreenRecorder.stop();
            if (verb === "cancel") return ScreenRecorder.cancel();
            if (verb === "pause" || verb === "resume") return ScreenRecorder.control(verb);
            return false;
        }
        /** Sólo lectura: la vista del grabador en una pantalla (zona, tarjetas, foco, opciones, pie). */
        function recorderView(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc && sc.open === "recorder" ? sc.surfaceItem("recorder") : null;
            return JSON.stringify(it ? it.viewState() : null);
        }
        /**
         * SÓLO BANCO: sin systemd (proceso suelto), región ya elegida (sin ella, slurp de verdad), otra carpeta
         * de salida, el codificador pedido (gpu · cpu) y otro nodo de render (uno inexistente = volver a x264).
         * JSON {direct, geometry, dir, encoder, vaapiDevice}; "{}" lo devuelve todo a lo normal.
         */
        function recorderTest(json: string): bool {
            let o = null;
            try { o = JSON.parse(json); } catch (e) { return false; }
            ScreenRecorder.testDirect = o.direct === true;
            ScreenRecorder.testGeometry = typeof o.geometry === "string" ? o.geometry : "";
            ScreenRecorder.testDir = typeof o.dir === "string" ? o.dir : "";
            ScreenRecorder.testEncoder = o.encoder === "gpu" || o.encoder === "cpu" ? o.encoder : "";
            ScreenRecorder.testVaapiDevice = typeof o.vaapiDevice === "string" ? o.vaapiDevice : "";
            ScreenRecorder.refreshProbe();
            return true;
        }

        /** 10A, sólo lectura: la vista de Wallpaper List en una pantalla (zona, filtros, búsqueda, foco). */
        function wallpaperView(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc && sc.open === "wallpaper" ? sc.surfaceItem("wallpaper") : null;
            if (!it) return JSON.stringify({ open: false });
            const v = it.viewState();
            v.open = true;
            return JSON.stringify(v);
        }

        /**
         * Media, acting on the shell's own idea of the active player (which a
         * picker can override). The rice's XF86Audio* keys stay on playerctl:
         * they keep working when the shell is not running, and two paths to the
         * same action would only disagree about which player is "current".
         */
        function mediaToggle(): bool { return Media.toggle(); }
        function mediaNext(): bool { return Media.next(); }
        function mediaPrev(): bool { return Media.previous(); }
        /** frac 0..1 of the track. False when the player cannot seek. */
        function mediaSeek(frac: real): bool { return Media.seekTo(frac); }

        /** Hold the island expanded without the pointer. For a keybind. */
        function peek(mon: string): bool {
            return Screens.peekOn(mon, "ipc");
        }

        /** 8C-1: island ⇄ barra persistente en esa pantalla; devuelve true si queda la barra. */
        function barToggle(mon: string): bool {
            return Screens.barToggleOn(mon, "ipc");
        }

        /** 8F-1: dock encendido/apagado en esa pantalla (hasta la 8F-2, sólo por aquí); true = encendido. */
        function dockToggle(mon: string): bool {
            const sc = Screens.resolve(mon);
            return sc ? sc.toggleDock() : false;
        }

        /** 8C-1, sólo lectura: accesos visibles, anchos, centro del reloj y cursor de la barra. */
        function barState(mon: string): string {
            const sc = Screens.resolve(mon);
            return sc ? JSON.stringify(sc.barInfo()) : "{}";
        }

        /** 8C-1, pruebas: el acceso bajo el puntero de la barra («» = ninguno); arranca su espera de vista previa. */
        function barHover(key: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            return sc ? sc.setBarHover(key) : false;
        }

        /**
         * Que el island anuncie algo (2026-09-15). `tone` es uno de
         * ok · warn · danger · info; vacío, `danger`. Sin esto no había forma de
         * probar la cara de aviso sin esperar a que se cayera la red.
         */
        function announce(text: string, glyph: string, tone: string): bool {
            const sc = Screens.resolve("");
            if (!sc) return false;
            return sc.announce(text, glyph, tone);
        }

        /** Force a volume flash; for scripts that change the level themselves. */
        function osd(kind: string): void {
            const list = Screens.list;
            for (let i = 0; i < list.length; i++)
                if (list[i]) list[i].flashOsd(kind.length > 0 ? kind : "volume");
        }

        /**
         * Abre el menu contextual del item `i` de la bandeja; un indice
         * negativo lo cierra. Existe para poder probar el menu sin raton
         * (Hyprland no mueve el cursor) y para que un script pueda llegar a el.
         */
        function trayMenu(i: int, mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc) { console.warn("ipc trayMenu: no screen for", mon); return false; }
            return sc.openTrayMenu(i);
        }

        /** Entrar en el submenu `i` del menu de bandeja abierto. */
        function trayEnter(i: int, mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc) return false;
            return sc.enterTrayMenu(i);
        }

        /** Subir un nivel en el menu de bandeja; en el primero, lo cierra. */
        function trayBack(mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc) return false;
            return sc.backTrayMenu();
        }

        /** Que entradas tiene el menu de bandeja abierto ahora mismo. */
        function trayDump(mon: string): string {
            const sc = Screens.resolve(mon);
            if (!sc) return "{}";
            return JSON.stringify(sc.dumpTrayMenu());
        }

        /** Cambia la salida (o la entrada) por defecto al indice `i`. */
        function mixerDefault(kind: string, i: int): bool {
            const n = Mixer.nodeAt(kind, i);
            if (!n) { console.warn("ipc mixerDefault: nothing at", kind, i); return false; }
            if (kind === "sink") Mixer.setDefaultSink(n);
            else if (kind === "source") Mixer.setDefaultSource(n);
            else return false;
            return true;
        }

        /** Volumen 0-100 de `kind[i]`: sink | source | playback | capture. */
        function mixerVolume(kind: string, i: int, pct: int): bool {
            const n = Mixer.nodeAt(kind, i);
            if (!n) { console.warn("ipc mixerVolume: nothing at", kind, i); return false; }
            Mixer.setVolume(n, pct / 100);
            return true;
        }

        /**
         * Antes de la fase 14: balance de una salida o entrada estéreo, −100 (izquierda) … 100;
         * `mixerBalanceState` dice lo que se lee (volúmenes por canal y el estado de la petición).
         */
        function mixerBalance(kind: string, i: int, pct: int): bool {
            const n = Mixer.nodeAt(kind, i);
            if (!n || !Mixer.canBalance(n)) { console.warn("ipc mixerBalance: no stereo node at", kind, i); return false; }
            return Mixer.setBalance(n, pct / 100) > 0;
        }
        function mixerBalanceState(kind: string, i: int): string {
            const n = Mixer.nodeAt(kind, i);
            if (!n || !n.audio) return JSON.stringify(null);
            return JSON.stringify({ name: String(n.name), can: Mixer.canBalance(n), balance: Mixer.balanceOf(n),
                                    volume: n.audio.volume, volumes: n.audio.volumes, op: Mixer.ops.get("bal:" + n.id) });
        }

        function mixerMute(kind: string, i: int): bool {
            const n = Mixer.nodeAt(kind, i);
            if (!n) { console.warn("ipc mixerMute: nothing at", kind, i); return false; }
            Mixer.toggleMute(n);
            return true;
        }

        /**
         * 13A, sólo lectura: por flujo, identidad estable y sus tres rutas — efectiva
         * (enlaces, atravesando filtros smart), pedida (metadatos `default`) y recordada
         * (estado de WirePlumber, por aplicación). `hidden`: nodos internos de filtros.
         * Pedida y recordada sólo con el Mixer reclamado (`active`); si no, «unknown».
         */
        function audioRoutes(): string {
            return JSON.stringify(AudioRoutes.summary());
        }

        /**
         * 13B/13C: mueve el flujo `id` (el de `audioRoutes`) a la salida o entrada `device`
         * (node.name); "default" lo devuelve al predeterminado (y WirePlumber olvida el
         * destino de esa app). `true` = pedido: el resultado está en `ops.routes`.
         */
        function audioMove(id: int, device: string): bool {
            const n = AudioRoutes.nodeById(id);
            if (!n || !n.isStream) { console.warn("ipc audioMove: no stream", id); return false; }
            return AudioRoutes.moveTo(n, device === "default" ? "" : device) > 0;
        }

        /**
         * 13D: el ecualizador por salida. `eqState`: servicio, perfiles y, por salida, estado
         * (none · starting · absent · on · bypassed · failed + reason), filtro y curva.
         * Las acciones devuelven «pedido»; el resultado está en `ops.eq`.
         */
        function eqState(): string { return JSON.stringify(Equalizer.summary()); }
        function eqSetup(device: string, label: string): bool { return Equalizer.setup(device, label) > 0; }
        function eqRemove(device: string): bool { return Equalizer.remove(device) > 0; }
        function eqEnable(device: string, on: bool): bool { return Equalizer.setEnabled(device, on) > 0; }
        /** `bands`: diez dB separados por comas (31 Hz … 16 kHz); `preamp` en dB (−12…0). */
        function eqCurve(device: string, bands: string, preamp: real): bool {
            return Equalizer.setCurve(device, String(bands).split(",").map(Number), preamp) > 0;
        }
        /** 13E: preset (flat · bass · treble · vocal · pop · rock · jazz · classic · custom). */
        function eqPreset(device: string, preset: string): bool { return Equalizer.applyPreset(device, preset) > 0; }
        /** 13E: una banda (0…9 = 31 Hz…16 kHz) o el preamp; pasa a Custom. */
        function eqBand(device: string, band: int, db: real): bool { return Equalizer.setBand(device, band, db) > 0; }
        function eqPreamp(device: string, db: real): bool { return Equalizer.setPreamp(device, db) > 0; }
        function eqReset(device: string): bool { return Equalizer.reset(device) > 0; }
        /** Antes de la fase 14: los resets con un solo significado y el preamp seguro. */
        function eqResetBands(device: string): bool { return Equalizer.resetBands(device) > 0; }
        function eqResetPreamp(device: string): bool { return Equalizer.resetPreamp(device) > 0; }
        function eqSafePreamp(device: string): bool { return Equalizer.safePreamp(device) > 0; }
        /** Sólo pruebas: perfiles, config y servicio propio bajo /tmp/ ("" = lo real). */
        function eqTestRoot(path: string): bool { return Equalizer.setTestRoot(path); }

        /** Sólo para pruebas (13A): reclama el Mixer como "ipc" sin abrir ninguna vista. */
        function mixerClaim(on: bool): bool {
            Mixer.claim("ipc", on);
            return Mixer.active;
        }

        /**
         * Fase 6C: lo pedido frente a lo efectivo. Cada tabla dice, por clave, la
         * revisión vigente, lo pedido, lo que el sistema dice que hay y el estado
         * (pending · ok · error · unknown), más `stale`: resultados de revisiones
         * viejas que se descartaron.
         */
        function ops(): string {
            return JSON.stringify({ profile: PowerProfile.ops.snapshot(), mixer: Mixer.ops.snapshot(),
                                    power: Power.ops.snapshot(), web: Web.ops.snapshot(),
                                    clip: Clip.ops.snapshot(), net: Net.ops.snapshot(),
                                    bt: Bt.ops.snapshot(), routes: AudioRoutes.ops.snapshot(),
                                    eq: Equalizer.ops.snapshot() });
        }

        /**
         * Fase 6D: operaciones globales (polkit; trabajos y Wi-Fi en 6D-2): id, tipo,
         * recurso, superficie de control, pantalla PROPIETARIA, estado, traslados y
         * plazo restante. `live`: las vivas.
         */
        function operations(): string {
            const out = Operations.snapshot();
            // Lo que cree cada vista de control de una operación viva (para probar traslados).
            out.views = [];
            for (const o of Operations.live()) {
                for (const sc of Screens.list) {
                    const it = sc ? sc.surfaceItem(o.surface) : null;
                    if (!it) continue;
                    out.views.push({ screen: sc.name, open: sc.open, opId: it.opId, screenName: it.screenName,
                                     owner: it.opOwner, live: it.opLive, elsewhere: it.opElsewhere,
                                     engaged: it.engaged });
                }
            }
            return JSON.stringify(out);
        }

        /** Pide un perfil de energía; devuelve la revisión (0 = ya estaba, -1 = nombre malo). */
        function profileSet(name: string): int { return PowerProfile.setProfile(name); }

        /**
         * Wifi (9.f.2). **Ninguno de estos verbos acepta la contrasena**, y es
         * deliberado: lo que se gana con `connectWithPsk` es justamente que la
         * clave no pase por argv, y un `ipc call sumi wifiConnect SSID CLAVE`
         * la dejaria visible en `ps` para cualquier proceso del mismo usuario
         * -- exactamente el riesgo que `rofi/scripts/wifi.sh` documento y
         * acepto en sus lineas 96-102. El camino con clave se ejercita
         * tecleando en la superficie, que es ademas como lo usa una persona.
         */
        /**
         * ARREGLADO el 2026-09-09: llamaba a `Net.acquireScan()` /
         * `releaseScan()`, que dejaron de existir cuando 9.f.2b cambio el
         * contador por reclamaciones con nombre. El verbo respondia sin hacer
         * nada y `scanWatchers` se quedaba en 0 -- comprobado en vivo antes de
         * tocarlo. La reclamacion del IPC se llama "ipc" y es idempotente,
         * como las de las superficies.
         */
        function wifiScan(on: bool): bool {
            Net.claimScan("ipc", on);
            return true;
        }

        /** Solo redes conocidas o abiertas: sin clave no hay nada que filtrar. */
        function wifiConnect(ssid: string): bool {
            const i = Net.indexOfSsid(ssid);
            if (i < 0) { console.warn("ipc wifiConnect: no such network", ssid); return false; }
            const net = Net.networks[i];
            if (Net.needsKey(net) && !net.known) {
                console.warn("ipc wifiConnect:", ssid, "needs a key; use the surface");
                return false;
            }
            const sc = Screens.resolve("");   // 6D: el propietario, la pantalla enfocada
            return Net.connectTo(ssid, sc ? sc.name : "");
        }

        function wifiDisconnect(): bool { return Net.disconnectCurrent(); }

        function wifiRadio(on: bool): bool { return Net.setRadio(on); }
        /** 6C-2: autoconnect del cable (no lo desconecta). Resultado en `ops.net.wiredAuto`. */
        function wiredAutoconnect(on: bool): bool { return Net.setWiredAutoconnect(on); }
        /**
         * 6C-2, pruebas: subir o bajar el cable (lo mismo que la ficha, sin su
         * confirmación). BAJARLO SE NIEGA sin el Wi-Fi conectado: dejaría la máquina
         * sin red. Resultado en `ops.net.wired`.
         */
        function wiredSet(up: bool): bool {
            if (!up && !Net.wifiUp) { console.warn("ipc wiredSet: refused, no Wi-Fi to fall back on"); return false; }
            return up ? Net.wiredConnect() : Net.wiredDisconnect();
        }

        /** DESTRUCTIVO: borra los perfiles guardados de esa red. */
        function wifiForget(ssid: string): bool { return Net.forgetNetwork(ssid); }

        /** Tira las claves guardadas sin borrar el perfil. */
        function wifiClearSecrets(ssid: string): bool { return Net.clearSecrets(ssid); }

        /** Tras cerrar el navegador de un portal cautivo. */
        function wifiRecheck(): bool { return Net.recheckConnectivity(); }

        /**
         * Pegar una entrada del portapapeles por su id. El id es un **numero**,
         * no contenido, asi que pasarlo por argv no expone nada -- al contrario
         * que el contenido, que nunca lo hace (`services/Clip`).
         */
        function clipPaste(id: string): bool { return Clip.paste(id, false); }
        function clipPasteImage(id: string): bool { return Clip.paste(id, true); }
        function clipRefresh(): bool { return Clip.refresh(); }

        /**
         * Abrir la ficha de una red concreta. Existe porque sin raton no habia
         * forma determinista de ejercitar los casos de la auditoria (1, 2 o 3
         * acciones): con `wtype` a ciegas dependias de que la lista estuviera
         * ordenada como esperabas.
         */
        function wifiDetail(ssid: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc) { console.warn("ipc wifiDetail: no screen for", mon); return false; }
            if (!Net.knowsSsid(ssid)) { console.warn("ipc wifiDetail: unknown ssid", ssid); return false; }
            // La seleccion es de ESTA pantalla: abrir una ficha aqui ya no
            // cambia la que este mirando la otra (SurfaceHost §`sel`).
            return sc.openSurfaceWith("wifiDetail", ssid);
        }

        /**
         * BLUETOOTH (9.f.3). Existen por la misma razon que los de wifi: el
         * cursor no se automatiza (Hyprland no expone dispatcher para moverlo),
         * asi que sin verbos no hay forma determinista de ejercitar P1 -- ni de
         * dejar anotado, capacidad a capacidad, que se ejercito.
         *
         * Aqui NO hay ningun secreto que proteger, al reves que en wifi: una
         * direccion MAC no es una contrasena, asi que pasarla por argv no
         * reintroduce el riesgo que `connectWithPsk` evita.
         */
        function btScan(on: bool): bool {
            Bt.claimScan("ipc", on);
            return true;
        }

        /** B4 / T2: el interruptor de energia del adaptador. */
        function btPower(on: bool): bool { return Bt.setPower(on); }

        /** T5: conectar y desconectar lo emparejado. */
        function btConnect(addr: string): bool { return Bt.connectTo(addr); }
        function btDisconnect(addr: string): bool { return Bt.disconnectFrom(addr); }

        /** T8: emparejar; luego `trust` y `connect` los encadena el servicio. */
        function btPair(addr: string): bool { return Bt.pairWith(addr); }
        function btCancelPair(addr: string): bool { return Bt.cancelPairWith(addr); }

        /** DESTRUCTIVO: desempareja. No existe `unpair()`, es `forget()`. */
        function btForget(addr: string): bool { return Bt.forgetDevice(addr); }

        /** Capacidades que ningun original tenia. */
        function btTrust(addr: string, on: bool): bool { return Bt.setTrusted(addr, on); }
        function btBlock(addr: string, on: bool): bool { return Bt.setBlocked(addr, on); }

        /**
         * Contestar la pregunta del agente de emparejamiento (2026-09-22). Un
         * movil pide comparacion numerica y hasta hoy nadie respondia: BlueZ
         * esperaba sus ~40 s y salia `AuthenticationTimeout`. Existe por la
         * misma razon que `btPair`: el cursor no se automatiza, y sin verbo no
         * hay forma de ejercitar esto sin raton.
         */
        function btConfirm(ok: bool): bool { return Bt.answerPair(ok); }

        /** Abrir la ficha de un aparato concreto, como `wifiDetail`. */
        function btDetail(addr: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc) { console.warn("ipc btDetail: no screen for", mon); return false; }
            if (!Bt.byAddress(addr)) { console.warn("ipc btDetail: unknown address", addr); return false; }
            return sc.openSurfaceWith("btDetail", addr);
        }

        /**
         * MINIMIZADOR (10.b). Existen por la misma razon que los verbos de
         * wifi/bt: el cursor no se automatiza, asi que sin ellos no hay forma
         * determinista de ejercitar P1 ni de dejar anotado que se ejercito. La
         * direccion no es un secreto (es un puntero, no una contrasena): pasarla
         * por argv no reintroduce ningun riesgo.
         */
        function winList(): string {
            return JSON.stringify(Toplevels.summary());
        }

        function winMinimize(addr: string): bool {
            const ws = Toplevels.windows;
            for (let i = 0; i < ws.length; i++)
                if (ws[i].address === addr) return Toplevels.minimize(ws[i]);
            console.warn("ipc winMinimize: no window at", addr);
            return false;
        }

        function winRestore(addr: string): bool {
            const ws = Toplevels.windows;
            for (let i = 0; i < ws.length; i++)
                if (ws[i].address === addr) return Toplevels.restore(ws[i]);
            console.warn("ipc winRestore: no window at", addr);
            return false;
        }

        /** Enfocar la ventana (el modi `window` de rofi, 10.c.3). */
        function winFocus(addr: string): bool {
            const ws = Toplevels.windows;
            for (let i = 0; i < ws.length; i++)
                if (ws[i].address === addr) return Toplevels.focus(ws[i]);
            console.warn("ipc winFocus: no window at", addr);
            return false;
        }

        /**
         * SERVICIOS systemd --user (10.c). Verbos para ejercitar P1 sin ratón,
         * como wifi/bt/minimizador. El nombre de unidad se valida en
         * `services/Units` contra `^[A-Za-z0-9@:._-]+\.service$` antes de tocar
         * `systemctl`; nunca se construye una línea de shell (SECURITY regla 3).
         */
        function unitsList(): string {
            return JSON.stringify(Units.summary());
        }
        function unitStart(unit: string): bool { return Units.act("start", unit); }
        function unitStop(unit: string): bool { return Units.act("stop", unit); }
        function unitRestart(unit: string): bool { return Units.act("restart", unit); }

        /**
         * 11F-1 (Systemd Units por ámbito): `scope` es `user` o `system`.
         *   unitsScope <scope> <mon>            abre la lista en ese ámbito
         *   unitsState <mon>                    lo que enseña y elige la lista
         *   unitDetailIn <scope> <unit> <mon>   la ficha de esa unidad en ese ámbito (cualquier tipo)
         *   unitDetailState <mon> · unitJournalState <mon>
         *   unitJournalIn <scope> <unit> <mon>
         * Sólo pruebas: `unitsListFailTest <scope> <n>` (las próximas n lecturas de ese ámbito
         * fallan) y `journalTestCommand <argv separado por espacios>` (sustituye a journalctl; recibe
         * el ámbito y la unidad al final). Nada de esto actúa sobre unidades.
         */
        function unitsScope(scope: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc || (scope !== "user" && scope !== "system")) return false;
            return sc.openSurfaceWith("services", scope);
        }
        function unitsState(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("services") : null;
            return it ? JSON.stringify(it.stateInfo()) : "{}";
        }
        function unitDetailIn(scope: string, unit: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc || (scope !== "user" && scope !== "system")) return false;
            const k = Units.key(scope, unit);
            if (!Units.loadDetail(k)) return false;
            return sc.openSurfaceWith("serviceDetail", k);
        }
        function unitDetailState(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("serviceDetail") : null;
            return it ? JSON.stringify(it.stateInfo()) : "{}";
        }
        function unitJournalIn(scope: string, unit: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc || (scope !== "user" && scope !== "system")) return false;
            const k = Units.key(scope, unit);
            if (!Units.loadJournal(k)) return false;
            return sc.openSurfaceWith("serviceJournal", k);
        }
        function unitJournalState(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("serviceJournal") : null;
            return it ? JSON.stringify(it.stateInfo()) : "{}";
        }
        function unitsListFailTest(scope: string, n: int): bool {
            if (scope !== "user" && scope !== "system") return false;
            const f = Object.assign({}, Units.listFailReads);
            f[scope] = Math.max(0, n);
            Units.listFailReads = f;
            Units.refreshScope(scope);
            return true;
        }
        function unitsFailedTest(keys: string): bool {
            const out = [];
            for (const k of keys.trim().split(/\s+/)) {
                if (k.length === 0) continue;
                const p = Units.parseKey(k);
                if (!Units.looksLikeUnit(p.unit)) return false;
                out.push({ scope: p.scope, unit: p.unit, load: "loaded", active: "failed", sub: "failed",
                           desc: "(test) pretend failure" });
            }
            Units.failedTest = out;
            Units.refreshFailed();
            return true;
        }
        /**
         * 11F-2, sólo pruebas: sustituye a `systemctl` en las acciones de SISTEMA (recibe el verbo y la
         * unidad al final). "" vuelve al real, que pide polkit. Las de usuario no cambian.
         */
        function unitsActTestCommand(argv: string): bool {
            const v = argv.trim();
            Units.actTestCommand = v.length === 0 ? [] : v.split(/\s+/);
            return true;
        }
        function journalTestCommand(argv: string): bool {
            const v = argv.trim();
            Units.journalTestCommand = v.length === 0 ? [] : v.split(/\s+/);
            return true;
        }

        /** Abre la ficha de una unidad, como `wifiDetail` (para P1 sin ratón). */
        function serviceDetail(unit: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc) { console.warn("ipc serviceDetail: no screen for", mon); return false; }
            if (!Units.loadDetail(unit)) return false;
            return sc.openSurfaceWith("serviceDetail", unit);
        }

        /**
         * La consola de unidades caídas del Dashboard, para P1 sin ratón
         * (QS-FUNC-008): abre el panel y la lanza. `dashboardJob` dice qué
         * enseña. Sin esto sólo se llega por teclado, y la primera acción del
         * panel es «update».
         */
        function dashboardDowned(mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc || !sc.openSurface("dashboard")) return false;
            const it = sc.surfaceItem("dashboard");
            if (!it) return false;
            it.runDowned();
            return true;
        }

        /**
         * 11A-1: abre el Dashboard en una pestaña (`overview` · `performance`), o la cambia si ya está
         * abierto. `tasks` (etapa B, 2026-11-09) abre la ventana flotante de tareas, como el nombre.
         */
        function dashboardTab(tab: string, mon: string): bool {
            const name = ({ overview: "dashboard", performance: "performance", tasks: "tasks" })[tab];
            const sc = Screens.resolve(mon);
            if (!name || !sc) return false;
            return sc.openSurface(name);
        }

        /** 11D-2: selección, desglose, progreso y energía de Performance. */
        function dashboardPerformance(mon: string): string {
            const sc = Screens.resolve(mon), it = sc ? sc.surfaceItem("dashboard") : null;
            return JSON.stringify(it ? it.performanceState() : {});
        }
        // Sólo presentación de energía: exige el motor aislado y nunca escribe en el daemon.
        function performanceTestPower(value: string, mon: string): bool {
            if (!Modes.testing) return false;
            const sc = Screens.resolve(mon), it = sc ? sc.surfaceItem("dashboard") : null;
            if (!it) return false;
            try {
                const v = JSON.parse(value);
                if (v !== null && (typeof v !== "object" || Array.isArray(v)
                    || typeof v.checked !== "boolean" || typeof v.present !== "boolean"
                    || !Array.isArray(v.available) || !Array.isArray(v.holds))) return false;
                return it.performanceTestPower(v);
            } catch (e) { return false; }
        }

        function dashboardJob(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("dashboard") : null;
            if (!it) return "{}";
            // etapa B: la consola, el catálogo y los trabajos se fueron a la capa Tasks (`tasksUiState`)
            return JSON.stringify({ running: Jobs.anyBusy,
                                    watching: it.downedWatch, text: it.downedText,
                                    tab: it.tab, action: it.focusedAction(),
                                    // F2d: las acciones de mantenimiento, con su etiqueta y si están apagadas
                                    actions: it.actionList.map(a => ({ id: a.id, enabled: a.enabled !== false, label: a.label })),
                                    // 11A-2: la fila con el foco en asuntos; etapa C: sin pliegue, actividad en una línea
                                    issueSel: it.issueSel, moreOpen: it.moreOpen, headline: it.headlineText,
                                    lastActivity: it.lastActivity ? it.lastActivity.kind : "", liveJobs: it.liveJobs,
                                    layout: it.layoutState(),
                                    section: it.section,
                                    checks: it.checkRows.map(c => c.id) });
        }
        /**
         * F3d-2, PRUEBAS SÓLO EN EL BANCO (puede lanzar la tarea, como pulsar su fila): la acción `id` del
         * Dashboard de `mon` por el MISMO camino que el ratón y ⏎ (`runAction`).
         */
        function dashboardAction(id: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("dashboard") : null;
            if (!it) return false;
            it.runAction(id);
            return true;
        }

        /**
         * 11A-2: los asuntos del Overview (`headline` issues · problems · loading · clear, las
         * fuentes con su estado) y la actividad reciente. Los `*Test` sólo sustituyen rutas de
         * lectura: nada real cambia ("" vuelve a lo real).
         */
        function issues(): string { return JSON.stringify(Issues.summary()); }
        /** F3d-1: tasks.json tal como lo ve la shell (estado, motivo, tareas válidas y descartadas). Sólo lectura. */
        function tasks(): string { return JSON.stringify(Tasks.summary()); }
        /**
         * Portabilidad F4a: los proveedores (providers.json + la elección de settings.json) y, EN SECO, el
         * argv de cada verbo con argumentos de muestra fijos (tools/f4/: «wall one.png» lleva un espacio
         * para ver que nada se interpola). No ejecuta nada.
         */
        function providers(): string {
            const samples = { path: "/tmp/kt-f4/wall one.png", output: "HDMI-A-1", wall: "/tmp/kt-f4/wall one.png",
                              json: '{"sumi-mpvpaper-all.sock":true}', transition: "fade" };
            return JSON.stringify(Object.assign(Providers.summary(), { samples: samples, dryRun: Providers.dryRun(samples) }));
        }
        /** 11B: el catálogo compartido y una búsqueda sobre él (el estado: ok · nomatch · unavailable). */
        function commands(query: string): string {
            const r = Commands.filter(query);
            return JSON.stringify({ state: r.state, rows: r.rows.map(c => c.id + " · " + Commands.whereText(c)) });
        }
        function commandsTestUnavailable(on: bool): bool { Commands.testUnavailable = on; return true; }
        function activity(): string { return JSON.stringify(Activity.summary()); }
        function issuesRefresh(): bool { Issues.refresh(); return true; }
        function issuesTest(what: string, path: string): bool {
            // F3d-1: «dot» y «disk» son las tareas dotbackup y diskbackup; «task:<id>», cualquier otra
            if (what === "dot") Issues.setTestPath("dotbackup", path);
            else if (what === "disk") Issues.setTestPath("diskbackup", path);
            else if (what.indexOf("task:") === 0) Issues.setTestPath(what.slice(5), path);
            else if (what === "updates") Updates.testPath = path;
            else if (what === "checks") Checks.testDir = path;
            else return false;
            Issues.refresh();
            return true;
        }
        function unitsFailTest(reads: int): bool { Units.failReads = Math.max(0, reads); Units.refreshFailed(); return true; }
        function activityTestPath(path: string): bool { Activity.testPath = path; return true; }

        /** Fase 6B: el registro de trabajos (estado, resumen, últimas líneas). */
        function jobs(): string {
            // 11A-1: `testing`, qué tipos tienen un comando FALSO puesto: comprobarlo antes de
            // lanzar. Sólo aquí: el snapshot es también el formato de jobs.json.
            return JSON.stringify(Object.assign(Jobs.snapshot(), { testing: Object.keys(Jobs.testCommands) }));
        }
        /**
         * Sólo para pruebas, y SÓLO con un comando falso puesto (`jobTestCommand`):
         * se salta la confirmación del panel, así que nunca lanza el script real.
         * El 2026-09-25 un `jobTestCommand` que falló en silencio hizo correr el
         * diskbackup real desde aquí.
         */
        function jobStart(kind: string): string {
            if (!Jobs.testCommands[kind]) { console.warn("ipc jobStart: no test command for", kind); return ""; }
            const sc = Screens.resolve("");   // 6D: el propietario, la pantalla enfocada
            return Jobs.start(kind, {}, sc ? sc.name : "");
        }
        /**
         * F3d-1: qué ejecutaría un trabajo del panel, SIN lanzarlo: el argv y el protocolo que salen de su
         * tarea (y si hay un comando de prueba puesto encima). Sólo lectura.
         */
        function jobArgv(kind: string): string {
            const r = Jobs.runner(kind);
            const t = Tasks.byId(kind);
            return JSON.stringify({ declared: Jobs.declared(kind), command: r.command, label: r.label,
                                    interactive: r.interactive, output: t ? t.output : "", prompts: t ? t.prompts : "",
                                    why: Jobs.whyNot(kind), needs: Jobs.needsOf(kind),
                                    test: Jobs.testCommands[kind] || null, sshKey: SshAgent.keyPath });
        }
        function jobAnswer(kind: string, text: string): bool { return Jobs.answer(kind, text); }
        function jobCancel(kind: string): bool { return Jobs.cancel(kind); }
        /**
         * SÓLO PRUEBAS (banco de Speed test): opciones extra del helper como `fake=slow secs=2` (sin guiones:
         * `qs` se come los `--`); "" las quita. Sólo acepta las opciones conocidas del helper.
         */
        function speedtestTestCommand(argv: string): bool { return SpeedTest.setTestArgs(argv); }
        /** SÓLO PRUEBAS: start · confirm · cancel · dismiss del servicio, sin abrir la vista. */
        function speedtestTest(action: string): bool {
            switch (action) {
            case "start": return SpeedTest.start();
            case "confirm": return SpeedTest.confirm();
            case "cancel": return SpeedTest.cancel("");
            case "dismiss": return SpeedTest.dismiss();
            }
            return false;
        }
        /**
         * Sólo para pruebas: sustituye el argv de un tipo (separado por espacios;
         * p. ej. un falso dotbackup que imita sus preguntas). "" vuelve al real.
         * Un JSON con comas llegaba partido a `qs ipc call`: por eso espacios.
         */
        function jobTestCommand(kind: string, argv: string): bool {
            const c = Object.assign({}, Jobs.testCommands);
            const v = argv.trim();
            if (v.length === 0) delete c[kind]; else c[kind] = v.split(/\s+/);
            Jobs.testCommands = c;
            return true;
        }

        /**
         * Estado del lanzador, para P1 sin raton (QS-FUNC-010): la consulta, si
         * esta mostrando las acciones de una app y cuales, y la seleccion.
         */
        /**
         * `Ctrl+⏎` sobre la fila elegida, sin teclado: `wtype` con modificador
         * manda keycodes que Hyprland resuelve mal (ADR-26). QS-FUNC-012a.
         */
        /**
         * Gancho de prueba de QS-FUNC-018: fuerza `Session.idle` para ejercitar
         * las puertas sin irse dos minutos de la maquina. Volver a `false`.
         */
        function idleForce(on: bool): bool {
            Session.forceIdle = on;
            return Session.idle;
        }

        /** 16B, SÓLO PRUEBAS: una tecla (Tab, Down, Escape…) por el camino de `Keys` de esa pantalla, sin wtype. */
        function keyTest(mon: string, name: string, shift: bool): bool {
            const sc = Screens.resolve(mon);
            return !!sc && sc.testKey(name, shift);
        }
        function launcherCtrlEnter(mon: string): bool {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("launcher") : null;
            if (!it || sc.open !== "launcher") return false;
            it.activate(Qt.ControlModifier);
            return true;
        }

        /**
         * Lo que ve el minimizador, sólo lectura (rediseño ARR-05, P-06): la ventana
         * elegida por identidad (`selKey`), su posición y los títulos en orden.
         */
        /** Historial Back/Forward de una pantalla (rediseño, fase 4): mismo camino que Alt+←/→. */
        function historyBack(mon: string): bool {
            const sc = Screens.resolve(mon);
            return sc ? sc.historyBack() : false;
        }
        function historyForward(mon: string): bool {
            const sc = Screens.resolve(mon);
            return sc ? sc.historyForward() : false;
        }
        /** Sólo lectura: las visitas `{surface, key, ctx}` y cuál es la actual. */
        function historyState(mon: string): string {
            const sc = Screens.resolve(mon);
            return sc ? JSON.stringify(sc.historyDump()) : "{}";
        }

        /** Sólo lectura (fase 4, Guarded): la pregunta de salida y si la abierta está protegida. Sin texto tecleado. */
        /** Fase 4C, para pruebas: la vista previa por hover sin mover el ratón, y fijarla. */
        function preview(name: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            return sc ? sc.openPreview(name) : false;
        }
        /** Pruebas: el icono bajo el puntero de la cara hover («» = ninguno). */
        function hoverKey(key: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            return sc ? sc.setHoverKey(key) : false;
        }
        /** Fase 8B-1, sólo lectura: geometría del reposo y caras de las piezas laterales. */
        /** 15F, sólo lectura: de dónde sale la cápsula del Lock en esa pantalla (island, dock o barra). */
        function lockOrigin(mon: string): string {
            const sc = Screens.resolve(mon);
            return sc ? JSON.stringify(sc.lockOrigin()) : "{}";
        }
        function islandState(mon: string): string {
            const sc = Screens.resolve(mon);
            return sc ? JSON.stringify(sc.islandInfo()) : "{}";
        }
        /**
         * Fase 8B-1, pruebas: lo mismo que un clic en una pieza lateral («music» o «net»):
         * abre su superficie, fija su vista previa o la cierra si ya es la abierta.
         */
        function islandCircle(which: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc) return false;
            if (which === "music") return sc.toggleFromCircle("media");
            if (which === "net") return sc.toggleFromCircle("controlCenter");
            return false;
        }
        /**
         * Fase 8B-1, pruebas: falsea SÓLO la cara de la pieza de Red (unknown · wired ·
         * wifi-1 · wifi-4 · limited · connecting · none · off · nohw; «» = la real). La red
         * no se toca. false si el estado no existe.
         */
        function islandTestNet(state: string): bool {
            if (state.length > 0 && !Screens.netFaceTests[state]) return false;
            Screens.netFaceTest = state;
            return true;
        }
        /** Fase 7A, pruebas: abre `name` en vista previa y la mantiene sin hover (ver Screen.previewHeld). */
        function previewHold(name: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc || !sc.openPreview(name)) return false;
            sc.previewHeld = true;
            return true;
        }
        function engage(mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc || !sc.preview) return false;
            sc.engage();
            return true;
        }

        function guardState(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc && sc.open.length > 0 ? sc.surfaceItem(sc.open) : null;
            const host = sc ? sc.surfaceHost() : null;
            return JSON.stringify({ open: sc ? sc.open : "", preview: sc ? sc.preview : false,
                                    hover: sc ? sc.hoverInfo() : null,
                                    guardReason: it ? it.guardReason : "",
                                    secretLength: it && it.keyLength !== undefined ? it.keyLength : -1,
                                    asking: host ? host.leaveTarget !== null : false,
                                    choice: host ? host.leaveChoice : -1, drafts: Drafts.summary() });
        }

        /**
         * SÓLO PRUEBAS (6D): texto ficticio en el campo secreto de la superficie abierta
         * (hoy la ficha Wi-Fi de una red con clave) para armar la guardia sin teclear.
         */
        function guardTestFill(mon: string, n: int): bool {
            const sc = Screens.resolve(mon);
            const it = sc && sc.open.length > 0 ? sc.surfaceItem(sc.open) : null;
            return !!(it && typeof it.testFillSecret === "function" && it.testFillSecret(n));
        }

        /** Contestar la pregunta de salida: `true` = Discard and leave, `false` = Keep editing. */
        function guardAnswer(mon: string, discard: bool): bool {
            const sc = Screens.resolve(mon);
            const host = sc ? sc.surfaceHost() : null;
            if (!host || host.leaveTarget === null) return false;
            if (discard) host.discardAndLeave(); else host.keepEditing();
            return true;
        }

        /** Sólo lectura (fase 5B): la entrada elegida por id y el estado del pegado. Nunca el contenido. */
        function clipboardState(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("clipboard") : null;
            if (!it) return "{}";
            return JSON.stringify({ selected: it.selected, selId: it.selId, count: it.count,
                                    ids: it.results.slice(0, 6).map(e => e.id),
                                    pendingRev: it.pendingRev, pasteError: it.pasteError });
        }

        /** Selector de emojis (2026-11-17), banco: estado de la superficie, sin el contenido copiado. */
        function emojiState(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("emoji") : null;
            return it ? JSON.stringify(it.state()) : "{}";
        }
        /** Banco: escribe la consulta del selector abierto (como `launcherType`). */
        function emojiType(text: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("emoji") : null;
            if (!it || sc.open !== "emoji") return false;
            it.setQuery(text);
            return true;
        }
        /** Banco: una tecla con Ctrl y/o Mayús (keyTest sólo lleva Mayús): Left, Right, Return, Backspace… */
        function emojiKey(mon: string, name: string, ctrl: bool, shift: bool): bool {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("emoji") : null;
            if (!it || sc.open !== "emoji") return false;
            const map = { Up: Qt.Key_Up, Down: Qt.Key_Down, Left: Qt.Key_Left, Right: Qt.Key_Right, Tab: Qt.Key_Tab,
                          Backtab: Qt.Key_Backtab, Return: Qt.Key_Return, Backspace: Qt.Key_Backspace };
            if (!map[name]) return false;
            const e = { key: map[name], modifiers: (ctrl ? Qt.ControlModifier : 0) | (shift ? Qt.ShiftModifier : 0),
                        text: "", isAutoRepeat: false, accepted: false };
            it.keyPressed(e);
            return e.accepted;
        }

        /** Sólo lectura (fase 5C): la red elegida por nombre y el orden de la lista. */
        function wifiState(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("wifi") : null;
            if (!it) return "{}";
            return JSON.stringify({ selected: it.selected, selName: it.selName, count: it.count,
                                    names: Net.networks.slice(0, 6).map(n => n.name) });
        }

        /**
         * Fase 6A: quién tiene reclamado qué, servicio a servicio. Con todo
         * cerrado, cada lista debe estar vacía (salvo "sysmon" en `units` si
         * System está abierto: esa la pone Sysmon mismo).
         */
        function subscriptions(): string {
            const keys = (o) => Object.keys(o || {}).sort();
            return JSON.stringify({
                clip: keys(Clip.claims),
                units: keys(Units.claims), journal: keys(Units.journalClaims),
                netScan: keys(Net.scanClaims), btScan: keys(Bt.scanClaims),
                media: keys(Media.claims), mixer: keys(Mixer.claims),
                sysmon: Sysmon.claims,
                hypr: keys(HyprConfig.claims), idle: keys(Idle.claims),
                netProfiles: keys(NetProfiles.claims), integrations: keys(Integrations.claims),
                running: { netScan: Net.scanWanted, btScan: Bt.scanWanted, clip: Clip.wanted,
                           units: Units.wanted, journal: Units.journalFollowing,
                           sysmon: Sysmon.level, sysmonTicks: Sysmon.ticks,
                           audioRoutesMeta: AudioRoutes.metaLive,
                           mediaPoll: Media.subscribers > 0 && Media.playing && !Media.live }
            });
        }

        /** Sólo para pruebas (fase 6A): reclama Sysmon como "ipc" ("summary", "detail" o "" para soltar). */
        function sysmonClaim(level: string): string {
            Sysmon.claim("ipc", level);
            return Sysmon.level;
        }

        /** 11E-1: muestras coherentes, historial y procesos ligados a una muestra. */
        function systemMonitor(mon: string): string {
            const sc = Screens.resolve(mon), it = sc && sc.open === "system" ? sc.surfaceItem("system") : null;
            return JSON.stringify(it ? it.state() : {open: false});
        }
        function sysmon(history: bool): string { return JSON.stringify(Sysmon.summary(history)); }
        function sysmonHistory(before: string, count: int): string {
            return JSON.stringify(Sysmon.historyPage(before, count));
        }
        function sysmonSample(id: string): string {
            return JSON.stringify({sample: Sysmon.sampleAt(id), processes: Sysmon.processesAt(id)});
        }
        function sysmonWatch(who: string, level: string): bool {
            if (!/^[a-zA-Z0-9_-]{1,40}$/.test(who) || ["", "summary", "detail", "inspect"].indexOf(level) < 0) return false;
            Sysmon.claim("ipc:" + who, level); return true;
        }
        /** M1: los últimos `count` cubos de 5 s de la tendencia (≤ 120; la respuesta se acota a 32K). */
        function sysmonTrend(count: int): string {
            let rows = Sysmon.trend.slice(-Math.max(1, Math.min(120, count)));
            while (rows.length > 1 && JSON.stringify(rows).length > 32768) rows = rows.slice(1);
            return JSON.stringify({count: Sysmon.trend.length, rows: rows,
                                   open: Sysmon.bucket ? {startMs: Sysmon.bucket.startMs, n: Sysmon.bucket.n} : null});
        }
        /** M1 (inspect): la lista entera, ordenada por "cpu", "memory" o "pid"; ≤ 40 filas. */
        function sysmonProcesses(sort: string, count: int): string {
            const key = {cpu: r => -(r.cpuPct || 0), memory: r => -r.memoryB, pid: r => r.pid}[sort] || (r => r.pid);
            const rows = Sysmon.processList.slice().sort((a, b) => key(a) - key(b)).slice(0, Math.max(1, Math.min(40, count)));
            return JSON.stringify({info: Sysmon.processListInfo, total: Sysmon.processList.length, rows: rows});
        }
        function sysmonSensors(): string { return JSON.stringify({sensors: Sysmon.sensors, peaks: Sysmon.sensorPeaks}); }
        /** M1: el proceso elegido de la UI (pid 0 lo suelta); se lee sólo con inspect. */
        function sysmonFocus(pid: int, start: int): bool { Sysmon.setFocus(pid, start); return true; }
        /**
         * Antes de la fase 12: la UI de inspección. `monitorUi` alterna en `mon` ("" = la enfocada)
         * y, con `section`, abre en esa sección; `monitorUiShow` sólo abre (como Details).
         */
        function monitorUi(mon: string, section: string): bool { return Screens.monitorOn(mon, section, "ipc"); }
        function monitorUiShow(mon: string, section: string): bool { return Screens.monitorShowOn(mon, section, "ipc"); }
        function monitorUiClose(): bool { return MonitorUi.close(); }
        function monitorUiState(): string { return JSON.stringify(MonitorUi.summary()); }

        /**
         * La capa Tasks (etapa B del Dashboard, 2026-11-09). `tasksUi`: abrirla (o traerla) en `mon` con la
         * tarea `id` elegida ("" = la última vista); NO arranca nada. `tasksUiState`: su estado (catálogo,
         * consola, preguntas, trabajos). `tasksUiKey`/`tasksUiQuery`: teclas y búsqueda por el mismo camino
         * que el teclado, para pruebas.
         */
        function tasksUi(id: string, mon: string): bool { return Screens.tasksOn(mon, id, false, "ipc"); }
        function tasksUiClose(): bool { return TasksUi.requestClose(); }
        function tasksUiState(): string { return JSON.stringify(TasksUi.summary()); }
        function tasksUiKey(name: string, shift: bool): bool { return !!TasksUi.layer && TasksUi.layer.shown && TasksUi.layer.key(name, shift); }
        function tasksUiQuery(text: string): bool { return !!TasksUi.layer && TasksUi.layer.shown && TasksUi.layer.setQuery(text); }
        function monitorUiSection(id: string): bool {
            if (!MonitorUi.sections.some(s => s.id === id)) return false;
            MonitorUi.section = id; return true;
        }
        function monitorUiRange(id: string): bool {
            if (!MonitorUi.ranges.some(r => r.id === id)) return false;
            MonitorUi.range = id; return true;
        }
        function monitorUiPause(on: bool): bool { return on ? MonitorUi.pause() : MonitorUi.resume(); }
        function monitorUiQuery(text: string, sort: string, kernel: bool): bool {
            if (["cpu", "memory", "pid", "name"].indexOf(sort) < 0) return false;
            MonitorUi.query = text; MonitorUi.sortKey = sort; MonitorUi.showKernel = kernel; return true;
        }
        function monitorUiSelect(pid: int, start: int): bool { return MonitorUi.select(pid, start); }
        /** Una tecla por el mismo manejador que el teclado real (Escape, Space, Slash, Up, Down, 1–8). */
        function monitorUiKey(name: string): bool { return !!MonitorUi.layer && MonitorUi.layer.key(name); }
        function monitorUiPlace(x: int, y: int): bool { return !!MonitorUi.layer && MonitorUi.layer.placeAt(x, y); }
        /**
         * 2026-10-26: la Calendar UI, el mismo modelo de capa que Monitor/Audio. `calendarUi` alterna en `mon`
         * ("" = la enfocada; Super+Ctrl+C desde el 10-27); `calendarUiShow` sólo abre (como Open calendar en Hoy).
         */
        function calendarUi(mon: string): bool { return Screens.calendarOn(mon, "ipc"); }
        function calendarUiShow(mon: string): bool { return Screens.calendarShowOn(mon, "ipc"); }
        function calendarUiClose(): bool { return CalendarUi.close(); }
        function calendarUiState(): string { return JSON.stringify(CalendarUi.summary()); }
        /** Una tecla por el mismo manejador que el teclado real (Escape, Return, flechas, RePág/AvPág, Inicio/Fin, Tab). */
        function calendarUiKey(name: string): bool { return !!CalendarUi.layer && CalendarUi.layer.key(name); }
        function calendarUiPlace(x: int, y: int): bool { return !!CalendarUi.layer && CalendarUi.layer.placeAt(x, y); }

        /**
         * Login screen (Sumi SDDM, 2026-11-23), INTERNOS (no son contrato; el contrato es `open/toggle login` y el
         * atajo `loginScreen`). `loginUi` alterna en `mon`; `loginUiShow` abre en una página («notch», «system»,
         * «key:<clave>»; "" = la última). `loginUiKey`: Escape, Return, Space, flechas, PageUp/PageDown, Tab, Backtab,
         * Delete, Ctrl+F, Ctrl+PageUp/PageDown.
         */
        function loginUi(mon: string): bool { return Screens.loginOn(mon, "ipc"); }
        function loginUiShow(page: string, mon: string): bool { return Screens.loginShowOn(page, mon, "ipc"); }
        function loginUiClose(): bool { return LoginUi.close(false); }
        function loginUiState(): string { return JSON.stringify(LoginUi.summary()); }
        function loginUiKey(name: string): bool { return !!LoginUi.layer && LoginUi.layer.key(name); }
        function loginUiPlace(x: int, y: int): bool { return !!LoginUi.layer && LoginUi.layer.placeAt(x, y); }

        /**
         * Ayuda de atajos (2026-10-30), INTERNOS (no son contrato): la tarjeta de los atajos de la shell.
         * `keybindsUi` alterna en `mon` ("" = la enfocada); `keybindsUiShow` sólo abre. Sólo lectura: nada escribe la
         * configuración de Hyprland. `keybindsUiKey` pasa una tecla por el mismo manejador que el teclado real
         * (Escape, Return, Up, Down, Left, Right, PageUp, PageDown, Home, End, Tab, Backtab, Space, F5, Ctrl+F);
         * `keybindsUiType` escribe en la búsqueda; `keybindsUiClick` elige una fila como un clic.
         */
        function keybindsUi(mon: string): bool { return Screens.keybindsOn(mon, "ipc"); }
        function keybindsUiShow(mon: string): bool { return Screens.keybindsShowOn(mon, "ipc", null); }
        function keybindsUiClose(): bool { return KeybindsUi.close(); }
        function keybindsUiState(): string { return JSON.stringify(KeybindsUi.summary()); }
        function keybindsUiKey(name: string): bool { return !!KeybindsUi.layer && KeybindsUi.layer.key(name); }
        function keybindsUiType(text: string): bool { return !!KeybindsUi.layer && KeybindsUi.open && KeybindsUi.layer.typeText(text); }
        function keybindsUiClick(name: string): bool { return !!KeybindsUi.layer && KeybindsUi.layer.clickRow(name); }
        function keybindsUiPlace(x: int, y: int): bool { return !!KeybindsUi.layer && KeybindsUi.layer.placeAt(x, y); }
        function keybindsUiHits(): string { return JSON.stringify(KeybindsUi.layer && KeybindsUi.open ? KeybindsUi.layer.hitTargets() : {}); }
        /** Lo leído de Hyprland y lo resuelto por acción (sin vista: no abre nada). */
        function keybinds(): string {
            const rows = {};
            for (const a of Keybinds.actions) rows[a.name] = Keybinds.rowOf(a.name);
            return JSON.stringify({ summary: Keybinds.summary(), rows: rows });
        }
        function keybindsRefresh(): bool { Keybinds.refresh("ipc"); return true; }

        /**
         * Antes de la fase 14: la Audio UI. `audioUi` alterna en `mon` ("" = la enfocada) y, con
         * `section`, abre en esa sección; `audioUiShow` sólo abre (como los enlaces).
         */
        function audioUi(mon: string, section: string): bool { return Screens.audioOn(mon, section, "ipc"); }
        function audioUiShow(mon: string, section: string): bool { return Screens.audioShowOn(mon, section, "ipc"); }
        function audioUiClose(): bool { return AudioUi.close(); }
        function audioUiState(): string { return JSON.stringify(AudioUi.summary()); }
        function audioUiSection(id: string): bool {
            if (!AudioUi.sections.some(s => s.id === id)) return false;
            AudioUi.section = id; return true;
        }
        /** Qué salida mira Equalizer ("" = seguir a la predeterminada). */
        function audioUiEqOutput(device: string): bool { return AudioUi.pickEq(device); }
        /** Una tecla por el mismo manejador que el teclado real (Escape, Up, Down, Left, Right, Return, 1–6). */
        function audioUiKey(name: string): bool { return !!AudioUi.layer && AudioUi.layer.key(name); }
        /** El foco de teclado de la sección visible y la lista de focos (para guardas de pruebas). */
        function audioUiFocus(): string { return JSON.stringify(AudioUi.layer ? AudioUi.layer.focusInfo() : null); }
        function audioUiPlace(x: int, y: int): bool { return !!AudioUi.layer && AudioUi.layer.placeAt(x, y); }
        /** Las tarjetas (sólo lectura; se leen sólo con Output, Input o Devices a la vista). */
        function audioDevices(): string { return JSON.stringify(AudioDevices.summary()); }

        // ---- 14A: configuración del sistema en lectura -------------------------------------
        /**
         * Reclamar una lectura sin abrir Settings (pruebas): `hypr`, `idle`, `net`, `integrations`.
         * Como `sysmonClaim`: la reclamación es de «ipc» y se suelta con on=false.
         */
        function sysClaim(which: string, on: bool): bool {
            const t = ({ hypr: HyprConfig, idle: Idle, net: NetProfiles, integrations: Integrations, audio: AudioDevices })[which];
            if (!t) return false;
            t.claim("ipc", on);
            return true;
        }
        /** Hyprland: catálogo con efectivo, escrito, origen y deriva; dispositivos; monitores y su regla. */
        function hyprConfig(): string { return JSON.stringify(HyprConfig.summary()); }
        function idleState(): string { return JSON.stringify(Idle.summary()); }
        function netProfiles(): string { return JSON.stringify(NetProfiles.summary()); }
        function integrations(): string { return JSON.stringify(Integrations.summary()); }

        // ---- portabilidad F2a: capacidades (portabilidad/ROADMAP.md §F2) ----------------------
        /** Sólo lectura: estado de la detección y cada capacidad efectiva (con lo forzado). */
        function caps(): string { return JSON.stringify(Capabilities.summary()); }
        /** Redetectar ahora; con una detección en curso, la repite al terminar. */
        function capsRefresh(): bool { return Capabilities.refresh("ipc"); }
        /** Forzar una capacidad SIN persistir (available|degraded|unavailable|unknown); "" lo quita. */
        function capsForce(id: string, state: string): bool { return Capabilities.force(id, state); }
        /** PRUEBAS: otro intérprete bajo /tmp/ (inexistente = sin python3; uno que duerme = timeout); "" = python3. */
        function capsTestPython(path: string): bool { return Capabilities.setTestPython(path); }
        /** F2e, PRUEBAS: lo que hace una acción que falló (`suspect`): redetecta, como mucho una vez cada 10 s. */
        function capsSuspect(id: string): bool { return Capabilities.suspect(id, "ipc test"); }

        // ---- portabilidad F3b: la terminal del usuario, en seco ------------------------------
        /** Ir a un workspace: el mismo camino que un clic en el island (`Hypr.focusWorkspace`, forma del dialecto). */
        function workspace(id: int): bool { return Hypr.focusWorkspace(id); }

        /**
         * F5a, SÓLO BANCO: cerrar la sesión de Hyprland por `Power.logout()` (el `exit` del dialecto). Se niega
         * salvo que el entorno de la shell traiga SUMI_TEST_HYPR_SIG igual a su propia firma de Hyprland, que
         * sólo pone el banco anidado (tools/f5/): en la sesión real no existe y no hace nada.
         */
        function logoutTest(): bool {
            const want = Quickshell.env("SUMI_TEST_HYPR_SIG") || "";
            if (!want.length || want !== (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "")) {
                console.warn("logoutTest: only inside the nested test bench");
                return false;
            }
            return Power.logout();
        }

        /**
         * F5d, SÓLO BANCO: el botón Suspend de verdad (`Power.suspend()`: bloquear antes si nadie retiene la suspensión).
         * Misma guarda que `logoutTest`: sólo con SUMI_TEST_HYPR_SIG = la firma de la propia shell, que pone el banco
         * anidado, cuyo PATH lleva un `systemctl` falso que nunca suspende. En la sesión real se niega y no hace nada.
         */
        function suspendTest(): bool {
            const want = Quickshell.env("SUMI_TEST_HYPR_SIG") || "";
            if (!want.length || want !== (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "")) {
                console.warn("suspendTest: only inside the nested test bench");
                return false;
            }
            return Power.suspend();
        }
        /** F8c bench only: all power calls are redirected to a private fake system bus. */
        function f8cAllowed(): bool {
            const bus = Quickshell.env("DBUS_SYSTEM_BUS_ADDRESS") || "";
            return Quickshell.env("KT_F8C") === "1" && bus.startsWith("unix:path=/tmp/dbus-")
                && Quickshell.env("SUMI_TEST_HYPR_SIG") === Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE");
        }
        function f8cPowerTest(action: string): bool {
            if (!f8cAllowed()) return false;
            if (action === "probe") { Power.probeCapabilities(); return true; }
            if (action === "reboot") return Power.reboot();
            if (action === "shutdown") return Power.shutdown();
            if (action === "hibernate") return Power.hibernate();
            if (action === "suspend") return Power.suspend();
            return false;
        }
        function f8cModeTest(wanted: bool): bool {
            if (!f8cAllowed()) return false;
            root.f8cModeOutcome = null;
            Session.claimModeIdle(wanted, result => root.f8cModeOutcome = result);
            return true;
        }
        function f8cModeState(): string { return JSON.stringify(root.f8cModeOutcome || {}); }

        /** F5a: el dialecto de la config de Hyprland según la sonda de HyprCtl (lua|hyprlang|unknown|pending). */
        function hyprDialect(): string { return JSON.stringify(HyprCtl.summary()); }

        /**
         * F5a: lo que la shell le mandaría a Hyprland, SIN mandarlo (tools/f5/argv-before.json D1–D5, M1–M4).
         * `verb` = focusWorkspace · moveSilent · focusWindow · exit · dpms (con `args` en JSON) o `hot` con
         * {"key": blur|animations|cursors|glass, "value": …}; "" = todos con las entradas fijas de los vectores
         * (workspace 3, special:minimized y 4, dirección 0x55aa01). Pasa por las MISMAS funciones que lo real.
         */
        function hyprForm(verb: string, args: string): string {
            let a = {};
            try { a = args.length ? JSON.parse(args) : {}; } catch (e) { return JSON.stringify({ error: "bad JSON" }); }
            const one = (v, x) => v === "hot" ? HyprCtl.hotConfigArgs(x.key, x.value) : HyprCtl.form(v, x);
            if (verb.length)
                return JSON.stringify({ dialect: HyprCtl.dialect, effective: HyprCtl.effective, form: one(verb, a) });
            const addr = "0x55aa01";
            return JSON.stringify({ dialect: HyprCtl.dialect, effective: HyprCtl.effective, forms: {
                D1: one("focusWorkspace", { workspace: 3 }),
                D2: one("moveSilent", { workspace: Toplevels.minimizedWs, address: addr }),
                D3: one("moveSilent", { workspace: 4, address: addr }),
                D4: one("focusWindow", { address: addr }),
                D5: one("exit", {}),
                M1: one("hot", { key: "blur", value: false }), M2: one("hot", { key: "animations", value: true }),
                M3: one("hot", { key: "cursors", value: false }), M4: one("hot", { key: "glass", value: { enabled: 0, blur: 1 } })
            } });
        }

        /**
         * El argv que lanzaría cada sitio de terminal, SIN lanzar nada, con entradas de ejemplo fijas
         * (tools/f3/fixtures/terminal-argv-before.json). `site` = launch · launchWd · action · run ·
         * openPath · clean · update · updatesList · calcurse; "" = todos. Pasa por las MISMAS
         * funciones que el lanzamiento real.
         */
        function terminalArgv(site: string): string {
            const btop = { id: "btop", command: ["btop"], workingDirectory: "" };
            const sites = {
                launch: () => ({ argv: Apps.termLaunchArgv(btop), scope: btop.id }),
                launchWd: () => ({ argv: Apps.termLaunchArgv({ id: "btop", command: ["btop"], workingDirectory: "/tmp" }), scope: "btop" }),
                action: () => ({ argv: Apps.termActionArgv({ command: ["nvim", "--clean"] }), scope: "nvim" }),
                run: () => ({ argv: Apps.termRunArgv(["htop"]), scope: "htop" }),
                openPath: () => ({ argv: Apps.termOpenArgv({ id: "micro", command: ["micro"] }, "/tmp/kt-f3b/notes.txt"), scope: "micro" }),
                // F3d-1: de la tarea (null si no está declarada)
                clean: () => ({ argv: Commands.terminalArgvOf("clean"), scope: Apps.terminalName }),
                update: () => ({ argv: Updates.updateArgv(), scope: Apps.terminalName }),
                updatesList: () => ({ argv: Updates.listArgv(), scope: Apps.terminalName }),
                calcurse: () => ({ argv: Apps.calcurseArgv(), unit: Apps.calcurseUnit })
            };
            const out = { terminal: Apps.terminal, label: Apps.terminalLabel, setting: Settings.appTerminal,
                          exec: Settings.appTerminalExec, why: Apps.terminalWhy, sites: {} };
            for (const k in sites) if (site === "" || site === k) out.sites[k] = sites[k]();
            return JSON.stringify(out);
        }
        /**
         * F3b, PRUEBAS SÓLO EN EL BANCO (lanzan de verdad; nunca en la sesión real): `cmd` en la
         * terminal por el MISMO camino que ⇧⏎ del lanzador (`Apps.run(argv, true)`). Las palabras van
         * separadas por espacios (qs ipc parte las listas). Devuelve lo que devuelve `Apps.run`.
         */
        function terminalRunTest(cmd: string): bool {
            const argv = String(cmd || "").split(" ").filter(x => x.length > 0);
            return argv.length > 0 && Apps.run(argv, true);
        }
        /**
         * F3e, PRUEBAS SÓLO EN EL BANCO (lanza de verdad): la aplicación `id` (.desktop, sin la extensión)
         * por el MISMO camino que el lanzador (`Apps.launch`): con `Terminal=true`, en la terminal del usuario.
         */
        function appLaunchTest(id: string): bool {
            const src = DesktopEntries.applications.values;
            for (let i = 0; i < src.length; i++)
                if (src[i] && src[i].id === id) return Apps.launch(src[i]);
            return false;
        }
        /**
         * ADR-32: el argv con el que el lanzador abriría la aplicación `id` (y sus acciones), SIN lanzar,
         * junto al `command` de Quickshell para compararlos. `id` = "" recorre todas las entradas y
         * devuelve sólo las que difieren (`total` = cuántas se miraron). Seguro en la sesión real.
         */
        function appArgv(id: string): string {
            const src = DesktopEntries.applications.values;
            const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
            const row = (e, a) => {
                const x = a || e;
                const qs = x.command ? Array.from(x.command) : [];
                const argv = Apps.argvOf(x);
                return { id: e.id + (a ? "#" + a.id : ""), exec: String(x.execString || ""), quickshell: qs, argv: argv,
                         differs: !same(qs, argv), wd: String(e.workingDirectory || ""), terminal: !!e.runInTerminal };
            };
            const out = [];
            let total = 0;
            for (let i = 0; i < src.length; i++) {
                const e = src[i];
                if (!e || (id !== "" && e.id !== id)) continue;
                const rows = [row(e, null)];
                for (let j = 0; e.actions && j < e.actions.length; j++)
                    if (e.actions[j]) rows.push(row(e, e.actions[j]));
                for (const r of rows) { total++; if (id !== "" || r.differs) out.push(r); }
            }
            return JSON.stringify({ total: total, rows: out });
        }
        /** F3b, PRUEBAS SÓLO EN EL BANCO: el conmutador de calcurse (abre o cierra su scope). */
        function calcurseToggleTest(): bool { return Apps.calcurseWhy().length === 0 && Apps.toggleCalcurse(); }

        // ---- portabilidad F3c: el navegador del usuario ---------------------------------------
        /**
         * Lo que lanzaría el web hub para `url` (o una búsqueda de `sumi shell` con "search"), SIN
         * lanzar: la misma `Web.browserArgv` y el mismo nombre de scope que `Web.openUrl`.
         */
        function webArgv(url: string): string {
            const u = url === "search" ? Web.searchUrl("sumi shell") : (url || "https://example.org/");
            return JSON.stringify({ browser: Web.browser, label: Web.labelOf(Web.browser), setting: Settings.appBrowser,
                                    why: Web.browserWhy, argv: Web.browserArgv(u), scope: Web.browser,
                                    confPath: Web.confPath, confState: Web.confState, error: Web.lastError,
                                    categories: Web.categoryCount, pages: Web.pageCount });
        }
        /** F3c, PRUEBAS SÓLO EN EL BANCO (abre de verdad): `Web.openUrl(url)`; devuelve la revisión. */
        function webOpenTest(url: string): int { return Web.openUrl(url); }
        /** F3c: el estado de la última apertura (`Web.ops`, clave «open»). Sólo lectura. */
        function webOpenState(): string { return JSON.stringify(Web.ops.get("open")); }

        // ---- 14B: pruebas de sistema con vuelta atrás ---------------------------------------
        /** Pruebas: sólo salidas cuyo nombre case con `regex` (el guard lo impone). "" lo quita. */
        function sysTestOnly(regex: string): string { SystemTest.testOnly = regex; return SystemTest.testOnly; }
        /**
         * Pruebas del guard: probar una salida con vuelta atrás (15 s). Se niega sin `sysTestOnly`:
         * nunca una pantalla real. Displays es sólo lectura (2026-09-29); el guard lo usarán los
         * perfiles de audio.
         */
        function displayTest(output: string, mode: string, x: int, y: int, scale: real, transform: int): bool {
            if (SystemTest.testOnly.length === 0) { console.warn("displayTest: set sysTestOnly first"); return false; }
            const p = {};
            p[output] = { mode: mode, position: x + "x" + y, scale: scale, transform: transform };
            return SystemTest.start("displays", p, Hypr.focusedName, "Keep these display settings?");
        }
        /**
         * 14D, pruebas: guardar `props` (JSON) en el perfil `uuid` por el mismo camino que Settings
         * (directo o con prueba y checkpoint). Se niega sin `sysTestOnly` o si el nombre del perfil
         * no casa con él: por IPC sólo se tocan perfiles de prueba. Necesita `sysClaim net true`.
         */
        function netSave(uuid: string, props: string): bool {
            const p = NetProfiles.byUuid(uuid);
            if (SystemTest.testOnly.length === 0 || !p || !new RegExp(SystemTest.testOnly).test(p.name)) {
                console.warn("netSave: set sysTestOnly to a regex that matches the profile first");
                return false;
            }
            let o;
            try { o = JSON.parse(props); } catch (e) { return false; }
            return NetProfiles.save(uuid, o, Hypr.focusedName);
        }
        function netUndo(): bool { return NetProfiles.undo(Hypr.focusedName); }
        /** 14E: plazos de hypridle. `idleManage` mueve los dos listeners (true) o los devuelve (false). */
        function idleManage(on: bool): bool { return Idle.manage(on, Hypr.focusedName); }
        /** 14E: segundos (0 = nunca); se aplica tras 0,9 s sin otro cambio. Necesita `sysClaim idle true`. */
        function idleSet(lock: int, screenOff: int): bool {
            return Idle.setTime("lock", lock, Hypr.focusedName) && Idle.setTime("screenOff", screenOff, Hypr.focusedName);
        }
        function idleUndo(): bool { return Idle.undo(Hypr.focusedName); }
        /**
         * 14F, pruebas: probar el perfil `profile` en la tarjeta `card` (nombre ALSA) con vuelta atrás.
         * Se niega sin `sysTestOnly` o si no casa con el nombre de la tarjeta. Necesita `sysClaim audio true`.
         */
        function audioProfileTest(card: string, profile: string): bool {
            if (SystemTest.testOnly.length === 0 || !new RegExp(SystemTest.testOnly).test(card)) {
                console.warn("audioProfileTest: set sysTestOnly to a regex that matches the card first");
                return false;
            }
            return AudioDevices.testProfile(AudioDevices.cards.find(c => c.name === card) || null, profile, Hypr.focusedName);
        }
        function sysTestKeep(): bool { return SystemTest.keep(); }
        function sysTestRevert(): bool { return SystemTest.revert(); }
        function sysTestState(): string {
            return JSON.stringify(Object.assign(SystemTest.summary(), { countdowns: Object.keys(SystemTest.layers)
                .map(n => ({ screen: n, visible: SystemTest.layers[n].visible, pick: SystemTest.layers[n].pick,
                             keyboard: SystemTest.layers[n].focusedHere, secs: SystemTest.layers[n].secs })) }));
        }
        /** Pruebas: `Escape` `Left` `Right` `Tab` `Return` `Space` en la cuenta regresiva de la pantalla enfocada. */
        function sysTestKey(name: string): bool {
            const l = SystemTest.layers[Hypr.focusedName];
            return !!l && l.key(name);
        }
        function sysmonTestRoot(path: string): bool { return Sysmon.setTestRoot(path); }
        function sysmonTestPoll(): bool { return Sysmon.testing && Sysmon.poll(); }

        /** Sólo lectura (fase 5D): la fila elegida por identidad y las filas (dirección o «scan»). */
        function btState(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("bluetooth") : null;
            if (!it) return "{}";
            return JSON.stringify({ selected: it.selected, selKey: it.selKey, count: it.count,
                                    scanning: Bt.scanWanted, keys: it.rows.slice(0, 8).map(r => it.keyOf(r)) });
        }

        function minimizerState(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("minimizer") : null;
            if (!it) return "{}";
            const rows = [];
            for (let i = 0; i < it.count; i++) {
                const w = it.wins[i];
                rows.push({ key: it.keyOf(w), title: String(w.title), minimized: w.minimized === true });
            }
            return JSON.stringify({ selKey: it.selKey, sel: it.sel, count: it.count,
                                    goneNote: it.goneNote, thumbs: it.thumbs, rows: rows });
        }

        /** F2e, PRUEBAS: escribir en el lanzador abierto en `mon` (no lanza nada: eso es Enter). */
        function launcherType(text: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("launcher") : null;
            return it ? it.typeForTest(text) : false;
        }
        function launcherState(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("launcher") : null;
            if (!it) return "{}";
            const rows = [];
            for (let i = 0; i < Math.min(it.resultCount, 8); i++) {
                const r = it.results[i];
                const open = (r && r.id) ? Toplevels.windowsFor(r.id).length : 0;
                rows.push(String(r.name) + (open > 0 ? " [" + open + " open]" : ""));
            }
            return JSON.stringify({ query: it.query, selected: it.selected, count: it.resultCount,
                                    actionsOf: it.actionEntry ? String(it.actionEntry.id) : "",
                                    selHasActions: it.selHasActions, hint: it.selHasActions || it.actionEntry !== null,
                                    windowsOf: it.windowsEntry ? String(it.windowsEntry.id) : "", zone: it.zone,
                                    footer: it.footerActions.map(a => a.id), footerIdx: it.footerIdx,
                                    rows: rows });
        }

        /** Abre el journal de una unidad en su superficie. */
        function unitJournal(unit: string, mon: string): bool {
            const sc = Screens.resolve(mon);
            if (!sc) return false;
            if (!Units.loadJournal(unit)) return false;
            return sc.openSurfaceWith("serviceJournal", unit);
        }

        /**
         * TEMA (10.c.4). `name` = un esquema corto (`vibrant`, `tonal-spot`, …)
         * o `static`. No calcula color: llama a `services/Colors`, que a su vez
         * ejecuta `minimaru theme <name>` / `matugen_toggle.sh` (ADR-28).
         */
        function themeSet(name: string): bool {
            if (name === "static") return Colors.setStatic();
            return Colors.setScheme(name);
        }

        /**
         * Paletas estáticas (F-c, 2026-11-04): poner un preset de sumi/palettes/ (`catppuccin-mocha`,
         * `gruvbox-light`…) de una vez, sin preview. `false` si el id no existe o el proveedor no lo hace aquí.
         */
        function themePreset(name: string): bool {
            return Colors.setPreset(name);
        }

        /**
         * 12A, la preview reversible del tema (`services/ThemePreview`). `themePreview <perfil>`
         * la empieza o la cambia desde la pantalla enfocada (desde otra, traslada el control);
         * TOCA LAS SALIDAS REALES de matugen salvo con `themePreviewTestRoot`. `true` = aceptado;
         * el resultado, en `themePreviewState`.
         */
        function themePreview(profile: string): bool {
            return ThemePreview.preview(profile, Hypr.focusedName);
        }
        /** 12A, pruebas de traslado: la misma petición, como si viniera de `mon`. */
        function themePreviewFrom(profile: string, mon: string): bool {
            return ThemePreview.preview(profile, mon);
        }
        /** 12F: la misma petición con modo (dark|light), contraste (-1…1) y origen (wallpaper|#rrggbb). */
        function themePreviewWith(profile: string, mode: string, contrast: string, source: string): bool {
            return ThemePreview.preview(profile, Hypr.focusedName, { lightness: mode, contrast: contrast, source: source });
        }
        function themeKeep(): bool { return ThemePreview.keep(); }
        function themeRevert(): bool { return ThemePreview.revert("Reverted"); }
        /** 12A: reintentar una restauración que falló (el registro sigue en disco). */
        function themeRetry(): bool { return ThemePreview.retry(); }
        /** 12A, sólo lectura: fase, perfiles (confirmado, pedido, en preparación, puesto), error. */
        function themePreviewState(): string { return JSON.stringify(ThemePreview.summary()); }
        /**
         * 12B, sólo lectura: la vista de Visual Profiles en `mon` — abierta, perfil seleccionado,
         * zona del teclado, acción enfocada, acciones (off = deshabilitada), texto de estado,
         * si la prueba la lleva otra pantalla, y el estado de las muestras.
         */
        function themePicker(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc ? sc.surfaceItem("theme") : null;
            if (!it) return JSON.stringify({ loaded: false, samples: ThemeSamples.summary() });
            const a = it.actions[it.actIndex];
            return JSON.stringify({
                loaded: true, open: it.open, selected: it.selected, pos: Math.round(it.pos * 100) / 100,
                zone: it.zone, focusedAction: it.zone === "actions" && a ? a.id : "",
                actions: it.actions.map(x => x.id + (x.on ? "" : "(off)")), status: it.statusText,
                elsewhere: it.elsewhere, samples: ThemeSamples.summary()
            });
        }
        /** 12D, sólo lectura: presets (integrados y tuyos, grupos, copias) y el estado aplicado. */
        function presets(): string { return JSON.stringify(Presets.summary()); }
        /** 12D, PRUEBAS: carpeta de presets, copias y estado bajo /tmp/ ("" = lo real). Aplicar sí escribe Settings. */
        function presetsTestRoot(path: string): bool { return Presets.setTestRoot(path); }
        /** 12E, sólo lectura: último export/import, el análisis en curso (cambios, omitidos, faltan). */
        function portability(): string { return JSON.stringify(Portability.summary()); }
        /** 12E: analizar un archivo (no aplica nada). */
        function portabilityAnalyze(path: string): bool { return Portability.analyze(path); }
        /** 12E, PRUEBAS: exports y copias bajo /tmp/ ("" = lo real). Importar sí escribe Settings. */
        function portabilityTestRoot(path: string): bool { return Portability.setTestRoot(path); }
        /** 12A, PRUEBAS: árbol de matugen falso (sólo bajo /tmp/); "" = lo real. */
        function themePreviewTestRoot(path: string): bool { return ThemePreview.setTestRoot(path); }

        /**
         * PERFIL DE ESCRITORIO (10.c.5). `normal` / `focus` / `gaming` /
         * `cinema`. `gaming` y `cinema` paran `sumi-shell` salvo si el shell es
         * el servidor de notificaciones (ADR-29) — por IPC va con `-y` (sin
         * confirmación; la confirmación es del dashboard). El shell
         * llama a `desktop-mode.sh`, no reimplementa su lógica (ADR-13).
         */
        function modes(): string { return JSON.stringify(Modes.summary()); }
        function modeRefresh(): bool { return Modes.refresh(); }
        function modeRetry(): bool { return Modes.retry(); }
        function modeTestRoot(path: string): bool { return Modes.setTestRoot(path); }
        function modeTest(profile: string): bool { return Modes.testing && Modes.set(profile); }
        function mode(profile: string): bool {
            return Modes.set(profile);
        }

        /**
         * NOTIFICACIONES (ADR-29). Solo tienen algo que hacer con el servidor del
         * shell encendido; apagado, la lista esta vacia y todo devuelve false.
         * Los mismos verbos existen en `notif-probe.qml`, para que
         * `tools/notif-noloss.sh` hable igual con la sonda que con el shell.
         *   notifList                   rastreadas, con el cuerpo tal como se pinta
         *   notifAction <id> <accion>   lo mismo que su boton (ActionInvoked)
         *   notifActivate <id>          lo mismo que el clic en el cuerpo
         *   notifDismiss <id>           lo mismo que la X
         * Del centro (Fase 2):
         *   notifRows                   las filas del centro tal como se pintan (JSON)
         *   notifExpand <grupo> <bool>  desplegar/plegar un grupo (`app:<nombre>`)
         *   notifDismissEntry <clave>   descartar una fila (viva o restaurada)
         *   notifClearAll · notifDnd <bool> · notifDndToggle
         *   notifReply <id> <texto>     responder en linea (NotificationReplied)
         */
        function notifList(): string { return Notifs.listJson(); }
        function notifAction(id: int, action: string): bool { return Notifs.actionById(id, action); }
        function notifActivate(id: int): bool { return Notifs.activateById(id); }
        function notifDismiss(id: int): bool { return Notifs.dismissById(id); }
        function notifRows(): string { return NotifHistory.rowsJson(); }
        function notifExpand(key: string, on: bool): bool { NotifHistory.setExpanded(key, on); return true; }
        function notifDismissEntry(key: string): bool { return NotifHistory.dismiss(key); }
        function notifClearAll(): bool { return NotifHistory.clearAll(); }
        /**
         * Fase 7B, pruebas: la MISMA pregunta de Clear all del centro abierto en `mon`,
         * pero capturando sólo las entradas de apps de prueba (`kt-…`), para no
         * descartar avisos vivos del usuario. Se contesta por teclado como la real.
         */
        function notifTestClearAsk(mon: string): bool {
            const sc = Screens.resolve(mon);
            const it = sc && sc.open === "notifications" ? sc.surfaceItem("notifications") : null;
            if (!it || !it.engaged) return false;
            const keys = NotifHistory.entries.filter(function (e) { return e.app.startsWith("kt-"); })
                                             .map(function (e) { return e.key; });
            return it.askClear(keys);
        }
        /** Fase 7E-1, sólo lectura: lo que enseña el Centro de control de `mon`. */
        function controlCenterState(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc && sc.open === "controlCenter" ? sc.surfaceItem("controlCenter") : null;
            return it ? it.stateJson() : JSON.stringify({ open: false });
        }
        /** Fase 7E-2, pruebas: la pregunta de Clear all del Centro de control, sólo sobre entradas kt-…. */
        function ccTestClearAsk(mon: string): bool {
            const sc = Screens.resolve(mon);
            const it = sc && sc.open === "controlCenter" ? sc.surfaceItem("controlCenter") : null;
            if (!it) return false;
            return it.askClear(NotifHistory.entries.filter(function (e) { return e.app.startsWith("kt-"); })
                                                   .map(function (e) { return e.key; }));
        }
        /** Fase 7E-1, sólo lectura: el brillo (pantallas con DDC, bus, valor, cola, ops). */
        function brightness(): string { return JSON.stringify(Brightness.summary()); }
        /**
         * 8G-1: brillo DESDE FUERA (atajo, script), con OSD en esa pantalla. `percent` 0-100.
         * Cambia el brillo REAL del monitor (DDC): no es un verbo de prueba.
         */
        function brightnessSet(percent: int, mon: string): bool {
            const sc = Screens.resolve(mon);
            return sc ? Brightness.setExternal(sc.name, percent / 100, false) : false;
        }
        /** 8G-1: un paso (±puntos, p. ej. 5 o -5) sobre el brillo de esa pantalla, con OSD. */
        function brightnessStep(delta: int, mon: string): bool {
            const sc = Screens.resolve(mon);
            return sc ? Brightness.setExternal(sc.name, delta / 100, true) : false;
        }
        /** 8G-1, sólo lectura: el OSD de esa pantalla y su banda sobre un panel abierto. */
        function osdState(mon: string): string {
            const sc = Screens.resolve(mon);
            return sc ? JSON.stringify(sc.osdInfo()) : "{}";
        }
        /**
         * Fase 7D, sólo lectura: la fila de Settings con el foco (id) y si el campo de ciudad edita.
         * 9A: también destino (surface), página que se ve, zona del teclado (content | nav),
         * entrada de la sidebar con el foco, si el marco está en modo estrecho, y el
         * deslizamiento de la página (slideX, opacity) para medir el relevo.
         */
        function settingsFocus(mon: string): string {
            // Settings UI (2026-11-07): el contenido de la ventana flotante de esa pantalla
            const it = Screens.settingsItemOn(mon);
            if (!it) return JSON.stringify({ open: false });
            const f = it.flat[it.kbIndex];
            const lf = it.pathFields["city"];
            const navKey = it.navKeys[it.navIndex] || "";
            return JSON.stringify({ open: true, surface: it.dest, dest: it.destId, page: it.shownKey,
                                    zone: it.zone, nav: navKey,
                                    query: it.query, results: it.results.length, searchSel: it.searchSel,
                                    selected: it.results[it.searchSel] ? it.results[it.searchSel].path || it.results[it.searchSel].label : "",
                                    fieldFocus: it.zone === "search",
                                    compact: it.compact, scroll: Math.round(it.saveContext().scrollOf[it.shownKey] || 0),
                                    slideX: Math.round(it.slideX * 10) / 10, paneOpacity: Math.round(it.paneOpacity * 100) / 100,
                                    row: f && f.row ? f.row.id : f && f.disc ? "disclosure:" + f.disc : (f ? "banner" : ""),
                                    // 12G: lo que dice la fila enfocada (pie y motivo), para probar sin capturas
                                    rowCaption: f && f.row ? it.captionOf(f.row) : "",
                                    rowReason: f && f.row ? it.rowReason(f.row) : "",
                                    expanded: Object.keys(it.expanded),
                                    cityEditing: lf ? lf.editing : false, cityPick: lf ? lf.pick : -1,
                                    // 8F-2
                                    dock: it.dockOn, barHere: it.barHere,
                                    // 12C: la página Colors — selección, motivos de cada fila y estado
                                    theme: { selected: it.themeSelected, status: it.themeStatus,
                                             why: { preview: it.themeWhyNot("preview"), keep: it.themeWhyNot("keep"),
                                                    revert: it.themeWhyNot("revert"), regenerate: it.themeWhyNot("regenerate") } },
                                    preview: it.dockPreviewItem ? { playing: it.dockPreviewItem.playing,
                                                                    phase: it.dockPreviewItem.phase } : null });
        }
        /**
         * 9A: abrir Settings en una página, y opcionalmente con el foco en una fila:
         * `shell/general`, `theme/colors`, `system/about`, `shell/calendar/city`. Es el mismo
         * camino que un enlace contextual (futureSettingssurface §3): abre la surface de ese
         * destino y enfoca. false si la ruta no existe.
         */
        function settingsOpen(path: string, mon: string): bool { return Screens.settingsOpenOn(path, mon); }
        /**
         * Portabilidad F2b, sólo lectura (pruebas sin capturas): las secciones abiertas de la página
         * que se ve, con lo que dice cada fila (valor, pie, motivo y tono). `{open:false}` si no hay Settings.
         */
        function settingsRows(mon: string): string {
            const it = Screens.settingsItemOn(mon);
            if (!it) return JSON.stringify({ open: false });
            return JSON.stringify({ open: true, page: it.shownKey, sections: it.blocks.filter(b => b.open).map(b => ({
                title: b.section.title, rows: b.rows.map(r => ({ id: r.id, kind: r.kind, name: r.name,
                    value: r.kind === "info" ? it.infoValue(r) : "", caption: it.captionOf(r),
                    reason: it.rowReason(r), tone: r.tone || "" })) })) });
        }
        /**
         * 9B, pruebas: escribir en «Search settings» como si se tecleara (abre Settings si
         * hace falta; "" limpia). Devuelve los resultados: ruta, etiqueta, breadcrumbs, valor
         * o motivo. No abre ninguno: eso es Enter.
         */
        function settingsSearch(query: string, mon: string): string {
            const sc = Screens.resolve(mon);
            if (!sc) return "[]";
            if (!Screens.settingsItemOn(mon) && !sc.openSurface("settings")) return "[]";
            const it = Screens.settingsItemOn(mon);
            if (!it) return "[]";
            if (query.length === 0) it.endSearch(true);
            else { it.endSearch(false); it.startSearch(query); }
            return JSON.stringify(it.results.map(e => ({ path: e.path, label: e.label, crumbs: e.crumbs,
                                                        value: it.reasonOf(e) || it.valueOf(e), kind: e.kind })));
        }
        /**
         * Settings UI independiente (2026-11-07), sólo lectura: la ventana (abierta, pantalla, posición,
         * tamaño, si el contenido está cargado, la distribución que se ve) y su vista guardada.
         */
        function settingsUiState(): string { return JSON.stringify(SettingsUi.summary()); }
        /** Una tecla por el mismo camino que el teclado (Escape, Tab, Down, «Alt+Left», «Ctrl+F»…), sin inyectar nada. */
        function settingsUiKey(name: string, shift: bool): bool {
            return !!SettingsUi.layer && SettingsUi.layer.key(name, shift);
        }
        /** Mover la ventana (se queda dentro del monitor, bajo la franja del island o de la barra). */
        function settingsUiPlace(x: int, y: int): bool { return !!SettingsUi.layer && SettingsUi.layer.placeAt(x, y); }
        /** Cambiar su tamaño, en px (como la esquina; sólo de la sesión). */
        function settingsUiResize(w: int, h: int): bool { return !!SettingsUi.layer && SettingsUi.layer.resizeTo(w, h); }

        /**
         * 9E-1, sólo lectura: el Mixer unificado de esa pantalla — foco del teclado (id estable),
         * plegables, lista de focos, reproductor activo y si está sonando.
         */
        function mixerFocus(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc && sc.open === "mixer" ? sc.surfaceItem("mixer") : null;
            if (!it) return JSON.stringify({ open: false });
            return JSON.stringify({ open: true, focus: it.focusId, apps: it.appsOpen,
                                    picking: it.picking, focusList: it.focusList,
                                    player: Media.sourceName, playing: Media.playing, title: Media.title,
                                    position: Math.round(Media.positionSec),
                                    // 9E-2: el fondo musical
                                    art: Media.artUrl, backdrop: it.backdropInfo(),
                                    // 13E: qué salida edita el EQ de la vista y lo que enseña
                                    eqDev: it.eqDev, eqWord: it.eqWord, eqView: it.eqView });
        }
        /** Fase 7D, sólo lectura: el clima (estado, consumidores, consultas lanzadas, dato, búsqueda, ops). */
        function weather(): string { return JSON.stringify(Weather.summary()); }
        /** Fase 7D, pruebas: un consumidor más (el Lock de la fase 15 aún no existe). `who` va con prefijo «ipc:». */
        function weatherClaim(who: string, on: bool): int { return Weather.claim("ipc:" + who, on); }
        /** Fase 7D, pruebas: otra API. Sólo `http://127.0.0.1:…` (un puerto cerrado = sin red); "" = Open-Meteo. */
        function weatherTestBase(url: string): bool {
            if (url.length > 0 && !url.startsWith("http://127.0.0.1:")) return false;
            Weather.testBase = url;
            return true;
        }
        /** Fase 7D: pedir ya (como al vencer). Devuelve la revisión, 0 si no está configurado. */
        function weatherRefresh(): int { return Weather.refresh(); }
        /** Fase 7C, sólo lectura: lo que enseña el calendario abierto en `mon` (fecha, agenda, detalle). */
        function calendarState(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc && sc.open === "calendar" ? sc.surfaceItem("calendar") : null;
            return it ? it.stateJson() : JSON.stringify({ open: false, agenda: Agenda.summary() });
        }
        /**
         * Fase 7C, pruebas: la agenda lee `calcurse -D <dir>` (datos de prueba) en vez de
         * los del usuario. Sólo bajo /tmp/ (el scratchpad de la sesión): nunca apunta
         * -D a un directorio del usuario. "" = los datos reales.
         */
        function agendaTestDir(dir: string): bool {
            if (dir.length > 0 && !dir.startsWith("/tmp/")) return false;
            Agenda.testDir = dir;
            return true;
        }
        /**
         * Fase 7C, pruebas: otro binario en lugar de calcurse ("" = el real). Sólo un
         * nombre `kt-…` (que no existe: simula que no está instalado) o un guion de
         * prueba bajo /tmp/ (lento, que falla): nunca un programa cualquiera.
         */
        function agendaTestBinary(name: string): bool {
            if (name.length > 0 && !name.startsWith("kt-") && !name.startsWith("/tmp/")) return false;
            Agenda.testBinary = name;
            return true;
        }
        /** Fase 7A, sólo lectura: lo que el centro de `mon` tiene seleccionado y abierto. */
        function notifCenterState(mon: string): string {
            const sc = Screens.resolve(mon);
            const it = sc && sc.open === "notifications" ? sc.surfaceItem("notifications") : null;
            if (!it) return JSON.stringify({ open: false });
            return JSON.stringify({ open: true, preview: sc.preview, engaged: it.engaged,
                                    selKey: it.selKey, replyKey: it.replyKey, rows: it.rowCount,
                                    readArmed: it.readArmed,
                                    confirm: it.confirming ? { count: it.confirmKeys.length,
                                                               focus: it.confirmFocus === 1 ? "clear" : "cancel" } : null });
        }
        /**
         * Fase 7A, pruebas: el borrador de respuesta de una entrada, como si se
         * hubiera tecleado ("" = tirarlo). Sólo en apps de prueba (`kt-…`): nunca
         * toca una conversación real. Nada se envía.
         */
        function notifTestDraft(key: string, text: string): bool {
            const e = NotifHistory.entry(key);
            if (!e || !e.app.startsWith("kt-")) return false;
            if (text.length > 0) Drafts.set(NotifHistory.draftKeyOf(key), text);
            else Drafts.discard(NotifHistory.draftKeyOf(key));
            return true;
        }
        // Lo usa `desktop-mode.sh`: cuenta como puesto por el modo (7E-1, `dndSource`).
        function notifDnd(on: bool): bool { return NotifHistory.setDnd(on, "mode"); }
        function notifDndToggle(): bool { return NotifHistory.toggleDnd(); }
        function notifReply(id: int, text: string): bool { return Notifs.replyById(id, text); }
        /**
         * El ajuste del servidor (ADR-29), escrito por su unico escritor (Settings).
         * Solo lo usa `scripts/notif-server`, que hace el cambio completo: el ajuste
         * solo no basta (se lee al arrancar y SwayNC tiene que salir). Devuelve si
         * hace falta reiniciar para que cuente.
         */
        function notifServer(on: bool): bool { Settings.notificationServer = on; return Notifs.restartPending; }

        function unload(): void {
            const list = Screens.list;
            for (let i = 0; i < list.length; i++)
                if (list[i]) list[i].unloadClosed();
        }

        /**
         * Modo de movimiento para PROBAR (rediseño, P-05): `normal`, `reduced`, `off`, o
         * `""` para volver al ajuste guardado. No se persiste y una recarga lo borra:
         * hasta la fase 3 el único ajuste es `reduceMotion`, y `off` no tiene fila.
         */
        function motion(mode: string): string {
            if (["", "normal", "reduced", "off"].indexOf(mode) < 0) {
                console.warn("ipc motion: unknown mode", mode);
                return Motion.mode;
            }
            Motion.override = mode;
            return Motion.mode;
        }

        /**
         * Estilo de interfaz para PROBAR (ADR-34): `soft`, `terminal`, o `""` para volver al ajuste guardado. No se
         * persiste y una recarga lo borra, como `motion`. Devuelve el estilo efectivo y lo que de él leen los tokens.
         */
        function style(name: string): string {
            if (name !== "" && Style.names.indexOf(name) < 0) {
                console.warn("ipc style: unknown style", name);
                return JSON.stringify({ error: "unknown style", name: Style.name });
            }
            Style.override = name;
            return JSON.stringify({ name: Style.name, rMd: Metrics.rMd, openCorner: Metrics.openCorner,
                                    pill: Metrics.pill(20), ui: Typography.ui, frame: Style.now.frame,
                                    decor: Style.now.decor });
        }

        /**
         * 9C-1, pruebas: Global speed sin guardarlo (0 = volver al ajuste). Devuelve la
         * velocidad efectiva y los tiempos que salen de ella.
         */
        function motionSpeed(v: real): string {
            if (v !== 0 && (v < 0.75 || v > 1.5)) return JSON.stringify({ error: "0.75–1.5, or 0" });
            Motion.speedOverride = v;
            return JSON.stringify({ speed: Motion.speed, standard: Motion.standard, vanish: Motion.vanish,
                                    calmMs: Motion.calmMs, springStiff: Math.round(Motion.springStiff * 1000) / 1000,
                                    dampFirm: Math.round(Motion.dampFirm * 1000) / 1000 });
        }

        /** R1 / I-4: una recarga con la sesión bloqueada no se acepta (docs/lock/SERVICIOS.md §4). */
        function reload(): void {
            if (Lock.engaged) {
                console.warn("lock: reload refused while the screen is locked");
                return;
            }
            Quickshell.reload(false);
        }
    }
}
