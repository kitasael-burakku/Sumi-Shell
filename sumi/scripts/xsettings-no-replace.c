/* Sólo se carga en el xsettingsd propio. El binario upstream reemplaza gestores:
 * el chequeo y la adquisición deben ocurrir bajo el MISMO bloqueo del servidor. */
#define _GNU_SOURCE
#include <X11/Xlib.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>
int minimal_shell_xsettings_guard_version(void) { return 1; }
int XSetSelectionOwner(Display *d, Atom selection, Window window, Time time) {
    int (*real)(Display *, Atom, Window, Time) = dlsym(RTLD_NEXT, "XSetSelectionOwner");
    if (!real) _exit(74);
    char *name = XGetAtomName(d, selection);
    int settings = name && !strncmp(name, "_XSETTINGS_S", 12);
    if (name) XFree(name);
    if (!settings) return real(d, selection, window, time);
    XGrabServer(d);
    Window owner = XGetSelectionOwner(d, selection);
    if (owner != None && owner != window) {
        XUngrabServer(d);
        XSync(d, False);
        _exit(73); /* Cierra sólo nuestra conexión; el gestor ajeno queda intacto. */
    }
    int result = real(d, selection, window, time);
    XSync(d, False);
    XUngrabServer(d);
    return result;
}
