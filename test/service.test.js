// What Service.qml does with its poll, exercised inside a real Quickshell.
//
// The reconnect logic lives in QML and leans on the order in which Quickshell's
// Process reports things: a process that is replaced while it is still running
// announces its exit before the replacement starts, and `running = true` on a
// process that is already running queues a second run. Neither can be seen by
// reading src/, and getting either wrong is a poll that kills itself once a
// second — so the service is run for real, against a stub Uptime Kuma, and
// counted from the outside.
//
// The plugin is copied into a throwaway Quickshell config with `secret-tool`
// rewritten to a shim, the same way scripts.test.js rewrites `jq`: the keyring
// is not a thing a test should be reading. Without a Quickshell to run, or a
// Wayland display for it to start on, there is nothing to exercise and the
// tests are skipped — which is what happens in CI.

import { test, expect, beforeAll, afterEach } from "bun:test";
import {
    mkdtempSync,
    mkdirSync,
    writeFileSync,
    readFileSync,
    cpSync,
    chmodSync,
    existsSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..");
const UNAVAILABLE = !Bun.which("quickshell") || !process.env.WAYLAND_DISPLAY;

/** How long the harness lets the service run before it quits, in milliseconds. */
// A poll wrongly read as a lost connection is retried after one second, so a
// loop has gone round several times by the time this is up.
const WINDOW_MS = 4000;

/** How long after a stop the service sends its last-resort KILL. */
// Read out of the service rather than restated, for the reason scripts.test.js
// gives for MAX_BODY: a copy of the number stops testing the number.
const KILL_AFTER_MS = Number(
    /id: pollKillTimer\s+interval: (\d+)/.exec(readFileSync(join(ROOT, "Service.qml"), "utf8"))[1],
);

let work;
let server;
let shell;
/** How many sessions were opened: one per poll, and one per sign-in. */
let handshakes;
/** How many of those sessions were sign-ins, which is how many times login.sh got its request. */
let logins;

/**
 * Just enough Engine.IO for a sign-in and a session: a handshake, the
 * acknowledgement the helper is waiting for, and then a poll that never answers.
 *
 * What a session is for is learnt from what is posted to it: `login` is
 * login.sh, and gets a token back; `loginByToken` is poll.sh, and gets an
 * empty monitor list, which is what makes the service call itself connected.
 */
function startServer() {
    handshakes = 0;
    logins = 0;
    const kinds = new Map();
    return Bun.serve({
        port: 0,
        async fetch(request) {
            const url = new URL(request.url);
            // Only the helper's own requests are counted: a listening port on
            // a desktop gets probed by whatever else is running there.
            if (url.pathname !== "/socket.io/") {
                return new Response("", { status: 404 });
            }
            const sid = url.searchParams.get("sid");
            if (request.method === "POST") {
                const body = await request.text();
                if (body.includes('"login"')) {
                    logins++;
                    kinds.set(sid, "login");
                } else if (body.includes('"loginByToken"')) {
                    kinds.set(sid, "poll");
                }
                return new Response("ok");
            }
            if (!sid) {
                handshakes++;
                return new Response(
                    `0{"sid":"teststubsid${handshakes}","upgrades":[],"pingInterval":25000,"pingTimeout":20000}`,
                );
            }
            const kind = kinds.get(sid);
            kinds.delete(sid);
            if (kind === "login") {
                return new Response('430[{"ok":true,"token":"TESTTOKEN"}]');
            }
            if (kind === "poll") {
                return new Response('430[{"ok":true}]\x1e42["monitorList",{}]');
            }
            return new Promise(() => {});
        },
    });
}

/**
 * Run the service in a Quickshell of its own until the harness quits.
 *
 * `script` is the body of the harness: QML declarations that drive `svc`, with
 * `real()` and `blank()` standing in for an Indicator pushing its settings.
 * `stored` is what the keyring holds for the account — "" for a first sign-in —
 * and `lookupSeconds` how long it takes to say so.
 *
 * The plugin sits in a subdirectory because that is where a plugin sits in the
 * real shell, and because Qt.resolvedUrl(".") at the root of a config comes
 * back without its trailing slash, which is what the helper paths are built on.
 */
async function runService(
    script,
    windowMs = WINDOW_MS,
    { stored = "TESTTOKEN", lookupSeconds = 0.3 } = {},
) {
    const root = mkdtempSync(join(work, "cfg-"));
    const plugin = join(root, "plugin");
    const calls = join(root, "secret-tool.log");
    mkdirSync(plugin);
    mkdirSync(join(root, "Commons"));

    // A lookup is slow enough that a second request for the token arrives
    // while the first is still being answered, as it does with a real keyring.
    // A store reads its secret to the end, as the real one does: a caller that
    // never closes stdin is a store that never finishes.
    const shim = join(root, "secret-tool");
    writeFileSync(
        shim,
        [
            "#!/usr/bin/bash",
            `echo "$1" >> ${calls}`,
            'case "$1" in',
            `    lookup) /usr/bin/sleep ${lookupSeconds}; [[ -n "${stored}" ]] && echo "${stored}" ;;`,
            "    store) /usr/bin/cat > /dev/null ;;",
            "esac",
            "exit 0",
            "",
        ].join("\n"),
    );
    chmodSync(shim, 0o755);

    cpSync(join(ROOT, "bin"), join(plugin, "bin"), { recursive: true });
    cpSync(join(ROOT, "src"), join(plugin, "src"), { recursive: true });
    cpSync(join(ROOT, "BoundedProcess.qml"), join(plugin, "BoundedProcess.qml"));
    writeFileSync(
        join(plugin, "Service.qml"),
        readFileSync(join(ROOT, "Service.qml"), "utf8").split("/usr/bin/secret-tool").join(shim),
    );

    // The two things Service.qml reads from the shell's own Commons.
    writeFileSync(
        join(root, "Commons", "Color.qml"),
        [
            "pragma Singleton",
            "import QtQuick",
            "import Quickshell",
            "Singleton {",
            '    readonly property color muted: "#888888"',
            '    readonly property string currentThemePath: "/nonexistent"',
            "}",
            "",
        ].join("\n"),
    );

    writeFileSync(
        join(root, "shell.qml"),
        [
            "import QtQuick",
            "import Quickshell",
            'import "plugin"',
            "ShellRoot {",
            "    id: harness",
            "    Service {",
            "        id: svc",
            '        onConnectionChanged: console.log("HARNESS connection " + connection)',
            '        onLoginFailed: function (message) { console.log("HARNESS loginFailed") }',
            "    }",
            "    function real() {",
            `        svc.baseUrl = "http://127.0.0.1:${server.port}";`,
            '        svc.username = "tester";',
            "    }",
            "    function blank() {",
            '        svc.baseUrl = "";',
            '        svc.username = "";',
            "    }",
            script,
            `    Timer { interval: ${windowMs}; running: true; onTriggered: Qt.quit() }`,
            "}",
            "",
        ].join("\n"),
    );

    shell = Bun.spawn(["quickshell", "-p", root], { stdout: "pipe", stderr: "pipe" });
    const [stdout, stderr] = await Promise.all([
        new Response(shell.stdout).text(),
        new Response(shell.stderr).text(),
    ]);
    await shell.exited;

    const states = [];
    for (const match of (stdout + stderr).matchAll(/HARNESS connection (\w+)/g)) {
        states.push(match[1]);
    }
    const called = existsSync(calls) ? readFileSync(calls, "utf8").trim().split("\n") : [];
    return {
        states,
        failures: [...(stdout + stderr).matchAll(/HARNESS loginFailed/g)].length,
        lookups: called.filter((c) => c === "lookup").length,
        stores: called.filter((c) => c === "store").length,
    };
}

beforeAll(() => {
    work = mkdtempSync(join(tmpdir(), "kuma-service-"));
});

afterEach(() => {
    if (shell) {
        shell.kill();
    }
    if (server) {
        server.stop(true);
    }
});

test.skipIf(UNAVAILABLE)(
    "settings that flap while the token is being looked up start one poll, not a loop",
    async () => {
        // What a second bar does at startup: its Indicator is handed the
        // service before it is handed its settings, so it pushes blanks and
        // then the real values, on top of the ones the first bar already set.
        server = startServer();
        const { states, lookups } = await runService(
            "    Timer { interval: 200; running: true; onTriggered: { harness.real(); harness.blank(); harness.real(); } }",
        );

        expect(lookups).toBe(1);
        expect(handshakes).toBe(1);
        expect(states).not.toContain("unreachable");
    },
    20000,
);

test.skipIf(UNAVAILABLE)(
    "starting over a running poll replaces it once, and is not read as a lost connection",
    async () => {
        // What `refresh` and a sign-in from the form both do.
        //
        // Watched until well past the last-resort KILL that stopping the old
        // poll armed: left armed, it lands on the replacement instead, and the
        // poll that was replaced once is replaced again a few seconds later.
        server = startServer();
        const { states, lookups } = await runService(
            [
                "    Timer { interval: 200; running: true; onTriggered: harness.real() }",
                "    Timer { interval: 1500; running: true; onTriggered: svc.start() }",
            ].join("\n"),
            1500 + KILL_AFTER_MS + 3000,
        );

        expect(lookups).toBe(1);
        expect(handshakes).toBe(2);
        expect(states).not.toContain("unreachable");
    },
    20000,
);

test.skipIf(UNAVAILABLE)(
    "a second sign-in is answered, and its token stored",
    async () => {
        // What a wrong password, a two-factor prompt or an expired session is
        // followed by: the form hands the service a password again. The helper
        // reads its request to the end, so a request that is written but never
        // closed is a sign-in that waits out its deadline.
        server = startServer();
        const { states, stores, failures } = await runService(
            [
                '    Timer { interval: 200; running: true; onTriggered: { harness.real(); svc.authenticate("pw", ""); } }',
                '    Timer { interval: 1500; running: true; onTriggered: svc.authenticate("pw", "") }',
            ].join("\n"),
            WINDOW_MS,
            { stored: "" },
        );

        expect(logins).toBe(2);
        expect(stores).toBe(2);
        expect(failures).toBe(0);
        expect(states.at(-1)).toBe("connected");
    },
    20000,
);

test.skipIf(UNAVAILABLE)(
    "an empty token lookup that finishes after a sign-in does not ask for credentials again",
    async () => {
        // What the form does on a first sign-in: setting the address and the
        // username starts a lookup of a token that is not there yet, and the
        // password goes to the helper straight after. The helper can win.
        server = startServer();
        const { states } = await runService(
            '    Timer { interval: 200; running: true; onTriggered: { harness.real(); svc.authenticate("pw", ""); } }',
            WINDOW_MS,
            { stored: "", lookupSeconds: 1 },
        );

        expect(logins).toBe(1);
        expect(states).not.toContain("setup");
        expect(states.at(-1)).toBe("connected");
    },
    20000,
);
