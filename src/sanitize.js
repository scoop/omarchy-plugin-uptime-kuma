// What the shell is allowed to render, and what it is allowed to open.
//
// Everything here guards a sink the plugin does not own. `plain()` feeds host
// components that render with AutoText, where the plugin cannot pin
// `textFormat`; `originOf()` and `dashboardUrl()` feed `xdg-open`, where a
// string becomes a program's idea of what to launch.
//
// Both do the same thing with a value they cannot vouch for: refuse it. A
// repaired URL is a URL somebody else chose the shape of, and the point of
// validating at the consumer is that the consumer never guesses.
//
// Pure functions only — no QML, no I/O — so `bun test` and the shell load the
// same file.

/** How many characters a host-rendered label may carry. */
var MAX_LABEL = 120;

/** How long a configured base URL may be before it is simply not one. */
var MAX_URL = 2000;

/** DNS's own ceiling on a name, and the longest label inside one. */
var MAX_HOST = 253;
var MAX_HOST_LABEL = 63;

/** The widest monitor id Uptime Kuma could plausibly have issued. */
var MAX_ID_DIGITS = 9;

/**
 * Characters that must not reach a component rendering with AutoText.
 *
 * `<`, `>` and `&` because Qt sniffs a string for markup and, finding it,
 * renders rich text — and rich text fetches `<img src="...">` from the shell
 * process, to a host the string's author picked.
 *
 * C0, DEL and C1 because a control character in a label is never a label; it
 * is someone reaching past the widget into whatever reads the line after it.
 *
 * The bidi set (U+061C, U+200E/F, U+202A-E, U+2066-9) because those reorder
 * the glyphs around them: a monitor named "kuma" plus U+202E plus "gnp.exe"
 * is drawn on screen as "kumaexe.png". The text would be honest and the
 * screen would lie.
 */
// no-control-regex exists to catch a control character that got into a pattern
// by accident. Here they are the subject: this is the one regex in the tree
// that is supposed to name them, and the narrow exemption sits on the line
// rather than in eslint.config.js so it cannot quietly cover a second one.
// eslint-disable-next-line no-control-regex
var STRIP = /[\u0000-\u001F\u007F-\u009F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069<>&]/g;

/**
 * A string safe to hand to a rendering sink the plugin cannot pin.
 *
 * Strips before it caps, deliberately: capping first would let padding decide
 * how much real text survives, and would leave the stripped characters counted
 * against a budget they no longer occupy.
 *
 * @param {*} text anything; `null` and `undefined` are the empty string
 * @param {number} [limit] characters to keep, default `MAX_LABEL`
 * @returns {string} the same text with nothing in it the host can act on
 */
function plain(text, limit) {
    var cap = typeof limit === "number" && isFinite(limit) && limit >= 0 ? limit : MAX_LABEL;
    // Not `String(text || "")`: that turns the id 0 into "" rather than "0".
    var raw = text === null || text === undefined ? "" : String(text);
    var stripped = raw.replace(STRIP, "");
    return stripped.length > cap ? stripped.slice(0, cap) : stripped;
}

/** A reg-name host with an optional port, and nothing else. */
var AUTHORITY = /^([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?$/;

/** An IPv6 literal in its brackets, with an optional port after them. */
var IPV6_AUTHORITY = /^\[([0-9A-Fa-f:.]{2,45})\](?::([0-9]{1,5}))?$/;

/** Whether a port is a plain in-range number — no leading zeros, no `0`. */
function _okPort(port) {
    if (port === undefined || port === null || port === "") {
        return true;
    }
    return /^[1-9][0-9]{0,4}$/.test(port) && Number(port) <= 65535;
}

/** Whether a reg-name is one DNS would recognise, label by label. */
function _okHost(host) {
    if (host.length === 0 || host.length > MAX_HOST) {
        return false;
    }
    var labels = host.split(".");
    for (var i = 0; i < labels.length; i++) {
        var label = labels[i];
        // An empty label is "..", a leading dot, or a trailing dot. All three
        // are somebody testing what this parser does with them.
        if (label.length === 0 || label.length > MAX_HOST_LABEL) {
            return false;
        }
        if (!/^[A-Za-z0-9-]+$/.test(label) || label.charAt(0) === "-") {
            return false;
        }
    }
    return true;
}

/**
 * The origin of a configured base URL, or nothing.
 *
 * `service.baseUrl` reaches this from `~/.config/omarchy/shell.json`, which
 * every process running as this user can rewrite. So it is parsed here, at the
 * consumer, and not trusted because a setup form once looked at it.
 *
 * Only the origin survives. Whatever path, query or fragment the setting
 * carried is discarded rather than carried forward, so the URL that is opened
 * is built from parts this function has seen, in an order it chose.
 *
 * @param {*} base the configured base URL
 * @returns {string|null} `scheme://host[:port]`, or null if it is not usable
 */
function originOf(base) {
    // A real string only: an object with a `toString` is a value that decides
    // what it is at the moment it is read, which is not a thing to validate.
    if (typeof base !== "string" || base.length === 0 || base.length > MAX_URL) {
        return null;
    }

    // Printable ASCII, no space. One rule that refuses control characters,
    // NUL, NEL and the rest of C1, every bidi override, and non-ASCII hosts
    // that would have to be punycoded to mean anything anyway.
    if (!/^[\x21-\x7E]+$/.test(base)) {
        return null;
    }

    // Option-shaped. `--` before the argument is what stops `xdg-open` reading
    // this as a flag; refusing it as well means the string is never one.
    if (base.charAt(0) === "-") {
        return null;
    }

    // A browser folds a backslash to a slash, so in
    // "https://evil.example\@good.example/" the authority is "evil.example"
    // and the rest is a path — while a regex reading to the first "/" reports
    // "good.example". Two parsers disagreeing about the host is the bug, so
    // the character is refused outright rather than normalised.
    if (base.indexOf("\\") !== -1) {
        return null;
    }

    var parts = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]*)/.exec(base);
    if (!parts) {
        return null;
    }

    var scheme = parts[1].toLowerCase();
    // http as well as https: Uptime Kuma is usually a box on the LAN, and this
    // plugin never puts a credential on this URL — the socket carries those.
    if (scheme !== "http" && scheme !== "https") {
        return null;
    }

    var authority = parts[2];
    // Userinfo is refused, not stripped. "https://token@kuma.example" is a
    // sentence about credentials, and an origin that quietly drops it is not
    // the thing the operator configured.
    if (authority.indexOf("@") !== -1) {
        return null;
    }

    var host;
    var port;
    var v6 = IPV6_AUTHORITY.exec(authority);
    if (v6) {
        host = "[" + v6[1] + "]";
        port = v6[2];
    } else {
        var reg = AUTHORITY.exec(authority);
        if (!reg || !_okHost(reg[1])) {
            return null;
        }
        host = reg[1];
        port = reg[2];
    }

    if (!_okPort(port)) {
        return null;
    }

    return scheme + "://" + host.toLowerCase() + (port ? ":" + port : "");
}

/**
 * A monitor id as a path segment, or nothing.
 *
 * Digits and nothing else, so the segment can never be "..", a second path, a
 * query, or a scheme. A float or a non-finite number is not an id either: it
 * is a number that arrived from somewhere that does not issue ids.
 *
 * @param {*} id an `id` from a row
 * @returns {string|null} the id in decimal, or null
 */
function _monitorId(id) {
    if (typeof id === "number") {
        if (!isFinite(id) || Math.floor(id) !== id || id < 0) {
            return null;
        }
        if (String(id).length > MAX_ID_DIGITS) {
            return null;
        }
        return String(id);
    }
    if (typeof id !== "string") {
        return null;
    }
    if (!new RegExp("^[0-9]{1," + MAX_ID_DIGITS + "}$").test(id)) {
        return null;
    }
    return String(Number(id));
}

/**
 * Where a monitor lives in the Uptime Kuma web UI.
 *
 * Built from an origin this file validated and an id this file validated, in
 * that order, with a constant in between. Nothing the caller passed is ever
 * concatenated into the result unexamined.
 *
 * @param {*} base the configured base URL
 * @param {*} monitorId the monitor's id
 * @returns {string|null} an absolute http(s) URL, or null — and null means
 *     open nothing, not open something else
 */
function dashboardUrl(base, monitorId) {
    var origin = originOf(base);
    var id = _monitorId(monitorId);
    if (origin === null || id === null) {
        return null;
    }
    return origin + "/dashboard/" + id;
}

if (typeof module !== "undefined") {
    module.exports = {
        plain: plain,
        originOf: originOf,
        dashboardUrl: dashboardUrl,
        MAX_LABEL: MAX_LABEL,
    };
}
