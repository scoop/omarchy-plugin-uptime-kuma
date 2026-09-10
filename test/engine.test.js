import { test, expect } from "bun:test";
import {
    decodePayload,
    decodePacket,
    encodeOpenNamespace,
    encodePong,
    encodeEvent,
} from "../src/engine.js";

test("decodePayload splits a payload on the record separator", () => {
    const raw = '40{"sid":"abc"}\x1e42["info",{"a":1}]\x1e42["loginRequired"]';

    expect(decodePayload(raw)).toEqual([
        '40{"sid":"abc"}',
        '42["info",{"a":1}]',
        '42["loginRequired"]',
    ]);
});

test("decodePacket reads the Engine.IO open handshake", () => {
    const p = decodePacket('0{"sid":"cU_1","pingInterval":25000,"pingTimeout":20000}');

    expect(p.kind).toBe("open");
    expect(p.sid).toBe("cU_1");
    expect(p.pingInterval).toBe(25000);
    expect(p.pingTimeout).toBe(20000);
});

test("decodePacket reads a server ping", () => {
    expect(decodePacket("2").kind).toBe("ping");
});

test("decodePacket reads an event with its name and arguments", () => {
    const p = decodePacket('42["heartbeat",{"monitorID":7,"status":0}]');

    expect(p.kind).toBe("event");
    expect(p.event).toBe("heartbeat");
    expect(p.args).toEqual([{ monitorID: 7, status: 0 }]);
});

test("decodePacket reads an acknowledgement and its id", () => {
    const p = decodePacket('431[{"ok":true}]');

    expect(p.kind).toBe("ack");
    expect(p.ackId).toBe(1);
    expect(p.args).toEqual([{ ok: true }]);
});

test("decodePacket reports an unparseable packet rather than throwing", () => {
    expect(decodePacket('42["truncated').kind).toBe("unknown");
});

test("encodeOpenNamespace connects to the default namespace", () => {
    expect(encodeOpenNamespace()).toBe("40");
});

test("encodePong answers a server ping", () => {
    expect(encodePong()).toBe("3");
});

test("encodeEvent frames an emit that expects an acknowledgement", () => {
    expect(encodeEvent("login", [{ username: "u" }], 0)).toBe('420["login",{"username":"u"}]');
});

test("encodeEvent omits the ack id when no acknowledgement is wanted", () => {
    expect(encodeEvent("clearEvents", [7], null)).toBe('42["clearEvents",7]');
});
