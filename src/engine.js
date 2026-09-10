// Engine.IO v4 / Socket.IO v5 wire codec.
//
// Plain script, not a module: QML loads this file as a JavaScript resource,
// which forbids `export`. The trailing guard is what makes the same file
// importable by the test runner.

/** Engine.IO frames several packets into one HTTP body, separated by 0x1e. */
var RECORD_SEPARATOR = "\u001e";

/**
 * Split one polling response into its individual packets.
 * @param {string} raw body of a GET on the polling endpoint
 * @returns {string[]} packets, in order
 */
function decodePayload(raw) {
    if (typeof raw !== "string" || raw === "") {
        return [];
    }
    return raw.split(RECORD_SEPARATOR);
}

/**
 * Interpret one packet.
 *
 * Engine.IO puts its packet type in the first character; Socket.IO adds a
 * second for its own type, and an acknowledgement carries a numeric id between
 * that prefix and its JSON body. A malformed packet is reported as "unknown"
 * rather than thrown: this is an undocumented interface, and one bad frame must
 * not take down a connection that is otherwise healthy.
 *
 * @param {string} packet one frame from {@link decodePayload}
 * @returns {object} a shape carrying `kind`, plus whatever that kind implies
 */
function decodePacket(packet) {
    if (typeof packet !== "string" || packet === "") {
        return { kind: "unknown" };
    }

    if (packet[0] === "0") {
        var open = parseJson(packet.slice(1));
        if (!open) {
            return { kind: "unknown" };
        }
        return {
            kind: "open",
            sid: open.sid,
            pingInterval: open.pingInterval,
            pingTimeout: open.pingTimeout,
        };
    }

    if (packet === "2") {
        return { kind: "ping" };
    }

    // "42" event, "43" acknowledgement. Both may carry an ack id before the body.
    if (packet[0] === "4" && (packet[1] === "2" || packet[1] === "3")) {
        var rest = packet.slice(2);
        var digits = /^[0-9]*/.exec(rest)[0];
        var body = parseJson(rest.slice(digits.length));
        if (!Array.isArray(body)) {
            return { kind: "unknown" };
        }
        if (packet[1] === "3") {
            return { kind: "ack", ackId: Number(digits), args: body };
        }
        return { kind: "event", event: body[0], args: body.slice(1) };
    }

    return { kind: "unknown" };
}

/** The packet that joins the default namespace, sent once after the handshake. */
function encodeOpenNamespace() {
    return "40";
}

/** The answer a server ping expects; silence here ends the session. */
function encodePong() {
    return "3";
}

/**
 * Frame an outbound event.
 * @param {string} event event name
 * @param {Array} args arguments to send with it
 * @param {number|null} ackId id to correlate a reply, or null to expect none
 * @returns {string} the packet
 */
function encodeEvent(event, args, ackId) {
    var body = JSON.stringify([event].concat(args || []));
    var id = ackId === null || ackId === undefined ? "" : String(ackId);
    return "42" + id + body;
}

/** JSON.parse that answers null instead of throwing. */
function parseJson(text) {
    try {
        return JSON.parse(text);
    } catch (e) {
        return null;
    }
}

if (typeof module !== "undefined") {
    module.exports = {
        decodePayload: decodePayload,
        decodePacket: decodePacket,
        encodeOpenNamespace: encodeOpenNamespace,
        encodePong: encodePong,
        encodeEvent: encodeEvent,
    };
}
