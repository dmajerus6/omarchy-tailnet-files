import QtQuick
import qs.Commons

// Every string this plugin draws comes from file names, host names or
// command output, so none of it may be read as rich text.
Text {
  textFormat: Text.PlainText
  font.family: Style.font.family
  font.pixelSize: Style.font.body
  elide: Text.ElideRight
  verticalAlignment: Text.AlignVCenter
}
