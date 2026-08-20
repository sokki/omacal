pragma Singleton
import QtQuick

// Font size tokens after the omarchy shell's Commons/Style.qml: a 12px base
// scaled by the desktop text size, with the shell's multiplier ladder. Sizes
// that are really icon or hero dimensions stay as scaled pixels at the call
// site; these tokens are for running text.
QtObject {
    id: root

    readonly property real fontBaseSize: 12 * backend.textScale

    function fontPx(mult) {
        return Math.max(1, Math.round(fontBaseSize * mult));
    }

    readonly property QtObject font: QtObject {
        readonly property int caption: root.fontPx(0.833)    // 10
        readonly property int bodySmall: root.fontPx(0.917)  // 11
        readonly property int body: root.fontPx(1.0)         // 12
        readonly property int subtitle: root.fontPx(1.083)   // 13
        readonly property int title: root.fontPx(1.167)      // 14
        readonly property int heading: root.fontPx(1.333)    // 16
    }
}
