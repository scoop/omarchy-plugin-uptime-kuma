import { test, expect } from "bun:test";
import {
    statusSince,
    parseTime,
    formatDuration,
    formatPercent,
    formatLatency,
    heldText,
    sparkline,
    applyUptime,
    applyAvgPing,
    applyCertInfo,
} from "../src/model.js";

const at = (status, minutes, extra) =>
    Object.assign(
        {
            status: status,
            // 2026-09-10 12:00:00 UTC plus however many minutes.
            time:
                "2026-09-10 " +
                String(12 + Math.floor(minutes / 60)).padStart(2, "0") +
                ":" +
                String(minutes % 60).padStart(2, "0") +
                ":00",
        },
        extra || {},
    );

const monitor = { active: true };

// ------------------------------------------------------------- when it began

test("the current status began at the earliest heartbeat still reporting it", () => {
    const beats = [at(1, 0), at(0, 1), at(0, 2), at(0, 3)];

    expect(statusSince(monitor, beats)).toBe("2026-09-10 12:01:00");
});

test("an older run of the same status does not count once it was interrupted", () => {
    const beats = [at(0, 0), at(1, 1), at(0, 2)];

    expect(statusSince(monitor, beats)).toBe("2026-09-10 12:02:00");
});

test("retrying and maintenance are one Degraded run, because they are one Status", () => {
    const beats = [at(1, 0), at(3, 1), at(2, 2)];

    expect(statusSince(monitor, beats)).toBe("2026-09-10 12:01:00");
});

test("a monitor with no heartbeats began its status at no time we know", () => {
    expect(statusSince(monitor, [])).toBe(null);
});

// -------------------------------------------------------------------- clocks

test("heartbeat times are read as UTC, which is how Uptime Kuma writes them", () => {
    expect(parseTime("2026-09-10 12:00:00")).toBe(Date.UTC(2026, 8, 10, 12, 0, 0));
});

test("fractional seconds and the ISO 'T' are both accepted", () => {
    expect(parseTime("2026-09-10T12:00:00.482")).toBe(Date.UTC(2026, 8, 10, 12, 0, 0));
});

test("a time carrying its own offset is honoured rather than assumed UTC", () => {
    expect(parseTime("2026-09-10T14:00:00+02:00")).toBe(Date.UTC(2026, 8, 10, 12, 0, 0));
});

test("an unreadable time is no time at all, rather than a nonsense number", () => {
    expect(parseTime("whenever")).toBe(null);
    expect(parseTime(null)).toBe(null);
});

// ------------------------------------------------------------------ duration

test("durations read in the largest two units that carry information", () => {
    expect(formatDuration(42 * 1000)).toBe("42s");
    expect(formatDuration(9 * 60 * 1000)).toBe("9m");
    expect(formatDuration((3 * 60 + 11) * 60 * 1000)).toBe("3h 11m");
    expect(formatDuration(2 * 60 * 60 * 1000)).toBe("2h");
    expect(formatDuration((2 * 24 + 5) * 60 * 60 * 1000)).toBe("2d 5h");
    expect(formatDuration(3 * 24 * 60 * 60 * 1000)).toBe("3d");
});

test("a clock that disagrees with the server reads as no elapsed time, not a negative one", () => {
    expect(formatDuration(-5000)).toBe("0s");
});

test("how long a status has held is phrased for the line it sits on", () => {
    const beats = [at(1, 0), at(0, 1), at(0, 2)];
    const now = Date.UTC(2026, 8, 10, 15, 13, 0);

    expect(heldText(monitor, beats, now)).toBe("for 3h 12m");
});

test("a run that fills the whole window says so, rather than claiming the window is the age", () => {
    const beats = [];
    for (let i = 0; i < 100; i++) {
        beats.push(at(1, i));
    }
    const now = Date.UTC(2026, 8, 10, 13, 39, 0);

    expect(heldText(monitor, beats, now)).toBe("for at least 1h 39m");
});

test("with no heartbeats there is nothing to say about how long", () => {
    expect(heldText(monitor, [], Date.now())).toBe("");
});

// ----------------------------------------------------------------- numerals

test("an uptime ratio reads as a percentage, keeping the digits that matter", () => {
    expect(formatPercent(0.9987)).toBe("99.87%");
    expect(formatPercent(1)).toBe("100%");
    expect(formatPercent(0.95)).toBe("95%");
});

test("a perfect zero is a real answer and is shown as one", () => {
    expect(formatPercent(0)).toBe("0%");
});

test("an uptime Uptime Kuma has not sent yet is blank, not zero", () => {
    expect(formatPercent(null)).toBe("");
    expect(formatPercent(undefined)).toBe("");
});

test("latency is whole milliseconds, and blank when unmeasured", () => {
    expect(formatLatency(12)).toBe("12 ms");
    expect(formatLatency(12.6)).toBe("13 ms");
    expect(formatLatency(null)).toBe("");
});

// ---------------------------------------------------------------- sparkline

test("the sparkline carries one sample per heartbeat, newest last", () => {
    const samples = sparkline(monitor, [at(1, 0, { ping: 10 }), at(0, 1)]);

    expect(samples.length).toBe(2);
    expect(samples.map((s) => s.status)).toEqual(["up", "down"]);
});

test("a failure draws full height, whatever it did or did not measure", () => {
    const samples = sparkline(monitor, [at(1, 0, { ping: 400 }), at(0, 1, { ping: 1 })]);

    expect(samples[1].level).toBe(1);
});

test("height is latency relative to the worst in the window", () => {
    const samples = sparkline(monitor, [at(1, 0, { ping: 100 }), at(1, 1, { ping: 50 })]);

    expect(samples[0].level).toBe(1);
    expect(samples[1].level).toBeGreaterThan(0.4);
    expect(samples[1].level).toBeLessThan(0.7);
});

test("a heartbeat with no latency still draws, or the run would look absent", () => {
    const samples = sparkline(monitor, [at(1, 0), at(1, 1)]);

    expect(samples[0].level).toBeGreaterThan(0);
});

test("only the last hundred heartbeats are drawn, so the line stays legible", () => {
    const beats = [];
    for (let i = 0; i < 140; i++) {
        beats.push(at(1, i, { ping: 10 }));
    }

    expect(sparkline(monitor, beats).length).toBe(100);
});

// ------------------------------------------------------- the discarded events

test("an uptime event is remembered for the period the pane shows", () => {
    const stats = applyUptime({}, 7, 24, 0.9987);

    expect(stats["7"].uptime24).toBe(0.9987);
});

test("uptime over longer periods is not kept, since nothing renders it", () => {
    const stats = {};

    expect(applyUptime(stats, 7, 720, 0.99)).toBe(stats);
    expect(applyUptime(stats, 7, "1y", 0.99)).toBe(stats);
});

test("an average latency event is remembered", () => {
    expect(applyAvgPing({}, 7, 31)["7"].avgPing).toBe(31);
});

test("a certificate event keeps only how long the certificate has left", () => {
    const stats = applyCertInfo({}, 7, JSON.stringify({ certInfo: { daysRemaining: 21 } }));

    expect(stats["7"].certDays).toBe(21);
});

test("a certificate event with nothing readable in it changes nothing", () => {
    const stats = {};

    expect(applyCertInfo(stats, 7, "not json")).toBe(stats);
    expect(applyCertInfo(stats, 7, JSON.stringify({}))).toBe(stats);
});

test("folding an event leaves the map it was given untouched", () => {
    const stats = { 7: { uptime24: 0.5 } };
    const next = applyAvgPing(stats, 7, 31);

    expect(stats["7"].avgPing).toBe(undefined);
    expect(next["7"].uptime24).toBe(0.5);
    expect(next["7"].avgPing).toBe(31);
});
