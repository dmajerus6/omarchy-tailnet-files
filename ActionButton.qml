import QtQuick
import qs.Commons
import qs.Commons as Commons

// Small text button. `hint` shows the key that does the same thing.
Rectangle {
  id: button

  property string label: ""
  property string glyph: ""
  property string hint: ""
  property bool primary: false
  property bool enabledState: true
  property color fg: Commons.Color.foreground
  property color accent: Commons.Color.accent

  signal clicked()

  implicitWidth: content.implicitWidth + Style.space(20)
  implicitHeight: Math.max(Style.space(28), Style.font.body + Style.space(14))
  radius: Style.cornerRadius
  opacity: enabledState ? 1 : 0.4
  color: primary
    ? Util.alpha(accent, mouse.pressed ? 0.4 : (mouse.containsMouse ? 0.3 : 0.2))
    : Util.alpha(fg, mouse.pressed ? 0.14 : (mouse.containsMouse ? 0.09 : 0.05))
  border.width: Math.max(1, Style.space(1))
  border.color: primary ? Util.alpha(accent, 0.7) : Util.alpha(fg, 0.12)
  scale: mouse.pressed ? 0.97 : 1
  Behavior on scale { NumberAnimation { duration: Style.duration(90); easing.type: Easing.OutCubic } }

  Row {
    id: content
    anchors.centerIn: parent
    spacing: Style.space(6)

    PlainText {
      visible: button.glyph !== ""
      text: button.glyph
      color: button.fg
      font.pixelSize: Style.font.title
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideNone
    }
    PlainText {
      visible: button.label !== ""
      text: button.label
      color: button.fg
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideNone
    }
    PlainText {
      visible: button.hint !== ""
      text: button.hint
      color: Qt.darker(button.fg, 1.7)
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideNone
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: button.enabledState ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: if (button.enabledState) button.clicked()
  }
}
