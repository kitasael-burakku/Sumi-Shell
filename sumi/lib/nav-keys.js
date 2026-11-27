.pragma library
/*
 * Teclado de la cara hover y de la barra (F9, 2026-11-27, ADR-42 «misma acción, mismo resultado»).
 *
 * Antes cada una tenía su lista de teclas: la isla aceptaba ↑/↓ pero no Tab ni Espacio; la barra, Tab y Espacio pero
 * ↑/↓ sólo en vertical. Ahora las dos: → ↓ Tab avanzan, ← ↑ Shift+Tab retroceden, Inicio/Fin, ⏎ o Espacio activan y
 * Shift+⏎ o la tecla Menú hacen lo del clic derecho (la vista propia de un indicador, el No molestar de la campana).
 *
 * Puro y con los códigos de Qt 6 fijos (Qt::Key y Qt::KeyboardModifier son ABI estable): pasar el objeto `Qt` de
 * QML como argumento no trae sus constantes (medido en el banco: Tab no movía nada). `Q` opcional sólo para pruebas.
 * Prueba en node: `tests/lib/nav-keys-test.js`. Devuelve `{ idx, act, accepted }`; `act` es "", "activate" o
 * "secondary".
 */
var QT = { Key_Right: 0x01000014, Key_Left: 0x01000012, Key_Up: 0x01000013, Key_Down: 0x01000015,
           Key_Tab: 0x01000001, Key_Backtab: 0x01000002, Key_Home: 0x01000010, Key_End: 0x01000011,
           Key_Return: 0x01000004, Key_Enter: 0x01000005, Key_Space: 0x20, Key_Menu: 0x01000055,
           ShiftModifier: 0x02000000 };
function step(key, modifiers, idx, n, Qopt) {
    const Q = Qopt && Qopt.Key_Tab === QT.Key_Tab ? Qopt : QT;
    const none = { idx: idx, act: "", accepted: false };
    if (n <= 0) return none;
    const at = idx < 0 ? -1 : Math.min(idx, n - 1);
    const shift = (modifiers & Q.ShiftModifier) !== 0;
    if (key === Q.Key_Right || key === Q.Key_Down || (key === Q.Key_Tab && !shift))
        return { idx: at < 0 ? 0 : Math.min(n - 1, at + 1), act: "", accepted: true };
    if (key === Q.Key_Left || key === Q.Key_Up || key === Q.Key_Backtab || (key === Q.Key_Tab && shift))
        return { idx: at < 0 ? 0 : Math.max(0, at - 1), act: "", accepted: true };
    if (key === Q.Key_Home) return { idx: 0, act: "", accepted: true };
    if (key === Q.Key_End) return { idx: n - 1, act: "", accepted: true };
    if (key === Q.Key_Menu) return { idx: at, act: at < 0 ? "" : "secondary", accepted: true };
    if (key === Q.Key_Return || key === Q.Key_Enter || key === Q.Key_Space)
        return { idx: at, act: at < 0 ? "" : (shift ? "secondary" : "activate"), accepted: true };
    return none;
}
