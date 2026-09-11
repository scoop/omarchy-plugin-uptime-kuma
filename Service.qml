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
    // Whether the person has said, about this address, that an unencrypted
    // connection is acceptable. Only ever consulted for an http:// address that
    // is not loopback; the helpers refuse one without it, so this is a decision
    // being carried rather than a check being made here.
    property bool allowPlaintext: false

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
    readonly property int _payloadMaxChars: 8000000
    readonly property int _demoMaxBytes: 524288

    // While the canned snapshot is on screen, the reconnect machinery has to
    // stand down — otherwise stopping the poll looks like a lost connection and
    // the retry drags the real instance back in.
    property bool _demo: false

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

    BoundedProcess {
        id: themeProc
        maxBytes: root._themeMaxBytes
        command: [root._pluginDir + "bin/read-bounded.sh", themeWatcher.path, String(root._themeMaxBytes)]
        onFinishedWith: function (text, tooLarge) {
            // An oversized theme file is a refusal, not something to parse.
            if (tooLarge || text.length === 0) {
                root.okColor = Color.muted;
                return;
            }
            var match = /^[ \t]*green[ \t]*=[ \t]*["']?(#[0-9A-Fa-f]{6})/m.exec(text);
            root.okColor = match ? match[1] : Color.muted;
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
        // running = false sends TERM to the helper. Its curl child is not
        // reached by that, so the escalation below is what actually ends the
        // session if the helper does not go quietly.
        if (pollProc.running) {
            pollProc.signal(15);
            pollKillTimer.restart();
        }
        pollProc.running = false;
        retryTimer.stop();
        _pending = "";
        _stderrPending = "";
    }

    Timer {
        id: pollKillTimer
        interval: 2000
        repeat: false
        onTriggered: if (pollProc.running) pollProc.signal(9)
    }

    // A shell that is going away should not leave a poll behind it.
    Component.onDestruction: {
        pollProc.running = false;
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

    BoundedProcess {
        id: tokenProc
        maxBytes: root._tokenMaxChars
        command: [
            "/usr/bin/secret-tool",
            "lookup",
            "service",
            "scoop.uptime-kuma",
            "account",
            root.username,
        ]
        onFinishedWith: function (text, tooLarge) {
            var value = tooLarge ? "" : text.trim();
            if (value === "") {
                root.connection = "setup";
                return;
            }
            root._token = value;
            root.start();
        }
    }

    BoundedProcess {
        id: forgetProc
        maxBytes: 4096
        command: ["/usr/bin/secret-tool", "clear", "service", "scoop.uptime-kuma", "account", root.username]
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
            allowPlaintext: root.allowPlaintext,
        });
        loginProc.running = true;
    }

    BoundedProcess {
        id: loginProc
        maxBytes: root._replyMaxChars
        property string payload: ""
        command: [root._pluginDir + "bin/login.sh"]
        stdinEnabled: true
        onStarted: {
            write(payload + "\n");
            payload = "";
            stdinEnabled = false;
        }
        onFinishedWith: function (text, tooLarge) {
            var result = {};
            try {
                if (tooLarge) {
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

    BoundedProcess {
        id: storeProc
        maxBytes: 4096
        property string token: ""
        command: [
            "/usr/bin/secret-tool",
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
        clearEnvironment: true
        environment: ({
                PATH: "/usr/bin:/bin",
                DBUS_SESSION_BUS_ADDRESS: Quickshell.env("DBUS_SESSION_BUS_ADDRESS"),
                XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR"),
                HOME: Quickshell.env("HOME"),
                LC_ALL: "C",
            })
        stdinEnabled: true
        onStarted: {
            write(
                JSON.stringify({
                    url: root.baseUrl,
                    token: root._token,
                    allowPlaintext: root.allowPlaintext,
                }) + "\n",
            );
            stdinEnabled = false;
        }
        // Raw chunks, with the lines assembled here.
        //
        // A line-delimited parser cannot be a ceiling: it has to buffer until
        // the delimiter arrives before it can hand anything over, so a peer
        // that never sends a newline is an unbounded allocation inside the
        // shell. curl's --max-filesize does not cover this either — it acts on
        // a declared Content-Length, and these responses are chunked. So the
        // budget is counted here, against the bytes as they arrive, and a
        // payload that outgrows it ends the session rather than being trimmed
        // into something that would parse.
        stdout: SplitParser {
            splitMarker: ""
            onRead: function (chunk) {
                root._ingest(chunk);
            }
        }
        stderr: SplitParser {
            splitMarker: ""
            onRead: function (chunk) {
                root._ingestError(chunk);
            }
        }
        onExited: function (exitCode) {
            if (root._demo) {
                return;
            }
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

    /**
     * Slide a canned history so it ends now.
     *
     * The snapshot is committed to the repository, so its timestamps are fixed
     * while the clock is not. Left alone, a demo recorded last week claims
     * every service came up last week — or, if the file was written slightly
     * ahead of the reader, that everything changed state zero seconds ago.
     */
    function _rebase(beats) {
        var parse = function (text) {
            return Date.parse(String(text).replace(" ", "T") + "Z");
        };
        var newest = 0;
        var key;
        for (key in beats) {
            var list = beats[key];
            if (list.length) {
                newest = Math.max(newest, parse(list[list.length - 1].time));
            }
        }
        if (!newest) {
            return beats;
        }
        var delta = Date.now() - newest;
        for (key in beats) {
            var history = beats[key];
            for (var i = 0; i < history.length; i++) {
                var shifted = new Date(parse(history[i].time) + delta);
                history[i].time = shifted.toISOString().slice(0, 19).replace("T", " ");
            }
        }
        return beats;
    }

    // A canned snapshot, for the preview screenshot and for anyone who wants to
    // work on the panel without an Uptime Kuma to point it at. It replaces the
    // in-memory state only: nothing is written, and a restart returns to the
    // real instance.
    BoundedProcess {
        id: demoProc
        maxBytes: root._demoMaxBytes
        command: [
            root._pluginDir + "bin/read-bounded.sh",
            root._pluginDir + "demo/snapshot.json",
            String(root._demoMaxBytes),
        ]
        onFinishedWith: function (text, tooLarge) {
            if (tooLarge || text.length === 0) {
                root.lastError = "Could not read the demo snapshot";
                return;
            }
            var snapshot;
            try {
                snapshot = JSON.parse(text);
            } catch (e) {
                root.lastError = "The demo snapshot is not readable JSON";
                return;
            }
            root._monitors = snapshot.monitorList || {};
            root._beats = root._rebase(snapshot.beats || {});
            root._stats = snapshot.stats || {};
            root.connection = "connected";
            root.lastUpdate = Date.now();
            root.view = Model.buildView(root._monitors, root._beats, root._stats, Date.now());
        }
    }

    Timer {
        id: retryTimer
        repeat: false
        onTriggered: if (!root._demo && root.configured && root._token !== "") root.start()
    }

    // ---------------------------------------------------------------- decoding

    property string _pending: ""
    property string _stderrPending: ""

    /**
     * Assemble lines out of raw chunks, refusing to hold more than the budget.
     *
     * poll.sh writes one payload per line, but nothing about a pipe guarantees
     * a line ever ends. The budget is checked against the buffer before the
     * newline is found, which is the whole point: by the time a delimiter-based
     * parser could complain, the allocation it would complain about exists.
     */
    function _ingest(chunk) {
        if (_pending.length + chunk.length > _payloadMaxChars) {
            root.lastError = "Ignored an oversized response from Uptime Kuma";
            _pending = "";
            stop();
            retryTimer.interval = root._backoffMs;
            retryTimer.start();
            return;
        }
        _pending += chunk;
        var cut = _pending.indexOf("\n");
        while (cut !== -1) {
            var line = _pending.slice(0, cut);
            _pending = _pending.slice(cut + 1);
            if (line !== "") {
                _consume(line);
            }
            cut = _pending.indexOf("\n");
        }
    }

    /**
     * The same, for diagnostics, which are short and must stay short.
     *
     * The trim happens to the chunk before it is joined, not to the joined
     * result: building the whole string and then slicing it is the allocation
     * this is supposed to prevent, just with a tidier line of code.
     */
    function _ingestError(chunk) {
        var bounded = chunk.length > _replyMaxChars ? chunk.slice(-_replyMaxChars) : chunk;
        var room = _replyMaxChars - bounded.length;
        _stderrPending = (room > 0 ? _stderrPending.slice(-room) : "") + bounded;
        var parts = _stderrPending.split("\n");
        for (var i = 0; i < parts.length - 1; i++) {
            if (parts[i].trim() !== "") {
                root.lastError = parts[i].trim();
            }
        }
        _stderrPending = parts[parts.length - 1];
    }

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

    // Reachable by anyone who can run omarchy-shell, with no user present, so
    // what is here has to be safe to be called by surprise: nothing that
    // deletes, persists, or hands back the instance's contents. Signing out
    // used to live here and does not any more — it destroyed the keyring entry
    // on request. The README documents `secret-tool clear` instead.
    IpcHandler {
        target: "scoop.uptime-kuma.service"

        function refresh(): void {
            root.stop();
            root.start();
        }

        /** The connection state, and deliberately nothing else. */
        function status(): string {
            return root.connection;
        }

        function demo(): void {
            root._demo = true;
            root.stop();
            demoProc.running = true;
        }
    }
}
