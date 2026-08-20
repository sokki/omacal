import QtQuick

// The This / This & Future / All buttons offered before touching a repeating
// event. Editing from the first occurrence onward equals editing the whole
// series, so the "future" option only appears past the first occurrence.
// Deletion flows render in the danger style.
Repeater {
    id: row

    property bool offersFuture: true
    property string kind: "accent"

    signal chosen(string scope)

    model: offersFuture
        ? [
            { label: qsTr("This"), scope: "this" },
            { label: qsTr("This & Future"), scope: "future" },
            { label: qsTr("All"), scope: "all" }
        ]
        : [
            { label: qsTr("This Event"), scope: "this" },
            { label: qsTr("All Events"), scope: "all" }
        ]

    PillButton {
        required property var modelData
        kind: row.kind
        text: modelData.label
        onClicked: row.chosen(modelData.scope)
    }
}
