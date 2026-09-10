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
 * Uptime Kuma is; anyone running one on a plain-http box on their LAN types
 * the scheme and keeps it. Nothing else is guessed at.
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
    return "";
}

/**
 * The first thing wrong with the form, read top to bottom as the person sees it.
 *
 * A two-factor code is checked whenever one is present and demanded once the
 * server has asked for one — an unattended six digits is worth checking before
 * it is spent, because a code is only good for one attempt and one window.
 *
 * @param {object} fields `{baseUrl, username, password, totp, totpRequired}`
 * @returns {object|null} `{field, message}`, or null when the form is ready to send
 */
function firstProblem(fields) {
    var form = fields || {};

    var badUrl = urlError(form.baseUrl);
    if (badUrl !== "") {
        return { field: "baseUrl", message: badUrl };
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
        firstProblem: firstProblem,
    };
}
