# Sysmon ampliado (11E-1)

Ejecutar con `PYTHONDONTWRITEBYTECODE=1` y Python 3, secuencialmente:

- `test-collector.py`: proc/sysfs, lsblk/statvfs y reloj falsos. CPU total/núcleos sin contar
  guest dos veces, swap, ausencia, reinicios de contadores, interfaces, dos GPU y desaparición,
  montaje/desmontaje simulado, bind/subvolúmenes, UUID duplicado de dos ext4 y Btrfs multidisco;
  PID reutilizado, nombres con paréntesis, cadencia y límite de procesos. No usa el shell vivo.
- `probe.py`: Quickshell offscreen en `/tmp/sumi-sysmon-probe`, Session/Units falsos y el
  servicio/recolector reales. Historial de 60 s mediante reloj de prueba, paginación sin repetir,
  datos actuales = último punto, procesos del instante elegido, dos consumidores, summary,
  reposo/reanudación y muerte del propietario sin recolector huérfano. Requiere sockets locales.
- `unshare --user --map-root-user --mount --fork python3 mount-test.py`: monta un alias de
  sólo lectura de la carpeta del proyecto dentro de un namespace privado. Lo añade a los
  puntos del mismo volumen sin duplicar capacidad y lo desmonta. No usa sudo ni afecta a los
  montajes de la sesión. Requiere namespaces de usuario habilitados.

Sondas **interactivas autorizadas**, sólo sobre el despliegue de esta entrega:

- `live-test.py`: IPC con sensores reales y varios consumidores, abre/cierra el Monitor anterior
  y captura JPEG q80 tras comprobar lockStatus y ausencia de hyprlock; ausencia mediante testRoot
  vacío, luego retirada. Exige empezar sin reclamaciones. Copias previas en antes-11e1.
- `window-test.py`: consumidor IPC de detalle durante 66 s reales, ventana y procesos acotados,
  coincidencia current/último punto, expiración del primer ID y atribución histórica. Lo suelta
  en finally. No modifica CPU, energía, dispositivos ni preferencias.

No hay datos persistentes nuevos. El contrato completo y el IPC paginado están en docs/IPC.md.
Las pruebas no implementan gráficas: la interfaz ampliada es la entrega 11E-2.

## Interfaz de System Monitor (11E-2)

> **Registro histórico desde antes de la fase 12:** la surface ya no despliega tarjetas ni elige
> muestras. `monitor-live-test.py` está escrita para la 11E-2 (espera pliegues y selección de
> muestras que ya no existen): no ejecutarla contra el código actual;
> `monitor-ui-probe.py` se adaptó a la surface compacta (sección siguiente).

- `monitor-ui-probe.py` (11E-2): UI real con servicios sustituidos, backend de 11E-1 y fixtures.
  Dos vistas, procesos históricos frente a una muestra nueva, hover independiente, caducidad,
  retirada de GPU, datos ausentes, batería/periférico, 880/600 px y escala 1,25. Sin tocar
  settings ni outputs reales. Usa su propio socket IPC y `QT_QPA_PLATFORM=offscreen`.
- `monitor-live-test.py`: sólo lectura, Performance → Monitor → Performance por teclado,
  identidad de cifras/procesos, Back/Forward, detalles y liberación a summary / cero.
  Cada tecla/captura comprueba unlocked, ausencia de hyprlock y vista abierta; empieza con ↓.
  No ejecuta modos ni cambia energía. Requiere sesión desbloqueada, qs, wtype y grim;
  capturas JPEG q80 bajo `~/Pictures/rediseno-fase11/11e2-*`, cierre en finally.

`probe.py` tolera que el temporizador adquiera una lectura entre dos llamadas IPC: espera la
liberación antes de pedir la siguiente. Un poll ocupado no es un fallo del recolector.
Ratón y Shift se comprueban manualmente; la sonda sólo valida el estado que consume el hover.

## Surface compacta y UI de inspección (antes de la fase 12, M1–M4)

Contrato en `docs/IPC.md` §«La UI de inspección y la surface compacta». Secuencialmente:

- `test-collector.py` (7 pruebas): además del 11E-1, el nivel `inspect` — lista entera con
  comando/usuario/clave, top sin comando, sensores por chip y tipo (ventiladores a 0, voltajes),
  límites NVMe imposibles (65262 °C) como «sin límite» y lecturas fuera de rango descartadas,
  clase media de 2 s, proceso elegido (`ok`, E/S por delta, `gone` si cambia el arranque), caché
  y swap in/out; `busyPct` por io_ticks y temperatura NVMe del grupo.
- `probe.py`: además, tendencia de 5 s (11–13 cubos en 66 s), detail ↔ inspect sin cambiar
  generación ni historial, liberación de lo propio de inspect, alerta de temperatura sólo tras
  10 s sostenidos y alerta de lectura perdida.
- `monitor-ui-probe.py` (adaptada, M4): la surface compacta con dos GPU, un solo Disks con
  volúmenes, Enter = Details en su sección (la surface pide cerrarse), flechas por fila, Tab
  hasta Inspect, 800/600 px y escala 1,25, aviso de temperatura sostenida (no de un pico),
  retirada de GPU (seis tarjetas caben sin desplazarse), dos vistas y datos ausentes.

Sondas **interactivas autorizadas** (sesión desbloqueada, `qs`, empiezan sin reclamaciones y
sueltan todo en finally; no cambian energía, modos ni procesos):

- `inspect-live-test.py`: inspect por IPC con datos reales (lista, sensores, foco) y su coste
  medido por nivel (shell y recolector); vuelta a detail sin reiniciar; liberación total.
- `monitor-ui-live-test.py`: la UI por IPC — una instancia (atajo con `hyprctl dispatch`, IPC,
  Details), pausa que congela la vista y no el muestreo, ventanas 60 s…1 h, teclas por
  `monitorUiKey` (sin inyectar), búsqueda/orden/selección y foco, arrastre acotado y recordado,
  Esc con la surface abierta sin perder historial.
- `compact-live-test.py`: por teclado real (`wtype`, con sonda ↓ y comprobación de bloqueo,
  hyprlock y surface abierta antes de cada tecla): Enter en Network → UI/Network con la misma
  generación, Tab hasta Inspect, y Dashboard → Performance → Inspect. Captura JPEG q80 en
  `~/Pictures/rediseno-antes12/`.
