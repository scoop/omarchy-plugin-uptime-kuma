// What the helper scripts must never do, exercised against a stub Uptime Kuma.
//
// These are the two properties that cannot be checked by reading src/: that a
// credential never becomes a command-line argument, and that an unencrypted
// address is refused before anything is sent to it. Both are properties of the
// running script, so they are tested by running it.
//
// `jq` is replaced on PATH by a shim that records its own argv and then execs
// the real thing. Every test that relies on that also asserts the shim ran at
// all — otherwise a later change to absolute executable paths would turn these
// into tests that pass by never looking.

import { test, expect, beforeAll, afterAll } from "bun:test";
import { mkdtempSync, writeFileSync, readFileSync, chmodSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BIN = join(import.meta.dir, "..", "bin");

const PASSWORD = "correct-horse-battery-staple";
const TOTP = "654321";
const TOKEN = "eyJhbGciOiJIUzI1NiJ9.TESTTOKENVALUE.signature";

let work;
let server;
let origin;
/** Every request body the stub server was sent, in order. */
let received;

/** A stub of just enough Engine.IO for the helpers' sign-in exchange. */
function startServer(ack) {
    received = [];
    return Bun.serve({
        port: 0,
        async fetch(request) {
            const url = new URL(request.url);
            if (request.method === "POST") {
                received.push(await request.text());
                return new Response("ok");
            }
            if (!url.searchParams.get("sid")) {
                return new Response(
                    '0{"sid":"teststubsid","upgrades":[],"pingInterval":25000,"pingTimeout":20000}',
                );
            }
            return new Response(ack);
        },
    });
}

/**
 * A PATH whose tools record what they were called with.
 *
 * `jq` records and then execs the real one; anything in `stubbed` records and
 * returns success without doing whatever it would really have done — the
 * keyring is not a thing a test should be writing to.
 */
function shimmedPath(log, stubbed = []) {
    const dir = join(work, "shims-" + Math.random().toString(36).slice(2));
    Bun.spawnSync(["mkdir", "-p", dir]);
    const write = (name, last) => {
        const shim = join(dir, name);
        writeFileSync(
            shim,
            ["#!/usr/bin/env bash", 'printf "%s\\n" "$*" >> "$ARGV_LOG"', last, ""].join("\n"),
        );
        chmodSync(shim, 0o755);
    };
    write("jq", 'exec /usr/bin/jq "$@"');
    for (const name of stubbed) {
        write(name, "cat > /dev/null; exit 0");
    }
    return { dir, log };
}

async function run(script, stdin, { path = null, log = null, killAfterMs = 0 } = {}) {
    const env = { ...process.env };
    if (path) {
        env.PATH = `${path}:${process.env.PATH}`;
        env.ARGV_LOG = log;
    }
    const proc = Bun.spawn([join(BIN, script)], {
        stdin: new TextEncoder().encode(stdin + "\n"),
        stdout: "pipe",
        stderr: "pipe",
        env,
    });
    if (killAfterMs) {
        setTimeout(() => proc.kill(), killAfterMs);
    }
    const [stdout, stderr] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
    ]);
    await proc.exited;
    return { stdout, stderr, code: proc.exitCode };
}

/** Whatever the jq shim recorded, or "" when it was never called. */
function argvLog(log) {
    return existsSync(log) ? readFileSync(log, "utf8") : "";
}

beforeAll(() => {
    work = mkdtempSync(join(tmpdir(), "kuma-scripts-"));
});

afterAll(() => {
    if (server) {
        server.stop(true);
    }
});

// ------------------------------------------------------------------- secrets

test("login.sh never puts the password or the two-factor code in an argument", async () => {
    server = startServer('43[{"ok":true,"token":"' + TOKEN + '"}]');
    origin = `http://127.0.0.1:${server.port}`;
    const log = join(work, "login-argv.log");
    const { dir } = shimmedPath(log);

    const { stdout } = await run(
        "login.sh",
        JSON.stringify({ origin, url: origin, username: "you", password: PASSWORD, totp: TOTP }),
        { path: dir, log },
    );

    // The exchange has to have actually happened, or this proves nothing.
    expect(JSON.parse(stdout).token).toBe(TOKEN);
    expect(received.some((body) => body.includes(PASSWORD))).toBe(true);
    expect(argvLog(log).length).toBeGreaterThan(0);

    expect(argvLog(log)).not.toContain(PASSWORD);
    expect(argvLog(log)).not.toContain(TOTP);
    server.stop(true);
});

test("login.sh never puts the token it received in an argument either", async () => {
    server = startServer('43[{"ok":true,"token":"' + TOKEN + '"}]');
    origin = `http://127.0.0.1:${server.port}`;
    const log = join(work, "token-argv.log");
    const { dir } = shimmedPath(log);

    const { stdout } = await run(
        "login.sh",
        JSON.stringify({ url: origin, username: "you", password: PASSWORD, totp: "" }),
        { path: dir, log },
    );

    expect(JSON.parse(stdout).token).toBe(TOKEN);
    expect(argvLog(log).length).toBeGreaterThan(0);
    expect(argvLog(log)).not.toContain(TOKEN);
    server.stop(true);
});

test("poll.sh never puts the session token in an argument", async () => {
    server = startServer('43[{"ok":true}]');
    origin = `http://127.0.0.1:${server.port}`;
    const log = join(work, "poll-argv.log");
    const { dir } = shimmedPath(log);

    await run("poll.sh", JSON.stringify({ url: origin, token: TOKEN }), {
        path: dir,
        log,
        killAfterMs: 1500,
    });

    expect(received.some((body) => body.includes(TOKEN))).toBe(true);
    expect(argvLog(log).length).toBeGreaterThan(0);
    expect(argvLog(log)).not.toContain(TOKEN);
    server.stop(true);
});

// -------------------------------------------------------- unencrypted addresses

test("login.sh refuses an unencrypted address before it sends anything to it", async () => {
    const { stdout } = await run(
        "login.sh",
        JSON.stringify({
            url: "http://kuma.example.lan",
            username: "you",
            password: PASSWORD,
            totp: "",
        }),
    );
    const result = JSON.parse(stdout);
    expect(result.ok).toBe(false);
    expect(result.error).toMatch(/encrypted/i);
});

test("login.sh accepts an unencrypted address once it has been consented to", async () => {
    server = startServer('43[{"ok":true,"token":"' + TOKEN + '"}]');
    // A non-loopback host is what needs consent, so the check has to be reached
    // by a name that is not 127.0.0.1 while still resolving to the stub.
    const withConsent = await run(
        "login.sh",
        JSON.stringify({
            url: `http://localhost.localdomain:${server.port}`,
            username: "you",
            password: PASSWORD,
            totp: "",
            allowPlaintext: true,
        }),
    );
    expect(JSON.parse(withConsent.stdout).ok).toBe(true);

    const without = await run(
        "login.sh",
        JSON.stringify({
            url: `http://localhost.localdomain:${server.port}`,
            username: "you",
            password: PASSWORD,
            totp: "",
        }),
    );
    expect(JSON.parse(without.stdout).ok).toBe(false);
    server.stop(true);
});

test("a loopback address needs no consent, because nothing goes on the wire", async () => {
    server = startServer('43[{"ok":true,"token":"' + TOKEN + '"}]');
    const { stdout } = await run(
        "login.sh",
        JSON.stringify({
            url: `http://127.0.0.1:${server.port}`,
            username: "you",
            password: PASSWORD,
            totp: "",
        }),
    );
    expect(JSON.parse(stdout).ok).toBe(true);
    server.stop(true);
});

test("poll.sh refuses an unencrypted address before it sends the token to it", async () => {
    const { stderr, code } = await run(
        "poll.sh",
        JSON.stringify({ url: "http://kuma.example.lan", token: TOKEN }),
    );
    expect(code).not.toBe(0);
    expect(stderr).toMatch(/encrypted/i);
});

test("poll.sh accepts an unencrypted address once it has been consented to", async () => {
    server = startServer('43[{"ok":true}]');
    const { stderr } = await run(
        "poll.sh",
        JSON.stringify({
            url: `http://localhost.localdomain:${server.port}`,
            token: TOKEN,
            allowPlaintext: true,
        }),
        { killAfterMs: 1500 },
    );
    expect(stderr).not.toMatch(/encrypted/i);
    server.stop(true);
});

// ---------------------------------------------------------- the terminal path

/** A shell.json holding this plugin's bar entry, as the host would write it. */
function fakeHome(entry) {
    const home = join(work, "home-" + Math.random().toString(36).slice(2));
    Bun.spawnSync(["mkdir", "-p", join(home, ".config", "omarchy")]);
    writeFileSync(
        join(home, ".config", "omarchy", "shell.json"),
        JSON.stringify({ bar: { layout: { right: [{ id: "scoop.uptime-kuma", ...entry }] } } }),
    );
    return home;
}

test("authenticate.sh never puts the password, the code or the token in an argument", async () => {
    server = startServer('43[{"ok":true,"token":"' + TOKEN + '"}]');
    const log = join(work, "auth-argv.log");
    const { dir } = shimmedPath(log, ["secret-tool"]);
    const home = fakeHome({ baseUrl: `http://127.0.0.1:${server.port}`, username: "you" });

    const proc = Bun.spawn([join(BIN, "authenticate.sh")], {
        stdin: new TextEncoder().encode(`${PASSWORD}\n${TOTP}\n`),
        stdout: "pipe",
        stderr: "pipe",
        env: { ...process.env, HOME: home, PATH: `${dir}:${process.env.PATH}`, ARGV_LOG: log },
    });
    const stdout = await new Response(proc.stdout).text();
    await proc.exited;

    expect(stdout).toContain("Authenticated");
    expect(argvLog(log).length).toBeGreaterThan(0);
    // secret-tool has to have been called, or the token never went anywhere.
    expect(argvLog(log)).toContain("store");

    expect(argvLog(log)).not.toContain(PASSWORD);
    expect(argvLog(log)).not.toContain(TOTP);
    expect(argvLog(log)).not.toContain(TOKEN);
    server.stop(true);
});

test("authenticate.sh refuses an unencrypted address that has not been consented to", async () => {
    const log = join(work, "auth-plain.log");
    const { dir } = shimmedPath(log, ["secret-tool"]);
    const home = fakeHome({ baseUrl: "http://kuma.example.lan", username: "you" });

    const proc = Bun.spawn([join(BIN, "authenticate.sh")], {
        stdin: new TextEncoder().encode(`${PASSWORD}\n\n`),
        stdout: "pipe",
        stderr: "pipe",
        env: { ...process.env, HOME: home, PATH: `${dir}:${process.env.PATH}`, ARGV_LOG: log },
    });
    const [stdout, stderr] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
    ]);
    await proc.exited;

    expect(proc.exitCode).not.toBe(0);
    expect(stderr).toMatch(/encrypted/i);
    expect(argvLog(log)).not.toContain("store");
    expect(stdout).not.toContain("Authenticated");
});
