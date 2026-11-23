# Traspaso para el README público de Sumi Shell

> Los hashes de commit citados aquí son del historial anterior a la publicación, que se reinició el 2026-11-23 con un único commit inicial. El autor conserva ese historial en privado.

La próxima sesión se dedica al [README raíz](../README.md). La aceptación de portabilidad de 0.4.0 está cerrada. Usa el [informe de aceptación](PORTABILITY-ACCEPTANCE.md) para sostener las afirmaciones sobre Arch y consulta el código cuando necesites comprobar una etiqueta, un comportamiento o una opción. El README actual está en inglés.

## Identidad y arquitectura

**Sumi Shell** es una shell de escritorio MIT para Hyprland, escrita en Quickshell y Qt Quick/QML. Es un proyecto independiente derivado de Ukishima. El nombre anterior era Kitasan-Shell y la migración explícita `identity-v1` copia el perfil legado. Minimaru es también el nombre de la paleta estática predeterminada. La shell se instala sin los dotfiles, comandos de Fish ni tareas del entorno donde se desarrolló.

Un mismo proceso ofrece una presentación por monitor y superficies que se abren desde ella o como ventanas independientes. Incluye lanzador, Overview/Dashboard, Settings, monitor del sistema, mezclador y medios, calendario, fondos de pantalla, bandeja y bloqueo de sesión. El portapapeles, grabador, proveedores de fondos, servicios de red y Bluetooth y la gestión de la pantalla de inicio de sesión dependen de sus respectivas integraciones. Las notificaciones y el agente Polkit de Sumi vienen apagados y se activan de forma explícita. La interfaz de **Login screen** se comunica con el proyecto separado **Sumi SDDM** mediante su CLI API 1.

El runtime descubre las capacidades del entorno y Settings → System → Environment muestra qué está disponible. La configuración de usuario vive bajo `$XDG_CONFIG_HOME/sumi-shell`. El estado y los cachés tienen sus bases XDG. Los datos del usuario están separados del árbol de Quickshell, con un esquema v4 para los ajustes y archivos independientes para tareas, marcadores y proveedores. El contrato público de IPC se versiona por separado. A la fecha de este traspaso enumera 11 verbos públicos y 32 atajos globales. Usa el contrato como fuente para esos recuentos.

## Presentaciones y aspecto

Las preferencias de presentación y notch se guardan por monitor. Las controla Settings → Shell → Layout y su enlace a **Notch**.

| Presentación | Qué muestra |
| --- | --- |
| Dynamic Island | Presentación inicial de un monitor nuevo. Isla compacta con reloj y actividad que se expande para mostrar paneles. |
| Barra persistente | Barra con accesos de escritorio y estado del sistema. Position y Length permiten ajustar el borde y la longitud por monitor. |
| Notch | Sustituye la isla en reposo por una muesca unida al borde. Conserva las superficies y ofrece actividades configurables. |
| Barra-notch | Activa **Persistent bar** y **Enable notch** a la vez. La barra se une al borde y adopta el contorno de notch. En el código es `barDock`, una combinación de las dos preferencias. |

**Soft** y **Terminal** se eligen en Settings → Theme → Interface style y se pueden combinar con las presentaciones. Soft usa radios, cápsulas y velo de acento. Terminal usa marcos rectos, controles con aspecto de terminal y texto monoespaciado por defecto. El marco, las decoraciones y el texto monoespaciado son ajustables. Interference, scanlines y glow son efectos opcionales de Terminal, apagados por defecto. Paleta, material, tipografía y movimiento son ajustes distintos. Los materiales implementados en Settings son **Glass** y **Vidrio Satinado**. Hay paletas estáticas y un proveedor dinámico opcional mediante Matugen. Las reglas de vidrio del compositor tienen sus propios requisitos.

La campaña Arch tiene capturas explícitas de barra, Island y notch. Barra-notch, Soft y Terminal constan en el código. Trata las capturas que falten de esas combinaciones como trabajo visual de la siguiente sesión, sin atribuirlas a la matriz de aceptación. [Presentación por monitor](../sumi/core/Screen.qml) · [Estilos](../sumi/theme/Style.qml) · [Opciones de Settings](../sumi/surfaces/Settings.qml)

## Requisitos y dependencias

Para el núcleo, documenta una sesión Wayland de Hyprland con su IPC, Quickshell **0.3.1 o superior con los módulos usados por Sumi**, Qt 6 con Qt Quick y plataforma Wayland, Python **3.11 o superior**, D-Bus de sesión, Bash y las herramientas GNU declaradas en el [README actual](../README.md#dependencies). Quickshell debe incluir los módulos requeridos de Hyprland, Wayland, Io, Widgets, Networking, Bluetooth, PipeWire, UPower, MPRIS, SystemTray, Notifications, Polkit y PAM. Tener el número de versión adecuado por sí solo no garantiza el conjunto de módulos.

PipeWire y WirePlumber son la pila que se ensayó para audio. Fontconfig detecta las fuentes y el paquete Arch declara Iosevka Term Nerd Font. El perfil gestionado requiere un gestor de usuario systemd accesible, logind y el entorno de la sesión gráfica importado. `--no-units` arranca Quickshell directamente. En esta campaña se probó esa ruta en Arch con systemd/logind presentes. La [guía directa](../packaging/NO-SYSTEMD.md) cubre también escenarios con login1/elogind sujetos a sus precondiciones.

Agrupa los opcionales por función y enlaza el detalle. Los principales son hyprlock y hypridle para respaldo e inactividad, una pila PAM funcional para autenticar, Matugen para paletas dinámicas, Qt Multimedia para previews de vídeo, NetworkManager y BlueZ para sus controles, UPower y un servicio de perfiles de energía, cliphist y wl-clipboard, proveedores de fondos, herramientas de captura y grabación, y Sumi SDDM. La integración automática de Lua usa `luac` compatible con el Lua enlazado a Hyprland y `readelf`. La variante manual no pide instalar ese compilador para escribir el fragmento. Hyprland 0.57 y posterior usa Lua. El fragmento hyprlang se mantiene para instalaciones antiguas hasta 0.56.

## Instalación y mantenimiento

Ejecuta los comandos de instalación de usuario desde la raíz de un clon, dentro de un Hyprland desbloqueado. El diagnóstico, la simulación y la instalación deben usar los mismos argumentos. El usuario elige un método y una instancia de Sumi.

- **Directo probado en VM.** `./install.sh check --install --no-units`, `./install.sh install --no-units --dry-run` y `./install.sh install --no-units`. Para arrancar, `qs -c sumi --no-duplicate`. La guía directa explica cómo añadir el inicio a la sesión de forma explícita.
- **Gestionado probado en VM.** `./install.sh check --install --enable`, `./install.sh install --enable --dry-run` y `./install.sh install --enable`. La opción habilita el inicio con la sesión siguiente. Para el primer arranque se probó `systemctl --user start sumi-shell.service`. Antes, comprobar `graphical-session.target` y que las dos variables de sesión coincidan con las de Hyprland.
- **Paquete local Arch.** Desde el clon, `python3 packaging/arch/build-local.py "$PWD" "$PWD" ../sumi-arch-build` genera las recetas y construye ambos candidatos. Sólo el estable se instaló y probó en la VM. El ciclo probado usó `pacman -U <paquete>`, `pacman -Qkk sumi-shell` y `pacman -R sumi-shell`. Antes de retirar o reemplazar el paquete, detén Sumi estando desbloqueado y retira las integraciones que apuntan a sus archivos. La receta estable usa un tar local. Evita prometer un tag, un paquete publicado o instalación desde AUR.
- **Verificación.** `./install.sh status` para la instalación de usuario y `qs -c sumi ipc call sumi api` para comprobar versión, API y build cargado. Un árbol de desarrollo tiene un build vacío. La respuesta de IPC importa además del código de salida.
- **Actualización del usuario.** Desde el nuevo clon, `./install.sh update` previsualiza. En la ruta gestionada, `./install.sh update --apply --reload` o `--restart` según el plan y sólo con la sesión desbloqueada. En la ruta directa, cerrar estando desbloqueado, `./install.sh update --apply`, arrancar la nueva copia a mano y usar `./install.sh update --verify`. El flujo y las guardas se probaron en bancos. La campaña Arch no incluyó una actualización entre paquetes distintos por falta de un candidato anterior compatible. Sigue la [guía de ciclo de vida](../packaging/INSTALL.md#updating) para `recover` y rollback.
- **Desinstalación del usuario probada en VM.** Deshacer integraciones y activación D-Bus que se hayan añadido. Cerrar la instancia directa estando desbloqueado. Ejecutar `./install.sh uninstall --dry-run` y luego `./install.sh uninstall`. El manifiesto protege los archivos ajenos y preserva preferencias, estado y cachés por defecto. `--purge` es una operación aparte. El instalador de usuario no administra los archivos de pacman.

Para una instalación existente, no mezclar una copia de usuario con la del paquete. Una configuración Quickshell `default` puede ocultar la configuración con nombre. Para actualizaciones, retiradas y recuperación, el respaldo del bloqueo y el estado desbloqueado forman parte del procedimiento.

## Evidencia y límites

**Fully Portable dentro de la matriz Arch Linux ensayada con login PAM normal**, para el candidato `14e07e8`. Los invitados usaron Hyprland 0.57.2, Quickshell 0.3.2, Qt 6.12, systemd 262.2 y KVM/VirGL. Se demostraron el arranque desde clon, la persistencia, las superficies y el IPC, el ciclo gestionado, la autenticación y el rescate real, y la instalación, reinstalación y retirada con pacman. La matriz tiene 25 PASS, 1 FAIL diagnóstico de contador PAM con autologin y 1 SKIP condicional por falta de paquete anterior.

PAM rechazó la contraseña en el contraste de autologin, donde el tally estaba vacío. El login normal creó el registro y el contador se verificó en ambos perfiles. No extrapoles a otros compositores, distribuciones, hardware físico, configuraciones PAM o múltiples pantallas durante el bloqueo. Diferencia la disponibilidad de código, las pruebas con dobles, la aceptación gráfica y una publicación efectiva. [Resultados y alcance](PORTABILITY-ACCEPTANCE.md)

## Estado de Git y mapa de lectura

`main` contenía `14e07e8` antes de este cierre documental, con la referencia local `origin/main` en `5e7666e`. El commit de documentación que añade este traspaso es el siguiente. Comprueba el estado y los hashes al abrir la sesión, con `git status --short --branch` y `git log -3 --oneline`. El cierre no crea tags ni releases ni actualiza el remoto.

| Ruta | Para qué sirve |
| --- | --- |
| [README.md](../README.md), [CHANGELOG.md](../CHANGELOG.md), [sumi/version.json](../sumi/version.json) | Presentación actual, cambios de versión y metadatos canónicos. |
| [sumi/shell.qml](../sumi/shell.qml), [sumi/core/](../sumi/core/), [sumi/surfaces/](../sumi/surfaces/) | Punto de entrada, composición por pantalla, IPC y superficies. |
| [sumi/services/](../sumi/services/), [sumi/lib/](../sumi/lib/), [sumi/scripts/](../sumi/scripts/) | Estado y capacidades, esquemas y helpers. |
| [sumi/theme/](../sumi/theme/), [sumi/lock/](../sumi/lock/), [sumi/systemd/](../sumi/systemd/) | Estilo y apariencia, bloqueo, unidades de inicio y rescate. |
| [API.md](../API.md), [api/contract-v1.json](../api/contract-v1.json), [sumi/examples/README.md](../sumi/examples/README.md) | IPC público y ejemplos de configuración. |
| [packaging/INSTALL.md](../packaging/INSTALL.md), [CHECK.md](../packaging/CHECK.md), [NO-SYSTEMD.md](../packaging/NO-SYSTEMD.md) | Instalación, diagnóstico y ciclo directo. |
| [packaging/arch/README.md](../packaging/arch/README.md), [ARCH.md](../packaging/arch/ARCH.md), [PORTABILITY-VM.md](../packaging/PORTABILITY-VM.md) | Construcción local, uso de pacman y procedimiento VM. |
| [tests/](../tests/), [LICENSE](../LICENSE), [licencia de Ukishima](../sumi/lib/LICENSE-ukishima) | Pruebas, licencia y atribución. |

## Qué revisar en el README público

- El alcance y el cierre de troubleshooting aún presentan la matriz Arch y pacman en VM como pendientes. Sustituye esas afirmaciones por la evidencia y los límites del informe.
- La apertura usa «island/bar/dock» sin aclarar las cuatro presentaciones o cómo se combinan con Soft y Terminal. Pon primero una explicación clara y una captura o comparación visual breve, con bienes redistribuibles y referencias versionadas.
- El recorrido de instalación favorece systemd y repite la alternativa directa. Separa un inicio rápido directo y otro gestionado. Deja la integración opcional de Hyprland y hypridle, el rescate, las migraciones y el ciclo avanzado en sus guías.
- Actualiza los recuentos de API y atajos contra el JSON y evita usar cifras que no aporten. La introducción debe distinguir la paleta Minimaru de un requisito de instalación.
- Incluye una sección de contribución con los puntos de entrada, cómo entregar un informe reproducible y las comprobaciones documentales relevantes. Valida comandos, enlaces relativos, licencias y capturas desde un clon.
- Antes de abrir el repositorio, confirma la visibilidad y que el enlace de clonación funciona desde fuera de la cuenta. Revisa los metadatos de autoría de tres commits antiguos que no usan un correo de anonimización de GitHub. Cualquier decisión sobre modificar ese historial, publicar un tag, una release o un paquete requiere autorización aparte.
