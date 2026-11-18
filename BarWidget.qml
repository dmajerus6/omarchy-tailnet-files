import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar icon: left click opens or closes the Tailnet Files window.
BarWidget {
  id: root

  moduleName: "dmaje.tailfiles"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function toggleWindow() {
    if (!bar || !bar.shell) return
    if (typeof bar.shell.toggle === "function") bar.shell.toggle(root.moduleName, "{}")
    else if (typeof bar.shell.summon === "function") bar.shell.summon(root.moduleName, "{}")
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{F0FB6}"
    tooltipText: strings.t("bar.tooltip")
    onPressed: function(buttonCode) { root.toggleWindow() }
  }
}
