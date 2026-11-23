import QtQuick

/**
 * Un tramo de la barra permanente (2026-11-19, core/Bar): fila en horizontal y columna en vertical, centrado en el otro
 * eje. Sustituye a los `Row` de antes, que centraban cada hijo con `anchors.verticalCenter` (un `Grid` no admite anclas
 * en sus hijos: se alinean con `*ItemAlignment`). `spacing` (el de `Grid`) vale para los dos ejes.
 *
 * En horizontal `rows: 1` (las columnas, de los hijos visibles) y en vertical `columns: 1`, que miden lo mismo que un
 * `Row` y una `Column`. NO `columns: 1000`: con menos visibles que columnas, `QQuickGrid::doPositioning` mete una
 * columna vacía más y con ella un `spacing` de más (medido: cada acceso 5 px más ancho que con el `Row` de antes).
 * Los dos se cambian A LA VEZ y en un orden que pasa por −1 × −1 (sin efecto hasta el `polish`): con dos enlaces, al
 * cambiar de borde había un instante 1 × 1 y el Grid avisaba de que no le cabían los hijos. En su archivo y no como
 * `component` en línea de Bar.qml: uno nuevo en línea no entra con la recarga en caliente.
 */
Grid {
    id: lane
    property bool vertical: false
    rows: 1
    onVerticalChanged: lane.orient()
    Component.onCompleted: lane.orient()
    function orient() {
        if (lane.vertical) { lane.rows = -1; lane.columns = 1; }
        else { lane.columns = -1; lane.rows = 1; }
    }
    horizontalItemAlignment: Grid.AlignHCenter
    verticalItemAlignment: Grid.AlignVCenter
}
