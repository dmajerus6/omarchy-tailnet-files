import QtQuick
import Quickshell
import Quickshell.Io

// Runs the `bin/tailfiles` helper. Every call is its own short-lived Process
// so the two panes can list folders at the same time; each one answers with
// a single JSON object on its last line of stdout.
Item {
  id: root

  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/tailfiles")).replace(/^file:\/\//, ""))

  function parseLast(text, stderrText) {
    var lines = String(text || "").trim().split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var line = lines[i].trim()
      if (line === "") continue
      try { return JSON.parse(line) } catch (e) { break }
    }
    var err = String(stderrText || "").trim().split("\n").pop()
    return { ok: false, kind: "other", error: err || "The tailfiles helper did not answer" }
  }

  Component {
    id: jobComponent

    Process {
      id: proc
      property var callback: null
      property bool exitSeen: false
      property bool outSeen: false
      property bool finished: false

      stdout: StdioCollector {
        id: outCollector
        waitForEnd: true
        onStreamFinished: { proc.outSeen = true; proc.finish() }
      }
      stderr: StdioCollector { id: errCollector; waitForEnd: true }

      // A process that prints nothing may never report its stream as finished.
      property Timer grace: Timer {
        interval: 300
        onTriggered: { proc.outSeen = true; proc.finish() }
      }

      onExited: function(exitCode) {
        exitSeen = true
        if (!outSeen) grace.start()
        finish()
      }

      function finish() {
        if (finished || !exitSeen || !outSeen) return
        finished = true
        var cb = callback
        callback = null
        var result = root.parseLast(outCollector.text, errCollector.text)
        if (cb) {
          try { cb(result) } catch (e) { console.warn("tailfiles callback failed:", e) }
        }
        Qt.callLater(function() { proc.destroy() })
      }
    }
  }

  function run(args, callback) {
    var proc = jobComponent.createObject(root, { command: [root.helper].concat(args), callback: callback || null })
    if (!proc) {
      if (callback) callback({ ok: false, kind: "other", error: "Could not start helper" })
      return null
    }
    proc.running = true
    return proc
  }

  function detached(args) {
    Quickshell.execDetached([root.helper].concat(args))
  }
}
