import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// Tailnet Files: a two-pane browser between this computer and the machines
// on your tailnet. The shell keeps this panel loaded (manifest keepLoaded),
// so transfers keep running after the window is closed.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property bool closingFromHost: false

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "dmaje.tailfiles"
  readonly property color fg: Commons.Color.foreground
  readonly property color bg: Commons.Color.background
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property color dim: Qt.darker(fg, 1.6)

  property var peers: []
  property string selfName: ""
  property string localUser: ""
  property string peersError: ""
  property int activePane: 0
  readonly property var activeView: activePane === 0 ? leftPane : rightPane
  readonly property var otherView: activePane === 0 ? rightPane : leftPane
  property string statusText: ""
  property bool statusIsError: false
  property bool initialized: false

  // Dialog state: kind is "" | "mkdir" | "rename" | "delete" | "user" | "help"
  property string dialogKind: ""
  property string dialogTitle: ""
  property string dialogBody: ""
  property var dialogContext: null

  // Transfers
  property int nextJobId: 1
  property bool transferRunning: false
  property int runningJobId: 0

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  Backend { id: backend }

  // ---------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(String(payloadJson || "{}")) || ({}) } catch (e) {}
    closingFromHost = false
    opened = true
    window.visible = true
    loadPeers(function() {
      if (!root.initialized) {
        root.initialized = true
        leftPane.setTarget("local")
        rightPane.setTarget(payload.host ? String(payload.host) : root.defaultRemote())
      } else if (payload.host) {
        if (String(payload.host) !== rightPane.target && dialogContext
            && (dialogContext.pane === rightPane || dialogContext.srcPane === rightPane)
            && (dialogKind === "mkdir" || dialogKind === "rename" || dialogKind === "delete" || dialogKind === "replace")) {
          closeDialog()
          setStatus(strings.t("status.dialogStale"), true)
        }
        rightPane.setTarget(String(payload.host))
      }
    })
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    closingFromHost = true
    opened = false
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  function defaultRemote() {
    var remembered = root.lastRemote
    for (var i = 0; i < peers.length; i++) if (peers[i].host === remembered && peers[i].online) return remembered
    for (var j = 0; j < peers.length; j++) if (peers[j].online) return peers[j].host
    return "local"
  }

  function loadPeers(after) {
    backend.run(["peers"], function(res) {
      if (res.ok) {
        root.peers = res.peers instanceof Array ? res.peers : []
        root.selfName = String(res.self || "")
        root.localUser = String(res.user || "")
        root.lastRemote = String(res.last || "")
        root.peersError = res.backend && res.backend !== "Running" ? strings.t("status.tailscaleDown").arg(res.backend) : ""
      } else {
        root.peers = []
        root.peersError = String(res.error || strings.t("status.tailscaleDown").arg("?"))
      }
      if (root.peersError !== "") root.setStatus(root.peersError, true)
      if (after) after()
    })
  }

  function setStatus(text, isError) {
    statusText = text
    statusIsError = !!isError
    statusTimer.restart()
  }

  Timer { id: statusTimer; interval: 6000; onTriggered: root.statusText = "" }

  // Remember the last remote machine so the window reopens where you were.
  property string lastRemote: ""

  function rememberRemote() {
    var host = rightPane.target
    if (host === "local" || host === lastRemote) return
    lastRemote = host
    backend.run(["remember", host], null)
  }

  // ---------------------------------------------------------------- actions

  // Pins a helper call to the account a listing was made under.
  function asArgs(target, user) {
    return (target !== "local" && user) ? ["--as", target + "=" + user] : []
  }

  function switchPane() {
    activePane = activePane === 0 ? 1 : 0
  }

  function copySelection() {
    var src = activeView
    var dst = otherView
    var items = src.selection()
    if (items.length === 0) { setStatus(strings.t("status.nothingSelected"), true); return }
    if (src.blocked || dst.blocked || dst.path === "") { setStatus(strings.t("status.destinationNotReady"), true); return }
    if (src.target === dst.target && src.path === dst.path) { setStatus(strings.t("status.sameFolder"), true); return }
    var paths = []
    var names = []
    for (var i = 0; i < items.length; i++) { paths.push(items[i].path); names.push(items[i].name) }
    var job = {
      srcTarget: src.target, srcName: src.machine.name, srcUser: src.loadedUser, srcDir: src.path,
      dstTarget: dst.target, dstName: dst.machine.name, dstUser: dst.loadedUser, dstDir: dst.path,
      paths: paths, names: names, replace: false
    }
    // Never overwrite silently: if something with the same name is already
    // there, ask first. (The helper checks again and refuses if it finds
    // anything this listing didn't show.)
    var clash = []
    for (var k = 0; k < dst.entries.length; k++) if (names.indexOf(dst.entries[k].name) >= 0) clash.push(dst.entries[k].name)
    if (clash.length > 0) {
      var what = clash.length === 1 ? clash[0] : strings.tn("transfer.items", clash.length).arg(Commons.I18n.formatNumber(clash.length))
      openDialog("replace", strings.t("dialog.replaceTitle").arg(what),
                 strings.t("dialog.replaceBody").arg(dst.path).arg(dst.machine.name),
                 { pane: dst, target: dst.target, path: dst.path, user: dst.loadedUser,
                   srcPane: src, job: job }, "")
      return
    }
    enqueue(job)
    src.clearMarks()
  }

  function enqueue(job) {
    jobs.append({
      jobId: nextJobId++,
      srcTarget: job.srcTarget, srcName: job.srcName, srcUser: job.srcUser || "",
      dstTarget: job.dstTarget, dstName: job.dstName, dstDir: job.dstDir, dstUser: job.dstUser || "",
      replace: !!job.replace,
      pathsJson: JSON.stringify(job.paths),
      label: job.names.length === 1 ? job.names[0] : strings.tn("transfer.items", job.names.length).arg(Commons.I18n.formatNumber(job.names.length)),
      jobState: "queued", pct: 0, rate: "", file: "", error: "", engine: ""
    })
    pumpQueue()
  }

  function pumpQueue() {
    if (transferRunning) return
    for (var i = 0; i < jobs.count; i++) {
      var j = jobs.get(i)
      if (j.jobState !== "queued") continue
      jobs.setProperty(i, "jobState", "running")
      runningJobId = j.jobId
      transferRunning = true
      transferProc.command = [backend.helper].concat(asArgs(j.srcTarget, j.srcUser), asArgs(j.dstTarget, j.dstUser),
                                                     ["copy"], j.replace ? ["--replace"] : [],
                                                     [j.srcTarget, j.dstTarget, j.dstDir], JSON.parse(j.pathsJson))
      transferProc.running = true
      return
    }
  }

  function jobIndex(id) {
    for (var i = 0; i < jobs.count; i++) if (jobs.get(i).jobId === id) return i
    return -1
  }

  function cancelJob(id) {
    var i = jobIndex(id)
    if (i < 0) return
    var j = jobs.get(i)
    if (j.jobState === "queued") jobs.setProperty(i, "jobState", "cancelled")
    else if (j.jobState === "running") transferProc.signal(15)
  }

  function clearFinished() {
    for (var i = jobs.count - 1; i >= 0; i--) if (jobs.get(i).jobState !== "running" && jobs.get(i).jobState !== "queued") jobs.remove(i)
  }

  function handleTransferEvent(line) {
    var ev
    try { ev = JSON.parse(line) } catch (e) { return }
    var i = jobIndex(runningJobId)
    if (i < 0) return
    if (ev.event === "start") jobs.setProperty(i, "engine", String(ev.engine || ""))
    else if (ev.event === "progress") {
      jobs.setProperty(i, "pct", Number(ev.pct || 0))
      jobs.setProperty(i, "rate", String(ev.rate || ""))
      if (ev.file) jobs.setProperty(i, "file", String(ev.file))
    } else if (ev.event === "done") {
      jobs.setProperty(i, "jobState", ev.ok ? "done" : (ev.cancelled ? "cancelled" : "failed"))
      if (ev.ok) jobs.setProperty(i, "pct", 100)
      if (!ev.ok) jobs.setProperty(i, "error", ev.kind === "exists" ? strings.t("transfer.exists").arg(String(ev.error))
                                                                    : String(ev.error || strings.t("error.generic")))
    }
  }

  function transferFinished(exitCode) {
    var i = jobIndex(runningJobId)
    if (i >= 0) {
      var j = jobs.get(i)
      if (j.jobState === "running") {
        jobs.setProperty(i, "jobState", exitCode === 0 ? "done" : "failed")
        if (exitCode !== 0) jobs.setProperty(i, "error", strings.t("error.helperExit").arg(exitCode))
      }
      j = jobs.get(i)
      var panes = [leftPane, rightPane]
      for (var p = 0; p < panes.length; p++) {
        if (panes[p].target === j.dstTarget && panes[p].path === j.dstDir) panes[p].refresh()
      }
      if (!opened && j.jobState !== "cancelled") {
        var title = j.jobState === "done" ? strings.t("notify.done") : strings.t("notify.failed")
        var body = j.label + " → " + j.dstName + (j.jobState === "failed" ? "\n" + j.error : "")
        Quickshell.execDetached(["notify-send", "-a", "Tailnet Files", "-i", "folder-remote", title, body])
      }
    }
    transferRunning = false
    runningJobId = 0
    pumpQueue()
  }

  ListModel { id: jobs }

  Process {
    id: transferProc
    running: false
    stdout: SplitParser { onRead: function(data) { root.handleTransferEvent(data) } }
    stderr: SplitParser { onRead: function(data) { if (String(data).trim() !== "") console.warn("tailfiles:", data) } }
    onExited: function(exitCode) { Qt.callLater(function() { root.transferFinished(exitCode) }) }
  }

  // File operations on the active pane.

  function promptMkdir() {
    var v = activeView
    if (v.blocked || v.path === "") return
    openDialog("mkdir", strings.t("dialog.mkdirTitle"), strings.t("dialog.mkdirBody").arg(v.path), { pane: v, target: v.target, path: v.path, user: v.loadedUser }, "")
  }

  function promptRename() {
    var v = activeView
    var row = v.currentRow()
    if (!row || row.type === "up" || v.blocked) return
    openDialog("rename", strings.t("dialog.renameTitle"), "", { pane: v, target: v.target, path: v.path, user: v.loadedUser, name: row.name }, row.name)
  }

  function promptDelete() {
    var v = activeView
    var items = v.selection()
    if (items.length === 0 || v.blocked) return
    var what = items.length === 1 ? items[0].name : strings.tn("transfer.items", items.length).arg(Commons.I18n.formatNumber(items.length))
    var body = v.isLocal ? strings.t("dialog.deleteLocalBody") : strings.t("dialog.deleteRemoteBody").arg(v.machine.name)
    openDialog("delete", strings.t("dialog.deleteTitle").arg(what), body, { pane: v, target: v.target, path: v.path, user: v.loadedUser, items: items }, "")
  }

  function promptUser(host) {
    var current = ""
    for (var i = 0; i < peers.length; i++) if (peers[i].host === host) current = peers[i].user
    openDialog("user", strings.t("dialog.userTitle").arg(host), strings.t("dialog.userBody").arg(localUser), { host: host }, current || localUser)
  }

  function setupKey(host) {
    backend.run(["setup-key", host], function(res) {
      if (res.ok) root.setStatus(strings.t("status.setupKey").arg(host), false)
      else root.setStatus(String(res.error || ""), true)
    })
  }

  function openDialog(kind, title, body, context, value) {
    dialogKind = kind
    dialogTitle = title
    dialogBody = body
    dialogContext = context
    dialogInput.text = value || ""
    Qt.callLater(function() {
      if (kind === "delete" || kind === "replace" || kind === "help") dialogKeys.forceActiveFocus()
      else {
        dialogInput.forceActiveFocus()
        if (kind === "rename" && value && value.lastIndexOf(".") > 0) dialogInput.select(0, value.lastIndexOf("."))
        else dialogInput.selectAll()
      }
    })
  }

  function closeDialog() {
    dialogKind = ""
    dialogContext = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function acceptDialog() {
    var kind = dialogKind
    var ctx = dialogContext
    var value = dialogInput.text.trim()
    if (kind === "help") { closeDialog(); return }
    if ((kind === "mkdir" || kind === "rename") && (value === "" || value.indexOf("/") >= 0 || value === "." || value === "..")) {
      setStatus(strings.t("status.badName"), true)
      return
    }
    closeDialog()
    if (!ctx) return
    // A dialog acts on the machine and folder it was opened for. If the pane
    // has moved since (a summon can retarget it), do nothing.
    if (kind === "mkdir" || kind === "rename" || kind === "delete" || kind === "replace") {
      var stale = ctx.pane.target !== ctx.target || ctx.pane.path !== ctx.path || ctx.pane.loadedUser !== ctx.user
      if (kind === "replace") {
        var j0 = ctx.job
        stale = stale || ctx.srcPane.target !== j0.srcTarget || ctx.srcPane.path !== j0.srcDir || ctx.srcPane.loadedUser !== j0.srcUser
      }
      if (stale) {
        setStatus(strings.t("status.dialogStale"), true)
        return
      }
    }
    if (kind === "replace") {
      var rj = ctx.job
      rj.replace = true
      enqueue(rj)
      ctx.srcPane.clearMarks()
      return
    }
    if (kind === "mkdir") {
      var p = ctx.pane
      backend.run(asArgs(ctx.target, ctx.user).concat(["mkdir", ctx.target, p.join(ctx.path, value)]), function(res) {
        if (!res.ok) { root.setStatus(String(res.error), true); return }
        p.selectAfterLoad = value
        p.refresh()
      })
    } else if (kind === "rename") {
      var rp = ctx.pane
      if (value === ctx.name) return
      backend.run(asArgs(ctx.target, ctx.user).concat(["rename", ctx.target, rp.join(ctx.path, ctx.name), rp.join(ctx.path, value)]), function(res) {
        if (!res.ok) { root.setStatus(String(res.error), true); return }
        rp.selectAfterLoad = value
        rp.refresh()
      })
    } else if (kind === "delete") {
      var dp = ctx.pane
      var paths = []
      for (var i = 0; i < ctx.items.length; i++) paths.push(ctx.items[i].path)
      setStatus(strings.t("status.deleting"), false)
      backend.run(asArgs(ctx.target, ctx.user).concat(["delete", ctx.target], paths), function(res) {
        if (!res.ok) {
          root.setStatus(String(res.error), true)
          // Some items may already be gone (trashed before a failure).
          if (res.trashed) { dp.clearMarks(); dp.refresh() }
          return
        }
        root.setStatus(res.trashed ? strings.t("status.trashed") : strings.t("status.deleted"), false)
        dp.clearMarks()
        dp.refresh()
      })
    } else if (kind === "user") {
      backend.run(["set-user", ctx.host, value], function(res) {
        if (!res.ok) { root.setStatus(String(res.error), true); return }
        root.loadPeers(function() {
          if (leftPane.target === ctx.host) leftPane.refresh()
          if (rightPane.target === ctx.host) rightPane.refresh()
        })
      })
    }
  }

  // ---------------------------------------------------------------- keys

  function handleKey(event) {
    var v = activeView
    var key = event.key
    var t = event.text
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0

    if (v.machineMenuOpen) {
      if (key === Qt.Key_Escape) v.machineMenuOpen = false
      else if (key === Qt.Key_Down || t === "j") v.moveMachine(1)
      else if (key === Qt.Key_Up || t === "k") v.moveMachine(-1)
      else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space || t === "l") v.chooseMachine()
      else if (key === Qt.Key_Tab) { v.machineMenuOpen = false; switchPane() }
      else return false
      return true
    }

    if (key === Qt.Key_Tab || key === Qt.Key_Backtab) { switchPane(); return true }
    if (key === Qt.Key_Escape) {
      if (v.markedCount > 0) v.clearMarks()
      else if (v.filterText !== "") { v.filterText = ""; v.rebuild(true) }
      else requestClose()
      return true
    }
    if (ctrl && key === Qt.Key_A) { v.markAll(); return true }
    if (ctrl && key === Qt.Key_L) { v.startPathEdit(); return true }
    if (ctrl && key === Qt.Key_R) { v.refresh(); loadPeers(null); return true }
    if (ctrl && key === Qt.Key_H) { v.toggleHidden(); return true }
    if (ctrl) return false

    if (key === Qt.Key_Down || t === "j") v.moveCursor(1)
    else if (key === Qt.Key_Up || t === "k") v.moveCursor(-1)
    else if (key === Qt.Key_PageDown) v.moveCursor(v.pageSize())
    else if (key === Qt.Key_PageUp) v.moveCursor(-v.pageSize())
    else if (key === Qt.Key_Home || t === "g") v.cursorTo(0)
    else if (key === Qt.Key_End || t === "G") v.cursorTo(v.rows.length - 1)
    else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Right || t === "l") v.activate()
    else if (key === Qt.Key_Backspace || key === Qt.Key_Left || t === "h") v.goUp()
    else if (key === Qt.Key_Space) v.toggleMarkAtCursor(true)
    else if (key === Qt.Key_Insert) v.toggleMarkAtCursor(true)
    else if (key === Qt.Key_F5 || t === "c" || t === "y") copySelection()
    else if (key === Qt.Key_F7 || t === "n") promptMkdir()
    else if (key === Qt.Key_F2 || t === "R") promptRename()
    else if (key === Qt.Key_Delete || key === Qt.Key_F8 || t === "D") promptDelete()
    else if (t === "r") v.refresh()
    else if (t === "o") { var row = v.currentRow(); if (row && row.type !== "up") v.openFile(row) }
    else if (t === ".") v.toggleHidden()
    else if (t === "s") v.cycleSort()
    else if (t === "m") v.openMachineMenu()
    else if (t === "~") v.goHome()
    else if (t === "/") v.startFilter()
    else if (t === "=") { otherView.setTarget(v.target); otherView.load(v.path) }
    else if (t === "?" || key === Qt.Key_F1) openDialog("help", strings.t("help.title"), "", null, "")
    else return false
    return true
  }

  // ---------------------------------------------------------------- window

  FloatingWindow {
    id: window
    title: "Tailnet Files"
    color: root.bg
    visible: false
    implicitWidth: Style.space(1180)
    implicitHeight: Style.space(740)
    minimumSize: Qt.size(Style.space(760), Style.space(460))

    onVisibleChanged: {
      if (!visible && root.opened && !root.closingFromHost) root.requestClose()
    }

    FocusScope {
      id: keys
      anchors.fill: parent
      focus: true

      // Holds focus whenever no text field is being edited. It is a sibling
      // of the panes, not their ancestor, so handing focus back to it really
      // takes it away from a field that has just closed.
      Item {
        id: keyCatcher
        focus: true
        Keys.onPressed: function(event) {
          if (root.dialogKind !== "") return
          if (root.handleKey(event)) event.accepted = true
        }
      }

      // Header
      Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(14)
        height: Math.max(Style.space(34), Style.font.heading + Style.space(14))

        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(10)

          PlainText {
            text: "\u{F0FB6}"
            color: root.accent
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideNone
          }
          PlainText {
            text: strings.t("app.title")
            color: root.fg
            font.pixelSize: Style.font.heading
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
          PlainText {
            text: root.selfName !== "" ? strings.t("app.subtitle").arg(root.selfName).arg(root.peers.filter(function(p) { return p.online }).length) : ""
            color: root.dim
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          ActionButton {
            glyph: "\u{F0450}"
            hint: "Ctrl+R"
            fg: root.fg; accent: root.accent
            onClicked: { root.loadPeers(null); leftPane.refresh(); rightPane.refresh() }
          }
          ActionButton {
            label: "?"
            fg: root.fg; accent: root.accent
            onClicked: root.openDialog("help", strings.t("help.title"), "", null, "")
          }
        }
      }

      // Panes
      Item {
        id: panes
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.bottom: toolbar.top
        anchors.leftMargin: Style.space(14)
        anchors.rightMargin: Style.space(14)
        anchors.topMargin: Style.space(10)
        anchors.bottomMargin: Style.space(10)

        FilePane {
          id: leftPane
          backend: backend
          tr: strings
          peers: root.peers
          localName: root.selfName !== "" ? root.selfName : strings.t("pane.thisComputerAlone")
          active: root.activePane === 0
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: (parent.width - Style.space(10)) / 2
          fg: root.fg; bg: root.bg; accent: root.accent; urgent: root.urgent
          onFocusRequested: { root.activePane = 0; keyCatcher.forceActiveFocus() }
          onEditingDone: keyCatcher.forceActiveFocus()
          onNotice: function(text, isError) { root.setStatus(text, isError) }
          onSetupKeyRequested: function(host) { root.setupKey(host) }
          onUserPromptRequested: function(host) { root.promptUser(host) }
        }

        FilePane {
          id: rightPane
          backend: backend
          tr: strings
          peers: root.peers
          localName: leftPane.localName
          active: root.activePane === 1
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: (parent.width - Style.space(10)) / 2
          fg: root.fg; bg: root.bg; accent: root.accent; urgent: root.urgent
          onFocusRequested: { root.activePane = 1; keyCatcher.forceActiveFocus() }
          onEditingDone: keyCatcher.forceActiveFocus()
          onNotice: function(text, isError) { root.setStatus(text, isError) }
          onSetupKeyRequested: function(host) { root.setupKey(host) }
          onUserPromptRequested: function(host) { root.promptUser(host) }
          onTargetChanged: root.rememberRemote()
        }
      }

      // Toolbar
      Item {
        id: toolbar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: transfers.top
        anchors.leftMargin: Style.space(14)
        anchors.rightMargin: Style.space(14)
        anchors.bottomMargin: Style.space(8)
        height: toolbarFlow.implicitHeight

        Flow {
          id: toolbarFlow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.space(6)

          ActionButton {
            primary: true
            label: root.activePane === 0 ? strings.t("action.copyRight").arg(rightPane.machine.name) : strings.t("action.copyLeft").arg(leftPane.machine.name)
            hint: "c"
            fg: root.fg; accent: root.accent
            enabledState: !root.activeView.blocked && !root.otherView.blocked
            onClicked: root.copySelection()
          }
          ActionButton { label: strings.t("action.mkdir"); hint: "n"; fg: root.fg; accent: root.accent; onClicked: root.promptMkdir() }
          ActionButton { label: strings.t("action.rename"); hint: "F2"; fg: root.fg; accent: root.accent; onClicked: root.promptRename() }
          ActionButton { label: strings.t("action.delete"); hint: "Del"; fg: root.fg; accent: root.accent; onClicked: root.promptDelete() }
          ActionButton { label: strings.t("action.open"); hint: "o"; fg: root.fg; accent: root.accent; onClicked: { var r = root.activeView.currentRow(); if (r && r.type !== "up") root.activeView.openFile(r) } }
          ActionButton { label: root.activeView.showHidden ? strings.t("action.hideHidden") : strings.t("action.showHidden"); hint: "."; fg: root.fg; accent: root.accent; onClicked: root.activeView.toggleHidden() }
        }

      }

      // Transfers
      Rectangle {
        id: transfers
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: hints.top
        anchors.leftMargin: Style.space(14)
        anchors.rightMargin: Style.space(14)
        anchors.bottomMargin: Style.space(6)
        height: jobs.count === 0 ? 0 : Math.min(jobList.contentHeight, (Style.space(30)) * 4) + Style.space(12)
        visible: jobs.count > 0
        radius: Style.cornerRadius
        color: Util.alpha(root.fg, 0.03)
        border.width: Math.max(1, Style.space(1))
        border.color: Util.alpha(root.fg, 0.1)
        Behavior on height { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }

        ListView {
          id: jobList
          anchors.fill: parent
          anchors.margins: Style.space(6)
          clip: true
          model: jobs
          spacing: Style.space(2)
          boundsBehavior: Flickable.StopAtBounds

          delegate: Item {
            id: jobRow
            required property int jobId
            required property string label
            required property string srcName
            required property string dstName
            required property string dstDir
            required property string jobState
            required property real pct
            required property string rate
            required property string file
            required property string error
            required property string engine
            width: jobList.width
            height: Style.space(28)

            PlainText {
              id: jobGlyph
              anchors.left: parent.left
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(16)
              elide: Text.ElideNone
              text: jobRow.jobState === "done" ? "\u{F012C}" : jobRow.jobState === "failed" ? "\u{F0156}" : jobRow.jobState === "cancelled" ? "–" : "↑"
              color: jobRow.jobState === "failed" ? root.urgent : (jobRow.jobState === "done" ? root.accent : root.fg)
            }
            PlainText {
              id: jobText
              anchors.left: jobGlyph.right
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, parent.width * 0.45)
              text: jobRow.label + "  →  " + jobRow.dstName + ":" + jobRow.dstDir
              color: root.fg
              elide: Text.ElideMiddle
            }
            Rectangle {
              id: bar
              anchors.left: jobText.right
              anchors.leftMargin: Style.space(12)
              anchors.right: jobMeta.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              height: Style.space(4)
              radius: height / 2
              color: Util.alpha(root.fg, 0.1)
              visible: jobRow.jobState === "running" || jobRow.jobState === "queued"
              Rectangle {
                width: parent.width * Math.max(0, Math.min(100, jobRow.pct)) / 100
                height: parent.height
                radius: parent.radius
                color: root.accent
                Behavior on width { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
              }
            }
            PlainText {
              anchors.left: jobText.right
              anchors.leftMargin: Style.space(12)
              anchors.right: jobMeta.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              visible: jobRow.jobState === "failed"
              text: jobRow.error
              color: root.urgent
              font.pixelSize: Style.font.bodySmall
            }
            PlainText {
              id: jobMeta
              anchors.right: jobCancel.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideNone
              text: jobRow.jobState === "running" ? (Commons.I18n.formatNumber(jobRow.pct) + "%" + (jobRow.rate ? "  " + jobRow.rate : "") + (jobRow.file && jobRow.engine === "scp" ? "  " + jobRow.file : ""))
                : jobRow.jobState === "queued" ? strings.t("transfer.queued")
                : jobRow.jobState === "done" ? strings.t("transfer.done")
                : jobRow.jobState === "cancelled" ? strings.t("transfer.cancelled") : ""
            }
            ActionButton {
              id: jobCancel
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              implicitHeight: Style.space(22)
              label: jobRow.jobState === "running" || jobRow.jobState === "queued" ? strings.t("transfer.cancel") : strings.t("transfer.dismiss")
              fg: root.fg; accent: root.accent
              onClicked: {
                if (jobRow.jobState === "running" || jobRow.jobState === "queued") root.cancelJob(jobRow.jobId)
                else { var i = root.jobIndex(jobRow.jobId); if (i >= 0) jobs.remove(i) }
              }
            }
          }
        }
      }

      PlainText {
        id: hints
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Style.space(16)
        anchors.rightMargin: Style.space(16)
        anchors.bottomMargin: Style.space(10)
        height: Style.font.bodySmall + Style.space(6)
        // Status messages take over the hint line so they show at any width.
        color: root.statusText === "" ? root.dim : (root.statusIsError ? root.urgent : root.fg)
        font.pixelSize: root.statusText === "" ? Style.font.caption : Style.font.bodySmall
        text: root.statusText !== "" ? root.statusText : strings.t("hints")
      }

      // Dialog
      Rectangle {
        anchors.fill: parent
        visible: root.dialogKind !== ""
        color: Util.alpha(root.bg, 0.6)
        z: 100
        MouseArea { anchors.fill: parent; onClicked: root.closeDialog() }

        Rectangle {
          id: dialogCard
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.space(40), root.dialogKind === "help" ? Style.space(620) : Style.space(460))
          height: dialogColumn.implicitHeight + Style.space(36)
          radius: Style.cornerRadius
          color: Commons.Color.popups.background
          border.width: Math.max(1, Style.space(2))
          border.color: (root.dialogKind === "delete" || root.dialogKind === "replace") ? root.urgent : Commons.Color.popups.border
          MouseArea { anchors.fill: parent }

          FocusScope {
            id: dialogKeys
            anchors.fill: parent
            Keys.onPressed: function(event) {
              var confirmKind = root.dialogKind === "delete" || root.dialogKind === "replace"
              if (event.key === Qt.Key_Escape || (confirmKind && event.text === "n")) { root.closeDialog(); event.accepted = true }
              else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || (confirmKind && event.text === "y")) { root.acceptDialog(); event.accepted = true }
              else if (root.dialogKind === "help") { root.closeDialog(); event.accepted = true }
            }
          }

          Column {
            id: dialogColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(18)
            spacing: Style.space(12)

            PlainText {
              width: parent.width
              text: root.dialogTitle
              color: root.fg
              font.pixelSize: Style.font.heading
              font.bold: true
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
            }
            PlainText {
              width: parent.width
              visible: root.dialogBody !== ""
              text: root.dialogBody
              color: root.dim
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
            }

            Rectangle {
              width: parent.width
              visible: root.dialogKind === "mkdir" || root.dialogKind === "rename" || root.dialogKind === "user"
              height: Math.max(Style.space(32), Style.font.body + Style.space(18))
              radius: Style.cornerRadius
              color: Util.alpha(root.fg, 0.06)
              border.width: Math.max(1, Style.space(1))
              border.color: root.accent

              TextInput {
                id: dialogInput
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                verticalAlignment: TextInput.AlignVCenter
                color: root.fg
                selectionColor: Util.alpha(root.accent, 0.4)
                selectedTextColor: root.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                clip: true
                Keys.onReturnPressed: root.acceptDialog()
                Keys.onEnterPressed: root.acceptDialog()
                Keys.onEscapePressed: root.closeDialog()
              }
            }

            Grid {
              visible: root.dialogKind === "help"
              columns: 2
              columnSpacing: Style.space(18)
              rowSpacing: Style.space(4)
              Repeater {
                model: [
                  ["Tab", "help.switchPane"], ["j / k  ↑ ↓", "help.move"],
                  ["Enter  l  →", "help.open"], ["Backspace  h  ←", "help.up"],
                  ["Space / Ctrl+A", "help.mark"], ["c  F5", "help.copy"],
                  ["n  F7", "help.mkdir"], ["F2  R", "help.rename"],
                  ["Del  F8  D", "help.delete"], ["o", "help.openApp"],
                  ["m", "help.machine"], ["/", "help.filter"],
                  ["Ctrl+L", "help.path"], [".", "help.hidden"],
                  ["s", "help.sort"], ["~", "help.home"],
                  ["=", "help.mirror"], ["r  Ctrl+R", "help.refresh"],
                  ["Esc", "help.close"]
                ]
                delegate: Row {
                  required property var modelData
                  spacing: Style.space(10)
                  PlainText { width: Style.space(130); text: modelData[0]; color: root.accent; font.pixelSize: Style.font.bodySmall }
                  PlainText { width: Style.space(150); text: strings.t(modelData[1]); color: root.fg; font.pixelSize: Style.font.bodySmall }
                }
              }
            }

            Row {
              anchors.right: parent.right
              spacing: Style.space(8)
              ActionButton {
                visible: root.dialogKind !== "help"
                label: strings.t("dialog.cancel")
                fg: root.fg; accent: root.accent
                onClicked: root.closeDialog()
              }
              ActionButton {
                primary: true
                label: root.dialogKind === "delete" ? strings.t("dialog.delete") : root.dialogKind === "replace" ? strings.t("dialog.replace")
                       : (root.dialogKind === "help" ? strings.t("dialog.close") : strings.t("dialog.ok"))
                fg: root.fg; accent: (root.dialogKind === "delete" || root.dialogKind === "replace") ? root.urgent : root.accent
                onClicked: root.acceptDialog()
              }
            }
          }
        }
      }
    }
  }
}
