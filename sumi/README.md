# Sumi Shell

Notas de desarrollo e historia del rediseño de Sumi Shell para Hyprland. Las referencias a fases y ADR
describen el contexto de cada cambio. El [README principal](../README.md), la [guía del instalador](../packaging/INSTALL.md)
y el [informe de aceptación](../docs/PORTABILITY-ACCEPTANCE.md) describen la instalación y el alcance vigentes.

El rediseño incluía el Lock de tres columnas con hyprlock de respaldo. El servidor de notificaciones
y el agente de polkit se pueden activar por separado. Ambos vienen desactivados en una instalación nueva.

## Ejecutar

```sh
qs -c sumi                                  # primer plano (log en la terminal)
systemctl --user restart sumi-shell         # como servicio (habilitado; máx. 5 arranques/60 s)
systemctl --user reload sumi-shell          # Quickshell.reload(false) vía IPC
journalctl --user -u sumi-shell -f
```

Una instalación de usuario coloca este árbol en `$XDG_CONFIG_HOME/quickshell/sumi`. El paquete Arch lo instala
en `/etc/xdg/quickshell/sumi`. Consulta la [resolución de configuraciones de IPC](../API.md#calling-the-ipc).

## IPC

El [contrato de IPC](../API.md) enumera los verbos públicos. `qs -c sumi ipc show` y `core/Ipc.qml` incluyen
también verbos internos y de prueba. Algunos ejemplos de desarrollo:

```sh
qs -c sumi ipc call sumi toggle launcher ""   # "" = monitor enfocado
qs -c sumi ipc call sumi open settings HDMI-A-1
qs -c sumi ipc call sumi close ""             # "" = cualquier superficie abierta
qs -c sumi ipc call sumi status | jq          # pid, rssKb, pantallas, avisos, notifs…
qs -c sumi ipc call sumi peek ""              # la cara hover sin puntero
qs -c sumi ipc call sumi wallRandom images    # all | images | videos
qs -c sumi ipc call sumi notifDnd true        # No molestar, persistente
qs -c sumi ipc call sumi mixerVolume playback 0 30
```

`open` es idempotente (`true` aunque ya esté abierta); nombre o monitor desconocidos →
`false` y un `console.warn`. El monitor `""` se resuelve: enfocado → primera pantalla,
nunca "ninguno". **Los atajos no usan el IPC** sino `GlobalShortcut` (ver *Atajos*); el IPC
es para scripts, la CLI `minimaru` y las pruebas.

## Tema

El shell **no tiene modo de tema**: lee `colors.json` y sigue lo que haya dentro (ADR-12).
Quien decide el contenido es el pipeline del rice.

```
matugen (con ~/.config/matugen/enabled)  ─┐
                                          ├─►  colors.json  ──► services/Colors ──► theme/Theme
hypr/scripts/apply-static-colors.sh      ─┘     (generado)             ▲
   (al apagar el toggle, SUPER+SHIFT+W)                                │
                                                colors.static.json (versionado, fallback)
```

`colors.static.json` es la paleta Minimaru y el fallback **token a token**: si el
dinámico falta, no parsea o trae un hex inválido, ese token cae al estático sin arrastrar
al resto. Un token que falte en los dos sale magenta a propósito — es una rotura de
paridad, y `check-template-parity.sh` la reporta.

Cambiar la paleta: `minimaru theme <scheme>`, `SUPER+SHIFT+W` (toggle) o cualquier cambio
de wallpaper. El island re-tiñe en ~75 ms sin reiniciar.

**Probar antes de cambiar (rediseño 12A–12C, 2026-09-28).** Visual Profiles (el carrusel,
`theme`) y Settings → Theme → Colors sólo **seleccionan**; **Preview** pone el perfil en TODAS
las salidas de `matugen/config.toml` sin tocar `matugen/scheme` ni el sentinel, y **Keep changes**
/ **Revert** deciden. Lo lleva `services/ThemePreview` con `scripts/theme-preview.py`: genera las
salidas con una config derivada (a `$XDG_RUNTIME_DIR/sumi-theme-preview`, sin `post_hook`),
guarda una copia exacta de lo vigente en `$XDG_STATE_HOME/sumi-shell/theme-preview/`, instala
de forma atómica y lanza las recargas con plazo. Revert repone sólo los archivos que siguen
llevando la preview (un fondo nuevo que regeneró gana); cerrar el último control abierto de la
prueba revierte; si el shell muere, al arrancar se restaura. Las muestras de las tarjetas son
`matugen --dry-run` con caché en `~/.cache/sumi-theme-samples/`. Static usa la lista de
`apply-static-colors.sh --list`.

**Modo, contraste y color de origen (12F).** El tema confirmado es perfil + `matugen/mode`
(dark | light) + `matugen/contrast` (-1…1) + `matugen/source` (wallpaper | #rrggbb), que
`matugen_reload.sh` lee junto a `scheme`; sin esos archivos, lo de antes. Se eligen en Settings →
Theme → Colors y pasan por la misma preview (`ThemePreview`: clave `perfil|modo|contraste|origen`).
Light cambia además `color-scheme`/`gtk-theme` de gsettings (copia y restauración como los archivos),
y cuando lo confirmado cambia sin prueba abierta (p. ej. SUPER+SHIFT+W a Static) el shell los alinea
con el modo. Las muestras del carrusel se calculan con las opciones en curso.

**Fondo por pantalla (12G).** El rice guarda desde el 2026-09-23 las excepciones por pantalla en
`hypr/.current-wallpaper-outputs`; colores (matugen) y fondo del lock siguen SIEMPRE al fondo de
todas (`.current-wallpaper`), salvo con un color de origen propio (12F). Con más de una pantalla,
Wallpaper List tiene un destino visible **All screens / This screen** (clic o `M`; `⏎` aplica al
destino, `⇧⏎`/clic derecho al otro) y la ayuda dice de dónde siguen saliendo los colores; una
pantalla con fondo propio ofrece **Use shared** (`U`) → `apply-wallpaper.sh --clear <salida>`.
Settings → Theme → Wallpaper → *Screens* lista cada pantalla (propio o compartido), las
desconectadas que conservan uno para cuando vuelvan, y el origen de los colores
(`Wallpaper.paletteOrigin`). Con una sola pantalla no hay nada que separar: el rice lo trata como
«todas».

Añadir un token: la clave va en los **tres** sitios —
`matugen/templates/sumi-shell-colors.json`, `colors.static.json` y `services/Colors.qml`
(la property y su `tok("...")`) — y el checker de paridad cubre los dos primeros.

## Presentaciones: nombres públicos e identificadores (2026-11-24)

La UI y la documentación pública usan nombres propios; el código, el esquema, el IPC y la CLI conservan los
identificadores de siempre, así que las configuraciones guardadas no se migran.

| Nombre público | Antes | Identificadores internos (sin cambios) |
| --- | --- | --- |
| **Dynamic Capsule** | Dynamic Island | `presentation: "island"`, `core/Island.qml`, `island*` (props, `shell.island.*`, `family: "island"`) |
| **Dynamic Bar** | Persistent bar | `presentation: "bar"`, `barMode`, `core/Bar.qml`, `barToggle`, `bar*` |
| **Edge** | Notch | `monitors[id].dock`, `dockMode`, página `shell/dock`, `notch*` (`shell.notch.*`, `Metrics.notch*`), `status().presentation: "dock"` |
| **Bar-Edge** | Bar-notch | `barDock` (`presentation: "bar"` + `dock` a la vez), `Metrics.reservedBarDockH` |

Al redactar texto visible: «capsule» para la forma de Dynamic Capsule, «Edge» como nombre propio (sin artículo
cuando se nombra el modo) y «Dynamic Bar» para el modo; «notch» sólo para describir la forma, nunca como nombre.
La muesca del greeter de Sumi SDDM es otra pieza: su nombre público es **Login Edge** (autenticación en la pantalla
de inicio, no una presentación de la shell). Sus grupos y claves (`notch`, `notchColor`, `notch*`) y sus etiquetas los
define el esquema de Sumi SDDM (`sumi-sddm config schema`), que esta shell muestra tal cual; aquí sólo son nuestros
los nombres de las escenas de la vista previa (`services/SddmTheme.allScenarios`) y las descripciones de Settings.

Ojo con el parecido: `barEdge`, `BarEdge` y `lib/bar-edge.js` son el **borde de pantalla** donde va la barra (fila
«Position» de Layout), no la presentación Bar-Edge.

## El island

**Rest** (rediseño del 2026-09-15): **sólo la hora, en el centro exacto**, y un visualizador de
audio en espejo a sus lados (5 barras por lado) mientras suena un reproductor MPRIS. En silencio
o en pausa las barras desaparecen y el island vuelve a medir lo mínimo (144 px). A la derecha,
únicamente los avisos de **privacidad** (micrófono, pantalla compartida): son alarmas, no estado,
y miden 0 px sin nada que avisar; mientras uno está encendido, un contrapeso vacío del mismo ancho
a la izquierda mantiene la hora centrada.

Salieron del reposo, a propósito: los dots de workspace, el título de lo que suena (lo dice la
tarjeta de media) y los indicadores de notificaciones, actualizaciones, bandeja, bluetooth y red.
Todo sigue en la cara hover. Una primera versión los dejaba en el reposo con contrapeso, y el
island quedaba largo y medio vacío: el usuario eligió «indicadores sólo en hover».

**Hover** (~825 px medidos): va en **bloques** desde el 2026-09-16, y el orden dice algo — *a la
izquierda dónde estás, en medio lo que haces, a la derecha lo que pasa*:

```
espacio │ tiempo │ buscar · medios · sistema · sesión │ estado
```

`espacio` los dots de workspace (clicables; el activo es una barra en el acento) · `tiempo` hora y
fecha · `buscar` lanzador, portapapeles, web, ventanas · `medios` música, fondo, tema, audio ·
`sistema` calendario, sensores, servicios, CLI · `sesión` café, ajustes, panel, apagar · `estado`
bluetooth, red, avisos, bandeja, batería. El bloque bajo el puntero se realza, y el cursor de
teclado (←/→) sigue **este mismo orden**.

Antes eran 21 iconos monocromos en una fila con tres reglas sueltas. Bluetooth y red se mudaron de
en medio al bloque de estado: informan más de lo que se pulsan, y partían en dos la fila de
acciones. Siguen abriendo su superficie al pulsarlas.

**El island habla** (2026-09-16). Ya no se apaga para que salga otra cosa en su sitio: **se
convierte** en lo que tiene que decir, ensanchándose sin cambiar de alto.

| Estado | Ancho | Qué |
|---|---|---|
| `osd` | 248 px | volumen y micrófono — era una cápsula aparte que apagaba el island |
| `notice` | según el texto | «Network disconnected», «Battery low · 12 %», «ES · Spanish», con su tono |

`sumi ipc call sumi announce "texto" glifo tono` lo dispara a mano (tonos: ok · warn ·
danger · info). Fuentes automáticas: red caída, batería baja, comprobación de actualizaciones
fallida — todas con 6 s de espera tras arrancar para no saludar con avisos en cada reinicio —, y
el cambio de distribución de teclado (2026-09-24, `Hypr.keyboardLayout`): 1,2 s, sin espera, y sin
pisar un aviso `warn`/`danger`. Sustituye a `kb-layout-notify.py`, cuya notificación se quedaba en
el centro.

~~**Visualizador**~~ *(retirado en la fase 15H, 2026-09-30: su único consumidor era el Lock, y el panel nuevo no lo tiene —LOCK-D13—; queda como historia)* (`services/Cava.qml`): `cava` sin interfaz, lanzado directamente (sin `sh -c`)
con su config en `$XDG_RUNTIME_DIR/sumi-cava.conf`, y **sólo mientras `Media.playing`**: al
pausar, 3 s de gracia y el proceso se para; en silencio no cuesta nada. Un juego o un vídeo sin
MPRIS no mueve las barras. Fotogramas en *Ajustes → Island → Audio visualizer* (off / 15 / 30 /
60; por defecto 30, decisión del usuario). Medido con música, shell entero en `tools/measure.sh`:

| fps | CPU (de un núcleo) |
|---|---|
| 15 | +1,9 % |
| 30 | +3,8 % (+10,7 MB, casi todo cava) |
| 60 | +5,9 % |

Las barras no llevan `Behavior`: lo liso lo da el suavizado de cava y el island se repinta a los
fps elegidos, no a 200 Hz. Para PipeWire, cava es una captura de audio más y encendería el aviso
rojo: el shell lo lanza con `PIPEWIRE_PROPS='{ sumi.visualizer = true }'` y `Privacy` excluye
**sólo** los nodos con esa marca. OBS, el visualizador de maly o un cava lanzado a mano siguen
avisando.

**Las dos caras tienen presupuestos distintos, y es deliberado:**

| Cara | Presupuesto | |
|---|---|---|
| `rest` | **fijo** | Está siempre delante. Un aviso sin nada que avisar mide 0 px, y `hyprland/window` se descartó por costar 308 px permanentes. |
| `hover` | **abierto** | Sólo existe con el puntero encima. Es la vía de integración por ratón: **cada superficie nueva gana aquí su botón**, y que crezca es su función. |

Al añadir una superficie: el botón va **siempre** a `hover`. A `rest` sólo va una **alarma**
(algo que no puede esperar a que acerques el puntero); el estado vive en `hover`. Ver ADR-16.

Todo sale de los modelos tipados de Quickshell: **ni un solo `hyprctl` por evento**.

**Avisos** (Fase 9.b). La regla es la del propio `waybar/config.jsonc` y es literal — **un aviso
sin nada que avisar mide 0 px**. Costes medidos con `grim` cuando vivían en el reposo: island
desnudo 143 px, notificaciones +27, actualizaciones +31, micrófono +16.

| Aviso | Dónde | Cuándo aparece |
|---|---|---|
| 󰹑 / 󰍬 privacidad | rest y hover | hay un nodo de Pipewire capturando pantalla o audio (salvo el visualizador del propio shell) |
| 󰂚 / 󰂛 notificaciones | hover, **siempre** | la campana es permanente; con número si hay no leídas, tachada con No molestar |
| 󰚰 / 󰀦 actualizaciones | hover | hay pendientes, **o** la comprobación falló |

**Bandeja** (Fase 9.c): el shell es el `StatusNotifierWatcher` del sistema — ese papel lo tenía
Waybar y al morir se lo llevó. Desde el rediseño del reposo los iconos viven sólo en la cara
hover, con un punto rojo cuando la aplicación pide atención. Medido: ~20,7 px por icono, lineal.

Son clicables: izquierdo activa, central es la acción secundaria, la rueda hace
scroll y el derecho abre el menú. **El menú lo dibuja el shell** (`components/TrayMenu.qml`) con
el vidrio y los colores del rice, consumiendo el DBusMenu que publica la aplicación — no se
reinventa el menú, sólo su pintura (ADR-24). Soporta separadores, casillas, iconos y submenús;
éstos sustituyen la lista y añaden una fila `‹ Atras`, en vez de desplegarse en cascada.
Probado a tres niveles: udiskie → `/dev/sda` → `Browse / Unmount / Eject / Unpower`.

No hace falta ordenar el arranque de los clientes: se re-registran solos cuando el watcher
vuelve, así que reiniciar el shell no deja la bandeja vacía.

**System Monitor**, dos niveles desde antes de la fase 12 (`rediseno/Antes-de-fase-12.md`, M1–M4):

- **Surface compacta** (`Super+Y`, 800×612 lógicos, una columna bajo 640): el vistazo. Seis
  tarjetas — CPU, GPU (una por GPU), memoria, red, discos (uno solo, con los volúmenes más llenos
  primero) y energía —, cada una con su valor de ahora, uno o dos secundarios y una micrográfica de
  60 s. **Details ↗** (clic, o `Enter` con la tarjeta elegida) abre la UI de inspección en esa
  sección y cierra la surface; **Inspect** abre su Overview. Una tarjeta sólo avisa con una alerta
  sostenida de Sysmon. `Tab` / flechas recorren, `Esc` cierra. Procesos, núcleos, montajes y el
  recorrido de muestras pasados (11E-2) viven ahora en la UI.
- **UI de inspección** (`Super+Ctrl+Y`, `core/MonitorLayer` + `services/MonitorUi`): ventana
  flotante del shell como la tienda de Wallhaven (capa `Top`, `sumi-monitor`, 1040×700 ×uiScale
  acotada al monitor, arrastre por la cabecera, una sola instancia; pedirla en otra pantalla la
  trae). Secciones Overview, CPU, GPU, Memory, Processes, Disks, Network y Sensors; ventanas de
  60 s, 5 m, 15 m y 1 h; **Pause** congela la vista (no el muestreo) y **Resume live** vuelve al
  presente. Processes busca por nombre/comando/usuario/PID, ordena por CPU, memoria, PID o nombre,
  oculta hilos del kernel y muestra la ficha del elegido (sin acciones sobre procesos); mientras el
  puntero está sobre la lista el orden se mantiene. Teclado al pulsar dentro: `1`–`8` secciones,
  `Espacio` pausa, `/` busca, `Esc` cierra. Sólo la sección visible está instanciada.
  Dashboard → Performance tiene **Inspect** junto a *Open System Monitor*.

**No muestrea mientras nadie mira.** Desde la 11E-1, `services/Sysmon` comparte reclamaciones
con nombre: `summary` lee CPU/RAM/temperatura cada 5 s, `detail` reúne métricas cada segundo,
historial de 60 s y procesos como máximo una vez cada 3 s; `inspect` (la UI) añade la lista entera
de procesos cada 2 s (hasta 4096 / 250 ms), sensores hwmon cada 2 s, frecuencia por núcleo y el
proceso elegido. Pasar de detail a inspect y volver no reinicia el recolector ni el historial.
Mientras haya un detail o inspect, Sysmon agrega cubos de 5 s (media y máximo) hasta 1 h: la
tendencia empieza al abrir una vista y se suelta al cerrar la última (decisión del usuario del
2026-09-27). Las alertas (`lib/monitor-alerts.js`, único sitio de umbrales) piden condiciones
sostenidas. Sin consumidores no hay recolector; cerrar el último
consumidor de detalle libera historial, tendencia y procesos, aunque siga una barra con summary.
Inactividad, cambio de nivel o recarga reinician los deltas: la primera tasa es desconocida,
no cero. `scripts/sysmon-collect.py` es de sólo lectura y termina por EOF al perder al shell.

Cada muestra tiene id de generación y secuencia, reloj monotónico, instante y duración de
lectura. `current` y la última muestra histórica son el mismo paquete. CPU total y por núcleo,
RAM/swap, GPU detectadas por DRM, interfaces activas y discos/volúmenes se publican juntos;
`null` significa sin datos. Los alias de compatibilidad usan NaN internamente; la vista muestra No data y la barra —.
Las gráficas y sus cifras leen la misma muestra seleccionada, distinta del resumen Now.

Volúmenes por sistema de archivos, puntos de montaje deduplicados y grupos de discos de
origen (también varios propietarios para un volumen lógico). Capacidad disponible usa
`f_bavail`; E/S se atribuye por dispositivo, con tasas desconocidas al empezar o reiniciar
contadores. Inventario al cambiar mountinfo o cada 5 s; sin SMART continuo, salud unchecked.
GPU sin sensor conserva el dato null; atribución de procesos de GPU se declara Unavailable.

Procesos: hasta 512 PID o 50 ms de lectura, top 10 de CPU y memoria con intervalo mínimo de 3 s; selección parcial
se etiqueta. Identidad PID + starttime evita atribuir un PID reutilizado al proceso anterior.
CPU de proceso ofrece porcentaje de un núcleo y de la máquina; memoria ofrece bytes y
porcentaje. `processSampleId` enlaza la muestra cercana anterior, nunca una lista del futuro.
Historial máximo 60 muestras / 60 s y 21 paquetes de procesos, sólo en memoria. No crea
archivos de estado. Contrato e IPC: docs/IPC.md; sondas en `quickshell/tests/sysmon/`.

El IPC entrega el historial por páginas de hasta ocho muestras, con presupuesto de 32K caracteres JSON;
los paquetes de procesos se consultan por la muestra elegida. Se evita superar el tamaño de
respuesta de qs y duplicar listas de procesos en cada punto. CPU térmica se descubre por nombre
de hwmon (`k10temp`, `coretemp`, `zenpower`), GPU por DRM, sin reutilizar scripts de Waybar.

El disco muestra lo **disponible**, no `total − usado`: en este equipo hay 47 GiB de bloques
reservados para root y la diferencia son 47 GiB de mentira.

**Mezclador** (Fase 9.e, `SUPER+CTRL+A`): salida, entrada y **volumen por aplicación**, que es
más de lo que daban Waybar y `audio.sh` juntos — aquél sólo sabía hacer `wpctl set-default`.
Cada fila tiene su icono de silencio, su porcentaje y su deslizador (arrastrar, pulsar, o rueda
con el mismo paso del 2 % que tenía `scroll-step`).

**Sin indicador permanente**, por decisión de la entrevista: el OSD de la Fase 5 cubre el eco de
las teclas de volumen, que es cuando de verdad hace falta ver el número. `services/Audio` sigue
siendo el dueño del sink por defecto y del OSD; `services/Mixer` es la vista completa y sólo
vive mientras la superficie está abierta.

**Rutas por aplicación (rediseño 13A, sólo lectura).** `services/AudioRoutes` dice, por flujo, a
qué dispositivo llega de verdad (los enlaces, atravesando los filtros del EQ), qué destino le ha
pedido alguien (metadatos `default` de PipeWire, con `pw-metadata -m`) y cuál le restaurará
WirePlumber la próxima vez (`~/.local/state/wireplumber/stream-properties`, por aplicación, no por
flujo). Los dos lectores externos sólo corren con el Mixer reclamado. Los nodos de un filtro smart
no se ofrecen ni como salida ni como aplicación. `ipc call sumi audioRoutes` lo enseña todo.

**Salida por aplicación (13B).** En Applications, bajo cada app que suena, **Output** elige a qué
salida va (Default + las salidas), con el ratón o con ←/→/Enter en su fila. Es lo mismo que haría
`pactl move-sink-input`: WirePlumber lo recuerda para esa aplicación y lo aplica a sus flujos
nuevos; **Default** la devuelve a la predeterminada y olvida la preferencia. La fila dice
«Changing to X…» hasta que los enlaces lo confirman, el error con la ruta que quedó, o la
preferencia pendiente de una salida desconectada. No toca la salida predeterminada ni volúmenes.

**Entrada por aplicación (13C).** Lo mismo para las apps que graban: **Input** bajo su fila, sólo
con más de una entrada (o si la app ya tiene preferencia). Las entradas virtuales
(`Audio/Source/Virtual`: el micro de EasyEffects u OBS, una supresión de ruido) cuentan como
entradas; Quickshell 0.3.1 no les da control de volumen, así que su porcentaje sale como «—».

**Ecualizador (13D, el motor).** Cada salida puede tener su EQ: un filtro de `filter-chain` de
PipeWire (preamp + diez bandas peaking de octava, 31 Hz…16 kHz) que WirePlumber interpone solo en
todo lo que va a esa salida. Los perfiles son `~/.config/sumi-shell/audio-eq.json`; de ellos
`scripts/audio-eq.py` genera `~/.config/pipewire/filter-chain.conf.d/kitasan-eq.conf` y lleva
`filter-chain.service` (habilitado sólo mientras hay perfiles). Vive fuera del shell: recargarlo
no corta nada; si el servicio cae, la salida suena directa y la Audio UI dice por qué. Ganancias y
On/Off cambian en vivo; añadir o quitar una salida reinicia el servicio (un instante sin EQ).
Grabar el monitor de una salida ecualizada da la señal SIN ecualizar (WirePlumber lleva esa
captura al filtro). Vuelta atrás completa: `scripts/audio-eq.py remove`.

**Audio en dos niveles (antes de la fase 14, `rediseno/Antes-de-fase-14.md`).** La surface es el
control inmediato y la configuración vive en la **Audio UI** (`Super+Shift+A`, `core/AudioLayer` +
`services/AudioUi`): una ventana flotante del shell como la del monitor (capa `Top`,
`sumi-audio`, 1000×660 ×uiScale acotada al monitor, arrastre por la cabecera, una instancia;
pedirla en otra pantalla la trae). Secciones:

- **Overview**: salida, entrada, aplicaciones y ecualizador en cuatro cifras que llevan a su
  sección; los dos volúmenes; quién suena o graba.
- **Output / Input**: el dispositivo predeterminado entre los disponibles, volumen, **balance** (sólo
  estéreo FL/FR; el canal más alto conserva el volumen) y canales; la tarjeta, perfil, puerto y
  formato **en lectura** (cambiarlos es de la fase 14); en Output, su ecualizador; en Input, el
  estado con palabras (sin dispositivo, silenciada, en reposo, grabando, sin control) y quién graba.
- **Applications**: los flujos agrupados por aplicación, con volumen, silencio y la misma ruta
  por app que la surface (el selector vive en `AudioRoutes`).
- **Equalizer**: la salida siempre explícita (sigue a la predeterminada si no se elige otra; una
  elegida que se desconecta sigue elegida como «not connected»), On/Off, una **curva estática** con
  la respuesta real del filtro (línea = bandas; discontinua = con el preamp, roja si pasa de 0 dB),
  preamp (−12…0 dB) y diez bandas (±12 dB) con su valor en dB siempre a la vista. Arrastrar es
  relativo (no salta al pulsar) en pasos de 0,5 dB, Mayús 0,1; clic sin arrastrar fija ese valor;
  doble clic 0 dB; rueda ±0,5. Presets Flat, Bass, Treble, Vocal, Pop, Rock, Jazz, Classic y
  **Custom**: tocar una banda o el preamp pasa a Custom (un Custom por salida, con su última curva).
  **Reset bands** (bandas a 0), **Reset preamp** (preamp a 0) y Flat (todo); «May clip» con
  **Lower preamp to …**; *Saving… / Saved* dice si el archivo ya lo tiene. Lo que no suena así
  (apagado, arrancando, error, salida desconectada) se atenúa y dice «Not applied».
- **Devices**: las tarjetas en lectura (perfil activo y los que ofrece, puertos enchufados o no,
  sus salidas y entradas con canales y formato) y los dispositivos virtuales. `pw-dump` a demanda:
  al abrir Output, Input o Devices, al cambiar los nodos y cada 4 s mientras se ve.

Teclado al pulsar dentro: `1`–`6` secciones, `↑`/`↓` (o `Tab`) recorren, `←`/`→` ajustan, `Enter`
activa, `Esc` cierra; el contorno del foco sólo aparece tras usar el teclado. En la surface, del
ecualizador queda una fila (interruptor, preset de la salida predeterminada y **Open ↗**); Output e
Input llevan **Details ↗**, y `D` abre la UI en la sección de lo enfocado (la surface se cierra).
Settings → System → Audio enlaza **Audio settings**, **Per-app devices** y **Equalizer** a la UI.
Cerrada, la UI no reclama nada (Mixer ni tarjetas); medido: 0,05 % de un núcleo cerrada, ≈0 % en
Overview y Equalizer, 0,25–0,35 % en Output y Devices.
El preamp de los presets deja el PICO real de la curva en 0 dB o menos (bandas vecinas sumadas:
Bass −7,5, Treble −6,5, Vocal y Pop −5,5, Rock −6, Jazz −3,5), y «May clip» calcula ese pico.
Una fila de ruta que falló dice «Retry»: clic o Enter repiten lo pedido.

**Calendario**: `SUPER+C` abre **Hoy** (hora, fecha y clima, con Open calendar) y `SUPER+CTRL+C`
la **Calendar UI**: mes navegable con la rueda o `←`/`→` (`Home` vuelve a hoy), semanas ISO a la
derecha y la agenda del día. Desde 2026-10-28 la agenda junta los **eventos locales** de la shell
—**New event** (`N`), **Edit** (`E`) y **Delete** (`Supr`, con confirmación), guardados en SQLite
(`$XDG_DATA_HOME/sumi-shell/calendar/events.sqlite3`, por `scripts/calendar-store.py`)— y, si
está instalado, calcurse en sólo lectura, marcado como tal; Open calcurse sigue en el pie. Un
borrador sin guardar sobrevive a cerrar la tarjeta. Desde la segunda entrega del mismo día: **Repeat**
(diario, semanal por días, mensual, anual; cada N; hasta una fecha o N veces) con alcance al editar o
borrar una ocurrencia (ésta, ésta y siguientes, toda la serie), **Reminder** (avisos por el servidor de
notificaciones de la shell, sin repetirse tras reiniciar; lo perdido en una suspensión se resume) e
**Import / Export** (.ics nuevo; importar un .ics o desde calcurse siempre con vista previa y copia previa
de la base). Desde la tercera entrega: **Accounts** (pie de la Calendar UI) añade cuentas **CalDAV**
(dirección, usuario y contraseña, que va al llavero del sistema por Secret Service, nunca a disco) y
sincroniza en los dos sentidos, local-first: a mano (Sync now, o `R` con el panel abierto), al iniciar
la sesión, al volver la red y cada 15/30/60 min si se elige. Los eventos existentes siguen en «On this
computer»; el editor elige calendario. Un cambio hecho aquí y en el servidor a la vez nunca se pisa:
queda como conflicto con tres salidas (Keep mine, Keep the server's, Keep both). Sin servidor, todo
sigue funcionando y se sube después.

**La cara rest no se clica, y no es un olvido.** Acercar el puntero al island lo pasa a modo
hover y la cara rest se desvanece, así que un `MouseArea` ahí es inalcanzable por construcción.
Lo accionable vive en la **cara hover**, que `SUPER+CTRL+P` asoma sin ratón (flechas y `Enter`):

| Botón (cara hover) | Clic | Clic derecho | Clic central |
|---|---|---|---|
| 󰂚 / 󰂛 notificaciones | abre el centro | alterna DND | limpia el historial |
| 󰚰 / 󰀦 actualizaciones | `sysupdate` en kitty | la lista de paquetes | vuelve a comprobar |

La campana está siempre (también con cero no leídas: es la vía de ratón al centro);
actualizaciones sólo cuando su aviso está activo.

Ninguno calcula nada por su cuenta: notificaciones sale del **servidor propio del shell**
(`services/Notifs` + `NotifHistory`, ADR-29; con el ajuste apagado no hay aviso que dar — hasta
la Fase 4, el 2026-09-22, ahí caía a `swaync-client -swb`),
privacidad de los nodos de Pipewire, y actualizaciones de la misma caché que ya escribe
`hypr/scripts/updates.sh` — que **no se retira**: es tubería del rice con otros dos consumidores
(`updates-check.timer` y `updates-notify-actionable.sh`). Era de Waybar y se mudó ahí en la Fase 11,
con su caché renombrada a `sumi-updates.*`.

Sus dos `notify-send` mandaban `-a "Waybar"`, y como el servidor es el shell desde la Fase 4,
`components/NotifCard` imprimía ese nombre en la tarjeta — el de un programa desinstalado.
Desde el 2026-09-22 mandan `-a "sumi"`, igual que `updates-notify-actionable.sh`, así que
las dos agrupan juntas. El JSON de la caché sigue siendo el formato de Waybar: es el contrato
que lee `services/Updates`.

Con el sistema al día el aviso de actualizaciones desaparece del todo, en vez del `󰄬` que
pintaba Waybar. Es una renuncia consciente de ADR-16, no un olvido.

**OSD de volumen**: cualquier cambio de nivel o de mute lo hace aparecer donde está el
island, que se aparta mientras dura. Sólo en el monitor enfocado. Los iconos son Nerd Font
(los mismos codepoints que usa tu Waybar), no SVG embebido.

## Launcher

Escribe para filtrar; `↑` `↓` mueven, `⏎` lanza, `Esc` cierra. El orden combina la calidad
del match (prefijo > substring > subsecuencia) con cuántas veces has abierto cada cosa,
que se guarda en `~/.local/state/sumi-shell/launcher-usage.json`.

Si lo que escribes es una operación (`12*8+4`), aparece arriba el resultado y `⏎` lo copia
en vez de lanzar nada. El parser es descenso recursivo, **nunca `eval`**: una consulta no
puede ejecutar código.

**Aplicaciones de terminal.** Las entradas con `Terminal=true` (btop, nvim, vim, yazi,
micro, nvtop…) se abren envueltas en `kitty`. Hay que hacerlo a mano: `DesktopEntry.execute()`
de Quickshell 0.3.1 expone `runInTerminal` pero no lo honra, y hasta la parada técnica del
2026-09-08 ninguna de esas ocho aplicaciones arrancaba desde aquí (ADR-26).

**Modo `run`.** Si lo que escribes es el nombre de un ejecutable de tu `$PATH`, aparece arriba
una fila de ejecución: `⏎` lo lanza y `⇧⏎` lo lanza dentro de `kitty`. Nunca se selecciona sola
habiendo aplicaciones que coincidan — se llega con `↑`, o es la única cuando la búsqueda no da
nada. La lista de `$PATH` se construye la primera vez que abres el launcher (3 787 nombres aquí)
y **no se refresca**: si instalas algo con el shell corriendo, hace falta recargarlo.

El troceo del comando es **por espacios y nada más**: sin comillas, sin expansión, sin tuberías,
sin `;`. `foo "a b"` manda tres argumentos, no dos. Es deliberado — se ejecuta con argv, nunca
con `sh -c` (regla 3 de `docs/SECURITY.md`).

No instala nada. Ukishima instala lo que le sueltes encima —paquetes con `pkexec`,
AppImages que ejecuta para desempaquetar—; esa ruta no existe aquí a propósito.

`lib/fuzzy.js` y `lib/calc.js` vienen de Ukishima (MIT); el aviso está en cada archivo y
el texto completo en `lib/LICENSE-ukishima`.

## Media

**Desde el 2026-09-26 (rediseño, 9E-1) Media ya no es una superficie propia:** su tarjeta es la
zona de reproducción de arriba del **Mixer** (`surfaces/Mixer.qml`: reproducción → salida →
resumen del Equalizer → entrada → Applications plegado). `media` queda como ALIAS de `mixer`
(`Screens.canonical`): Super+Ctrl+M, el círculo de Música, la barra, `ipc open|toggle|close media` y
los scripts siguen funcionando, y sólo cambia el foco inicial (transporte por `media`, volumen por
`mixer`). Desde la 9E-2 la zona de reproducción lleva la carátula de fondo
(`components/CoverBackdrop`): ampliada, desenfocada y con un velo oscuro que crece con su
claridad (luminancia media de la carátula a 8×8); fundido al cambiar de pista y el fondo del tema
sin carátula. Lo de abajo describe el servicio y la historia de la tarjeta.

En reposo el island sólo lo insinúa (el visualizador se mueve mientras suena algo; el título
salió del reposo el 2026-09-15). En hover, un botón abre la tarjeta: portada, fuente, título, artista · álbum, una línea de progreso con seek y el
transporte. Con más de un reproductor real, la fuente se vuelve un selector.

Tres decisiones que conviene conocer:

- **Sin red.** El arte es el que publique el reproductor. Ukishima consulta decapi.me y
  netflix.com para adornar Twitch y Netflix; eso cuenta a un tercero lo que estás viendo.
- **Las teclas `XF86Audio*` siguen en `playerctl`**, como las tiene tu rice: funcionan sin
  el shell y no compiten con él por decidir cuál es el reproductor actual. Los verbos IPC
  están por si algún día quieres cambiarlas.
- **Un programa y su backend se ven como uno.** `maly` reproduce a través de su propio
  `mpv` y ambos publican MPRIS con la misma pista. Cuando dos anuncian lo mismo a la vez,
  se conserva el de `uniqueId` menor, que es el programa. Elegir a mano gana siempre.

La posición se sondea sólo mientras la tarjeta está abierta (MPRIS no la emite).

## Wallpapers

El shell **no ejecuta awww ni mpvpaper**: todo apply pasa por
`hypr/scripts/apply-wallpaper.sh`, la misma puerta que usan `minimaru wall` y
`wallpaper.service` (ADR-3). Tras un apply con éxito dispara `matugen_reload.sh`, igual
que hacía el picker de rofi (`wallpaper_grid.sh`, retirado en la Fase 10.e), así que la
paleta sigue al wallpaper por el camino de siempre.

**Un inventario** (rediseño 10A, 2026-09-26) para la tira y Settings → Theme → Wallpaper,
sobre las carpetas de **Sources** (`theme.wallpaper.sources`; por defecto las dos del rice,
`~/Pictures/Wallpapers` y `~/Videos/Wallpapers`). Cada carpeta se escanea a **un nivel** y el
tipo lo da la extensión. Se añaden en Theme → Wallpaper → Folders → *Add a folder* (se
comprueba que existe, que es una carpeta y que se puede leer; una carpeta dentro de
`~/.cache/sumi-shell`, donde irán los temporales de las descargas, no se admite) y se
quitan con *Remove* o `Supr`; nada se borra del disco. El shell deja la lista en
`$XDG_STATE_HOME/sumi-shell/wallpaper-sources`, y `generate-thumbs.sh` la lee para generar y
podar las miniaturas de las mismas carpetas (sin la lista, las dos de siempre). Los thumbnails
se **leen** de `~/.cache/sumi-wallpapers/thumbs`: el shell nunca escribe uno. Se nombran
por el archivo, así que dos carpetas con el mismo nombre de archivo comparten miniatura (la
primera de Sources se la queda; Sources avisa en *Repeated file names*). Si faltan:
`systemctl --user start thumbs-refresh.service`. El escaneo anota qué miniaturas existen (W4):
la tira no pide una que aún no está («generating thumbnail…») y, mientras falte alguna, se
reescanea cada 2 s, como mucho 30 veces (`wallSources` → `thumbsMissing`, `thumbPollLeft`). La carpeta de descargas
(`theme.wallpaper.downloadDir`, fila *Download folder*) tiene que ser de Sources y escribible;
la usarán las descargas de Wallhaven (fase 10D).

La tira: **Search installed wallpapers** filtra por nombre al teclear (todas las palabras, sin
red), combinada con All/Images/Videos y con **Recent/Favorites** (`WallpaperMeta`; el chip
activo otra vez vuelve a toda la biblioteca). La cabecera nombra siempre el fondo aplicado
(«· not in these results» si el filtro lo oculta) y su miniatura lleva una marca. Teclado:
`←` `→` mueven, `⏎` aplica (sin resultados, limpia la búsqueda), `/` o `Ctrl+F` van a la
búsqueda (`⏎`/`↓` vuelven a la tira, `Esc` limpia y después vuelve), `⇥` recorre tira →
búsqueda → filtros (en los filtros `←` `→` y `⏎`), `R` saca uno al azar, `P` restaura el
anterior, `W` abre la tienda de Wallhaven, `S` abre Settings · Theme · Wallpaper; la rueda también mueve. Back/Forward devuelven
búsqueda, filtros y el enfocado.

**Apply observado** (10B): «applied» sólo cuando, tras salir bien `apply-wallpaper.sh`, el
archivo de estado dice lo pedido; si no, «Could not apply» con el motivo (en el pie de la tira y
en *Current wallpaper*). Los colores siguen despegados (un matugen muerto a medias es lo que hay
que evitar), pero un envoltorio escribe su código en `$XDG_RUNTIME_DIR/sumi-wallpaper-colors`
y el shell lo enseña: *updating colours… / colours failed / colours didn't report* (90 s).
**Restore previous** (`P`, el icono de reloj de la tira o Theme → Wallpaper) vuelve a la
entrada anterior de Recent: comprueba que el archivo existe y, si aquel fondo tenía otro
esquema con los colores del fondo encendidos, lo escribe antes (`scripts/apply-scheme
--write-only`) para que el apply regenere una sola vez; si el apply falla, el esquema vuelve.
Cada entrada de Recent guarda `scheme` y `dynamic` (las anteriores a la 10B, sin contexto:
restauran sólo el fondo y lo dicen).

**Rotación** (Theme → Wallpaper → Rotation, apagada por defecto): un solo programador en el
shell (`services/WallpaperRotation`), sin timer de systemd; sin shell no rota. Cuenta desde el
último cambio observado del fondo (aplicar uno a mano reinicia la cuenta), saca de la bolsa
(All/Images/Videos/Favorites) y aplica a todas las pantallas, así que repinta con matugen. Pausa
siempre con el bloqueo puesto y, si se eligen, en pantalla completa, con batería o en los modos
Gaming/Cinema; lo vencido en pausa se hace al salir. **Transitions**: el tipo de transición de
awww para imágenes (`WALL_TRANSITION`, que `apply-wallpaper.sh` valida; sin ella, `any` como
siempre); los vídeos no tienen.

**Vídeo de fondo en pausa** (2026-09-26, pedido por el usuario; no es un ajuste del shell):
`apply-wallpaper.sh` arranca cada mpvpaper con el IPC de mpv en
`$XDG_RUNTIME_DIR/sumi-mpvpaper-<salida|all>.sock` y con `-p -a FULL` (se pausa solo mientras
una ventana a pantalla completa lo tapa). `services/Modes` lo pausa en Gaming y Cinema y restaura cada pausa del snapshot al salir,
con `hypr/scripts/wallpaper-video-pause.sh` (`status --json` / `restore <json>`); un vídeo
que arranca en Gaming/Cinema nace pausado. mpvpaper respeta esa pausa al salir de la pantalla
completa (medido). La fila *Pause rotation in Gaming and Cinema* es sólo de la rotación.

**La tienda de Wallhaven** (antes de la fase 11, W1–W4, 2026-09-26): toda la búsqueda y la
descarga de Wallhaven de la fase 10 viven en una **ventana flotante** propia, fuera de la tira
(que queda para elegir y aplicar). `core/WallhavenLayer` (capa `Top`, namespace
`sumi-wallhaven`, a pantalla completa con máscara sólo en la tarjeta), su estado de vista en
`services/WallhavenStore`, el catálogo en `core/WallhavenCatalog` y la ficha en
`core/WallhavenDetail`. Se abre con **Super+Ctrl+W** (atajo global `sumi:wallhaven`), con el
chip **Wallhaven ↗** de la cabecera de la tira (o `W`; la tira se cierra) y con `whStore`: una sola
instancia — pedirla en otra pantalla la lleva allí. Se arrastra por la cabecera sin salir del
monitor (margen de 16 px); la posición se recuerda por pantalla durante la sesión. `Esc` cierra lo
de encima (confirmación, menú, ficha, Filters) y después la tienda; la X también. Cerrar no pierde
la búsqueda, los resultados ni las descargas. Está hecha para el **ratón**: el teclado sirve para
el campo (`⏎` busca) y `Esc`; las zonas y teclas D/C/X/R/PgUp de la tira se retiraron (decisión
del usuario). Vidrio a 0,985: probada sobre blanco, negro, saturado, ajedrez y un fondo complejo.

- **Catálogo:** la búsqueda en la cabecera (sólo con `⏎` o *Search*; «Search ·» si hay filtros sin
  enviar), filtros a la vista (General/Anime/People, SFW/Sketchy/NSFW con su motivo en el pie,
  *Sort* en menú, sentido) y *Filters* en un panel lateral con el número de avanzados activos, que
  además salen como etiquetas quitables; cuadrícula de miniaturas grandes (resolución y peso al
  pasar; «In library» y la descarga fijos), *Previous/Next* y todos los estados (idle con *Browse
  latest*, esqueleto, resultados atenuados al buscar, vacío, sin red, 429, clave rechazada,
  ilegible, combinación inválida, resultados viejos con *Retry*, miniatura que no carga).
- **Ficha** (clic en una tarjeta): vista grande, datos, autor y etiquetas, ‹ › por la página y UNA
  acción según el estado — *Download* · progreso y *Cancel download* · el motivo y *Retry download*
  · ya en la biblioteca: *Apply now* y *Show in library* (la tira enfocada en ese archivo) —, *Find
  similar*, *Open on wallhaven.cc* y las etiquetas (buscan `id:`).
- **Descargas:** botón de descarga rápida al pasar por una tarjeta, línea de progreso, resumen en
  la cabecera y un aviso al terminar una suelta (*Apply now* / *Show in library*; las de una
  colección no avisan una a una). **My collections** (chip a la derecha de los filtros): tarjetas
  de colecciones; una colección con *Download collection* (confirmación modal) y su progreso con
  *Cancel* / *Retry pending*. Descargar nunca aplica.

Lo que sigue describe la lógica de la fase 10 (servicios, estados, archivos), que la tienda
conserva sin cambios; donde dice «la fila», «la tira» o una tecla, hoy es la tienda y el ratón.

**Wallhaven** (10C-1, `services/Wallhaven`; hasta W4 en una fila bajo la tira, hoy en la tienda):
**Search Wallhaven**, con su propio texto e independiente de la búsqueda local. Sólo pide al pulsar `⏎` o *Search*
(nunca al abrir ni al teclear), una petición a la vez. La primera búsqueda despliega los
resultados:
miniaturas sólo de `th.wallhaven.cc`, resolución, formato, tamaño e id, «In library» si ya hay un
`wallhaven-<id>…` en la biblioteca, y *Previous/Next* con el `seed` de la API en orden aleatorio.
Estados: *Searching…*, *Nothing on Wallhaven matches…*, **Wallhaven unavailable** (sin red, 5xx,
15 s sin respuesta) con *Retry*, límite de peticiones (429: bloquea hasta `Retry-After`, 60 s si
no lo dice), clave rechazada, respuesta ilegible o de más de 2 MB; un fallo deja los resultados
anteriores a la vista con el aviso encima. Sin clave se usa el catálogo SFW público. La opción de prueba
`whTestBase` admite un servidor de bucle local.

**Filtros y detalle** (10C-2): bajo la barra, General/Anime/People, SFW/Sketchy/NSFW (NSFW
apagado sin clave, con el motivo), orden (Relevance, Latest, Random, Views, Favorites, Toplist)
y sentido, resolución mínima y **More filters** (sobre los resultados: periodo de Toplist,
mínima personalizada, resoluciones exactas —alternativa a la mínima—, proporciones, color de
la paleta de Wallhaven, formato `type:png|jpg` y la ayuda de sintaxis). Cambiar un filtro NO
pide: «Filters changed · press Search»; lo que no se puede enviar (sin categorías, sin
contenido, NSFW sin clave, mínima mal escrita) se dice antes y Search no pide. Los activos
salen como etiquetas con ×, y *Reset filters*. **Ficha** (`⏎` o clic en un resultado):
miniatura grande, datos, colores y, tras medio segundo en el mismo resultado, etiquetas y autor
(`/w/<id>`, una vez por id); `←`/`→` recorren la página; *Similar* (`like:<id>`), una etiqueta
(`id:<n>`) u *Open on wallhaven.cc* son acciones explícitas.

**Descargas** (10D-1, `services/Downloads`): un gestor compartido fuera de la vista (cerrar
la tienda no pausa ni cancela). *Download* en la ficha o el botón de la tarjeta; como mucho
dos archivos a la vez; curl a `~/.cache/sumi-shell/downloads/<id>.part` (fuera de la
biblioteca: el escaneo no lo ve); antes de entrar se comprueba tamaño, tipo MIME y dimensiones,
y entra con `mv -n` como `wallhaven-<id>.<ext>` en la carpeta de descargas. Lo que ya está
(también los `wallhaven-<id>_WxH` bajados a mano) → *Already in your library*, sin bajar nada.
Falta de espacio → *Download paused: not enough space*; 429 → pausa y sigue sola; *Cancel*
borra sólo los temporales en curso; *Retry download* retoma lo fallido, cancelado, pausado o
interrumpido. Registro en `$XDG_STATE_HOME/sumi-shell/downloads.json`; tras un reinicio o una
recarga lo que estaba vivo queda *interrupted* (o hecho, si el archivo final existe) y se borran
los temporales. Cada trabajo es una operación (`Operations`, tipo `download`). Al terminar,
**Downloaded · not applied** con *Apply now* (el apply de siempre) y *Show in library* (la tira,
sin filtros, enfocada en él). **Descargar nunca aplica.** El **Dashboard** (10D-2) enseña las mismas descargas en
un bloque *Downloads* (hasta cuatro filas, primero lo que pide atención: en curso,
pausado, fallido, interrumpido), con *Cancel* o *Retry* por trabajo y *Clear finished*. Desde la
11A-1 el bloque está en la pestaña **Tasks** (`↓` desde la barra de pestañas entra en él).

**Cuenta de Wallhaven** (10E-1a, `services/WallhavenAccount`): Theme → Wallpaper → Wallhaven.
La **clave** se escribe en un campo secreto y se guarda en
`$XDG_STATE_HOME/sumi-shell/secrets/wallhaven.key` (carpeta 0700, archivo 0600, escritura
atómica, recibida por stdin): nunca en `settings.json` (que `dotbackup` sube), argumentos, URLs,
logs ni el IPC (`whAccount` sólo dice si hay una). Estados *Not configured*, *Pending validation*
(guardada sin comprobar, o Wallhaven caído), *Configured*, *Rejected* (401); *Test connection* pide
`/api/v1/settings` sólo al pulsarlo y trae los filtros de la cuenta, que la tienda enseña en su
cabecera. La clave va como `X-API-Key` (salvo rechazada); NSFW sólo con una clave comprobada.
Una clave sin guardar activa la guarda *Keep editing / Discard and leave*; *Remove the key* pide
una segunda pulsación. Cambiar, quitar o que rechacen la clave cancela las peticiones e invalida
los resultados en memoria.

**My collections** (10E-1b): el chip de la fila de filtros abre la lista de colecciones de la
cuenta (hacen falta clave comprobada y usuario; si no, lo dice y lleva a Settings), en tarjetas
con cuántas tiene y si es privada; una colección abre sus fondos en la misma cuadrícula (ficha,
páginas, descargas) con sólo el filtro **Content**; *Back to collections* y *Back to search* (la
búsqueda vuelve tal cual, sin pedir). Las descargas desde una colección, y las que ya estaban,
quedan en el **índice privado** `$XDG_STATE_HOME/sumi-shell/wallhaven-index.json` (0600;
por id: archivo, cuenta, colecciones; una imagen, varias colecciones, sin copias). En la tira:
«Wallhaven · <colecciones>» junto al nombre de los `wallhaven-*`, y el chip **Collection: All |
nombre** (sólo las colecciones con archivos aquí; se combina con tipo, Recent/Favorites y texto;
funciona sin red).

**Download collection** (10E-2): en una colección (su botón), se recorren **todas** sus páginas
con el Content activo, una tras otra y espaciadas (un 429 pausa y sigue tras `Retry-After`); la
confirmación dice el nombre, el Content, cuántas son accesibles, cuántas ya están (se enlazan a la
colección, no se bajan otra vez) y cuántas se bajarán. Confirmado, es UN trabajo: dos a la vez,
validación, *Cancel* y *Retry pending*, falta de espacio, progreso «descargadas/total
· en curso · ya aquí · fallidas» en la línea de la colección y en el Dashboard. Nada se aplica. El aleatorio usa una **bolsa barajada** que persiste
en `~/.local/state/sumi-shell/wallpaper-bag.json`: cada wallpaper sale una vez antes
de que ninguno repita.

El preview de vídeo en la tile enfocada está **apagado por defecto**: medido en +170 MB
y 6.1 % de un core mientras reproduce, para enseñar en 196×110 lo que el thumbnail ya
muestra. Se enciende con `wallpaperVideoPreview`.

## Grabador de pantalla (2026-10-29)

Hermano de la tira de Wallpapers: la misma familia (estado arriba, opciones como chips, tarjetas con
profundidad, ayuda o aviso en el pie) en 600×222. Se abre desde el glifo nuevo de la barra (junto a
Visual profiles; en More, grupo *Capture*), desde el botón de la cara hover del island (bloque de
medios) o con `ipc call sumi open recorder ""`. Desde el Grabador 2.0, su configuración está en
**Settings → Shell → Screen recording** (y los chips de la surface editan esos mismos ajustes).

- **Modos** (las tarjetas; la enfocada es el modo y se recuerda): *Full screen* (la pantalla de la
  surface; con varias, *This screen*), *Region* (slurp: arrastrar un área o, desde la segunda entrega,
  un clic en una ventana visible) y, con más de una pantalla, *Choose screen* (slurp `-o`: un clic en
  la pantalla). wf-recorder graba una salida a la vez: no hay «todas las
  pantallas en un archivo».
- **Opciones**: *System audio* (monitor de la salida predeterminada), *Mic* (una entrada real: un
  monitor no cuenta; sin ninguna dice *No mic*), *Standard* (30 fps, CRF 23) / *High* (60 fps,
  CRF 18), *3 s delay*. Con sistema y micro, el micro se graba aparte y se mezcla al guardar (puede ir
  unas décimas desfasado). Desde la segunda entrega codifica la GPU (VAAPI) cuando puede, con la
  misma nitidez que x264 (QP 29 / 24 ≈ CRF 23 / 18 por SSIM); si no arranca, x264 sin que se note.
  `"encoder": "cpu"` en `recorder.json` lo fuerza a x264 (sin interruptor en la surface).
- **Teclado**: ← → modo · ⏎ grabar · ⇥/↑ opciones (← → y ⏎; Esc/↓ vuelve) · A audio · M micro ·
  Q calidad · D cuenta atrás · O carpeta · L última grabación · C copiarla. Grabando: Espacio pausa/reanuda,
  S para y guarda; preparando, ⏎ o C cancela. Esc cierra (en las opciones, vuelve a las tarjetas).
- **Mientras graba**, sin abrir la surface: en la presentación island/dock, una pieza bajo la forma
  (`core/RecorderPill`: ● tiempo · pausa · parar; preparando, cancelar; después «Saved»/«Failed»
  unos segundos); con la barra, un tramo al principio de la derecha (el mismo estado, navegable con
  el teclado del peek) y el glifo de la izquierda en rojo. El punto rojo de privacidad se enciende
  (`Privacy.screenActive` cuenta el grabador propio) y la etiqueta «Screen» de la barra la sustituye
  el tramo. La pieza no sale sobre una pantalla completa (saldría en el vídeo) ni con el grabador
  abierto.
- **Segunda entrega** (2026-10-29): bloquear la sesión PAUSA (no reanuda sola; al desbloquear, el island
  lo dice y la pieza sigue en «Paused»; preparando, cancela); al guardar, la pieza y la barra ofrecen
  *Copy* (la grabación al portapapeles como archivo, `text/uri-list`), y el aviso no se va con el puntero
  encima o el teclado en el tramo; reanudar ya no pasa por «Starting…».
- **Grabador 2.0** (2026-10-29): Settings → Screen recording (catálogo `recorder.*` de `settings.json`):
  preset *Standard*/*High*/*Custom* (Custom: codificador, fps 24/30/60/120/otro, calidad Balanced/High/Very
  high/bitrate, resolución nativa/1080p/720p/otra altura), contenedor MP4/MKV/WebM, audio (sistema y micro
  con su dispositivo, AAC/Opus, bitrate, 44,1/48 kHz), carpeta y nombre (`{date} {time} {screen}`; nunca se
  sobrescribe) y comportamiento (cuenta atrás 0/3/5/10 s, indicador, temporizador, controles en la pieza y en
  la barra, notificación y abrir la carpeta al terminar, recordar el modo). Sólo se ofrece lo que funciona
  aquí: `screen-recorder.py probe` prueba cada codificador con un fotograma (H.264/HEVC/AV1 por VAAPI, H.264
  por x264; NVENC/QSV no se ofrecen, sin verificar con wf-recorder) y detecta si rellena el tamaño (AV1 en
  la RX 7600: sólo con tamaños múltiplos de 64×16). La calidad tiene un valor por codificador (misma SSIM que
  x264). Lo que se grabará lo resuelve `screen-recorder.py plan` (la surface lo dice en una línea; Settings
  en *Will record*). El audio va en FLAC en los tramos y se codifica una vez al guardar (wf-recorder no
  aplica el bitrate de audio). El puntero se graba siempre (wf-recorder 0.6.0 no tiene opción). Surface:
  chip *Custom*, la cuenta atrás con su duración, vistas *Completed* (Play, carpeta, nueva; chips Copy file /
  Copy path; teclas C P O N) y *Error* (Recover si quedaron tramos, Settings, Try again, Dismiss); «,» abre
  Settings. `recorder.json` queda como estado de la herramienta (modo, última grabación) y la primera vez pasa
  a Settings lo que se había cambiado allí.

Quien graba es `scripts/screen-recorder.py`, fuera de la shell, en su scope
(`app-sumi-recorder-*`, con `Apps.spawn`): recargar o reiniciar la shell no corta la grabación y
`services/ScreenRecorder` la recupera con su tiempo (`status`). Pausa por tramos Matroska en
`<carpeta>/.recording-<token>/`, unidos sin recodificar al parar en
`$(XDG_VIDEOS_DIR)/Recordings/Recording AAAA-MM-DD HH-MM-SS.mp4`. Estado en
`$XDG_RUNTIME_DIR/sumi-shell/recorder/state.json`; la configuración en `settings.json` (`recorder.*`) y el
último modo y la última grabación en `$XDG_STATE_HOME/sumi-shell/recorder.json`. Necesita `wf-recorder` y
`ffmpeg` (`slurp` para región/pantalla); si faltan, el pie lo dice antes de pulsar.

Medido (2026-10-29): con la pantalla quieta Hyprland emite `screencast>>0` a los ~2 s aunque
wf-recorder siga; si una salida no cambia NI UNA VEZ desde el inicio, wf-recorder no recibe
fotogramas e ignora SIGINT/SIGTERM: parar escala a SIGKILL y se dice «Nothing was recorded».
IPC: `recorder`, `recorderStart <modo> <pantalla>`,
`recorderControl pause|resume|toggle|stop|cancel|copy|copyPath|new|recover|retry|dismiss`,
`recorderView <pantalla>`; `recorderTest` sólo en el banco.

## Motor de modos (rediseño 11D-1 / 11D-2)

`services/Modes` es la fuente de Dashboard, Centro de control, `minimaru mode` e IPC.
`DesktopMode` queda como fachada de compatibilidad. Focus cambia DND, movimiento a Reduced
y cursores; Gaming además pide Performance, apaga blur/animaciones/hyprglass, pone movimiento
Off, pausa vídeo e inhibe idle; Cinema cambia DND, cursores, pausa vídeo e idle, conservando
energía, blur, animaciones y hyprglass. Normal restaura lo capturado, sin imponer valores fijos.

Antes de escribir se guarda el snapshot y después se relee cada efecto. Los cambios manuales
(DND con su origen incluido) se detectan al abrir Performance, cambiar de modo o pedir refresh;
se conservan hasta volver a normal. Sin sondeo periódico. Un efecto ausente queda Unavailable;
uno no comprobado produce Partially applied. Sólo `activeMode` identifica un modo comprobado.

Estado y snapshot: `$XDG_RUNTIME_DIR/sumi-modes.json`, ligado a la identidad de la sesión
Hyprland; se reconcilia al cargar. La caché `~/.cache/sumi-desktop-mode` sigue existiendo
para apply-wallpaper. El movimiento sólo usa `Motion.override`: no escribe settings.json.
La reclamación temporal de Session usa `--what=idle`, independiente de Keep awake; su hijo
suelta la inhibición al cerrar el pipe (recarga) o morir su propietario (pidfd). Hypridle sigue
activo y ningún modo para Sumi Shell. No hay procesos hypridle sueltos.

Sin shell, `desktop-mode.sh normal` es el suelo con los valores habituales; sólo admite
normal/status. Focus/gaming/cinema exigen el shell. `minimaru mode status` con shell devuelve
el mismo JSON de `ipc modes`. Aceptar `mode` significa petición aceptada, no éxito comprobado.
**Performance (11D-2):** cuatro tarjetas 2×2, con diana para Focus, marca y borde sólo al
comprobar el modo. El foco y el hover muestran los efectos: verificaciones, capacidades
Unavailable, fallos y cambios manuales conservados. Flechas eligen y Enter aplica; Tab recorre
las tarjetas, Retry / Back to normal, energía y el acceso a System Monitor. Back/Forward
conservan selección, sección y scroll. Mientras aplica, la tarjeta pedida muestra progreso por
efectos; las acciones no se duplican. El perfil energético tiene su bloque separado con
comprobación, disponibilidad, degradación, retenciones, petición en curso y error.
`PowerProfile.available` sigue la capacidad `hasPerformanceProfile` del binding nativo.

El snapshot añade `progress` y una `revision` de escritura: permite reintentar aunque FileView
conserve en su caché el texto de una escritura fallida. No cambia su ruta ni se guardan ajustes
de movimiento. `dashboardPerformance` expone el estado visible; `performanceTestPower` sólo
sustituye la presentación de energía con Modes en pruebas, y entonces bloquea su selector real.

Pruebas reproducibles: `quickshell/tests/modes/`. Toda la matriz, fallos y reinicios se probaron
con sustitutos; los recorridos reales y la restauración visual de hyprglass requieren todavía
la autorización/prueba del usuario. Un vídeo nuevo sin snapshot no se reanuda inventando un
estado anterior; los sockets conocidos conservan su restauración por separado.

## Dashboard

Super+Ctrl+D. Tres pestañas en un panel fijo de 720×500 (rediseño 11A-1): **Overview**,
**Performance** (modos y perfil de energía, acceso a System Monitor) y **Tasks** (consola de
dotbackup/diskbackup y descargas de Wallhaven). `performance` y `tasks` son nombres que abren esa
pestaña (la fila de modo del Centro de control, `mode` en la paleta, `minimaru mode` sin argumento).

**Overview (11A-2).** Arriba, lo que requiere atención según `services/Issues`: unidades caídas,
actualizaciones pendientes, hallazgos de `health`/`doctor` y backups vencidos — tres a la vista y el
resto plegado, cada uno con su dato, su hora y una acción. Lo que **no se pudo comprobar** se dice
(«Could not check», con el último dato bueno y Retry) y nunca cuenta como cero: una lectura fallida
de `systemctl --failed` conserva la lista anterior. **All clear** sólo cuando todo lo que cuenta se
comprobó, con la hora. La antigüedad de un backup es sólo información hasta que se le pone una
frecuencia en Settings → Shell → Dashboard. Las tareas que calculan la antigüedad de archivos declaran sus
fuentes en `tasks.json`. Consulta los [ejemplos de tareas](examples/README.md). Debajo, el
mantenimiento en orden fijo, la **actividad reciente** (`$XDG_STATE_HOME/sumi-shell/activity.json`,
las 20 últimas: lo que se lanzó desde el shell; lo entregado a una terminal queda «Opened in
terminal», nunca «Completed») y los diagnósticos plegados (health, doctor y el estado del shell).

**Tasks y la paleta (11B).** Un solo catálogo y un solo ejecutor, `services/Commands`: las diez
órdenes de `sumi` con su sitio (*In the panel*, *Kitty*, *Surface*, *Menu*), para la paleta
(Super+Ctrl+X), la pestaña Tasks y el mantenimiento del Overview. Tasks tiene el buscador y la lista
a la izquierda y, a la derecha, la orden elegida (qué hace, dónde acaba, cómo terminó lo último), la
consola de su trabajo y los **trabajos en seguimiento** (los backups y las descargas de Wallhaven por
id, con Follow / Cancel / Retry / Clear finished). `diskbackup` ya no abre Kitty desde la paleta: lleva
a Tasks con su confirmación, y lanzarlo otra vez con uno en curso sólo lo sigue.

**health y doctor en el panel (11C).** `minimaru health --json` y `minimaru doctor --json` corren la
misma lógica que el informe de terminal (cada rama que decide un resultado llama además a `_rui_rec`,
en `fish/conf.d/report-ui.fish`) y emiten JSON Lines: un registro por comprobación (`ok` · `finding` ·
`unknown` · `info`, con su detalle) y un veredicto. Son trabajos de `Jobs` (`health`, `doctor`):
Tasks enseña el informe por secciones, con Copy; «Running… no result until it finishes» mientras
corren; sin veredicto, *Failed · no report*; una recarga a mitad, *unknown*. Sólo `clean` y `update`
siguen en Kitty. Los resúmenes de `~/.cache/minimaru-{health,doctor}-summary` los escriben igual.

## Systemd Units

Super+U. **User | System** (Ctrl+Tab), nunca mezclados: cada fila, ficha y journal va por clave
`ámbito:unidad`. La lista trae `.service`, `.timer`, `.socket` y `.mount`/`.automount` con su
etiqueta, las caídas primero y los montajes plegados; sólo se lee el ámbito que se mira. Los tipos no
listados (`.target`, `.path`, …) se abren escribiendo su nombre exacto. Una lectura fallida es
*Unknown state* con la lista anterior, nunca «0». La ficha enseña los datos del tipo (próxima y última
ejecución, escucha, origen/destino) y la unidad que activa (`T`); el journal del sistema sin permiso
dice *Permission required*, y el completo tiene *Resume live* (End) y *Copy* (C). Desde el Dashboard,
una unidad caída se abre en su ámbito. Start/Stop/Restart en servicios de los dos ámbitos (11F-2):
lo que systemd rechazaría se desactiva con su motivo; los servicios esenciales de la sesión (sddm,
logind, dbus, polkit, journald, udevd, user@<uid>…, por nombre y alias reales) no se paran ni
reinician desde aquí; los de sistema se confirman en la ficha y piden la contraseña por el agente
polkit del shell, y el resultado sólo se afirma tras releer la unidad (y su journal, para los que
corren y terminan).

## Sesión

`lock()` **no bloquea nada por su cuenta**: pide `loginctl lock-session` y deja que
hypridle ejecute su `lock_cmd` (`hypr/scripts/lock.sh`, ADR-30). Es el mismo camino
que `before_sleep_cmd` y que SUPER+ALT+H, así que el rice tiene un único lock.

### Pantalla de bloqueo (ADR-30)

El bloqueo lo pinta el propio shell — `lock/LockSession.qml` sostiene un `WlSessionLock`
real (`ext-session-lock-v1`) y `lock/LockAuth.qml` autentica con `PamContext` sobre la
pila `login` (la misma que hyprlock: `faillock` cuenta igual). hyprlock **no se retiró**:
queda como red de seguridad automática si el shell no bloquea en ~1,5 s, o si cae con la
sesión bloqueada.

- **Un solo camino**: `hypr/scripts/lock.sh` — todas las entradas (SUPER+ALT+H, la
  superficie de energía, `ipc call sumi lock`, la inactividad de 300 s, antes de
  suspender) pasan por `loginctl lock-session` → hypridle → `lock.sh`, que pide
  `lockNow` al shell y cae a hyprlock si no responde.
- **Recuperación**: `misc:allow_session_lock_restore = true`; el shell rebloquea solo
  tras una caída (`lock.json`); `sumi-lock-rescue.service` lanza hyprlock si el shell
  no vuelve (`sumi-shell.service` lo dispara por `OnFailure=`/`ExecStopPost=`).
- **No existe, y no existirá, un verbo que desbloquee** (I-3): sólo `PamResult.Success`
  suelta el bloqueo.
- Cada caída al fallback deja una línea `journalctl -t sumi-lock`.
- **Desde la fase 15 (2026-09-29)** lo que se pinta es el **panel del rediseño** (`lock/LockBoardSurface`): clima,
  fetch y música a la izquierda; hora, avatar y campo en el centro; CPU/temperatura/RAM/disco y las notificaciones
  agrupadas a la derecha; energía abajo a la derecha fuera del panel. Datos de `services/LockData` (uno por sesión);
  calma a los 10 s (`lock/LockCalm`); el panel sigue al monitor con el foco y el texto a medias con él. Settings →
  Shell → Lock screen: avatar e imagen del fetch (con aviso si faltan) y **Preview**.
- Pruebas del bloqueo y recuperación en la [guía de VM](../packaging/PORTABILITY-VM.md#bloqueo-y-rescate).
  IPC en [API.md](../API.md#lockstatus--string-json). Ajustes del lock en *Ajustes*.

Keep-awake sostiene **dos** inhibidores, y hacen falta los dos:

| inhibidor | qué frena |
|---|---|
| Wayland (`zwp_idle_inhibit`, sobre una superficie de 1×1) | el idle/DPMS del propio compositor |
| logind (`systemd-inhibit --what=idle:sleep --mode=block`) | hypridle, que corre sus propios timers y **no ve** el de Wayland |

Medido: con sólo el de Wayland, hypridle bloquea igual. El proceso de logind se relanza
si muere (5 reintentos, reseteados tras 10 s de vida sana).

`resumes` en el `status` cuenta los despertares tras suspend; el reloj compartido se
re-sincroniza en cada uno, porque su timer es monotónico y no avanza dormido.

## Atajos

**Ayuda dentro de la shell (2026-10-30):** Settings → Shell → Interaction → **Keyboard shortcuts** (o «keyboard»
en el launcher) abre una tarjeta flotante (`core/KeybindsLayer`, no es una surface) con las 29 acciones por
categorías, búsqueda por título, identificador, descripción o combinación, la tecla **efectiva** cuando Hyprland
deja identificarla y, si no, por qué; Open ejecuta la acción por el mismo camino que su tecla. Sólo lectura:
Hyprland es el dueño de las combinaciones (P4). IPC interno: `keybindsUi*`, `keybinds`, `keybindsRefresh`.

**Una sola fuente de las teclas por defecto:** `lib/shortcuts.json` (nombre = identificador público intacto,
título, categoría, descripción con la que se registra cada `GlobalShortcut`, tecla por defecto y si la acción
cambia algo al momento). De ahí salen la ayuda, `install.sh hyprland --apply` y las descripciones de
`core/Shortcuts.qml`; `examples/hyprland/sumi.lua` y `.conf` tienen que coincidir (`tests/api/api-check.py`,
control `catalog`). Las teclas **oficiales** son las de la tabla; el rice del autor usa otras en dos
(`SUPER+V` portapapeles, `SUPER+SHIFT+N` notificaciones) y las suyas viven en `hypr/modules/keybinds.lua`,
sección `SUMI SHELL`, como `hl.dsp.global("sumi:<nombre>")`.

**Con Lua (Hyprland 0.57) la tecla sólo se reconoce por la descripción** (medido el 2026-10-30,
`tools/keybinds/binds-probe.py`): `hyprctl binds -j` dice `HL.Dispatcher(global)` y un `arg` numérico interno
que cambia al reordenar la config; una función de Lua sale como `function: 0x…`. Por eso el ejemplo y el
instalador ligan cada atajo con `{ description = "Sumi Shell: <nombre>" }`. Sin ella la ayuda dice «Key not
identifiable» (nunca «no asignado» ni la tecla por defecto). Con hyprland.conf (≤ 0.56) `arg` es
`sumi:<nombre>` y se ve siempre.

Historia: 26 comprobados el 2026-09-30 (16A) por `modmask`+`key`; el 27.º, `SUPER+CTRL+C` → `sumi:calendarUi`,
el 2026-10-27; el 28.º, `SUPER+R` → `sumi:recorder`, el 2026-10-30; el 29.º, `SUPER+F1` → `sumi:keybinds` (esta
ayuda), el mismo día.

Las 29 teclas por defecto, con su título y categoría: `API.md` § «Default keys» (generada del catálogo y
comprobada por `api-check`; no se copia aquí para no tener otra lista). Fuera de esos 29: `SUPER+SHIFT+R` reinicia
el shell (`exec`, funciona con el shell caído; es del rice del autor, no un atajo de la shell) y `ALT+←` / `ALT+→`
recorren el historial de la pantalla dentro de la shell.

Dentro de una surface: `Tab`/`Mayús+Tab` recorren grupos y controles (en las listas de un solo grupo, como
`↓`/`↑`), las flechas actúan dentro del control y `Esc` resuelve el nivel local y después cierra.

**Desde la Fase 9.a las teclas NO lanzan `qs … ipc call`**: el protocolo global-shortcuts de Hyprland entrega el
evento dentro del proceso vivo (medido el 2026-09-08: 4 ms frente a 24 ms del `exec` + cliente IPC). El IPC sigue
siendo la vía de los scripts, de `minimaru.fish` y de las pruebas; las dos comparten acción en `core/Screens`.
Con el shell caído Hyprland despacha a un atajo sin cliente y no pasa nada.

Qué hace cada atajo vive en UN sitio, `Screens.runShortcut(nombre, pantalla, quién)`: lo llaman los `GlobalShortcut`
y el botón Open de la ayuda (nunca se simula una pulsación).

Guardar `keybinds.lua` basta: Hyprland recarga el archivo solo. **No** hay que registrar además con
`hyprctl eval`, porque entonces el bind queda duplicado y un `toggle` se dispara dos veces (docs/HYPRLAND.md).
Una descripción cambiada en `core/Shortcuts.qml` sólo llega a `hyprctl globalshortcuts` tras reiniciar el
shell (una recarga no vuelve a registrar el atajo).

**Probar atajos y teclas sin teclado real:** `hyprctl dispatch 'hl.dsp.global("sumi:<nombre>")'` es el mismo
camino que la tecla, y `qs -c sumi ipc call sumi keyTest <mon> <Tab|Down|Escape|…> <shift>` mete una
tecla por el manejador de `Keys` de esa pantalla (no escribe en campos de texto). **No usar `wtype`**: su teclado
virtual disparó tres veces el atajo global Super+Esc (fase 16B) y en `keybinds.lua` hay Ctrl+Alt+Esc → apagar.

## Ajustes

**Desde el 2026-09-24 (rediseño, fase 3):** `~/.config/sumi-shell/settings.json`, anidado y
versionado (`schemaVersion` 2). Único escritor: el shell (`services/Settings`, el ConfigStore).
El catálogo de ids, tipos, defaults y rangos está en `lib/settings-schema.js` (probado con node).
Hasta esa fecha era un JSON plano en `~/.local/state/sumi-shell/settings.json`: se migró una
vez y **se dejó intacto** como backup; el shell ya no lo lee (si no existe el nuevo, lo migra).

- **Editarlo a mano** se aplica en vivo. El vigilante se rearma tras cada escritura, porque la
  escritura atómica sustituye el inodo (memoria del proyecto).
- **Un valor inválido** (fuera de rango, tipo equivocado, ruta remota) se rechaza campo a campo:
  ese campo usa su default y la superficie lo dice. Nunca se recorta en silencio.
- **Un archivo roto** (JSON inválido, estructura, permisos) o **de una versión futura** NO se
  sobrescribe por mover un control: la superficie lo explica y ofrece Retry / Restore last good /
  Restore previous / Restore defaults. Se guarda una copia de diagnóstico.
- **Una edición externa** que llega con un cambio local sin guardar (300 ms) es un conflicto:
  Use file / Keep mine.
- **Antes de cada escritura** se copia la revisión anterior a
  `~/.local/state/sumi-shell/backups/settings/settings.{1..5}.json` (rotando).
- **`scripts/notif-server`** lee y, con el shell caído, edita
  `.shell.integrations.notificationServer` aquí.

**Settings UI independiente (2026-11-07).** Settings ya no es una superficie del island: es una
tarjeta flotante como el monitor o la Calendar UI (`core/SettingsLayer`, estado de ventana en
`services/SettingsUi`, capa `Top`, namespace `sumi-settings`, 1180×780 ×uiScale acotada al
monitor, mínimo 560×420; se arrastra por la cabecera y se redimensiona por la esquina, sólo en la
sesión). Una instancia; pedirla en otra pantalla la lleva allí con su vista. La abren los mismos
caminos de siempre (atajo `sumi:settings`, engranaje del island y de la barra, `open/toggle/close
settings|settingsTheme|settingsSystem`, `settingsOpen <ruta>`, «Configure…» de otras superficies:
Esc vuelve a la superficie de origen). Reabrir vuelve a la página, scroll y fila que se dejaron;
cerrada, el contenido se descarga tras «Unload after» (al bloquear, en el acto y sin secretos).
El índice lateral y el menú compacto comparten cinco grupos plegables. Shell reúne General, Layout, Edge,
Animations, Interaction e Import and export. Appearance, Desktop tools, Apps & services y System reúnen el resto.
Las flechas izquierda y derecha recorren la jerarquía. Elegir una página en la búsqueda, en el historial o con
`settingsOpen` despliega su grupo. Alt+←/→ recorre las páginas visitadas.

En Animations, Motion reúne el modo y la velocidad. Windows, Dynamic Bar y Capsule & Edge muestran ocho estilos
cada una. El puntero permite previsualizar una tarjeta y el teclado reproduce la elección. Reduced reproduce
al señalar o enfocar y Off deja las tarjetas quietas. El título y las pestañas quedan a la vista mientras caben
sobre el contenido. Ctrl+PgUp/PgDn cambia de sección.

Los enlaces a superficies del island (Wallpaper list, Networks, el Mixer…) las abren
encima; Esc deja Settings donde estaba. IPC de diagnóstico: `settingsUiState`, `settingsUiKey`,
`settingsUiPlace`, `settingsUiResize`. Banco: `tools/visual-review/settings-ui.py` del repo
Quickshell. Lo que sigue describe el marco de la fase 9A y vale para la tabla, las filas y el
teclado.

La superficie (engranaje en la cara hover, o `ipc call sumi open settings ""`) son **tres
surfaces con un marco común** desde el 2026-09-26 (rediseño, 9A): `settings` (Shell: General,
Animations, Interaction, Surfaces, Dock, Panels, Modules, Calendar, Notifications, OSD, Launcher,
Lock screen), `settingsTheme` (Theme: Overview, Wallpaper con Recent/Favorites, Library y Sources editable (10A), Colors con la paleta,
Typography, Icons) y `settingsSystem` (System: Audio, Network, Bluetooth, Power, Displays, Input, Hyprland, About; 9D-2 —
sobre Mixer, Net, Bt y PowerProfile, sin guardar nada propio; Displays/Input/Hyprland en sólo lectura; desde la 13F,
Audio → Applications enlaza **Per-app devices** y **Equalizer** —con el estado del EQ de la salida predeterminada—;
desde antes de la fase 14 llevan a la Audio UI, con **Audio settings** además, y Settings se cierra). Comparten un solo item del host, así que
cambiar entre ellas no mueve el panel; `ipc call sumi settingsOpen theme/colors ""` abre una
página. Advanced y Experimental van plegados dentro de su página (9C-1; Enter o → los abren, y
la búsqueda los abre sola para enfocar una fila suya). Recent y Favorites de fondos son estado operativo en `$XDG_STATE_HOME/sumi-shell/wallpaper-meta.json`
(`services/WallpaperMeta`, 9D-1): Recent se llena con cada cambio observado del fondo. **Search settings** (9B) busca en las tres por etiqueta, sinónimos y breadcrumbs, y el
resultado abre su página con el foco en el control (`settingsSearch` por IPC); teclear una letra
o `Ctrl+F` empieza a buscar. Wallpaper y Visual profiles enlazan con `S` o su engranaje. `Tab`
recorre sidebar → búsqueda → página (en la sidebar, `↑`/`↓` y `Enter`). En la página, `↑`/`↓` mueven de fila (las acciones del aviso incluidas), `←`/`→` cambian el valor, `Enter`/`Espacio`
activan, `Supr` vuelve al default y `Mayús+Supr` resetea la sección en dos pasos (arma y
confirma). Con el ratón: clic, el botón ↺ de cada fila Custom y «Reset section» de la cabecera,
también en dos pasos. Un punto delante del nombre marca un valor **Custom**. El foco empieza en
la primera fila (o en las acciones del aviso si el archivo tiene un problema); el ratón sólo se
lo lleva si el puntero se mueve de verdad. Las filas de Theme → Colors no son del shell y
no tienen Custom ni reset: *Profile* sólo selecciona y *Preview* / *Keep changes* / *Revert* van por
`ThemePreview` (12C; hasta entonces *Colours from wallpaper* y *Scheme* aplicaban al tocarlas).

**Presets (12D).** Theme → Presets aplica grupos de ajustes: los del catálogo con `preset:`
(`appearance`, `layout`, `motion`) y nada más —ni rutas, ni dispositivos, ni integraciones, ni el
tema de matugen—. Integrados en `services/Presets.qml` (Default, Compact, Glass, Vidrio Satinado, Minimal),
inmutables; los tuyos en `~/.config/sumi-shell/presets/<id>.json` por `scripts/presets.py`
(escritura atómica; la versión anterior, en `$XDG_STATE_HOME/sumi-shell/backups/presets/`).
Se aplica por grupos elegidos y el estado dice *Applied*, *Partially applied* o *Modified from*
(`preset-state.json`). El guardado de Settings sale del catálogo (`snapshot`): un ajuste nuevo ya
no necesita que se le añada a mano a ninguna lista.

**Vidrio Satinado.** Theme → Material (antes Shell → Material) permite elegir el acabado y editar su borde y
sombra; la muestra usa `glassOpacity` vigente. Theme → Presets ofrece Vidrio Satinado como
integrado duplicable. Aplicarlo modifica sólo el material, borde y sombra. Glass vuelve al
acabado original sin modificar la opacidad. «Reset section» en Material restaura sólo estos
ajustes; la sección Opacity mantiene el control de opacidad. El satinado usa los tonos semánticos
de la paleta y el mismo alfa en el fondo normal y denso, sin refracción ni efectos continuos.
El blur detrás de la ventana depende de la regla/capacidad del compositor; el acabado QML
funciona también sin él. No se instala ni configura hyprglass.

**Material por superficie** (2026-10-28). Global material y Global opacity se aplican a todo:
paneles, herramientas flotantes, barra, OSD, menús y popups. Theme → Material → Advanced → Surfaces
(plegado) deja que una superficie
compatible (Settings, Launcher, Wallpaper, Wallhaven, notificaciones, Media…) tenga material y
opacidad propios; cada propiedad que no se elige se hereda del global y lo sigue al cambiar. Se
guarda en `theme.appearance.surfaces` sólo lo que cambia (`lib/surface-materials.js` tiene la
tabla; `Theme.materialFor/opacityFor/bgFor` resuelven, `Glass.surface` lo aplica). Las
herramientas flotantes (Wallhaven, Audio UI, System Monitor, Calendar UI) siguen al global como
todo; para dejarlas casi opacas se les da su propia opacidad. La opacidad es la del fondo: texto e iconos no cambian; el blur sigue siendo del
compositor. Lock, polkit, barra, OSD, menús y tooltips siguen al global.

**Importar y exportar (12E).** Shell → Import and export. *Export* escribe
`~/sumi-settings-<fecha>.json` (nunca pisa) con los ajustes exportables del catálogo: los que
llevan `export: false` no salen ni se aceptan (Keep awake, integraciones, monitores, pantalla
preferida, cuenta de Wallhaven, clima activado y ciudad, imágenes del lock); los `local: true`
(Sources, carpeta de descargas) van marcados y al importar se comprueban aquí. *Import* sólo lee:
analiza formato, versión y cada id (desconocidos, no importables e inválidos se enumeran y no se
aplican), enseña el diff por sección y deja elegir Merge o Replace y si traer los presets. Antes
de escribir copia `settings.json` a `backups/settings/settings.pre-import-<ms>.json`; si el
guardado falla, deshace ajustes y presets. *Undo import* hace lo mismo a mano en la sesión.
`services/Portability.qml` + `scripts/portability.py`.

**System en lectura (14A).** Displays, Input, Hyprland, Power y Network enseñan lo **efectivo** y
**de dónde sale**. Hyprland, Input y Displays son **sólo información** (decisión del 2026-09-29): se
editan en tu Lua, y Settings dice qué vale cada cosa y en qué archivo y línea vive (con la ruta
completa); lo único editable ahí es *Preferred display*, que es del shell. La configuración **no se
supone**: `scripts/hypr-config.py where` la busca desde el Hyprland que corre (`hyprctl instances` →
su proceso: `--config`/`-c`, si no su `XDG_CONFIG_HOME` o su `HOME/.config`, y dentro `hypr/hyprland.lua`
o `hyprland.conf`, que se nombra pero no se lee). Recorre ese archivo en el orden de
sus `require` (tokeniza el Lua, no lo ejecuta) y dice archivo y línea de cada clave; `services/HyprConfig`
lo compara con `getoption`: si no coinciden, *changed while running* (un modo, el tema, una prueba). Una
opción global que un `hl.device` sobrescribe lo dice («… has its own»), porque Hyprland **no deja leer
los valores por dispositivo**. Cada salida dice qué regla le aplica y si algo la cambió en caliente.
Catálogo (qué se enseña y cómo) en `lib/system-catalog.js`; bordes,
blur y animaciones salen como *Managed elsewhere* (tema y modos). Power lee `hypridle.conf` (y lo que
incluya con `source =`): plazos, orden (bloquear primero) y qué lo pausa (Keep awake, Gaming, Cinema).
Network lista los perfiles guardados con `scripts/nm-profiles.py` (libnm, **sin secretos**) y si el
rollback de NetworkManager está disponible (pide contraseña: polkit `auth`). Shell → General →
Integrations comprueba el dueño de las notificaciones y si corre otro agente de polkit
(`scripts/integrations.py`). Todo se lee **sólo con su página a la vista** (`ipc subscriptions`).

**Pruebas con vuelta atrás (14B).** Un cambio que puede dejarte sin pantalla se prueba con
`scripts/sumi-guard.py`, que corre como unidad transitoria de systemd (`sumi-guard-<id>`) y **no
depende del shell**: aplica, comprueba leyendo el estado real, espera 15 s y revierte si nadie dice
Keep, si la salida desaparece, si Hyprland recarga o si lo paran (y su `ExecStopPost` revierte aunque
lo maten con `kill -9`). `services/SystemTest` lo sigue desde
`$XDG_RUNTIME_DIR/sumi-guard/<id>.json` y `core/TestCountdown` pinta la cuenta en todas las
pantallas (Esc revierte, en cualquier distribución de teclado). Si el shell se reinicia a mitad, la
cuenta vuelve con el mismo plazo. Para salir de una prueba a mano: `systemctl --user stop
'sumi-guard-*'` (revierte).

**Editar una red guardada (14D).** Settings → System → Network → elige un perfil en *Saved networks* y
cambia, en un **borrador**, lo admitido: conectar solo, prioridad, *metered*, IPv4 automático o manual
(direcciones con prefijo y gateway), DNS y «usar sólo estos DNS». Nunca SSID, seguridad, contraseñas,
MAC ni MTU. Se escribe con `nmcli connection modify` (conserva los secretos guardados: medido) desde
`scripts/nm_edit.py`, que valida cada valor (`ipaddress`) y nunca lo pasa por un shell. Dos caminos:
- **Save** (lo que no puede cortar nada: un perfil inactivo, o conectar solo/prioridad/metered): se
  guarda al momento, vale la próxima vez que conecte, y **Undo** lo devuelve.
- **Test and apply** (DNS o IPv4 de un perfil **en uso**): el guard (tipo `network`) crea un
  **checkpoint de NetworkManager sólo sobre sus interfaces** — polkit pide tu contraseña —, aplica
  **en memoria** (`--temporary`) y reaplica, comprueba la interfaz y abre la cuenta regresiva (con qué
  cambia y si hay internet). *Keep* destruye el checkpoint y lo guarda en disco; *Revert*, Esc o el
  plazo hacen el rollback de NetworkManager y esperan a que la interfaz vuelva a estar conectada (en
  una Wi-Fi el rollback la reconecta). Si el guard muere, NetworkManager revierte **solo** al vencer
  el plazo del checkpoint; si cancelas la contraseña, no cambia nada.

**Plazos de inactividad (14E).** Settings → System → Power → *Lock after* y *Screen off after* (Never,
1 min … 1 h / 2 h), siempre bloqueando antes de apagar la pantalla; sin suspensión automática en esta
máquina. Es opt-in: *Edit the idle times here* (dos pulsaciones) mueve, una vez y con copia, los dos
listeners de `hypridle.conf` a `~/.config/hypr/hypridle-sumi.conf` (incluido con `source =`; el
bloque `general` no se toca); *Give back* los devuelve (el archivo exacto si no lo editaste). Lo hace
`scripts/idle-config.py`: prueba cada candidato con un hypridle **aislado** (sin Wayland ni D-Bus: sólo
lee y dice qué reglas registraría), reinicia **sólo** `hypridle.service` y comprueba en su journal los
plazos registrados; si algo falla, vuelve a lo anterior. Un cambio se aplica tras 0,9 s sin tocar el
selector, y **Undo** lo deshace. Con Keep awake o un modo que pausa el idle, la fila dice
*Temporarily overridden by …*. El archivo gestionado se versiona: sin él hypridle no bloquearía nunca.

**Perfil de una tarjeta de audio (14F).** Audio UI (Super+Shift+A) → *Devices*: en cada tarjeta,
*Change to* ofrece sus perfiles **disponibles** (y *Off*); *Pro Audio* sólo con **Advanced**, porque
renombra las salidas y el EQ y las rutas por app no las siguen. Al elegir uno se lee qué pasará («it
has your default output: the sound cuts while it changes»…). *Test* (o Enter; ←/→ eligen) lo aplica con
`pactl` por el guard (tipo `audio-profile`) y abre la cuenta regresiva de 15 s: *Keep* lo deja; si no,
vuelve el perfil de antes y, si se movieron, la salida y la entrada predeterminadas. WirePlumber recuerda
el perfil elegido de cada tarjeta (`~/.local/state/wireplumber/default-profile`).

| id (JSON) | propiedad | default | efecto |
|---|---|---|---|
| `shell.interface.scale` | `uiScale` | 1.0 | escala lógica de todo el shell (0,8–1,5) |
| `shell.interface.density` | `density` | `default` | reservado: sin fila hasta que tenga efecto |
| `shell.interface.autoHide` | `autoHide` | false | retrae el island; una tira de 10 px arriba-centro lo devuelve |
| `shell.interface.reserveSpace` | `reserveSpace` | false | reclama zona exclusiva |
| `shell.interface.workspaceIndicators` | `workspaceCount` | 5 | dots siempre visibles; 0 = sólo los que existen |
| `shell.animations.mode` | `motionMode` | `normal` | `normal` / `reduced` / `off`; `reduceMotion` queda como lectura derivada |
| `shell.animations.windowStyle` | `windowStyle` | `minimalist` | Ocho estilos de apertura para ventanas flotantes y avisos. Settings → Animations muestra la miniatura con el modo y la velocidad efectivos. |
| `shell.animations.barPanels` | `barPanels` | `slide` | Ocho estilos para los paneles que se abren desde la barra permanente. |
| `shell.animations.islandStyle` | `islandStyle` | `fluid` | Ocho estilos para abrir y recoger la isla y la muesca. |
| `shell.animations.speed` | `motionSpeed` | 1.0 | Slower (0,75), Default (1) y Faster (1,25). La barra recorre el perímetro en Normal, cambia de lado con un fundido en Reduced y se coloca inmediatamente en Off. |
| `shell.calendar.firstDay` | `calendarFirstDay` | `locale` | `locale` / `monday` / `sunday`: primer día de la rejilla del Calendar (9C-2) |
| `shell.calendar.clock` | `clockFormat` | `24h` | `24h` / `12h` («8:28 PM»): `Clock.time`, o sea island, barra, Calendar y Lock (9C-2) |
| `shell.notifications.popupSeconds` | `notifPopupSec` | 4 | vida de un popup normal, 2–30 s; baja urgencia +1 s; los críticos no expiran (9C-2) |
| `shell.osd.durationMs` | `osdMs` | 1800 | cuánto se queda el OSD de volumen/brillo, 800–5000 ms (9C-2) |
| `shell.osd.showValue` | `osdShowValue` | true | el porcentaje junto al carril; «off» (silencio) se ve siempre (9C-2) |
| `shell.launcher.scrollbar` | `launcherScrollbar` | `left` | lado del indicador de scroll del Launcher (9C-2) |
| `theme.typography.textSize` | `textScale` | 1.0 | 1 / 1,08 / 1,15: tamaño del texto (los tamaños de `Typography`), aparte de la escala; no el reloj del reposo ni el Lock (9D-1) |
| `theme.appearance.glassOpacity` | `glassOpacity` | 0.95 | opacidad del vidrio de las surfaces (`Theme.glassBg`; `glassDeep` un punto más); 0,75–1; bajo 0,94 se lee lo de detrás (12D) |
| `theme.appearance.material` | `material` | `glass` | acabado original o `satin`; no cambia `glassOpacity` |
| `theme.appearance.materialEdge` | `materialEdge` | `subtle` | borde del satinado: `none`, `subtle`, `defined` |
| `theme.appearance.materialShadow` | `materialShadow` | true | sombra suave del satinado; no afecta la sombra del material original |
| `shell.surfaces.unloadSeconds` | `unloadSec` | 60 | segundos que una superficie cerrada sigue construida |
| `shell.surfaces.minimizerThumbnails` | `minimizerThumbs` | false | miniaturas en el minimizador (+6 MB) |
| `shell.island.visualizerFps` | `visualizerFps` | 30 | visualizador del reposo: 0 / 15 / 30 / 60 |
| `shell.session.keepAwake` | `keepAwake` | false | sostiene los dos inhibidores de idle |
| `shell.integrations.polkitAgent` | `polkitAgent` | false | el shell es el agente de polkit |
| `shell.integrations.notificationServer` | `notificationServer` | false | sólo se lee al arrancar; **sin fila**: `scripts/notif-server shell\|off\|status` |
| `shell.lock.avatar` | `lockAvatar` | `""` | ruta local del avatar del lock |
| `shell.lock.fetchImage` | `lockFetchImage` | `""` | ruta local de la imagen de la columna de sistema del lock |
| `theme.wallpaper.videoPreview` | `wallpaperVideoPreview` | false | reproduce el vídeo enfocado en la tira (caro) |
| `theme.wallpaper.sources` | `wallpaperSources` | `["~/Pictures/Wallpapers", "~/Videos/Wallpapers"]` | carpetas de la biblioteca (máx. 16, un nivel); 10A |
| `theme.wallpaper.downloadDir` | `wallpaperDownloadDir` | `"~/Pictures/Wallpapers"` | dónde entrarán las descargas de Wallhaven; de Sources y escribible; 10A |
| `theme.wallpaper.rotation.enabled` · `.minutes` · `.from` | `wallRotation` · `wallRotationMinutes` · `wallRotationFrom` | false · 60 · `all` | rotación (15, 30, 60, 180, 360 o 1440 min; all · images · videos · favorites); 10B |
| `theme.wallpaper.rotation.pauseFullscreen` · `.pauseBattery` · `.pauseModes` | `wallRotationPause…` | true · false · false | pausas de la rotación; 10B |
| `theme.wallpaper.transition` | `wallTransition` | `any` | transición de awww para imágenes (any · fade · wipe · wave · grow · outer · none); 10B |
| `theme.wallpaper.wallhaven.username` | `wallhavenUser` | `""` | usuario de Wallhaven (My collections); la **clave no** está aquí; 10E-1a |
| `shell.monitors` | `monitors` | `{}` | presentación por monitor (`modelo\|serie` → `presentation`, `dock`); sin consumidor hasta las fases 8–9 |

Las dos últimas (sección *Lock screen*) usan `components/PathField`: la fila muestra una
vista previa pequeña (redonda para el avatar) y la ruta efectiva, elidida por la izquierda;
`Enter` entra en edición, `Enter` de nuevo guarda, `Esc` cancela. Sólo rutas locales — la
validación real la hace quien consume la ruta (`Avatar.path`, el mismo filtro aquí), así que
un `http:`/`data:` guardado por error simplemente nunca se dibuja.

## Árbol

```
shell.qml               ShellRoot: Variants{screens} → core/Screen; core/Ipc, Shortcuts; LockSession
notif-probe.qml         sonda de las notificaciones en bus privado (va en la raíz: qmldir)
lock-preview.qml        vista previa del lock que NO bloquea (docs/lock/COMPONENTES.md §6; raíz: qmldir)

lock/                   pantalla de bloqueo real (ADR-30, docs/lock/README.md)
  LockSession.qml       dueño: WlSessionLock, PersistentProperties, lock.json, fases, el contrato de la UI
  LockAuth.qml          PamContext (pila login), faillock, el texto tecleado (dentro de LockSession)
  LockSurface, LockBackdrop, LockIsland, AuthCapsule, LockStatus, FetchColumn, MusicCard,
  PowerCorner, Reveal, Parchment    composición, coreografía y fondo — no ven WlSessionLock ni PamContext

core/Screen.qml         por monitor: reserve + overlay PanelWindow, máscara, latches, foco, NotifLayer
core/Island.qml         Morph + caras rest/hover (VizBars, botones, tooltip) + SurfaceHost
core/Morph.qml          width/height/radius con la curva líquida; closeness; morphing; hop
core/SurfaceHost.qml    registro {name → {loader, size}} + Loaders perezosos + descarga + pila de navegación
core/NotifLayer.qml     popups de notificación de un monitor, abajo a la derecha (ADR-29)
core/Osd.qml            cápsula de volumen, donde está el island
core/Ipc.qml            IpcHandler "sumi" (76 verbos, docs/IPC.md)
core/Shortcuts.qml      29 GlobalShortcut (appid `sumi`); descripción de lib/shortcuts.json, acción de Screens.runShortcut
core/KeybindsLayer.qml  la ayuda de atajos (tarjeta flotante, sólo lectura); KeybindsKeys dibuja una combinación
core/Hypr.qml           singleton: focusedName, resolveScreen(), hasFullscreen(); nunca refresh*()
core/Screens.qml        singleton: registro de Screen con unregister

services/Settings       ConfigStore: ~/.config/sumi-shell/settings.json v2 (lib/settings-schema.js); `loaded`, `status`
services/Colors         colors.json de matugen + fallback token a token
services/Session        keep-awake (2 inhibidores), lock(), watcher de suspend
services/Clock          un reloj para todo el shell, re-sync al despertar
services/Wallpaper      inventario sobre Sources, consulta, apply observado, Restore previous, bolsa aleatoria
services/WallpaperRotation  el único programador de la rotación (pausas)
services/ScreenRecorder    el grabador: lanza/sigue scripts/screen-recorder.py, reloj, plan, Completed/Error
core/RecorderPill        la pieza de grabación bajo el island (mini HUD con pausa/parar)
services/Wallhaven      búsqueda remota (explícita, paginada, errores, hosts permitidos)
services/WallhavenStore   estado de la tienda (abierta, pantalla, posiciones) y listas compartidas
core/WallhavenLayer       la tienda como ventana flotante (capa Top, arrastre acotado al monitor)
services/MonitorUi      estado de la UI de inspección (sección, ventana, pausa, procesos)
core/MonitorLayer       la UI de inspección flotante; core/Monitor{Overview,Cpu,Gpu,Memory,
                        Processes,Disks,Network,Sensors} sus secciones; MonitorGraph/Stat/…
services/Downloads      descargas: cola de dos, temporales, validación, reconciliación
services/WallhavenAccount  clave (secrets/, 0600), estado, Test connection, filtros de la cuenta
services/WallhavenIndex    índice privado de asociaciones (0600), colecciones locales
services/Audio          sink/source de Pipewire, señal `changed`
services/Media          MPRIS, selección de reproductor, dedupe programa/backend
services/Cava           espectro del visualizador; cava sólo con un reproductor sonando
services/Apps           entradas de escritorio, ranking y contador de uso
services/Notifs         el servidor de notificaciones (NotificationServer tras un ajuste, ADR-29)
services/NotifHistory   historial persistente 100/7 días (0600, un escritor), no leídas, DND, grupos
services/Privacy        capturas vivas según los nodos de Pipewire (sin el monitor de salidas)
services/Updates        la caché de updates.sh, por FileView con watch
services/Tray           SystemTray; el shell es el watcher del sistema
services/Sysmon         muestras coherentes, historial 60 s, tendencia 1 h y procesos bajo reclamaciones
services/PowerProfile   perfil de energía vía powerprofilesctl
services/Mixer          sinks, sources y streams; volumen por aplicación
services/AudioRoutes    rutas por flujo (efectiva, pedida, recordada) y moverlas (13A/13B)
services/Equalizer      EQ por salida sobre filter-chain (13D; scripts/audio-eq.py)
services/AudioUi        estado de la Audio UI (sección, salida del EQ, posiciones; antes de la fase 14)
services/AudioDevices   tarjetas en lectura: perfiles, puertos, formato (pw-dump bajo reclamación)
core/AudioLayer         la Audio UI flotante; core/Audio{Overview,Output,Input,Applications,
                        Equalizer,Cards} sus secciones; AudioEndpoint/Section/Channel/Focus piezas
services/Net, Bt        Quickshell.Networking / Bluetooth, lectura y acción (9.f)
services/Battery        UPower, con gate para desktops
services/Clip           portapapeles sobre cliphist (9.g)
services/Web            web hub sobre hypr/websites.conf (9.i)
services/Power          acciones de energía de la sesión (9.h)
services/Polkit         agente de polkit con reintento acotado (QS-FUNC-017)
services/SshAgent       agente SSH efímero para el push de dotbackup (10.a)
services/Checks         resumen de `minimaru health` / `doctor` (10.d)
services/Issues         asuntos del Overview del Dashboard (11A-2)
services/Activity       actividad reciente: activity.json (11A-2)
services/Commands       catálogo de sumi y su ejecutor (11B)
services/Toplevels      ventanas para el minimizador (10.b)
services/Units          systemd por ámbito user/system y tipo (10.c; 11F-1)
services/Modes          motor de modos con snapshot, verificación y reconciliación (11D-1)
services/DesktopMode    fachada de compatibilidad hacia Modes
services/Lock           fachada del lock para core/ e IPC (ADR-30); refleja la LockSession registrada
services/SystemInfo     datos de la columna de sistema del lock, sin fastfetch (os/kernel/wm/shell/cpu/gpu/mem)

surfaces/Surface        base de superficie (open, s, closeness, settled, keyPressed)
surfaces/Dashboard      3 pestañas (10.a; 11A-1)          surfaces/CommandPalette  paleta de la CLI (10.g)
surfaces/Launcher       campo + lista rankeada + calculadora
surfaces/Notifications  el centro: grupos, respuesta en línea, Clear all, DND (ADR-29)
surfaces/Mixer          reproducción, salida, resumen del EQ, entrada y apps (9E-1; `media` es su alias)
surfaces/Wallpaper      tira de 5 slots con chase         surfaces/VideoPreview  MediaPlayer aislado
surfaces/ThemePicker    perfil visual (10.c.4)            surfaces/Settings  ajustes + las dos filas de tema
surfaces/System         vistazo del monitor               surfaces/Calendar  mes con semanas ISO
surfaces/Wifi, WifiDetail   redes y ficha (9.f.2)         surfaces/BtList, BtDetail  bluetooth (9.f.3)
surfaces/Clipboard      historial de cliphist             surfaces/WebHub    sitios y búsqueda
surfaces/Minimizer      ventanas y minimizadas (10.b)     surfaces/Power     energía de la sesión
surfaces/System, SystemCard, SystemGraph   Monitor compacto y micrográficas de 60 s
lib/monitor.js         formato y composición pura de muestras, sin acciones
lib/monitor-alerts.js  umbrales y alertas sostenidas del monitor (un solo sitio)
surfaces/Services, ServiceDetail, ServiceJournal   systemd --user (10.c)
surfaces/Auth           diálogo de polkit

components/Icon         glifo Nerd Font por nombre (codepoints verificados con fontTools)
components/Aviso        glifo + contador que mide 0 px cuando no hay nada que decir
components/NotifCard    un popup de notificación (todo lo que pinta es dato ajeno)
components/TrayIcon, TrayMenu   bandeja y su DBusMenu dibujado en Minimaru (ADR-24)
components/Workspaces   dots por monitor, desde los modelos tipados
components/ActionButton, ActionGroup   botones y grupos de acciones dinámicos
components/SettingRow, Toggle, Choice, Slider, SearchField   controles

theme/Theme, Motion, Metrics, Typography   tokens
lib/fuzzy.js, calc.js   portados de Ukishima (MIT, ver lib/LICENSE-ukishima); lib/ansi.js
scripts/notif-server    notificaciones: shell | off | status (systemd), direct-shell | direct-off | direct-status
scripts/apply-scheme, ssh-askpass
```

## Añadir una superficie

1. `surfaces/Foo.qml` que herede de `Surface`, defina `implicitHeight` (y `implicitWidth`
   si no es fija) y, si consume teclas, `function keyPressed(event)`.
2. En `core/SurfaceHost.qml`: una entrada en `registry` (`loader`, `size(item)`) y un
   `Loader { id: ldFoo; active: false; anchors.fill: parent; onLoaded: host.revision++; sourceComponent: Foo { … } }`.
3. Nada más: IPC, morph, foco y descarga salen del registro.

## Notas de implementación (aprendidas en la Fase 1)

- Una propiedad QML llamada `onXxx` se parsea como manejador de señal al asignarle valor:
  por eso los tokens Material `on_surface`/`on_primary` se llaman `fg`/`fgOnPrimary`.
  `error` también está reservado en `Singleton` (→ `errorColor`).
- `IpcHandler` no tiene propiedad por defecto: los hijos (FileView…) van en un `Scope` que
  lo envuelva.
- El proceso se llama `qs`, no `quickshell`, cuando se lanza con `qs -c` (para `pgrep`).
- **Asignar a una property que tiene binding lo rompe.** `Process.running: flag` más un
  respawn que hace `running = true` deja el proceso fuera del control del flag. Donde haya
  respawn, el `running` se maneja entero a mano (`onFlagChanged` + `Component.onCompleted`).
- **Una `Image` con `source` decodifica aunque esté `visible: false`.** En una lista larga
  hay que atar el propio `source` a la ventana visible, no sólo la visibilidad: con 79
  miniaturas eso eran 153 MB y 3.6 % de CPU en una tira inmóvil.
- **Los modelos de Quickshell se pueblan tarde**, no sólo los de Hyprland:
  `DesktopEntries.applications` da 0 entradas en `Component.onCompleted` y 70 a los
  ~300 ms. Consumirlos por binding, nunca leerlos una vez y guardarlos.
- **`Palette` es un tipo de QtQuick**: un singleton propio con ese nombre pierde, el binding
  resuelve al tipo y todos los tokens leen `undefined` (sin error, sólo
  "Unable to assign [undefined] to QColor"). Por eso el singleton se llama `Colors`.
- No llamar `Hyprland.refresh*()` al arrancar (docs/REVERSE_ENGINEERING.md, BUG-1). El IPC
  con monitor `""` a 1.5 s del arranque abre correctamente: es la prueba de regresión.
- **`onPositionChanged` de un `MouseArea` también dispara cuando el ítem se mueve bajo un
  cursor quieto.** Con superficies animadas eso basta para que el hover robe el foco del
  teclado nada más abrir. La fila avisa en coordenadas de ventana (`mapToItem(null, …)`),
  que no cambian si el que se mueve es el ítem, y el dueño compara con la última posición;
  la primera lectura tras abrir **sólo siembra la referencia**, nunca cambia el foco.
- **A un singleton QML no se le escribe por nombre dinámico.** `Settings[key] = v` no
  produce error y no escribe nada; hay que resolver la property en el propio código
  (`(v) => { Settings.uiScale = v; }`).
- **`Connections` interpreta cualquier `onXxx` como señal del *target*.** Poner ahí un
  `onTargetChanged` para depurar da "Cannot assign to non-existent property" e **invalida
  el bloque entero**: los handlers legítimos dejan de conectarse. Una traza mal puesta
  puede así fabricar el defecto que se estaba buscando.
- **Una captura inmediata no prueba ausencia.** Las superficies entran animadas: `grim`
  disparado en el mismo comando que el cambio sale antes de que se vea nada. Para
  comprobar que algo aparece hay que esperar ~0.45 s.
- **`FileView.reload()` es asíncrono aunque `blockLoading` sea `true`**: `text()` sirve el
  contenido *anterior*. Por eso la primera llamada a `status()` tras arrancar devolvía el RSS
  de cuando se construyó el `FileView` — 198844 kB medidos contra 394748 reales, un 50,4 % por
  debajo, y por debajo incluso del suelo de plataforma, que era la pista. Lo arregla
  `blockAllReads: true`, que hace síncrono también el reload (Fase 9.a: −4 kB de desfase).
- **`PwObjectTracker` no es opcional.** Sin él, `Pipewire.nodes` se puebla pero
  `properties["media.class"]` es `undefined` en todos los nodos y `audio.volume` se lee `0.00`
  en vez del valor real. Rastrear no es "mantener fresco": es la condición para que el nodo
  tenga datos. Consecuencia: como `services/Privacy` rastrea todos los nodos siempre (lo
  necesita), la puerta de muestreo de `Mixer` no ahorra nada hoy — se conserva por correcta, no
  por ahorradora.
- **En un stream de reproducción, `isSink` vale `true`** (alimenta a un sink). No sirve para
  distinguir dispositivo de stream; para eso está `isStream`.
- **Para medir geometría, preguntarle al shell, no a una captura.** Medir anchos con `grim` y
  un umbral de brillo es poco fiable: la sombra y los bordes redondeados semitransparentes hacen
  que el detector se coma o se invente píxeles (daba 336/344 donde el shell dice 281/429), y con
  otro wallpaper deja de encontrar el island. `status().screens[].island` expone `w`, `h`,
  `restW` y `hoverW` reales. La captura sirve para ver si algo se dibuja **mal**, no para medirlo.
- **Un binding que lanza no avisa: deja el valor anterior.** En el calendario, indexar la celda
  con `parent.parent.index` daba `undefined`, el binding de `visible` moría y se quedaba en su
  valor por defecto (`true`), así que los 42 días salían marcados como hoy y sin número. Dentro
  de un delegate hay que referenciar por **id** (`weekRow.index`), no por cadenas de padres, y
  añadir `pragma ComponentBehavior: Bound`. Es el mismo modo de fallo silencioso que el ciclo de
  anchos de 9.c.
- **`components/Choice` pinta con Inter**, que no tiene Nerd Font: meter un glifo en el `label`
  de una opción lo dibuja como caja.
- **`Column.implicitWidth` es el máximo del *ancho* de sus hijos, no de su `implicitWidth`.**
  Atar el ancho del contenedor a `col.implicitWidth` y a la vez el de las filas al del
  contenedor cierra la cadena sobre sí misma (`w = max(min, w)`): la caja se queda en el mínimo
  y el texto se sale. **No hay aviso de "binding loop": la ecuación no diverge.** Regla: la fila
  declara `implicitWidth` desde su contenido y nada más; lo que deba ocupar todo el ancho se
  estira con `x`/`width` explícitos contra el contenedor.
- **Una entrada de menú con hijos ES el handle de su submenú.** Su `menuHandle` apunta al menú
  que la *contiene*, no al suyo: usarlo dibuja el submenú idéntico a su padre.
- **Hace falta un `QsMenuOpener` por nivel abierto.** Reasignar uno solo cierra el menú padre, y
  un submenú de DBusMenu sólo es válido mientras su padre sigue abierto: llega vacío. No es el
  handshake `AboutToShow` — `opened()` y `updateLayout()` se ejecutan sin error y no cambian nada.
- **Una superficie layer-shell sólo abre un popup con *grab* si el clic es real.**
  `QsMenuAnchor.open()` llamado desde un IPC da `Failed to create grabbing popup … parent window
  has received input`. Por eso el menú de la bandeja se dibuja en QML: así se puede probar sin
  ratón (ADR-24).
- **`QsMenuAnchor` exige `//@ pragma UseQApplication`** en la primera línea de `shell.qml`. Su
  coste medido es ruido (410,9 contra 409,7 MB), pero arrastra el tema de QtWidgets.
- **Un cliente de bandeja se re-registra solo** cuando reaparece el watcher: no hay que ordenar
  `udiskie.service` detrás del shell. Medido parando y arrancando el shell con udiskie intacto.
- **Una clase de Waybar puede venir como lista.** `updates.sh` emite
  `"class": ["updated","error"]`: leer `class[0]` daba "updated" y escondía el aviso justo
  cuando la comprobación había fallado. Hay que mirar la lista entera.
- **SwayNC era activable por D-Bus** (`/usr/share/dbus-1/services/org.erikreider.swaync.service`):
  pararlo con systemd no bastaba, cualquiera que tocase su bus lo resucitaba — un `stop` durante
  las pruebas devolvió `Job canceled` porque el propio cliente del shell lo reactivó. Por eso la
  Fase 3 lo enmascaró en vez de pararlo. Desinstalado en la Fase 4 (2026-09-22); la lección vale
  para cualquier daemon con activación D-Bus.
- **`pw-record` es la forma de provocar un aviso de privacidad**: aparece un nodo con
  `media.class = Stream/Input/Audio`. Una captura por wlr-screencopy (`wf-recorder`, `grim`) **no**
  crea nodo y por tanto no lo enciende, ni aquí ni en Waybar. **El aviso de «micrófono» cuenta
  toda captura de audio**, también la del monitor de una salida (`stream.capture.sink = true`):
  OBS grabando el escritorio o maly con su visualizador (`pw-record` sobre `@DEFAULT_MONITOR@`).
  Es a propósito y el usuario lo quiere así. Sólo se excluye el cava del shell, marcado con
  `PIPEWIRE_PROPS` (filtrar por `stream.capture.sink` los escondía a todos: pasó y se corrigió
  el 2026-09-15). Para provocarlo: `pw-record --target <monitor> -P '{ stream.capture.sink = true }' /dev/null`.
- **`wtype` no dispara keybinds de Hyprland.** Escribe en una superficie que tenga el foco, que
  es otra cosa. Para probar un atajo: `hyprctl eval 'hl.dispatch(hl.dsp.global("sumi:X"))'`.
- **`Qt.exit(0)` no funciona en Quickshell** (`Signal QQmlEngine::exit() emitted, but no
  receivers connected`): un sondeo con `qs -p` se termina con `timeout`.
- **`pgrep -f "qs -c sumi"` no es fiable** para encontrar el shell: caza transitorios del
  `ExecStartPre` y a los propios clientes `qs … ipc call`. El PID bueno sale de
  `systemctl --user show sumi-shell -p MainPID --value` o de `status().pid`.
- Tras `Quickshell.reload(false)` la superficie abierta se cierra (el estado de Screen se
  reconstruye); el PID y las ventanas se conservan.
- Un `SIGSEGV` lo recupera el propio `qs` (mismo PID, "Quickshell has been restarted");
  `Restart=on-failure` en la unidad es la segunda red. Tras esa recuperación el proceso pasa a
  llamarse `quickshell` y su cmdline **pierde `-c sumi`**: buscar el shell por nombre o por
  cmdline falla (lo sufrieron `scripts/notif-server` y `tools/measure.sh`); usar `MainPID`. Las
  ids de notificación vuelven a empezar en 1 (el historial ya no las usa de clave).
- **Las notificaciones** tienen su propio documento: `docs/FASE9/NOTIFICACIONES.md` (decisiones,
  procedimiento del cambio, no pérdida) y ADR-29. El cambio de servidor sólo con
  `scripts/notif-server`. Sin gestor de usuario, sigue `packaging/NO-SYSTEMD.md`;
  `direct-shell` exige detener la shell y conserva las activaciones ajenas.

## Red y bluetooth (9.f.1)

`services/Net` y `services/Bt` envuelven `Quickshell.Networking` y `Quickshell.Bluetooth`. Tres
cosas que conviene saber antes de tocarlos:

1. **Los módulos son `Quickshell.Networking` y `Quickshell.Bluetooth`.**
   `Quickshell.Services.Network` **no existe** — falla con *module is not installed*.
2. **Todo por binding.** En `Component.onCompleted` (t=0) `Networking.devices` está vacío,
   `wifiEnabled` vale `false` y `Bluetooth.defaultAdapter` es `null`; todo poblado a **55 ms**
   (sonda a 50 ms, 2026-09-08). Por eso cada servicio tiene `ready = hasData || settled`, con
   `settled` a los 1500 ms: sin eso no se distingue «aún no llegó» de «no hay hardware».
3. **`signalStrength` viene 0–1**, no 0–100.

Y dos que ahorran trabajo: `Networking` entrega la lista de redes **ya deduplicada por SSID y
sin las ocultas** (17 entradas contra 19 BSSID / 15 SSID de `nmcli`), y `Network.known` dice de
antemano si hará falta contraseña. El escáner (`WifiDevice.scannerEnabled`) se queda **apagado**
aquí; encenderlo es cosa de la superficie de 9.f.2, que también tiene que apagarlo al cerrarse.

    qs -c sumi ipc call sumi status | jq .network
    qs -c sumi ipc call sumi status | jq .bluetooth

**Emparejar con código (2026-09-22).** `Bt.pairWith()` no llama a `pair()` del binding: abre una
sesión **interactiva** de `bluetoothctl` con `agent on` + `default-agent` y stdin abierto, porque
Quickshell 0.3.1 no registra agente (comprobado en el binario, y el PR #138 de upstream se cerró
sin fusionar). Eso quiere decir que BlueZ **sí pregunta**, y la pregunta llega por el mismo stream
que ya se parsea:

    [agent] Confirm passkey 753437 (yes/no):

Hasta esa fecha nadie la contestaba: BlueZ esperaba sus ~40 s y la ficha acababa enseñando
`AuthenticationTimeout` con el prompt crudo pegado — o sea, el shell tenía el código en la mano y
lo enseñaba como error en vez de como pregunta. Ahora `pairLine()` la reconoce, la ficha muestra el
código con *Yes, the codes match* / *No*, y `Bt.answerPair()` escribe la respuesta. Las dos huellas,
medidas con un iPhone: sin contestar, `AuthenticationTimeout` a los ~40 s; contestando «no»,
**`AuthenticationFailed` en 1,3 s**. Lo que pide **teclear** un PIN (`Enter PIN code`) sigue sin
cubrirse: se dice y se manda a `bluetoothctl`, en vez de dejar a BlueZ esperando.

    qs -c sumi ipc call sumi btConfirm true     # contestar sin ratón

La superficie de wifi (9.f.2) vive en `surfaces/Wifi.qml`, con **SUPER+CTRL+N**. Tres cosas que
conviene no volver a aprender:

1. **Anclajes y altura fija, nunca un `ListView` dentro de un `Column`.** Los delegados miden el
   ListView, el ListView mide la Column y la Column calcula su `implicitWidth` a partir del
   ListView; si encima la lista crece mientras el morph abre, el destino se mueve en vuelo. Qt lo
   canta como `Column called polish() inside updatePolish()` y **el shell deja de responder al
   IPC** (2026-09-09).
2. **`known` no basta para conectar sin clave.** NetworkManager puede tener el perfil y no la
   clave; hay que reintentar pidiendo contraseña cuando llega `NoSecrets`.
3. **Los `toString()` de los enums devuelven frases, no nombres** (`NoSecrets` sale como
   "Secrets were required but not provided"). Compara contra el enum.

Elegir una red abre `surfaces/WifiDetail.qml` (ficha con IP, MAC, BSSID, cifrado y último uso,
más conectar/desconectar, limpiar claves y olvidar). Tres cosas más que costaron encontrarse:

4. **La ficha también tiene que sostener el escáner**, y el apagado lleva 2 s de margen. Si no,
   al saltar de la lista a la ficha el contador toca 0, NetworkManager tira la lista y **la red
   recién elegida desaparece del modelo**.
5. **Escape**: la superficie abierta tiene derecho de veto (`core/Screen.qml`). Qt despacha
   `onEscapePressed` antes que `onPressed`, y el evento llega **ya aceptado**: hay que bajar
   `e.accepted = false` antes de delegar.
6. **`connectWithPsk()` sólo vale para WpaPsk/Wpa2Psk/Sae.** Para las EAP empresariales no hay
   camino desde el shell: la ficha manda a `nmtui` o `nm-connection-editor`. (Hasta 10.e mandaba
   a rofi, ADR-18 — que tampoco podía: `wifi.sh` sólo hacía `nmcli … password`.)

**La IP es el único proceso de todo 9.f.** No tiene fuente nativa (`read()` da `method: auto` con
`addresses` vacío, y `NetworkDevice.address` es el MAC), así que se lanza
`ip -j -4 addr show <iface>` sólo mientras la ficha está abierta.

Los verbos son `wifiScan`, `wifiConnect <ssid>`, `wifiDisconnect`, `wifiRadio <bool>`,
`wifiForget <ssid>`, `wifiClearSecrets <ssid>`, `wifiRecheck` y `wifiDetail <ssid> <mon>`.

**El cable tiene su ficha desde el 2026-09-21** (`surfaces/Wired.qml`, QS-FUNC-015). Hasta
entonces `WiredDevice` se leía sólo para el indicador: el island decía `ethernet`/`LAN` y la
superficie no tenía dónde contarlo. Tres cosas que conviene saber:

7. **La fila del cable es el índice −1 del cursor**, no un elemento del `ListView`. Aquel modelo
   son redes wifi; meter ahí algo ajeno obligaría a corregir índices en el delegado y en el
   escáner. Por debajo del cero no molesta a nadie, y el título del panel pasa a «NETWORK».
8. **`refreshIp(iface)` ya no está clavado al wifi.** Sin argumento pregunta por la interfaz
   activa (`ifname`, que sabe que el cable manda); cada ficha pide la suya con `refreshWifiIp()` o
   `refreshWiredIp()`. `status().network` publica `ipv4Iface` para que la IP no se pueda leer mal.
9. **Desconectar el cable apaga antes `autoconnect`.** Con él encendido NetworkManager vuelve a
   levantar el perfil al instante y la acción parece no hacer nada. Es la única acción del
   servicio que puede dejar la máquina sin salida: la ficha la pide con confirmación.
10. **Una superficie no se entera de `singleton.propiedadVar.campo`.** `Net.wiredDev.connected`
    en un binding de la ficha **no se reevaluó** al desconectar el cable de verdad (2026-09-21):
    la tarjeta se quedó diciendo «connected», con la IP muerta y el botón en *Disconnect*,
    mientras `AUTOCONNECT` —que sale de `Net.wiredAutoconnect`, declarada dentro del singleton—
    sí cambiaba. La regla ya estaba en la cabecera de `Net.qml` y ahora tiene una cicatriz: el
    servicio publica **estado plano** y las superficies leen eso (`Net.wiredUp`). Sólo se ve
    ejecutando la acción; ninguna recarga ni ninguna captura lo habría enseñado.

### Bluetooth (9.f.3)

`surfaces/BtList.qml` con **SUPER+CTRL+B**, y `surfaces/BtDetail.qml` para la ficha del aparato.
Ni un proceso: `Quickshell.Bluetooth` cubre tambien `connect`, `disconnect`, `pair`,
`cancelPair`, `forget`, `trusted`, `blocked` y `discovering`.

**Se llama `BtList` y no `Bluetooth` a proposito**: `Quickshell.Bluetooth` es un singleton del
mismo nombre, y un tipo propio que lo tape en un archivo que importe los dos seria un fallo
silencioso. La clave del registro si es `bluetooth`.

Cinco cosas medidas el 2026-09-09 que conviene no volver a descubrir:

1. **`discovering = true` si puebla el modelo con lo NO emparejado** (8 aparatos en 14 s,
   identicos a `bluetoothctl devices` en la misma corrida). No hace falta el rodeo del stdin
   interactivo que necesitaba `rofi/scripts/bluetooth.sh`.
2. **Pero bluez CACHEA lo visto**: tras parar el escaneo, `bluetoothctl devices` sigue listando
   a los vecinos. Por eso la lista solo ensena lo encontrado **mientras se busca**; si no, una
   pantalla que dice "tus dispositivos" se llena de televisores ajenos.
3. **`dev.name` cae al MAC con guiones** (`5E-7F-0A-0A-6C-8F`) cuando el aparato no se anuncia:
   6 de 8. De ahi `Bt.isAnonymous()`, para no pintar la misma cadena dos veces en una fila.
4. **`dev.icon` llega vacio en 6 de 8.** `Quickshell.iconPath()` no basta; hace falta glifo de
   reserva por clase (`Bt.deviceGlyph()`).
5. **`discovering` no cambia sincrono**: escribirlo y leerlo en el mismo tick devuelve el valor
   viejo; a los 500 ms ya es el nuevo.
6. **La bateria puede no venir por bluez.** El DualSense no publica `org.bluez.Battery1`: su carga
   vive en `/sys/class/power_supply/ps-controller-battery-*`. `batteryAvailable: false` ahi es
   correcto, no un fallo -- y el script original, que parseaba `bluetoothctl info`, tampoco la
   veia.

**EMPAREJAR ES EL UNICO PROCESO, y la razon esta medida.** `BluetoothDevice.pair()` empareja pero
**no crea bond**: sin el, el emparejamiento no sobrevive a una desconexion y el kernel ni siquiera
expone el aparato aunque bluez diga `Connected: true`. Tres caminos, mismo mando, mismo dia:

| Camino | `Bonded` |
|---|---|
| `pair()` del binding | `false` |
| `bluetoothctl pair <addr>` suelto (lo que hace ukishima) | `false` |
| **sesion interactiva** por stdin con `agent on` + `default-agent` | **`true`** |

La razon llevaba meses escrita en `rofi/scripts/bluetooth.sh` (lineas 85-93): una invocacion
suelta de `bluetoothctl` no hace el trabajo, hay que alimentar una sesion interactiva. Alli era
para `scan on`; vale igual para `pair`, porque **es la sesion interactiva la que registra el
agente**. Y hace falta agente hasta para un aparato "just works": la corrida de control imprimio
`[agent] Authorize service 00001124...` (perfil HID).

Asi que `services/Bt` lanza `["bluetoothctl"]` -- argv puro, **nunca `sh -c`** (SECURITY.md regla
3, que ukishima incumple aqui) -- con `stdinEnabled`, escribe los comandos en `onStarted` (antes
la sesion no existe) y reacciona a las lineas con `SplitParser`. Se cierra con `quit` y un plazo
de 3 s que la mata si no se va sola.

Queda **una** reserva sin medir: un aparato que pida PIN o confirmacion haria que la sesion
preguntara por stdin y el shell no tiene con que contestar. Ahi hace falta `bluetoothctl`
interactivo en una terminal, que es lo que dice la lista al fallar. (Hasta 10.e decia rofi,
ADR-18 — pero `bluetooth.sh` hacia `bluetoothctl pair` suelto, sin agente: tampoco contestaba
el PIN.) El dia que upstream fusione su agente (PR #138, cerrado sin fusionar el 2025-07-23),
esto se tira entero y se vuelve a `pair()`.

Los verbos son `btScan <bool>`, `btPower <bool>`, `btConnect <addr>`, `btDisconnect <addr>`,
`btPair <addr>`, `btCancelPair <addr>`, `btForget <addr>`, `btTrust <addr> <bool>`,
`btBlock <addr> <bool>` y `btDetail <addr> <mon>`. Aqui no hay secreto que proteger: una
direccion MAC no es una contrasena, asi que pasarla por argv no reintroduce el riesgo que
`connectWithPsk` evita en wifi.

## ToplevelManager (ventanas) — existe, pero le falta el workspace

`Quickshell.Wayland` expone **`ToplevelManager`** (singleton, con `toplevels` y `activeToplevel`)
y **`Toplevel`** con `appId`, `title`, `activated`, `minimized`, `maximized`, `fullscreen`,
`activate()` y `close()`. Comprobado en vivo: se puebla a los **28 ms** del arranque del proceso.

**Lo que NO trae es el workspace**, y eso decidio 9.j: el conmutador de ventanas del rice
minimiza moviendo a `special:minimized`, asi que habria que salir a Hyprland igualmente. Leer la
lista desde el shell cuesta **0,005 ms** contra los 15 ms del script de rofi, pero la latencia
total (~5 ms contra 18) no es perceptible. Veredicto: se queda en rofi (docs/MIGRATION.md §9.j).
Superado por alcance, no por medición (ADR-27): el minimizador de 10.b lo sustituyó y
`window-switcher.sh` se retiró en 10.e.

## Anadir un atajo global

Desde la ayuda de atajos (2026-10-30) son estos sitios, y `tests/api/api-check.py` comprueba que cuadren:

1. `lib/shortcuts.json`: la entrada (nombre, título, categoría, descripción, tecla por defecto que no choque).
2. `core/Shortcuts.qml`: un `GlobalShortcut` con `name: "x"`, `description: Keybinds.description("x")` y
   `onPressed: Screens.runShortcut("x", "", "shortcut")`; y la acción en `Screens.runShortcut`.
3. `api/contract-v1.json` y `API.md` si es público (todos lo son hoy), y los dos `examples/hyprland/`.
4. En el rice, `hypr/modules/keybinds.lua` con `sumiShell("x")` **y** `sumiDesc("x")` (sin la descripción
   la ayuda no puede mostrar su tecla).

Si falta el `GlobalShortcut`, **la tecla no hace nada y no avisa de nada**: Hyprland despacha a un atajo sin
cliente (pasó el 2026-09-09 con `power`). El contraste que lo caza:

    grep -oE 'sumiShell\("[a-zA-Z]+"\)' ~/.config/hypr/modules/keybinds.lua | sort -u
    grep -oE 'name: "[a-zA-Z]+"' core/Shortcuts.qml | sort -u

Los dos conjuntos tienen que coincidir en ambos sentidos. Y `hyprctl globalshortcuts` muestra lo
que el compositor ve de verdad.

## Acciones dinamicas: `components/ActionGroup`

Salio de la auditoria de UI del 2026-09-09 y **no sabe nada de redes**: solo importa `QtQuick` y
`theme`. Se le pasa una lista y el se dibuja, se mide y se navega solo.

    ActionGroup {
        actions: [
            { id: "connect", label: "Conectar", primary: true },
            { id: "forget",  label: "Olvidar",  danger: true, confirm: true, visible: known }
        ]
        onTriggered: (id) => ...
    }

Campos: `id` · `label` · `visible` · `primary` · `danger` · `confirm` (segundo Enter) · `enabled`.
`orientation` es `vertical` (arriba/abajo) u `horizontal` (izquierda/derecha), y `handleKey(event)`
devuelve si consumio la tecla. **El foco es un indice sobre lo que se ve**, no sobre la lista
completa, y se re-acota solo cuando una accion aparece o desaparece -- que era justo el fallo que
lo motivo. Uselo cualquier superficie con un numero variable de botones, empezando por 9.f.3.

Tres cosas que costaron encontrarse al escribirlo:

7. **Reasignar el mismo objeto a una property `var` no notifica.** QML compara por referencia:
   hay que construir uno nuevo (`Object.assign({}, ...)`).
8. **`onActiveChanged` solo corre cuando el valor cambia.** El host carga las superficies
   perezosamente **ya abiertas**, asi que lo que haya que hacer al abrir va tambien en
   `Component.onCompleted`.
9. **Al ocultar un campo de texto hay que devolver el foco.** Qt le quita `activeFocus` al
   `TextInput` sin dárselo a nadie, y el `FocusScope` de `core/Screen` deja de recibir teclas: la
   superficie se queda **sorda al teclado con el raton funcionando**. Se resuelve en el handler
   del estado que oculta el campo, no en cada sitio que lo cierra.
10. **Semaforos con contador se desbalancean** con la descarga perezosa. Para "quien necesita
   esto", una reclamacion con nombre (idempotente) en vez de `++/--`.
**Ninguno acepta la contraseña**, a propósito: lo que se gana con `connectWithPsk` es que la
clave no pase por argv, y un verbo con clave la dejaría en `ps`.

## Medidas (HDMI-A-1 1920×1080, Quickshell 0.3.1, 2026-09-07)

| | CPU reposo | RSS |
|---|---|---|
| Shell mínimo (1 PanelWindow + 1 Rectangle) — suelo de la plataforma | — | 265 MB |
| Sumi Shell sin sombra | — | 277 MB |
| Sumi Shell Fase 1 | 0 ticks / 20 s | 290 MB |
| Sumi Shell Fase 2, reposo tras arranque limpio | 2 ticks / 30 s (0.07 %) | 329 MB |
| Sumi Shell Fase 6, reposo | ~0.2 % | 394 MB (355 sin el servicio de media) |
| Sumi Shell Fase 6, tarjeta de media abierta | 0.4 % | 450 MB |
| Sumi Shell Fase 2, tras una sesión larga de pruebas | 14 ticks / 20 s | 355 MB, **estable** |
| Sumi Shell Fase 8, reposo (con un MPRIS reproduciendo) | 0–1 ticks / 15 s | 362 MB |
| Sumi Shell Fase 8, settings abierto | 1 tick / 10 s | 360 MB (dentro del ruido) |
| **Parada técnica 2026-09-08, arranque limpio, nada abierto** | **1 tick / 20 s** | **355,9 – 376,9 MB** |
| Parada técnica, tras una pasada por las 7 superficies | — | 457 MB |
| Parada técnica, tras 3 pasadas (sin fuga: 457 → 452 → 458) | — | 458 MB |
| Parada técnica, tras abrir además la tira de wallpapers | — | 488 MB |
| Parada técnica, tras `unload` explícito + 4 s | — | 467 MB (devuelve 21 de 111) |
| Ukishima en reposo (referencia) | ≈0.5 % | 416 MB |
| **Rediseño ARR-03 (2026-09-24), sesión recién arrancada** | 0,10 % | 435,6 MB |
| **Rediseño completo (16F, 2026-10-01), 3 min tras reiniciar, sin tocar** | **0,05 %** | **435,7 MB** |
| 16F, tras 3 pasadas por las 20 surfaces y 3 flotantes (556 → 569 → 574) | 0,10 % | 567,5 MB |
| 16F, sesión de uso con juegos, 2 h 41 min (no es el suelo) | — | 861–874 MB |

Los 329 MB de la Fase 2 quedan ~39 MB por encima de la Fase 1 y 14 MB por encima del
criterio que se fijó (suelo 265 + 50). La hipótesis era el vidrio de hyprglass, y **la
medida la desmintió**: 329 MB con la capa glaseada y 331 MB sin ella, así que el coste no
está ahí sino en lo que la Fase 2 añadió al propio shell (FileViews, tokens, derivaciones).
De ahí ADR-14: lo caro se mide antes de darlo por sabido.

El RSS crece con la actividad de render y luego se queda plano: 100 llamadas a `status`,
20 ciclos de apertura/cierre y 45 s de reposo no lo movieron ni un MB. No hay fuga; es
memoria que Qt no devuelve al sistema (lo mismo que se midió en Ukishima).

### Corrección del 2026-09-08 (parada técnica)

Durante la auditoría se midieron **498–520 MB** y se anotó como si fuera el suelo del shell.
**Era falso, y el error fue de método:** esa cifra salió de un proceso que llevaba horas vivo y
al que se le habían abierto todas las superficies muchas veces. Repetido con el procedimiento de
ADR-23 —reiniciar, esperar, no tocar nada— el suelo real es **355,9–376,9 MB**, coherente con los
371,5 MB que ya estaban escritos.

Lo que sí es cierto y no estaba escrito: **la primera vez que se toca cada superficie el RSS sube
~80 MB, la tira de wallpapers otros ~30, y eso no vuelve.** `unload` devuelve 21 MB de los 111.
No es una fuga (tres pasadas seguidas dejan 457 → 452 → 458 MB), es memoria que Qt retiene:
cachés de imagen y de glifos, y arenas de glibc.

Dos avisos para futuras medidas:
- El ruido entre corridas limpias es de **~10 MB sobre 360**. Dos corridas que difieran menos que
  eso no distinguen nada. Se vio al medir el tracker de Pipewire: la versión **sin** tracker salió
  9 MB *por encima* de la que lo lleva.
- Medir sobre un proceso que ya se ha usado no mide el shell, mide la sesión.
