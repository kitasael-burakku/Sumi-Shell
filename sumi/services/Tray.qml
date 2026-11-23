pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.SystemTray

/**
 * La bandeja del sistema (Fase 9.c).
 *
 * Declarar `SystemTray` convierte al shell en el `StatusNotifierWatcher` del
 * sistema: hasta ahora ese papel lo tenia Waybar, y al morir se lo llevo --
 * medido el 2026-09-07, no quedaba **ningun** watcher en el bus y
 * `udiskie --tray` corria sin sitio donde dibujarse.
 *
 * ORDEN DE ARRANQUE: **no hace falta ninguno.** La primera version de este
 * comentario afirmaba que un cliente SNI se registra una sola vez y que habia
 * que ordenar `udiskie.service` detras del shell. **Medido, es falso**: con
 * `udiskie` corriendo, parar el shell (el watcher desaparece del bus) y
 * volverlo a arrancar hace que el icono reaparezca solo, con el mismo
 * `ActiveEnterTimestamp` de udiskie -- o sea sin reiniciarlo. Los clientes
 * vigilan `NameOwnerChanged` y se re-registran cuando el watcher vuelve.
 *
 * Consecuencia: la Fase 9.c se completa con **cero cambios en el rice**, y el
 * shell puede reiniciarse durante el desarrollo sin dejar la bandeja vacia.
 */
Singleton {
    id: root

    readonly property var items: SystemTray.items ? SystemTray.items.values : []
    readonly property int count: root.items.length

    /** Alguno pide atencion: es la razon por la que el tray va en la cara rest. */
    readonly property bool needsAttention: {
        const list = root.items;
        for (let i = 0; i < list.length; i++)
            if (list[i] && list[i].status === SystemTrayItem.NeedsAttention)
                return true;
        return false;
    }

    /** Para `status()`: que hay en la bandeja, sin exponer los handles. */
    function summary() {
        const list = root.items;
        const out = [];
        for (let i = 0; i < list.length; i++) {
            const it = list[i];
            if (!it) continue;
            out.push({
                id: String(it.id),
                title: String(it.title),
                status: it.status === SystemTrayItem.NeedsAttention ? "attention"
                      : (it.status === SystemTrayItem.Passive ? "passive" : "active"),
                hasMenu: it.hasMenu,
                onlyMenu: it.onlyMenu
            });
        }
        return out;
    }
}
