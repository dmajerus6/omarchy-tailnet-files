import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons

// One side of the browser: a machine, a folder on it, and its listing.
// Keyboard input arrives from App.qml, which owns focus for the window;
// the pane only takes focus itself while its path or filter field is edited.
Rectangle {
  id: pane

  required property var backend
  required property var tr
  property var peers: []
  property string localName: "This computer"
  property bool active: false

  property color fg: Commons.Color.foreground
  property color bg: Commons.Color.background
  property color accent: Commons.Color.accent
  property color urgent: Commons.Color.urgent
  readonly property color dim: Qt.darker(fg, 1.6)
  readonly property color hoverFill: Util.alpha(fg, 0.06)
  readonly property color cursorFill: Util.alpha(accent, active ? 0.22 : 0.10)
  readonly property color markFill: Util.alpha(accent, 0.12)

  property string target: "local"
  property string path: ""
  property string home: ""
  property string loadedTarget: ""
  // The SSH account the current listing was made under; actions on it are
  // pinned to this account (see helperAs()).
  property string loadedUser: ""
  property int skippedCount: 0
  property var entries: []
  property var rows: []
  property var marked: ({})
  property int markedCount: 0
  property real markedBytes: 0
  property int cursor: 0
  property bool loading: false
  property string error: ""
  property string errorKind: ""
  property bool showHidden: false
  property string sortKey: "name"
  property bool sortDescending: false
  property string filterText: ""
  property bool filtering: false
  property bool editingPath: false
  property bool machineMenuOpen: false
  property int machineIndex: 0
  property int serial: 0
  property string selectAfterLoad: ""

  readonly property var machines: {
    var list = [{ host: "local", name: localName, os: tr.t("pane.thisComputer"), online: true, user: "" }]
    for (var i = 0; i < peers.length; i++) list.push(peers[i])
    return list
  }
  readonly property var machine: {
    for (var i = 0; i < machines.length; i++) if (machines[i].host === target) return machines[i]
    return { host: target, name: target, os: "", online: true, user: "" }
  }
  readonly property bool isLocal: target === "local"
  readonly property bool blocked: error !== "" && (errorKind === "auth" || errorKind === "unreachable" || errorKind === "hostkey" || loadedTarget !== target)
  readonly property int rowHeight: Math.max(Style.space(26), Style.font.body + Style.space(12))
  // Narrow panes drop the date first, then the size, so names keep their room.
  readonly property bool showSizeCol: width > Style.space(300)
  readonly property bool showTimeCol: width > Style.space(440)
  readonly property real sizeColWidth: showSizeCol ? sizeCol.implicitWidth : 0
  readonly property real timeColWidth: showTimeCol ? timeCol.implicitWidth : 0

  signal focusRequested()
  signal editingDone()
  signal notice(string text, bool isError)
  signal setupKeyRequested(string host)
  signal userPromptRequested(string host)

  color: Util.alpha(fg, 0.025)
  border.width: Math.max(1, Style.space(1))
  border.color: active ? Util.alpha(accent, 0.9) : Util.alpha(fg, 0.12)
  radius: Style.cornerRadius

  // ------------------------------------------------------------ navigation

  function setTarget(host) {
    machineMenuOpen = false
    if (host === target && loadedTarget === target && error === "") return
    target = host
    path = ""
    home = ""
    entries = []
    rows = []
    loadedTarget = ""
    loadedUser = ""
    skippedCount = 0
    clearMarks()
    filterText = ""
    error = ""
    errorKind = ""
    load("")
  }

  // Arguments that pin a helper call to the account this listing was made under.
  function helperAs() {
    return (target !== "local" && loadedUser !== "") ? ["--as", target + "=" + loadedUser] : []
  }

  function load(p) {
    var mySerial = ++serial
    var wanted = String(p || "")
    var forTarget = target
    loading = true
    backend.run(["ls", forTarget, wanted], function(res) {
      if (mySerial !== pane.serial || forTarget !== pane.target) return
      pane.loading = false
      if (!res.ok) {
        var fatal = res.kind === "auth" || res.kind === "unreachable" || res.kind === "hostkey"
        if (!fatal && pane.loadedTarget === forTarget) {
          // A folder that will not open should not cost the listing we had.
          pane.selectAfterLoad = ""
          pane.notice(String(res.error || pane.tr.t("error.generic")), true)
          return
        }
        pane.error = String(res.error || pane.tr.t("error.generic"))
        pane.errorKind = String(res.kind || "other")
        if (fatal) { pane.loadedTarget = ""; pane.loadedUser = "" }
        pane.entries = []
        pane.rebuild(true)
        return
      }
      var user = String(res.user || "")
      var moved = res.path !== pane.path || pane.loadedTarget !== forTarget || user !== pane.loadedUser
      pane.loadedUser = user
      pane.skippedCount = Number(res.skipped || 0)
      pane.error = ""
      pane.errorKind = ""
      pane.path = String(res.path || wanted)
      if (res.home) pane.home = String(res.home)
      else if (wanted === "" || pane.home === "") pane.home = pane.home || pane.path
      pane.loadedTarget = forTarget
      pane.entries = res.entries instanceof Array ? res.entries : []
      if (moved) {
        pane.clearMarks()
        pane.filterText = ""
        pane.filtering = false
      }
      pane.rebuild(moved)
    })
  }

  function refresh() {
    if (loadedTarget === target && path !== "") load(path)
    else load("")
  }

  function goHome() { load(home || "") }

  function goUp() {
    if (isRoot(path) || blocked) return
    selectAfterLoad = baseName(path)
    load(parentOf(path))
  }

  function isRoot(p) { return p === "" || p === "/" }

  function parentOf(p) {
    var s = String(p || "").replace(/\/+$/, "")
    var i = s.lastIndexOf("/")
    if (i <= 0) return "/"
    var parent = s.substring(0, i)
    return /^\/[A-Za-z]:$/.test(parent) ? parent + "/" : parent
  }

  function baseName(p) {
    var s = String(p || "").replace(/\/+$/, "")
    return s.substring(s.lastIndexOf("/") + 1)
  }

  function join(base, name) {
    if (!base || base === "/") return "/" + name
    return base.replace(/\/+$/, "") + "/" + name
  }

  // ------------------------------------------------------------ the listing

  function rebuild(resetCursor) {
    var q = filterText.trim().toLowerCase()
    var list = []
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      var name = String(e.name || "")
      if (!showHidden && name.charAt(0) === ".") continue
      if (q !== "" && name.toLowerCase().indexOf(q) === -1) continue
      list.push(e)
    }
    var key = sortKey
    var dir = sortDescending ? -1 : 1
    list.sort(function(a, b) {
      var ad = a.type === "dir" ? 0 : 1
      var bd = b.type === "dir" ? 0 : 1
      if (ad !== bd) return ad - bd
      var r = 0
      if (key === "size") r = (a.size || 0) - (b.size || 0)
      else if (key === "mtime") r = (a.mtime || 0) - (b.mtime || 0)
      if (r === 0) r = String(a.name).toLowerCase().localeCompare(String(b.name).toLowerCase())
      return r * dir
    })
    if (loadedTarget === target && path !== "" && path !== "/" && q === "")
      list.unshift({ name: "..", type: "up", size: 0, mtime: 0 })
    rows = list

    var want = selectAfterLoad
    selectAfterLoad = ""
    if (want !== "") {
      for (var j = 0; j < rows.length; j++) if (rows[j].name === want) { cursor = j; positionCursor(); return }
    }
    if (resetCursor) cursor = rows.length > 1 && rows[0].type === "up" ? 1 : 0
    cursor = Math.max(0, Math.min(cursor, rows.length - 1))
    positionCursor()
  }

  function positionCursor() {
    Qt.callLater(function() { if (pane.rows.length > 0) list.positionViewAtIndex(pane.cursor, ListView.Contain) })
  }

  function moveCursor(delta) {
    if (rows.length === 0) return
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + delta))
    positionCursor()
  }

  function cursorTo(index) {
    if (rows.length === 0) return
    cursor = Math.max(0, Math.min(rows.length - 1, index))
    positionCursor()
  }

  function pageSize() { return Math.max(1, Math.floor(list.height / rowHeight) - 1) }

  function currentRow() { return rows.length > 0 ? rows[Math.max(0, Math.min(cursor, rows.length - 1))] : null }

  function activate(index) {
    if (index !== undefined) cursor = index
    var row = currentRow()
    if (!row || blocked) return
    if (row.type === "up") goUp()
    else if (row.type === "dir") load(join(path, row.name))
    else openFile(row)
  }

  function openFile(row) {
    if (!row || row.type === "up") return
    if (!isLocal) notice(tr.t("notice.fetching").arg(row.name), false)
    backend.run(helperAs().concat(["open", target, join(path, row.name)]), function(res) {
      if (!res.ok) pane.notice(String(res.error || pane.tr.t("error.generic")), true)
    })
  }

  // ------------------------------------------------------------ marks

  // Marks are keyed "m:" + name and tested with === true, so a file called
  // "constructor", "toString" or "__proto__" can never read an inherited
  // property as a mark.
  function markKey(name) { return "m:" + name }
  function isMarked(name) { return marked[markKey(name)] === true }

  function clearMarks() {
    marked = ({})
    markedCount = 0
    markedBytes = 0
  }

  function recountMarks() {
    var count = 0
    var bytes = 0
    for (var i = 0; i < entries.length; i++) {
      if (isMarked(entries[i].name)) { count++; bytes += entries[i].size || 0 }
    }
    markedCount = count
    markedBytes = bytes
  }

  function setMark(name, on) {
    if (name === "..") return
    var next = ({})
    for (var k in marked) if (marked[k] === true) next[k] = true
    if (on) next[markKey(name)] = true
    else delete next[markKey(name)]
    marked = next
    recountMarks()
  }

  function toggleMarkAtCursor(advance) {
    var row = currentRow()
    if (!row || row.type === "up") { if (advance) moveCursor(1); return }
    setMark(row.name, !isMarked(row.name))
    if (advance) moveCursor(1)
  }

  function markAll() {
    var next = ({})
    var allMarked = true
    for (var i = 0; i < rows.length; i++) if (rows[i].type !== "up" && !isMarked(rows[i].name)) allMarked = false
    if (!allMarked) for (var j = 0; j < rows.length; j++) if (rows[j].type !== "up") next[markKey(rows[j].name)] = true
    marked = next
    recountMarks()
  }

  function markRange(from, to) {
    var next = ({})
    for (var k in marked) if (marked[k] === true) next[k] = true
    for (var i = Math.min(from, to); i <= Math.max(from, to); i++) if (rows[i] && rows[i].type !== "up") next[markKey(rows[i].name)] = true
    marked = next
    recountMarks()
  }

  // What an action applies to: the marked items, else the row under the cursor.
  function selection() {
    var out = []
    if (markedCount > 0) {
      for (var i = 0; i < entries.length; i++) {
        var e = entries[i]
        if (isMarked(e.name)) out.push({ name: e.name, type: e.type, path: join(path, e.name) })
      }
      return out
    }
    var row = currentRow()
    if (row && row.type !== "up") out.push({ name: row.name, type: row.type, path: join(path, row.name) })
    return out
  }

  // ------------------------------------------------------------ toggles

  function toggleHidden() { showHidden = !showHidden; rebuild(false) }

  function cycleSort() {
    if (sortKey === "name") sortKey = "mtime"
    else if (sortKey === "mtime") sortKey = "size"
    else sortKey = "name"
    sortDescending = sortKey !== "name"
    rebuild(false)
  }

  function sortBy(key) {
    if (sortKey === key) sortDescending = !sortDescending
    else { sortKey = key; sortDescending = key !== "name" }
    rebuild(false)
  }

  function startFilter() {
    filtering = true
    Qt.callLater(function() { filterInput.forceActiveFocus(); filterInput.selectAll() })
  }

  function endFilter(keep) {
    filtering = false
    if (!keep) { filterText = ""; rebuild(true) }
    editingDone()
  }

  function startPathEdit() {
    if (blocked && loadedTarget !== target) return
    editingPath = true
    pathInput.text = path
    Qt.callLater(function() { pathInput.forceActiveFocus(); pathInput.selectAll() })
  }

  function endPathEdit(apply) {
    editingPath = false
    if (apply) {
      var p = pathInput.text.trim()
      if (p.indexOf("~") === 0) p = (home || "") + p.substring(1)
      if (p !== "") load(p)
    }
    editingDone()
  }

  function openMachineMenu() {
    machineIndex = 0
    for (var i = 0; i < machines.length; i++) if (machines[i].host === target) machineIndex = i
    machineMenuOpen = true
  }

  function moveMachine(delta) {
    machineIndex = Math.max(0, Math.min(machines.length - 1, machineIndex + delta))
  }

  function chooseMachine(index) {
    var m = machines[index === undefined ? machineIndex : index]
    if (m) setTarget(m.host)
  }

  // ------------------------------------------------------------ formatting

  function formatSize(bytes) {
    if (!bytes || bytes < 0) return "0 B"
    var units = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    var v = bytes
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
    return Commons.I18n.formatNumber(v, i === 0 || v >= 100 ? 0 : 1) + " " + units[i]
  }

  function formatTime(epoch) {
    if (!epoch) return ""
    var d = new Date(epoch * 1000)
    var now = new Date()
    var loc = Qt.locale(Commons.I18n.formatLocale)
    return d.getFullYear() === now.getFullYear()
      ? d.toLocaleString(loc, "MMM d  HH:mm")
      : d.toLocaleString(loc, "MMM d  yyyy")
  }

  function iconFor(row) {
    if (row.type === "up") return "\u{F005D}"
    if (row.type === "dir") return "\u{F024B}"
    var n = String(row.name).toLowerCase()
    var ext = n.lastIndexOf(".") > 0 ? n.substring(n.lastIndexOf(".") + 1) : ""
    if (["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "heic", "avif", "tiff"].indexOf(ext) >= 0) return "\u{F021F}"
    if (["mp4", "mkv", "mov", "webm", "avi", "m4v"].indexOf(ext) >= 0) return "\u{F022B}"
    if (["mp3", "flac", "wav", "ogg", "m4a", "opus", "aac"].indexOf(ext) >= 0) return "\u{F0223}"
    if (["zip", "tar", "gz", "tgz", "xz", "zst", "bz2", "7z", "rar", "dmg", "iso"].indexOf(ext) >= 0) return "\u{F05C4}"
    if (ext === "pdf") return "\u{F0226}"
    if (["js", "ts", "qml", "py", "rb", "go", "rs", "c", "h", "cpp", "java", "sh", "lua", "json", "toml", "yaml", "yml", "html", "css"].indexOf(ext) >= 0) return "\u{F022E}"
    if (["txt", "md", "doc", "docx", "rtf", "odt", "log"].indexOf(ext) >= 0) return "\u{F0219}"
    return "\u{F0214}"
  }

  function machineIcon(m) { return m.host === "local" ? "\u{F0379}" : "\u{F048B}" }

  // ------------------------------------------------------------ layout

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton
    onPressed: function(mouse) { pane.focusRequested(); mouse.accepted = false }
  }

  Column {
    id: chrome
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(10)
    spacing: Style.space(6)

    // Machine switcher
    Rectangle {
      id: machineButton
      width: parent.width
      height: Math.max(Style.space(34), Style.font.title + Style.space(16))
      radius: Style.cornerRadius
      color: machineMouse.containsMouse || pane.machineMenuOpen ? pane.hoverFill : "transparent"
      clip: true

      Row {
        id: machineRow
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)

        PlainText {
          text: pane.machineIcon(pane.machine)
          color: pane.fg
          font.pixelSize: Style.font.heading
          anchors.verticalCenter: parent.verticalCenter
        }
        Rectangle {
          width: Style.space(7); height: width; radius: width / 2
          anchors.verticalCenter: parent.verticalCenter
          color: pane.blocked ? pane.urgent : (pane.machine.online ? pane.accent : pane.dim)
        }
        PlainText {
          id: machineName
          text: pane.machine.name
          color: pane.fg
          font.pixelSize: Style.font.title
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(implicitWidth, Math.max(Style.space(40), machineButton.width - Style.space(150)))
        }
        PlainText {
          text: String(pane.machine.os || "")
          width: Math.min(implicitWidth, Math.max(0, machineButton.width - machineName.width - Style.space(110)))
          color: pane.dim
          font.pixelSize: Style.font.bodySmall
          anchors.verticalCenter: parent.verticalCenter
        }
        PlainText {
          text: "▾"
          color: pane.dim
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      PlainText {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: pane.loading ? pane.tr.t("pane.loading") : ""
        color: pane.dim
        font.pixelSize: Style.font.bodySmall
      }

      MouseArea {
        id: machineMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          pane.focusRequested()
          if (pane.machineMenuOpen) pane.machineMenuOpen = false
          else pane.openMachineMenu()
        }
      }
    }

    // Path
    Rectangle {
      width: parent.width
      height: Math.max(Style.space(28), Style.font.body + Style.space(14))
      radius: Style.cornerRadius
      color: Util.alpha(pane.fg, pane.editingPath ? 0.08 : 0.04)
      border.width: pane.editingPath ? Math.max(1, Style.space(1)) : 0
      border.color: pane.accent

      PlainText {
        visible: !pane.editingPath
        anchors.fill: parent
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        text: pane.path !== "" ? pane.path : (pane.error !== "" ? "" : pane.tr.t("pane.connecting"))
        color: pane.fg
        elide: Text.ElideLeft
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.IBeamCursor
          onClicked: { pane.focusRequested(); pane.startPathEdit() }
        }
      }

      TextInput {
        id: pathInput
        visible: pane.editingPath
        anchors.fill: parent
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        verticalAlignment: TextInput.AlignVCenter
        color: pane.fg
        selectionColor: Util.alpha(pane.accent, 0.4)
        selectedTextColor: pane.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        clip: true
        Keys.onReturnPressed: pane.endPathEdit(true)
        Keys.onEnterPressed: pane.endPathEdit(true)
        Keys.onEscapePressed: pane.endPathEdit(false)
        onActiveFocusChanged: if (!activeFocus && pane.editingPath) pane.endPathEdit(false)
      }
    }

    // Column headers
    Item {
      width: parent.width
      height: Style.font.bodySmall + Style.space(10)

      PlainText {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(34)
        anchors.verticalCenter: parent.verticalCenter
        text: pane.tr.t("col.name") + (pane.sortKey === "name" ? (pane.sortDescending ? " ↓" : " ↑") : "")
        color: pane.dim
        font.pixelSize: Style.font.bodySmall
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: pane.sortBy("name") }
      }
      PlainText {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8) + pane.timeColWidth + (pane.showTimeCol ? Style.space(12) : 0)
        anchors.verticalCenter: parent.verticalCenter
        visible: pane.showSizeCol
        width: pane.sizeColWidth
        horizontalAlignment: Text.AlignRight
        text: pane.tr.t("col.size") + (pane.sortKey === "size" ? (pane.sortDescending ? " ↓" : " ↑") : "")
        color: pane.dim
        font.pixelSize: Style.font.bodySmall
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: pane.sortBy("size") }
      }
      PlainText {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: pane.timeColWidth
        visible: pane.showTimeCol
        text: pane.tr.t("col.modified") + (pane.sortKey === "mtime" ? (pane.sortDescending ? " ↓" : " ↑") : "")
        color: pane.dim
        font.pixelSize: Style.font.bodySmall
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: pane.sortBy("mtime") }
      }
    }
  }

  // Column widths measured once from sample text so rows line up.
  PlainText { id: sizeCol; visible: false; text: "1023.9 MB"; font.pixelSize: Style.font.bodySmall }
  PlainText { id: timeCol; visible: false; text: "Sep 30  2026  "; font.pixelSize: Style.font.bodySmall }

  ListView {
    id: list
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: chrome.bottom
    anchors.bottom: footer.top
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(6)
    anchors.topMargin: Style.space(2)
    anchors.bottomMargin: Style.space(6)
    clip: true
    visible: !pane.blocked
    model: pane.rows
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    property int anchorIndex: 0

    delegate: Rectangle {
      id: rowItem
      required property var modelData
      required property int index
      readonly property bool isCursor: index === pane.cursor
      readonly property bool isMarked: pane.marked[pane.markKey(modelData.name)] === true

      width: list.width
      height: pane.rowHeight
      radius: Style.cornerRadius
      color: isCursor ? pane.cursorFill : (isMarked ? pane.markFill : (rowMouse.containsMouse ? pane.hoverFill : "transparent"))

      Rectangle {
        visible: rowItem.isMarked
        width: Style.space(3)
        height: parent.height - Style.space(8)
        anchors.left: parent.left
        anchors.leftMargin: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter
        color: pane.accent
        radius: width / 2
      }

      PlainText {
        id: icon
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(18)
        text: pane.iconFor(rowItem.modelData)
        color: rowItem.modelData.type === "dir" || rowItem.isMarked ? pane.accent : pane.fg
        font.pixelSize: Style.font.title
        elide: Text.ElideNone
      }

      PlainText {
        anchors.left: icon.right
        anchors.leftMargin: Style.space(6)
        anchors.right: sizeText.left
        anchors.rightMargin: pane.showSizeCol || pane.showTimeCol ? Style.space(10) : Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        text: rowItem.modelData.name + (rowItem.modelData.link ? "  →" : "")
        color: String(rowItem.modelData.name).charAt(0) === "." && rowItem.modelData.type !== "up" ? pane.dim : pane.fg
        font.bold: rowItem.isMarked
        elide: Text.ElideMiddle
      }

      PlainText {
        id: sizeText
        anchors.right: timeText.left
        anchors.rightMargin: pane.showTimeCol && pane.showSizeCol ? Style.space(12) : 0
        anchors.verticalCenter: parent.verticalCenter
        visible: pane.showSizeCol
        width: pane.sizeColWidth
        horizontalAlignment: Text.AlignRight
        text: rowItem.modelData.type === "file" ? pane.formatSize(rowItem.modelData.size) : ""
        color: pane.dim
        font.pixelSize: Style.font.bodySmall
      }

      PlainText {
        id: timeText
        anchors.right: parent.right
        anchors.rightMargin: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter
        width: pane.timeColWidth
        visible: pane.showTimeCol
        text: pane.formatTime(rowItem.modelData.mtime)
        color: pane.dim
        font.pixelSize: Style.font.bodySmall
      }

      MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function(mouse) {
          pane.focusRequested()
          if (mouse.button === Qt.RightButton || (mouse.modifiers & Qt.ControlModifier)) {
            pane.cursor = rowItem.index
            pane.setMark(rowItem.modelData.name, !rowItem.isMarked)
            list.anchorIndex = rowItem.index
          } else if (mouse.modifiers & Qt.ShiftModifier) {
            pane.markRange(list.anchorIndex, rowItem.index)
            pane.cursor = rowItem.index
          } else {
            pane.cursor = rowItem.index
            list.anchorIndex = rowItem.index
          }
        }
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.LeftButton) pane.activate(rowItem.index)
        }
      }
    }

    PlainText {
      anchors.centerIn: parent
      visible: !pane.loading && pane.rows.length === 0 && pane.error === "" && pane.loadedTarget === pane.target
      text: pane.filterText !== "" ? pane.tr.t("pane.noMatches") : pane.tr.t("pane.empty")
      color: pane.dim
    }
  }

  // Connection problems replace the listing with what to do about them.
  Flickable {
    id: errorArea
    anchors.fill: list
    visible: pane.blocked
    clip: true
    contentWidth: width
    contentHeight: Math.max(height, errorBox.implicitHeight + Style.space(24))
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height

  Column {
    id: errorBox
    y: Math.max(Style.space(12), (errorArea.contentHeight - implicitHeight) / 2)
    x: (errorArea.width - width) / 2
    width: Math.min(errorArea.width - Style.space(32), Style.space(420))
    spacing: Style.space(12)

    PlainText {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      elide: Text.ElideNone
      font.pixelSize: Style.font.heading
      font.bold: true
      color: pane.fg
      text: pane.errorKind === "auth" ? pane.tr.t("error.authTitle").arg(pane.machine.name)
        : pane.errorKind === "unreachable" ? pane.tr.t("error.unreachableTitle").arg(pane.machine.name)
        : pane.errorKind === "hostkey" ? pane.tr.t("error.hostkeyTitle")
        : pane.tr.t("error.genericTitle")
    }
    PlainText {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      elide: Text.ElideNone
      color: pane.dim
      font.pixelSize: Style.font.bodySmall
      text: pane.error
    }
    PlainText {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      elide: Text.ElideNone
      color: pane.fg
      visible: text !== ""
      text: pane.errorKind === "auth" ? pane.tr.t("error.authHelp")
        : pane.errorKind === "unreachable" ? pane.tr.t("error.unreachableHelp")
        : pane.errorKind === "hostkey" ? pane.tr.t("error.hostkeyHelp").arg(pane.target)
        : ""
    }
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(8)

      ActionButton {
        visible: pane.errorKind === "auth"
        label: pane.tr.t("action.setupKey")
        fg: pane.fg; accent: pane.accent; primary: true
        onClicked: pane.setupKeyRequested(pane.target)
      }
      ActionButton {
        visible: pane.errorKind === "auth"
        label: pane.tr.t("action.changeUser")
        fg: pane.fg; accent: pane.accent
        onClicked: pane.userPromptRequested(pane.target)
      }
      ActionButton {
        label: pane.tr.t("action.retry")
        fg: pane.fg; accent: pane.accent
        primary: pane.errorKind !== "auth"
        onClicked: pane.refresh()
      }
    }
  }

  }

  // Footer: counts, or the filter field while filtering.
  Item {
    id: footer
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(10)
    height: Math.max(Style.space(24), Style.font.bodySmall + Style.space(12))

    PlainText {
      visible: !pane.filtering
      anchors.fill: parent
      color: pane.dim
      font.pixelSize: Style.font.bodySmall
      text: {
        if (pane.blocked) return ""
        var n = pane.rows.length > 0 && pane.rows[0].type === "up" ? pane.rows.length - 1 : pane.rows.length
        var s = pane.tr.tn("footer.items", n).arg(Commons.I18n.formatNumber(n))
        if (pane.markedCount > 0) s += "  ·  " + pane.tr.tn("footer.marked", pane.markedCount).arg(Commons.I18n.formatNumber(pane.markedCount)).arg(pane.formatSize(pane.markedBytes))
        if (pane.filterText !== "") s += "  ·  " + pane.tr.t("footer.filtered").arg(pane.filterText)
        if (pane.showHidden) s += "  ·  " + pane.tr.t("footer.hidden")
        if (pane.skippedCount > 0) s += "  ·  " + pane.tr.tn("footer.skipped", pane.skippedCount).arg(Commons.I18n.formatNumber(pane.skippedCount))
        return s
      }
    }

    Rectangle {
      visible: pane.filtering
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Util.alpha(pane.fg, 0.08)
      border.width: Math.max(1, Style.space(1))
      border.color: pane.accent

      PlainText {
        id: filterLabel
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: "/"
        color: pane.accent
      }
      TextInput {
        id: filterInput
        anchors.left: filterLabel.right
        anchors.leftMargin: Style.space(6)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        color: pane.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        clip: true
        text: pane.filterText
        onTextEdited: { pane.filterText = text; pane.rebuild(true) }
        Keys.onReturnPressed: pane.endFilter(true)
        Keys.onEnterPressed: pane.endFilter(true)
        Keys.onEscapePressed: pane.endFilter(false)
        Keys.onUpPressed: pane.moveCursor(-1)
        Keys.onDownPressed: pane.moveCursor(1)
        onActiveFocusChanged: if (!activeFocus && pane.filtering) pane.endFilter(true)
      }
    }
  }

  // Machine menu, dropped from the switcher.
  Rectangle {
    id: machineMenu
    visible: pane.machineMenuOpen
    z: 50
    x: chrome.x
    y: chrome.y + machineButton.height + Style.space(4)
    width: Math.min(chrome.width, Style.space(360))
    height: menuColumn.implicitHeight + Style.space(12)
    radius: Style.cornerRadius
    color: Commons.Color.popups.background
    border.width: Math.max(1, Style.space(1))
    border.color: Util.alpha(pane.accent, 0.8)

    Column {
      id: menuColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(6)

      PlainText {
        width: parent.width
        leftPadding: Style.space(8)
        height: Style.font.bodySmall + Style.space(12)
        text: pane.tr.t("menu.title")
        color: pane.dim
        font.pixelSize: Style.font.bodySmall
      }

      Repeater {
        model: pane.machines
        delegate: Rectangle {
          id: mrow
          required property var modelData
          required property int index
          width: menuColumn.width
          height: pane.rowHeight + Style.space(6)
          radius: Style.cornerRadius
          color: index === pane.machineIndex ? pane.cursorFill : (mMouse.containsMouse ? pane.hoverFill : "transparent")
          opacity: modelData.online ? 1 : 0.5

          PlainText {
            id: micon
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: pane.machineIcon(mrow.modelData)
            color: pane.fg
            font.pixelSize: Style.font.title
            elide: Text.ElideNone
          }
          Rectangle {
            id: mdot
            anchors.left: micon.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(7); height: width; radius: width / 2
            color: mrow.modelData.online ? pane.accent : pane.dim
          }
          PlainText {
            anchors.left: mdot.right
            anchors.leftMargin: Style.space(8)
            anchors.right: mmeta.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: mrow.modelData.name
            color: pane.fg
            font.bold: mrow.modelData.host === pane.target
          }
          PlainText {
            id: mmeta
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: mrow.modelData.host === "local" ? "" : ((mrow.modelData.user ? mrow.modelData.user + "@ · " : "") + String(mrow.modelData.os || "") + (mrow.modelData.online ? "" : " · " + pane.tr.t("menu.offline")))
            color: pane.dim
            font.pixelSize: Style.font.bodySmall
          }
          MouseArea {
            id: mMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: pane.machineIndex = mrow.index
            onClicked: pane.chooseMachine(mrow.index)
          }
        }
      }
    }
  }
}
