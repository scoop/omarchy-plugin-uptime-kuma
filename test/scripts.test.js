// What the helper scripts must never do, exercised against a stub Uptime Kuma.
//
// These are the properties that cannot be checked by reading src/: that a
// credential never becomes a command-line argument, that an unencrypted address
// is refused before anything is sent to it, and that nothing the server says
// can grow without bound inside the shell. All of them are properties of the
// running script, so they are tested by running it.
//
// `jq` and `secret-tool` are replaced by shims that record their own argv. The
// scripts name every binary by absolute path — a shadow `curl` earlier in PATH
// would otherwise be handed the password — so a shim on PATH no longer
// intercepts anything. The harness therefore runs a *copy* of the script with
// `/usr/bin/jq` rewritten to the shim's path. "the scripts name every binary
// absolutely" below is what keeps that rewrite honest: if a script ever went
// back to a bare `jq`, that test fails rather than these quietly recording
// nothing.

import { test, expect, beforeAll, afterAll } from "bun:test";
import {
    mkdtempSync,
    mkdirSync,
    writeFileSync,
    readFileSync,
    symlinkSync,
    chmodSync,
    existsSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BIN = join(import.meta.dir, "..", "bin");
const SCRIPTS = ["login.sh", "poll.sh", "authenticate.sh", "read-bounded.sh"];

/** Rewritten in the copies so the shims see the calls; must stay absolute in bin/. */
const SHIMMABLE = ["jq", "secret-tool"];

const PASSWORD = "correct-horse-battery-staple";
const TOTP = "654321";
const TOKEN = "eyJhbGciOiJIUzI1NiJ9.TESTTOKENVALUE.signature";

/** The scripts' own ceiling on one HTTP response body. */
// Read the ceiling out of the script rather than restating it here: a test that
// carries its own copy of a limit stops testing the limit the moment someone
// changes it, and quietly starts passing for the wrong reason.
const MAX_BODY = Number(/^MAX_BODY=(\d+)$/m.exec(readFileSync(join(BIN, "poll.sh"), "utf8"))[1]);

let work;
let server;
let origin;
/** Every request body the stub server was sent, in order. */
let received;

/** A stub of just enough Engine.IO for the helpers' sign-in exchange. */
function startServer(ack, { status = 200, handshake = null } = {}) {
    received = [];
    return Bun.serve({
        port: 0,
        async fetch(request) {
            const url = new URL(request.url);
            if (request.method === "POST") {
                received.push(await request.text());
                return new Response("ok", { status });
            }
            if (!url.searchParams.get("sid")) {
                return new Response(
                    handshake ??
                        '0{"sid":"teststubsid","upgrades":[],"pingInterval":25000,"pingTimeout":20000}',
                    { status },
                );
            }
            return new Response(ack, { status });
        },
    });
}

/**
 * A copy of bin/ whose tools record what they were called with.
 *
 * `jq` records and then execs the real one; anything in `stubbed` records and
 * returns success without doing whatever it would really have done — the
 * keyring is not a thing a test should be writing to. The scripts are copied
 * rather than run in place because they call their binaries by absolute path.
 * The shim directory also goes on PATH, so a script that resolved a tool
 * through PATH would still be caught by the argv assertions.
 */
function shimmedBin(log, stubbed = []) {
    const root = mkdtempSync(join(work, "bin-"));
    const shims = join(root, "shims");
    mkdirSync(shims);

    const write = (name, last) => {
        const shim = join(shims, name);
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

    for (const name of SCRIPTS) {
        let src = readFileSync(join(BIN, name), "utf8");
        for (const tool of SHIMMABLE) {
            src = src.split(`/usr/bin/${tool}`).join(join(shims, tool));
        }
        const copy = join(root, name);
        writeFileSync(copy, src);
        chmodSync(copy, 0o755);
    }
    return { bin: root, shims, log };
}

async function run(
    script,
    stdin,
    { bin = BIN, shims = null, log = null, killAfterMs = 0, withoutRuntimeDir = false } = {},
) {
    const env = { ...process.env };
    if (shims) {
        env.PATH = `${shims}:${process.env.PATH}`;
        env.ARGV_LOG = log;
    }
    if (withoutRuntimeDir) {
        delete env.XDG_RUNTIME_DIR;
    }
    const proc = Bun.spawn([join(bin, script)], {
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

// ------------------------------------------------------------ the PATH itself

/** A script with its comment lines removed, so prose about curl is not read as a call to it. */
function codeOf(name) {
    return readFileSync(join(BIN, name), "utf8")
        .split("\n")
        .filter((line) => !/^\s*#/.test(line))
        .join("\n");
}

test("the scripts name every binary absolutely, so PATH cannot swap one", () => {
    // A shadow `curl` earlier in PATH receives the password; a shadow `jq`
    // receives it on stdin. `#!/usr/bin/env bash` picks the interpreter the
    // same way.
    const tools = ["curl", "jq", "tr", "head", "mktemp", "secret-tool", "dd", "rm", "cat", "sed"];
    for (const name of SCRIPTS) {
        const src = readFileSync(join(BIN, name), "utf8");
        expect(`${name}: ${src.split("\n")[0]}`).toBe(`${name}: #!/usr/bin/bash`);

        const code = codeOf(name);
        for (const tool of tools) {
            // Start of a command: line start, or after a pipe, semicolon,
            // ampersand, opening paren or `$(`.
            const bare = new RegExp(`(^|[|(;&])[ \\t]*${tool}\\b`, "m");
            expect(`${name} calls bare ${tool}: ${bare.test(code)}`).toBe(
                `${name} calls bare ${tool}: false`,
            );
        }
    }
});

test("every curl invocation ignores the environment's proxy settings", () => {
    // A same-user `https_proxy` would otherwise route the password and the
    // session token through a proxy of someone else's choosing.
    for (const name of SCRIPTS) {
        const code = codeOf(name);
        const calls = (code.match(/\/usr\/bin\/curl/g) ?? []).length;
        const noproxy = (code.match(/--noproxy/g) ?? []).length;
        expect(`${name}: ${calls} curl, ${noproxy} noproxy`).toBe(
            `${name}: ${calls} curl, ${calls} noproxy`,
        );
    }
});

// ------------------------------------------------------------------- secrets

test("login.sh never puts the password or the two-factor code in an argument", async () => {
    server = startServer('43[{"ok":true,"token":"' + TOKEN + '"}]');
    origin = `http://127.0.0.1:${server.port}`;
    const log = join(work, "login-argv.log");
    const { bin, shims } = shimmedBin(log);

    const { stdout } = await run(
        "login.sh",
        JSON.stringify({ origin, url: origin, username: "you", password: PASSWORD, totp: TOTP }),
        { bin, shims, log },
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
    const { bin, shims } = shimmedBin(log);

    const { stdout } = await run(
        "login.sh",
        JSON.stringify({ url: origin, username: "you", password: PASSWORD, totp: "" }),
        { bin, shims, log },
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
    const { bin, shims } = shimmedBin(log);

    await run("poll.sh", JSON.stringify({ url: origin, token: TOKEN }), {
        bin,
        shims,
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

// ------------------------------------------------------------- bounded bodies

test("login.sh refuses a response larger than the cap instead of forwarding it", async () => {
    // `--max-filesize` is advisory: it acts on a declared Content-Length and
    // does nothing at all for the chunked body this returns. The only cap that
    // is real is the one the reader applies, so it is the one under test.
    const huge = "0" + "x".repeat(MAX_BODY);
    server = startServer("", { handshake: huge });
    const { stdout } = await run(
        "login.sh",
        JSON.stringify({
            url: `http://127.0.0.1:${server.port}`,
            username: "you",
            password: PASSWORD,
            totp: "",
        }),
    );
    const result = JSON.parse(stdout);
    expect(result.ok).toBe(false);
    expect(result.error).toMatch(/more data/i);
    // Refused, not truncated into something that parses.
    expect(stdout.length).toBeLessThan(4096);
    server.stop(true);
});

test("poll.sh refuses a response larger than the cap", async () => {
    const huge = "0" + "x".repeat(MAX_BODY);
    server = startServer("", { handshake: huge });
    const { stdout, stderr, code } = await run(
        "poll.sh",
        JSON.stringify({ url: `http://127.0.0.1:${server.port}`, token: TOKEN }),
    );
    expect(code).not.toBe(0);
    expect(stderr).toMatch(/more data/i);
    expect(stdout.length).toBeLessThan(4096);
    server.stop(true);
});

test("login.sh refuses a session token too large to be one", async () => {
    // The cap applies to what this script prints, too: a token that never ends
    // must not be handed on to the panel just because it arrived inside an
    // otherwise acceptable body.
    server = startServer('43[{"ok":true,"token":"' + "t".repeat(70000) + '"}]');
    const { stdout } = await run(
        "login.sh",
        JSON.stringify({
            url: `http://127.0.0.1:${server.port}`,
            username: "you",
            password: PASSWORD,
            totp: "",
        }),
    );
    const result = JSON.parse(stdout);
    expect(result.ok).toBe(false);
    expect(result.error).toMatch(/too large/i);
    expect(stdout).not.toContain("ttttt");
    server.stop(true);
});

// --------------------------------------------------------------- HTTP failures

test("login.sh treats a 5xx as a failure rather than an answer", async () => {
    // The error page is shaped exactly like a handshake, which is the point:
    // without --fail curl hands the body over and the script parses it.
    server = startServer('43[{"ok":true,"token":"' + TOKEN + '"}]', { status: 500 });
    const { stdout } = await run(
        "login.sh",
        JSON.stringify({
            url: `http://127.0.0.1:${server.port}`,
            username: "you",
            password: PASSWORD,
            totp: "",
        }),
    );
    const result = JSON.parse(stdout);
    expect(result.ok).toBe(false);
    expect(stdout).not.toContain(TOKEN);
    server.stop(true);
});

test("poll.sh treats a 5xx as a failure rather than an answer", async () => {
    server = startServer('43[{"ok":true}]', { status: 503 });
    const { stdout, code } = await run(
        "poll.sh",
        JSON.stringify({ url: `http://127.0.0.1:${server.port}`, token: TOKEN }),
    );
    expect(code).not.toBe(0);
    expect(stdout).toBe("");
    server.stop(true);
});

// ------------------------------------------------------- the session cookie jar

test("login.sh fails closed when there is no private directory for the cookie jar", async () => {
    // The jar holds an authenticated Engine.IO session id. Falling back to
    // shared /tmp would put it where any account can read it, so there is no
    // fallback.
    server = startServer('43[{"ok":true,"token":"' + TOKEN + '"}]');
    const { stdout } = await run(
        "login.sh",
        JSON.stringify({
            url: `http://127.0.0.1:${server.port}`,
            username: "you",
            password: PASSWORD,
            totp: "",
        }),
        { withoutRuntimeDir: true },
    );
    const result = JSON.parse(stdout);
    expect(result.ok).toBe(false);
    expect(result.error).toMatch(/XDG_RUNTIME_DIR/);
    expect(received.length).toBe(0);
    server.stop(true);
});

test("poll.sh fails closed when there is no private directory for the cookie jar", async () => {
    server = startServer('43[{"ok":true}]');
    const { stderr, code } = await run(
        "poll.sh",
        JSON.stringify({ url: `http://127.0.0.1:${server.port}`, token: TOKEN }),
        { withoutRuntimeDir: true },
    );
    expect(code).not.toBe(0);
    expect(stderr).toMatch(/XDG_RUNTIME_DIR/);
    expect(received.length).toBe(0);
    server.stop(true);
});

// ---------------------------------------------------------- the terminal path

/** A shell.json holding this plugin's bar entry, as the host would write it. */
function fakeHome(entry, { extra = null } = {}) {
    const home = join(work, "home-" + Math.random().toString(36).slice(2));
    mkdirSync(join(home, ".config", "omarchy"), { recursive: true });
    const config = {
        bar: { layout: { right: [{ id: "scoop.uptime-kuma", ...entry }] } },
        ...(extra ?? {}),
    };
    writeFileSync(join(home, ".config", "omarchy", "shell.json"), JSON.stringify(config));
    return home;
}

/** Runs authenticate.sh against a fake home, answering its two prompts. */
async function authenticate(home, { bin = BIN, shims = null, log = null } = {}) {
    const env = { ...process.env, HOME: home };
    if (shims) {
        env.PATH = `${shims}:${process.env.PATH}`;
        env.ARGV_LOG = log;
    }
    const proc = Bun.spawn([join(bin, "authenticate.sh")], {
        stdin: new TextEncoder().encode(`${PASSWORD}\n${TOTP}\n`),
        stdout: "pipe",
        stderr: "pipe",
        env,
    });
    const [stdout, stderr] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
    ]);
    await proc.exited;
    return { stdout, stderr, code: proc.exitCode };
}

test("authenticate.sh never puts the password, the code or the token in an argument", async () => {
    server = startServer('43[{"ok":true,"token":"' + TOKEN + '"}]');
    const log = join(work, "auth-argv.log");
    const { bin, shims } = shimmedBin(log, ["secret-tool"]);
    const home = fakeHome({ baseUrl: `http://127.0.0.1:${server.port}`, username: "you" });

    const { stdout } = await authenticate(home, { bin, shims, log });

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
    const { bin, shims } = shimmedBin(log, ["secret-tool"]);
    const home = fakeHome({ baseUrl: "http://kuma.example.lan", username: "you" });

    const { stdout, stderr, code } = await authenticate(home, { bin, shims, log });

    expect(code).not.toBe(0);
    expect(stderr).toMatch(/encrypted/i);
    expect(argvLog(log)).not.toContain("store");
    expect(stdout).not.toContain("Authenticated");
});

test("authenticate.sh refuses a shell.json that is a symlink", async () => {
    // The config is read through one O_NOFOLLOW open rather than by pathname:
    // another process running as this user can replace the name between the
    // check and the read, and a symlink is how it points the read somewhere
    // else entirely.
    const log = join(work, "auth-symlink.log");
    const { bin, shims } = shimmedBin(log, ["secret-tool"]);
    const home = fakeHome({ baseUrl: "https://kuma.example.com", username: "you" });
    const real = join(work, "elsewhere-" + Math.random().toString(36).slice(2) + ".json");
    writeFileSync(
        real,
        JSON.stringify({
            bar: {
                layout: {
                    right: [{ id: "scoop.uptime-kuma", baseUrl: "https://x", username: "y" }],
                },
            },
        }),
    );
    const config = join(home, ".config", "omarchy", "shell.json");
    Bun.spawnSync(["rm", "-f", config]);
    symlinkSync(real, config);

    const { stdout, stderr, code } = await authenticate(home, { bin, shims, log });

    expect(code).not.toBe(0);
    expect(stderr).toMatch(/shell\.json/i);
    expect(stdout).not.toContain("Authenticated");
});

test("authenticate.sh refuses a shell.json larger than the cap", async () => {
    const log = join(work, "auth-huge.log");
    const { bin, shims } = shimmedBin(log, ["secret-tool"]);
    const home = fakeHome(
        { baseUrl: "https://kuma.example.com", username: "you" },
        { extra: { padding: "p".repeat(300000) } },
    );

    const { stdout, stderr, code } = await authenticate(home, { bin, shims, log });

    expect(code).not.toBe(0);
    expect(stderr).toMatch(/shell\.json/i);
    expect(stdout).not.toContain("Authenticated");
});
