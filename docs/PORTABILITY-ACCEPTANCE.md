# Aceptación de portabilidad de Sumi Shell 0.4.0

> Los hashes de commit citados aquí son del historial anterior a la publicación, que se reinició el 2026-11-23 con un único commit inicial. El autor conserva ese historial en privado.

**Fully Portable en la matriz Arch ensayada con inicio de sesión PAM normal.** Los criterios obligatorios del perfil directo, el gestionado y el paquete estable se demostraron con el mismo candidato. La actualización de paquete era condicional. El contraste de autologin queda registrado aparte.

## Candidato y entorno

| Elemento | Identidad verificada |
| --- | --- |
| Fuente | Commit `14e07e8542edf7fb10689a7fa8c20c4e73d3e2fd`, Sumi 0.4.0, IPC API 1 |
| Clon transferido | SHA-256 `8a1355dc259976755f53b2a676bb3bfce25ce404db3539d7ba7d4b2e17798154` |
| Build del runtime | `sha256:5f7e7959c93f81f37461ec1d21e1ead911015c8ea95307594aa22c5a1127142f` |
| Paquete estable local | `sumi-shell-0.4.0-1-any.pkg.tar.zst`, SHA-256 `15d61484f3d76708a3f2a15cce451babfdf021eb759695346e4793ee9f448fde` |
| Medio Arch | Arch Linux 2026.11.01, SHA-256 `01bcdcf01af2f7d58f2794899c834770d25c9bfc945bd092b32bb66672a4a216`, firma de distribución verificada |
| Invitado | Linux `7.3.5.arch1-1`, Hyprland `0.57.2-1`, Quickshell `0.3.2-1`, Qt `6.12.0`, systemd `262.2-1`, Linux-PAM `1.7.3-1`, pambase `20260616-1` |
| Opcionales para el candado | hyprlock `0.9.7-3`, hypridle `0.1.8-2`. `wev` y `grim` se usaron como instrumentos |
| Virtualización | QEMU 11.1.3, KVM, VirtIO GPU con VirGL, una salida `Virtual-1` de 1280 × 800 |

La persistencia directa se ensayó sobre un hijo del overlay conservado. Gestionado y paquete usaron discos derivados de la base Arch antes de instalar Sumi y cuentas de prueba diferentes. Cada perfil de bloqueo tuvo su propio overlay desechable y una consola serie alternativa independiente. Se usaron medios de sólo lectura y exportación por puerto serie virtual. El perfil directo estuvo sin NIC. Los ensayos que necesitaron paquetes usaron NAT para obtenerlos y el de bloqueo bajó la interfaz antes de autenticar. La ejecución se limitó a los invitados y la instrumentación del banco.

## Matriz de resultados

| Perfil | Caso | Resultado | Evidencia |
| --- | --- | --- | --- |
| Directo mínimo | Preflight, vista previa e instalación desde clon limpio con `--no-units`. Arranque Wayland en frío | **PASS** | [Resultados registrados](#directo) |
| Directo mínimo | Barra, Island, notch y Settings con un solo PID e IPC coincidente con el build | **PASS** | [Resultados registrados](#directo) |
| Persistencia directa | Cambios desde dos filas reales de Settings. Salida completa de Hyprland y nuevo PID. Preferencias v4 idénticas byte a byte y presentación aplicada | **PASS** | [Resultados registrados](#directo) |
| Persistencia directa | Integridad de runtime y servicios. PipeWire y WirePlumber activos. D-Bus entrega una notificación tras la activación explícita | **PASS** | [Resultados registrados](#directo) |
| Directo | Desinstalación por manifiesto tras retirar el opt-in de notificaciones | **PASS** | [Resultados registrados](#directo) |
| Gestionado | Cuenta limpia, preflight, dry-run, `install --enable`, ambas unidades y el enlace de inicio | **PASS** | [Resultados registrados](#gestionado) |
| Gestionado | `graphical-session.target` activo y misma firma de Hyprland y socket Wayland en el gestor y la sesión. IPC y un solo proceso | **PASS** | [Resultados registrados](#gestionado) |
| Gestionado | Barra, Island, notch y apertura de superficies | **PASS** | [Resultados registrados](#gestionado) |
| Gestionado | Reinicio controlado, cierre completo, arranque automático tras reingresar y ajustes preservados | **PASS** | [Resultados registrados](#gestionado) |
| Recuperación normal | Backend Qt inválido. Al quitar el override, el IPC, el PID gestionado y la superficie vuelven | **PASS** | [Resultados registrados](#gestionado) |
| Recuperación de ajustes | El compositor y el IPC sobreviven al JSON truncado, se preservan sus bytes y se guarda un respaldo. Restaurar el original devuelve los ajustes | **PASS** | [Resultados registrados](#gestionado) |
| Tema y opcionales | Paleta Gruvbox y regreso a paleta estática sin Matugen. Runtime idéntico y proceso disponible. Primer arranque directo con Qt Multimedia ausente | **PASS** | [Resultados registrados](#gestionado) |
| Gestionado | Desinstalación de runtime, unidades y enlace. Preferencias y cuatro archivos ajenos comprobados por hash | **PASS** | [Resultados registrados](#gestionado) |
| Bloqueo y PAM | Login normal con contraseña y TTY serie disponible. Hyprlock de Arch acepta la contraseña antes de provocar caídas | **PASS** | [Resultados registrados](#bloqueo-y-rescate) |
| Bloqueo propio | Sumi protege la salida virtual. Teclado y puntero funcionan con el testigo antes del bloqueo y no le llegan eventos durante el bloqueo | **PASS** | [Resultados registrados](#bloqueo-y-rescate) |
| Autenticación | PAM rechaza la contraseña incorrecta, la sesión sigue bloqueada y la contraseña correcta la abre. Demostrado en gestionado y directo | **PASS** | [Resultados registrados](#bloqueo-y-rescate) |
| Diagnóstico de PAM | Sondeo inicial del contador en el banco con autologin. PAM rechazó la contraseña, pero no generó un registro válido para mostrar. Contraste fuera del login PAM normal | **FAIL** | [Resultados registrados](#bloqueo-y-rescate) |
| Rescate gestionado | Parada controlada de Sumi durante el bloqueo. El `MainPID` de la unidad de rescate corresponde a hyprlock. Se mantuvo bloqueado hasta autenticar | **PASS** | [Resultados registrados](#bloqueo-y-rescate) |
| Rescate gestionado | Muerte inesperada del proceso principal con SIGKILL. Hyprlock adquiere el bloqueo. Tras autenticar vuelven Sumi e IPC | **PASS** | [Resultados registrados](#bloqueo-y-rescate) |
| Rescate directo | Caída sin unidades. Se mantiene el bloqueo del compositor y hyprlock lo recupera desde la TTY. Tras autenticar se abre una nueva instancia de Sumi | **PASS** | [Resultados registrados](#bloqueo-y-rescate) |
| Integración con hypridle | El evento de logind y el timeout de inactividad disparan el helper y el bloqueo autenticado. Verificado en los dos perfiles de bloqueo | **PASS** | [Resultados registrados](#bloqueo-y-rescate) |
| Paquete Arch | Resolución real de dependencias, instalación del paquete estable y `pacman -Qkk` | **PASS** | [Resultados registrados](#paquete-arch) |
| Paquete Arch | Arranque directo desde `/etc/xdg/quickshell/sumi`, runtime de sólo lectura para el usuario, barras y superficies | **PASS** | [Resultados registrados](#paquete-arch) |
| Paquete Arch | Unidad desde `/usr/lib/systemd/user`, inicio manual y automático tras reingresar. PID, IPC y persistencia | **PASS** | [Resultados registrados](#paquete-arch) |
| Paquete Arch | Reinstalación de la misma versión, integridad y nuevo arranque funcional | **PASS** | [Resultados registrados](#paquete-arch) |
| Paquete Arch | Actualización desde otra versión compatible | **SKIP** | Caso condicional. El inventario sólo tenía el candidato 0.4.0-1 y su variante Git. [Versión mínima de actualización](../sumi/version.json) |
| Paquete Arch | Desinstalación, runtime y unidades retirados, preferencias y archivo ajeno conservados | **PASS** | [Resultados registrados](#paquete-arch) |

## Incidencias y repeticiones

- El arranque inicial del banco intentaba ajustar permisos de un medio ya montado en sólo lectura. Se quitó ese paso de la instrumentación y se repitieron los perfiles desde sus bases.
- En directo, el primer sondeo esperaba un dueño D-Bus de notificaciones. El servidor viene desactivado por diseño. Se verificó ese estado predeterminado y se probó el opt-in real, su entrega y su retirada. [Contrato de la integración](../packaging/NO-SYSTEMD.md#notifications-opt-in)
- La fase de bloqueo se repitió tras corregir la sintaxis de la opción de hyprlock en el banco y esperar la fase estable de Sumi. Para acreditar rescate se usó la adquisición del bloqueo en el journal de la unidad, su `MainPID` y el muestreo del compositor. `logger` usa otro identificador de journal.
- En el primer contraste con autologin, PAM rechazó la contraseña y el contador se mantuvo en cero con el tally vacío. En dos overlays nuevos se usó login de TTY por contraseña sin editar el PAM de Arch. En ambos, el archivo de tally no existía antes del login y apareció con propiedad del usuario después. El intento incorrecto posterior produjo una entrada válida de PAM y `lockStatus.failed=1`. Sumi refleja el contador de PAM. La prueba conservó la política de autenticación del invitado.
- El banco offscreen de LockAuth con dobles de PAM pasó sus ocho comprobaciones. Los veredictos de autenticación y cobertura de la matriz proceden de Wayland y PAM reales del invitado.
- Las repeticiones cambiaron la instrumentación y el método de login del invitado. No se confirmó un defecto de producto que justificara cambiar el candidato. Todas las filas obligatorias de la matriz final corresponden a `14e07e8` y al mismo ID de build. No se creó otro commit.

## Evidencia conservada

Los extractos de esta sección se cotejaron con los registros de la campaña. Los PID identifican procesos del invitado dentro de cada prueba. Se incluyen campos representativos, recuentos y hashes para que el informe se pueda leer desde un clon independiente.

### Directo

| Comprobación | Registro |
| --- | --- |
| Primer arranque | Quickshell registró `Configuration Loaded`. `api` devolvió `apiVersion=1`, `version=0.4.0` y el build de la tabla de identidad. |
| Presentaciones | `status` devolvió `island`, `bar` y `dock` con PID 504 en `Virtual-1`. Las capturas revisadas mostraron las tres presentaciones. Settings abrió en esa misma instancia. |
| Persistencia | Las filas de barra y notch cambiaron desde Settings. La presentación pasó de `dock` a `bar` y volvió en `bar` tras reentrar. PID 591 antes del cierre y 1024 al volver. |
| SHA-256 de `settings.json` v4 | `21c052ed209a1925373df0291477fc5d26fcaefb2ec552d51f1c7b0a638048e5` antes y después de reentrar. |
| SHA-256 del inventario `sha256sum` del runtime | `8708be720d8bb09a3850d2e6c831a7fb7a9484e4686bb9b0e7d247d0ffce02d3` antes y después. |
| Servicios y retirada | PipeWire y WirePlumber activos. La notificación de prueba devolvió `u 1` tras el opt-in. Después del opt-out, el desinstalador conservó los hashes de preferencias y del archivo ajeno. |

### Gestionado

| Comprobación | Registro |
| --- | --- |
| Inicio y cierre | Target gráfico activo y variables de sesión iguales en Hyprland y el gestor de usuario. Una instancia y concordancia de PID con `MainPID`. PID inicial 756, tras reinicio 1260 y tras volver a entrar 1552, con `NRestarts=0` en el inicio automático. |
| Presentaciones y superficies | Capturas de barra, Island y notch. El IPC aceptó la apertura de Settings, launcher, calendario, mixer, Login screen y fondos. |
| Fallo Qt | El journal registró que faltaba el plugin de prueba. Tras retirar el override, el PID 1887 volvió a servir el mismo build y mostró su superficie. |
| Recuperación de ajustes | JSON truncado conservado byte a byte. Respaldo idéntico y ajustes v4 recuperados tras restaurar el original. |
| Paletas y opcionales | `status.palette.source` pasó de `preset` a `static` sin cambiar el runtime. El primer arranque directo se completó con Matugen, cliphist, los proveedores de fondos ensayados, la grabadora y Qt Multimedia ausentes. |
| Retirada | Preferencias y cuatro testigos ajenos conservaron sus hashes. Desaparecieron el runtime, las unidades propias y el enlace de arranque. |

### Bloqueo y rescate

- La TTY serie se verificó antes de provocar fallos. El locker de reserva mostró su superficie de 1280 × 800 y autenticó mediante su PAM.
- Las dos pruebas con login PAM normal registraron `locked, secure=true, failed=0` al bloquear, `locked, secure=true, failed=1` tras la contraseña incorrecta, y `unlocked, secure=false` tras la válida. PAM registró el rechazo. El testigo de teclado y puntero mantuvo su recuento durante el bloqueo y recuperó el foco al desbloquear.
- En el contraste con autologin, el rechazo de PAM quedó registrado y el tally no contenía entradas. En la repetición con contraseña, el archivo de tally no existía antes del login de TTY y apareció con propiedad de la cuenta después. La entrada válida del fallo era de tipo `SVC`, servicio `login`.
- El journal del rescate gestionado registró que hyprlock adquirió el bloqueo. En las muestras del compositor no hubo observaciones desbloqueadas antes de autenticar. Fueron 52 con parada controlada, 56 con SIGKILL y 32 en el rescate manual sin unidades. Hypridle disparó el bloqueo por logind y por inactividad en ambos perfiles.

### Paquete Arch

`pacman -U` resolvió e instaló Hyprland, Quickshell y la fuente Iosevka Term Nerd Font junto con Sumi. `pacman -Qkk sumi-shell` devolvió `437 total files, 0 altered files` tras instalar y tras reinstalar. El inicio directo usó `/etc/xdg/quickshell/sumi/shell.qml`. En la nueva sesión, la unidad de `/usr/lib/systemd/user/sumi-shell.service` arrancó con PID 1528, `NRestarts=0` e IPC operativo. Las preferencias y el testigo ajeno conservaron sus hashes tras reinstalar y tras retirar el paquete.

## Reproducción y alcance

El [procedimiento para una VM Arch limpia](../packaging/PORTABILITY-VM.md) documenta el entorno, los perfiles y la captura de evidencia. Las recetas y el ciclo del paquete se describen en las [instrucciones de construcción](../packaging/arch/README.md) y la [guía de Arch](../packaging/arch/ARCH.md).

Los invitados se apagaron con evento QMP `guest-shutdown` y salida 0. Las capturas, los journals completos y los overlays se conservaron fuera del Git. Este informe incorpora los datos que sustentan la matriz y no depende de enlaces a esos archivos.

Los resultados del bloqueo se acotan a una salida virtual y al PAM medido en esta imagen. Quedan fuera otras distribuciones, el hardware físico, la suspensión y las configuraciones de autenticación particulares.
