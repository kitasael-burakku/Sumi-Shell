# Pruebas del motor de modos (11D-1)

Ejecutar secuencialmente desde este directorio con Python 3: `probe.py`,
`extended-probe.py`, `edge-tests.py`, `fault-tests.py`, `session-probe.py` y
`video-tests.py`. Requieren Quickshell, Qt, timeout y acceso a sockets locales.

Todas las mutaciones de modos usan ejecutables falsos y archivos de `/tmp`.
`probe.py` copia el motor real a una configuración mínima y sustituye sus servicios;
`session-probe.py` copia Session completo, con Settings falso y systemd-inhibit falso.
Esta última conecta a Wayland, con Keep awake falso y sin ventana visible.
Ninguna prueba aplica modos ni inhibidores reales o reinicia servicios.

Las cajas `/tmp/sumi-mode-probe` y `/tmp/sumi-session-probe` conservan el log y
las llamadas a los sustitutos. No correr dos pruebas del motor simultáneamente.
`video-tests.py` crea sockets mpv de prueba; comprueba respuestas con eventos delante,
restauración individual y errores. Los recorridos reales requieren autorización del usuario.

## Performance (11D-2)

`performance-live.py` es una sonda **interactiva del shell desplegado**, no una prueba
para ejecutar a ciegas. Necesita `probe.py` ejecutada antes (genera los sustitutos),
la 11D-2 desplegada, HDMI-A-1 desbloqueado y autorización para usar el teclado. Verifica
`lockStatus`, ausencia de hyprlock, surface abierta y testRoot antes de cada tecla/captura.
Guarda JPEG q80 en `~/Pictures/rediseno-fase11/11d2-*`; restaura el backend real y cierra
sus vistas al terminar. No aplica modos reales ni escribe perfiles energéticos reales.

Cubre selección por flechas/Tab, aplicación con Enter, progreso sin Active, partial,
Unavailable, Retry/Back to normal, DND manual, CLI/IPC/Centro de control y su enlace,
energía checking/absent/degraded/held/pending/error, System Monitor→Back (Alt+Left),
y fallo del snapshot con reintento. `performanceTestPower` prueba la presentación de
energía; sus controles reales quedan bloqueados mientras Modes tenga testRoot.

`fault-tests.py` añade el reintento después de la escritura fallida idéntica: una revisión
por guardado evita que FileView omita la segunda escritura y deje Applying para siempre.
