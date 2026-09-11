// What the setup form knows about the shape of a connection, before anything
// is sent anywhere. Pure functions only — no QML, no I/O — so the rules the
// form enforces can be read and tested without a running shell.
//
// Nothing here ever touches the password beyond asking whether one was typed:
// a password is whatever the person typed, including spaces, and this file has
// no business normalising it.

/** The URL shape `bin/login.sh` insists on, checked here so the person is told before a round trip. */
var URL_SHAPE = /^https?:\/\/[^\s/]+(\/\S*)?$/;

/** A trailing dashboard path, as pasted out of a browser's address bar. */
var DASHBOARD_PATH = /\/dashboard(\/\d+)?$/;

/**
 * The URL as we will actually use it, given what the person typed.
 *
 * A bare hostname is assumed to be https, because that is what a published
 * Uptime Kuma is; anyone running one on a plain-http box types the scheme and
 * keeps it — and is then asked to confirm it. Nothing else is guessed at.
 *
 * @param {string} raw whatever is in the URL field
 * @returns {string} the normalised URL, or "" if there was nothing to normalise
 */
function normalizeUrl(raw) {
    var value = String(raw || "").trim();
    if (value === "") {
        return "";
    }
    if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(value)) {
        value = "https://" + value;
    }
    value = value.replace(DASHBOARD_PATH, "");
    return value.replace(/\/+$/, "");
}

/**
 * A two-factor code with its grouping removed.
 *
 * Authenticators show the code as "123 456" and that is how it gets pasted, so
 * the spaces are dropped rather than rejected.
 *
 * @param {string} raw whatever is in the code field
 * @returns {string} the digits, in order
 */
function normalizeTotp(raw) {
    return String(raw || "").replace(/\D/g, "");
}

/** The authority of a normalized URL — host and port, and userinfo if any. */
var AUTHORITY = /^https?:\/\/([^/?#]*)/;

/**
 * Hosts that http:// can be trusted with, because the traffic never leaves the
 * machine. Matched whole: `localhost.example.com` is somebody else's server.
 */
var LOOPBACK = /^(?:localhost|127(?:\.\d{1,3}){3}|\[::1\]|\[::ffff:127(?:\.\d{1,3}){3}\])$/;

/** The host a URL names, without its port. "" when there is no authority. */
function hostOf(url) {
    var match = AUTHORITY.exec(String(url || ""));
    if (!match) {
        return "";
    }
    var authority = match[1];
    if (authority.charAt(0) === "[") {
        // A bracketed IPv6 literal; the colons inside it are not a port.
        var close = authority.indexOf("]");
        return close === -1 ? authority : authority.slice(0, close + 1);
    }
    return authority.split(":")[0];
}

/**
 * Whether using this URL would put the password and the session token on the
 * wire in the clear.
 *
 * http:// to a loopback address is not a disclosure — nothing is transmitted
 * anywhere. http:// to anything else is, however local the address looks: a
 * LAN is a place with other people's machines on it.
 *
 * @param {string} url a normalized URL
 * @returns {boolean} true when this address needs the person's consent
 */
function isPlaintext(url) {
    var value = String(url || "");
    if (value.slice(0, 7).toLowerCase() !== "http://") {
        return false;
    }
    return !LOOPBACK.test(hostOf(value).toLowerCase());
}

/**
 * Why this URL cannot be used, if it cannot.
 *
 * @param {string} raw whatever is in the URL field
 * @returns {string} the reason, or "" when the URL is usable
 */
function urlError(raw) {
    var url = normalizeUrl(raw);
    if (url === "") {
        return "Enter the address of your Uptime Kuma";
    }
    if (!URL_SHAPE.test(url)) {
        return "That is not an http:// or https:// address";
    }
    // A credential in the authority is both a leak — it lands in shell.json and
    // in every log the URL reaches — and the oldest way to disguise a host:
    // `https://kuma.example.com@evil.example` is a request to evil.example.
    var authority = AUTHORITY.exec(url);
    if (authority && authority[1].indexOf("@") !== -1) {
        return "Put your username in the field below, not in the address";
    }
    return "";
}

/**
 * The first thing wrong with the form, read top to bottom as the person sees it.
 *
 * A two-factor code is checked whenever one is present and demanded once the
 * server has asked for one — an unattended six digits is worth checking before
 * it is spent, because a code is only good for one attempt and one window.
 *
 * @param {object} fields `{baseUrl, username, password, totp, totpRequired,
 *     allowPlaintext}`
 * @returns {object|null} `{field, message}`, or null when the form is ready to send
 */
function firstProblem(fields) {
    var form = fields || {};

    var badUrl = urlError(form.baseUrl);
    if (badUrl !== "") {
        return { field: "baseUrl", message: badUrl };
    }

    // Asked here, where the address is, rather than at the end: the thing being
    // consented to is which address, not which password.
    if (isPlaintext(normalizeUrl(form.baseUrl)) && !form.allowPlaintext) {
        return {
            field: "allowPlaintext",
            message: "That address is not encrypted — tick the box to use it anyway",
        };
    }

    if (String(form.username || "").trim() === "") {
        return { field: "username", message: "Enter your Uptime Kuma username" };
    }

    // Not trimmed: a password of spaces is a password, and refusing it here
    // would be this plugin inventing a rule the server does not have.
    if (String(form.password || "") === "") {
        return { field: "password", message: "Enter your password" };
    }

    var totp = normalizeTotp(form.totp);
    if (form.totpRequired && totp === "") {
        return { field: "totp", message: "Enter the code from your authenticator app" };
    }
    if (totp !== "" && totp.length !== 6) {
        return { field: "totp", message: "A two-factor code is six digits" };
    }

    return null;
}

if (typeof module !== "undefined") {
    module.exports = {
        normalizeUrl: normalizeUrl,
        normalizeTotp: normalizeTotp,
        urlError: urlError,
        isPlaintext: isPlaintext,
        firstProblem: firstProblem,
    };
}
