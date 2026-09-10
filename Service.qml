import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "src/engine.js" as Engine
import "src/model.js" as Model

// Owns the one connection to Uptime Kuma and the state derived from it.
//
// Mounted for the life of the shell, because the Indicator's job is to be
// right when nobody is looking at it. The Indicator and the Pane read from
// here; neither of them talks to Uptime Kuma itself.
Item {
    id: root

    property string omarchyPath: ""
    property var shell: null
    property var manifest: null

    // Pushed down by the Indicator: the shell injects settings into bar
    // widgets only, never into a service.
    property string baseUrl: ""
    property string username: ""

    // "setup" — nothing configured yet, or the stored token was refused
    // "connecting" — a session is being established
    // "connected" — the snapshot has arrived and events are streaming
    // "unreachable" — we had a session and lost it; what we show is now stale
    property string connection: "setup"
    property string lastError: ""
    property double lastUpdate: 0

    readonly property bool configured: baseUrl !== "" && username !== ""

    // The whole rendered state, rebuilt from the raw wire shapes.
    property var view: Model.buildView({}, {})

    property var _monitors: ({})
    property var _beats: ({})
    // What Uptime Kuma reports beside the heartbeats: 24-hour uptime, average
    // latency, and how long a certificate has left. Keyed by monitor id.
    property var _stats: ({})
    property string _token: ""
    property int _backoffMs: 1000

    // Everything crossing a process boundary gets a ceiling. A token is a few
    // hundred bytes, the login helper answers with one small JSON object, and
    // the largest thing Uptime Kuma has ever sent us in one batch is a quarter
    // of a megabyte. These are generous, and they are applied before the value
    // is parsed rather than after.
    readonly property int _themeMaxBytes: 65536
    readonly property int _tokenMaxChars: 8192
    readonly property int _replyMaxChars: 65536
    readonly property int _payloadMaxChars: 4000000

    readonly property string _pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

    // The shell's palette keeps only foreground/background/accent/muted/urgent;
    // the theme's own `green` is parsed and thrown away. A monitoring view needs
    // to say "checked, and fine" in a way that reads differently from "no
    // information", so we read that one value ourselves rather than inventing a
    // colour or settling for grey.
    property color okColor: Color.muted

    // Watcher only. FileView follows symlinks, blocks on a FIFO and reads a file
    // whole before any size check runs, and the theme directory is writable by
    // anything running as this user — so it is used to learn *that* the file
    // changed, never to read it. The read goes through a helper that carries
    // its refusals on the open itself.
    FileView {
        id: themeWatcher
        path: Color.currentThemePath + "/colors.toml"
        watchChanges: true
        preload: false
        blockAllReads: true
        printErrors: false
        onFileChanged: themeProc.running = true
    }

    Process {
        id: themeProc
        command: [root._pluginDir + "bin/read-bounded.sh", themeWatcher.path, String(root._themeMaxBytes)]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                // The helper returns max + 1 bytes when the file is larger than
                // it should be; that is a refusal, not something to parse.
                if (text.length === 0 || text.length > root._themeMaxBytes) {
                    root.okColor = Color.muted;
                    return;
                }
                var match = /^[ \t]*green[ \t]*=[ \t]*["']?(#[0-9A-Fa-f]{6})/m.exec(text);
                root.okColor = match ? match[1] : Color.muted;
            }
        }
    }

    signal loginFailed(string message)
    signal loginNeedsTotp

    // ---------------------------------------------------------------- lifecycle

    Component.onCompleted: {
        readToken();
        themeProc.running = true;
    }

    onConfiguredChanged: if (configured && _token === "") readToken()

    function start() {
        if (!configured || _token === "") {
            return;
        }
        stop();
        connection = "connecting";
        pollProc.running = true;
    }

    function stop() {
        pollProc.running = false;
        retryTimer.stop();
    }

    /** Drop the session and ask for credentials again. */
    function forget() {
        stop();
        _token = "";
        connection = "setup";
        forgetProc.running = true;
    }

    // ------------------------------------------------------------------- secrets

    function readToken() {
        if (!configured) {
            return;
        }
        tokenProc.running = true;
    }

    Process {
        id: tokenProc
        command: ["secret-tool", "lookup", "service", "scoop.uptime-kuma", "account", root.username]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var value = text.length > root._tokenMaxChars ? "" : text.trim();
                if (value === "") {
                    root.connection = "setup";
                    return;
                }
                root._token = value;
                root.start();
            }
        }
    }

    Process {
        id: forgetProc
        command: ["secret-tool", "clear", "service", "scoop.uptime-kuma", "account", root.username]
    }

    /**
     * Exchange a password for a session token. The password is written to the
     * helper on stdin and is never stored; only the token it returns is kept.
     */
    function authenticate(password, totp) {
        loginProc.payload = JSON.stringify({
            url: root.baseUrl,
            username: root.username,
            password: password,
            totp: totp || "",
        });
        loginProc.running = true;
    }

    Process {
        id: loginProc
        property string payload: ""
        command: [root._pluginDir + "bin/login.sh"]
        stdinEnabled: true
        onStarted: {
            write(payload + "\n");
            payload = "";
            stdinEnabled = false;
        }
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var result = {};
                try {
                    if (text.length > root._replyMaxChars) {
                        throw new Error("oversized reply");
                    }
                    result = JSON.parse(text);
                } catch (e) {
                    result = { ok: false, error: "Unreadable answer from the login helper" };
                }
                if (result.ok && result.token) {
                    root._token = result.token;
                    storeProc.token = result.token;
                    storeProc.running = true;
                    root.start();
                    return;
                }
                if (result.totpRequired) {
                    root.loginNeedsTotp();
                    return;
                }
                root.lastError = result.error || "Login failed";
                root.loginFailed(root.lastError);
            }
        }
    }

    Process {
        id: storeProc
        property string token: ""
        command: [
            "secret-tool",
            "store",
            "--label=Uptime Kuma session (scoop.uptime-kuma)",
            "service",
            "scoop.uptime-kuma",
            "account",
            root.username,
        ]
        stdinEnabled: true
        onStarted: {
            write(token + "\n");
            token = "";
            stdinEnabled = false;
        }
    }

    // ------------------------------------------------------------------ transport

    Process {
        id: pollProc
        command: [root._pluginDir + "bin/poll.sh"]
        stdinEnabled: true
        onStarted: {
            write(JSON.stringify({ url: root.baseUrl, token: root._token }) + "\n");
            stdinEnabled = false;
        }
        // One line per HTTP response body, still framed with 0x1e.
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function (line) {
                root._consume(line);
            }
        }
        stderr: SplitParser {
            splitMarker: "\n"
            onRead: function (line) {
                if (line.trim() !== "") {
                    root.lastError = line.trim();
                }
            }
        }
        onExited: function (exitCode) {
            // 2 means the stored token was refused — usually the Uptime Kuma
            // password changed, which invalidates it by design. Retrying that
            // forever would be pointless; the operator has to sign in again.
            if (exitCode === 2) {
                root.lastError = "Your session expired — sign in again";
                root.forget();
                return;
            }
            if (root.connection !== "setup") {
                root.connection = "unreachable";
                retryTimer.interval = root._backoffMs;
                retryTimer.start();
                root._backoffMs = Math.min(root._backoffMs * 2, 60000);
            }
        }
    }

    Timer {
        id: retryTimer
        repeat: false
        onTriggered: if (root.configured && root._token !== "") root.start()
    }

    // ---------------------------------------------------------------- decoding

    function _consume(line) {
        // curl caps each response, but the ceiling belongs on this side of the
        // pipe as well: the cap is on what we agree to hold, not on what the
        // other end agrees to send.
        if (line.length > _payloadMaxChars) {
            root.lastError = "Ignored an oversized response from Uptime Kuma";
            return;
        }
        var packets = Engine.decodePayload(line);
        var changed = false;

        for (var i = 0; i < packets.length; i++) {
            var packet = Engine.decodePacket(packets[i]);
            if (packet.kind !== "event") {
                continue;
            }
            if (_apply(packet.event, packet.args)) {
                changed = true;
            }
        }

        if (changed) {
            root._backoffMs = 1000;
            root.connection = "connected";
            root.lastUpdate = Date.now();
            rebuildTimer.restart();
        }
    }

    /** Fold one event into the raw state. Returns whether anything moved. */
    function _apply(event, args) {
        if (event === "monitorList") {
            _monitors = args[0] || {};
            return true;
        }
        if (event === "heartbeatList") {
            var list = _beats;
            list[String(args[0])] = args[1] || [];
            _beats = list;
            return true;
        }
        if (event === "heartbeat") {
            var beat = args[0];
            if (!beat || beat.monitorID === undefined) {
                return false;
            }
            var all = _beats;
            var key = String(beat.monitorID);
            var history = all[key] || [];
            history = history.concat([beat]);
            // Uptime Kuma itself keeps the last hundred; matching that bounds
            // memory over a session that may run for weeks.
            if (history.length > 100) {
                history = history.slice(history.length - 100);
            }
            all[key] = history;
            _beats = all;
            return true;
        }
        // Uptime Kuma volunteers these three alongside the heartbeats and they
        // were being dropped on the floor. They are the difference between
        // knowing a monitor is Up and knowing whether that is normal for it.
        if (event === "uptime") {
            return _fold(Model.applyUptime(_stats, args[0], args[1], args[2]));
        }
        if (event === "avgPing") {
            return _fold(Model.applyAvgPing(_stats, args[0], args[1]));
        }
        if (event === "certInfo") {
            return _fold(Model.applyCertInfo(_stats, args[0], args[1]));
        }
        return false;
    }

    /**
     * Take an amended stats map, if it was amended at all.
     *
     * The fold functions hand back the map they were given when the event said
     * nothing we render — an uptime figure for a period we do not show, a
     * certificate for a monitor that has none — and that is what "unchanged"
     * looks like here.
     */
    function _fold(next) {
        if (next === _stats) {
            return false;
        }
        _stats = next;
        return true;
    }

    // Events arrive in bursts — the login snapshot alone is nearly ninety of
    // them. Rebuilding once the burst settles keeps the Pane from rebuilding
    // the whole tree per packet.
    Timer {
        id: rebuildTimer
        interval: 120
        repeat: false
        onTriggered: {
            root.view = Model.buildView(root._monitors, root._beats, root._stats, Date.now());
        }
    }

    // -------------------------------------------------------------------- ipc

    IpcHandler {
        target: "uptime-kuma"

        function refresh(): void {
            root.stop();
            root.start();
        }

        function diagnose(): string {
            return (
                "configured=" + root.configured +
                " baseUrl=" + (root.baseUrl === "" ? "(empty)" : "set") +
                " username=" + (root.username === "" ? "(empty)" : root.username) +
                " tokenChars=" + root._token.length +
                " lastError=" + (root.lastError === "" ? "(none)" : root.lastError)
            );
        }

        function status(): string {
            return (
                root.connection +
                " up=" +
                root.view.counts.up +
                " down=" +
                root.view.counts.down +
                " paused=" +
                root.view.counts.paused
            );
        }

        function logout(): void {
            root.forget();
        }
    }
}
