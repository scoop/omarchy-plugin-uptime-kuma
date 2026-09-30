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
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, cpSync, chmodSync } from "node:fs";
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
/** How many sessions were opened, which is how many polls were started. */
let handshakes;

/** Just enough Engine.IO to hold a session open: a handshake, then a poll that never answers. */
function startServer() {
    handshakes = 0;
    return Bun.serve({
        port: 0,
        async fetch(request) {
            const url = new URL(request.url);
            // Only the helper's own requests are counted: a listening port on
            // a desktop gets probed by whatever else is running there.
            if (url.pathname !== "/socket.io/") {
                return new Response("", { status: 404 });
            }
            if (request.method === "POST") {
                await request.text();
                return new Response("ok");
            }
            if (!url.searchParams.get("sid")) {
                handshakes++;
                return new Response(
                    '0{"sid":"teststubsid","upgrades":[],"pingInterval":25000,"pingTimeout":20000}',
                );
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
 *
 * The plugin sits in a subdirectory because that is where a plugin sits in the
 * real shell, and because Qt.resolvedUrl(".") at the root of a config comes
 * back without its trailing slash, which is what the helper paths are built on.
 */
async function runService(script, windowMs = WINDOW_MS) {
    const root = mkdtempSync(join(work, "cfg-"));
    const plugin = join(root, "plugin");
    const lookups = join(root, "lookups.log");
    mkdirSync(plugin);
    mkdirSync(join(root, "Commons"));

    // Slow enough that a second request for the token arrives while the first
    // is still being answered, as it does with a real keyring.
    const shim = join(root, "secret-tool");
    writeFileSync(
        shim,
        [
            "#!/usr/bin/bash",
            `echo lookup >> ${lookups}`,
            "/usr/bin/sleep 0.3",
            "echo TESTTOKEN",
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
    return { states, lookups: readFileSync(lookups, "utf8").trim().split("\n").length };
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
