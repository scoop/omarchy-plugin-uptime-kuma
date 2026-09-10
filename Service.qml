import QtQuick
import Quickshell
import Quickshell.Io
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
    property string _token: ""
    property int _backoffMs: 1000

    readonly property string _pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

    signal loginFailed(string message)
    signal loginNeedsTotp

    // ---------------------------------------------------------------- lifecycle

    Component.onCompleted: readToken()

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
                var value = text.trim();
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
        return false;
    }

    // Events arrive in bursts — the login snapshot alone is nearly ninety of
    // them. Rebuilding once the burst settles keeps the Pane from rebuilding
    // the whole tree per packet.
    Timer {
        id: rebuildTimer
        interval: 120
        repeat: false
        onTriggered: root.view = Model.buildView(root._monitors, root._beats)
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
