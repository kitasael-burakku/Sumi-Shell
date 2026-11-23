.pragma library

// Las variables de los directorios de usuario XDG sólo aceptan rutas absolutas.
function base(value, fallback) {
    return typeof value === "string" && value.startsWith("/") ? value : fallback;
}
