// The domain model: Uptime Kuma's wire shapes turned into the vocabulary in
// CONTEXT.md. Pure functions only — no QML, no I/O — so the test runner and the
// shell can load the same file.

/** Heartbeat status codes as Uptime Kuma records them. */
var BEAT_DOWN = 0;
var BEAT_UP = 1;
var BEAT_PENDING = 2;
var BEAT_MAINTENANCE = 3;

/** Status values, worst first. Order is the severity ordering. */
var SEVERITY = ["down", "degraded", "up"];

/**
 * Whether Uptime Kuma is currently checking this monitor at all.
 *
 * `forceInactive` is set when an ancestor group is paused, so a monitor can be
 * active itself and still not be checked.
 *
 * @param {KumaMonitor} monitor a monitor as it appears in `monitorList`
 * @returns {boolean} true when the monitor is Paused
 */
function isPaused(monitor) {
    return monitor.active === false || monitor.forceInactive === true;
}

/**
 * The Status of a monitor, given its most recent Heartbeat.
 *
 * A monitor that has never been checked has no heartbeat to judge, and is
 * reported as Degraded: it is not confirmed working, and calling it Up would be
 * a guess in the direction that hides problems.
 *
 * @param {KumaMonitor} monitor a monitor as it appears in `monitorList`
 * @param {KumaHeartbeat|null} lastBeat its most recent heartbeat, if any
 * @returns {string} "up", "degraded" or "down"
 */
function statusOf(monitor, lastBeat) {
    if (!lastBeat) {
        return "degraded";
    }
    if (lastBeat.status === BEAT_UP) {
        return "up";
    }
    if (lastBeat.status === BEAT_PENDING || lastBeat.status === BEAT_MAINTENANCE) {
        return "degraded";
    }
    if (lastBeat.status === BEAT_DOWN) {
        return "down";
    }
    return "degraded";
}

/**
 * The worst Status in a collection — how a Group reports its children.
 *
 * Nothing at all is Up: an empty Group is not a problem, and must not raise the
 * Indicator.
 *
 * @param {string[]} statuses statuses to reduce
 * @returns {string} the worst of them
 */
function worstStatus(statuses) {
    for (var i = 0; i < SEVERITY.length; i++) {
        if (statuses.indexOf(SEVERITY[i]) !== -1) {
            return SEVERITY[i];
        }
    }
    return "up";
}

/**
 * Order by name, case-insensitively and ignoring stray surrounding whitespace.
 *
 * Uptime Kuma accepts a name like " Beszel", and left alone that leading space
 * would sort it ahead of every real letter. Position should be a property of
 * what a thing is called, not of how it was typed or when it was created.
 *
 * @param {Array<{name: string}>} items anything carrying a `name`
 * @returns {Array} the same items, ordered
 */
function byName(items) {
    return items.slice().sort(function (a, b) {
        var left = String(a.name || "")
            .trim()
            .toLowerCase();
        var right = String(b.name || "")
            .trim()
            .toLowerCase();
        if (left < right) {
            return -1;
        }
        if (left > right) {
            return 1;
        }
        return 0;
    });
}

/** How Status is written when it is shown as a word rather than a colour. */
var STATUS_LABEL = { up: "Up", degraded: "Degraded", down: "Down" };

/** How many heartbeats the sparkline draws, and what Uptime Kuma keeps. */
var WINDOW = 100;

/**
 * Read one of Uptime Kuma's heartbeat times.
 *
 * The server writes them in UTC without saying so — "2026-09-10 22:15:03" —
 * and a bare string like that is local time to `Date`, which would put every
 * duration out by the operator's offset. So it is parsed by hand and only
 * handed to `Date` when it carries a zone of its own.
 *
 * @param {string} text a heartbeat `time`
 * @returns {number|null} milliseconds since the epoch, or null if unreadable
 */
function parseTime(text) {
    var stamp = String(text || "").trim();
    var match =
        /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$/.exec(
            stamp,
        );
    if (!match) {
        return null;
    }
    if (match[7]) {
        // It says which zone it is in, so Date can be trusted with it.
        var parsed = Date.parse(stamp.replace(" ", "T"));
        return isNaN(parsed) ? null : parsed;
    }
    return Date.UTC(
        Number(match[1]),
        Number(match[2]) - 1,
        Number(match[3]),
        Number(match[4]),
        Number(match[5]),
        Number(match[6]),
    );
}

/**
 * An elapsed span, in the largest two units that still carry information.
 *
 * Seconds stop mattering once there are minutes of them, and minutes once
 * there are days: an outage is triaged by its order of magnitude.
 *
 * @param {number} ms the span
 * @returns {string} e.g. "42s", "9m", "3h 11m", "2d 5h"
 */
function formatDuration(ms) {
    // A local clock ahead of the server would otherwise read as a negative age.
    var seconds = Math.max(0, Math.floor((ms || 0) / 1000));
    if (seconds < 60) {
        return seconds + "s";
    }
    var minutes = Math.floor(seconds / 60);
    if (minutes < 60) {
        return minutes + "m";
    }
    var hours = Math.floor(minutes / 60);
    if (hours < 24) {
        var restMinutes = minutes % 60;
        return restMinutes === 0 ? hours + "h" : hours + "h " + restMinutes + "m";
    }
    var days = Math.floor(hours / 24);
    var restHours = hours % 24;
    return restHours === 0 ? days + "d" : days + "d " + restHours + "h";
}

/**
 * When the Status a monitor holds now began.
 *
 * Walks back from the newest heartbeat while the Status it reports is
 * unchanged. Status, not the raw code: a monitor that retried and then entered
 * maintenance has been Degraded throughout, and saying otherwise would restart
 * the clock on a problem that never went away.
 *
 * @param {KumaMonitor} monitor a monitor as it appears in `monitorList`
 * @param {KumaHeartbeat[]} beats its heartbeat history, oldest first
 * @returns {string|null} the `time` of the earliest heartbeat in that run
 */
function statusSince(monitor, beats) {
    var history = beats || [];
    if (history.length === 0) {
        return null;
    }
    var current = statusOf(monitor, history[history.length - 1]);
    var earliest = null;
    for (var i = history.length - 1; i >= 0; i--) {
        if (statusOf(monitor, history[i]) !== current) {
            break;
        }
        earliest = history[i];
    }
    return earliest && earliest.time ? earliest.time : null;
}

/**
 * How long the current Status has held, phrased for the line it sits on.
 *
 * A run reaching the oldest heartbeat we hold is only a lower bound — Uptime
 * Kuma sends a hundred and no more — and says so. Reporting the window as the
 * age would tell an operator a month-old service came up an hour ago.
 *
 * @param {KumaMonitor} monitor a monitor as it appears in `monitorList`
 * @param {KumaHeartbeat[]} beats its heartbeat history, oldest first
 * @param {number} nowMs the current time
 * @returns {string} e.g. "for 3h 11m", "for at least 2d 5h", or "" if unknown
 */
function heldText(monitor, beats, nowMs) {
    var history = beats || [];
    var since = parseTime(statusSince(monitor, history));
    if (since === null) {
        return "";
    }
    var bounded =
        history.length >= WINDOW &&
        statusOf(monitor, history[0]) === statusOf(monitor, history[history.length - 1]);
    return (bounded ? "for at least " : "for ") + formatDuration(nowMs - since);
}

/**
 * An uptime ratio as a percentage, keeping only the digits that differ.
 *
 * Two decimals is where Uptime Kuma's own figures stop being noise, and a
 * whole number keeps no decimals at all: "95%" reads faster than "95.00%".
 *
 * @param {number|null} ratio 0.0–1.0, as `uptime` reports it
 * @returns {string} e.g. "99.87%", or "" when nothing has been reported
 */
function formatPercent(ratio) {
    if (typeof ratio !== "number" || isNaN(ratio)) {
        return "";
    }
    return Math.round(ratio * 10000) / 100 + "%";
}

/**
 * A latency in whole milliseconds.
 *
 * @param {number|null} ms a `ping`, or an `avgPing`
 * @returns {string} e.g. "12 ms", or "" when nothing was measured
 */
function formatLatency(ms) {
    if (typeof ms !== "number" || isNaN(ms)) {
        return "";
    }
    return Math.round(ms) + " ms";
}

/**
 * What a certificate has left, said plainly.
 *
 * @param {number|null} days `certInfo.daysRemaining`
 * @returns {string} e.g. "21 days", "expired", or "" when there is no
 *     certificate to speak of
 */
function formatCertDays(days) {
    if (typeof days !== "number" || isNaN(days)) {
        return "";
    }
    if (days <= 0) {
        return "expired";
    }
    return days === 1 ? "1 day" : days + " days";
}

/**
 * Recent heartbeats reduced to what a sparkline draws.
 *
 * Height is latency against the slowest check in the window, so a service
 * getting steadily worse shows it before it fails. A failure is drawn full
 * height whatever it measured: the eye should land on the gap, not read it as
 * a fast check.
 *
 * @param {KumaMonitor} monitor a monitor as it appears in `monitorList`
 * @param {KumaHeartbeat[]} beats its heartbeat history, oldest first
 * @returns {Array} `{status, level}` per heartbeat, oldest first, at most 100
 */
function sparkline(monitor, beats) {
    var history = beats || [];
    if (history.length > WINDOW) {
        history = history.slice(history.length - WINDOW);
    }

    var slowest = 0;
    var i;
    for (i = 0; i < history.length; i++) {
        if (typeof history[i].ping === "number" && history[i].ping > slowest) {
            slowest = history[i].ping;
        }
    }

    var samples = [];
    for (i = 0; i < history.length; i++) {
        var status = statusOf(monitor, history[i]);
        var level;
        if (status === "down") {
            level = 1;
        } else if (typeof history[i].ping === "number" && slowest > 0) {
            // A floor of 0.15 so the quickest check is still a mark on the
            // page rather than a gap indistinguishable from a failure.
            level = Math.round((0.15 + 0.85 * (history[i].ping / slowest)) * 1000) / 1000;
        } else {
            level = 0.35;
        }
        samples.push({ status: status, level: level });
    }
    return samples;
}

/** A copy of the stats map with one monitor's entry amended. */
function _withStat(stats, monitorId, key, value) {
    var next = {};
    var id;
    for (id in stats) {
        if (Object.prototype.hasOwnProperty.call(stats, id)) {
            next[id] = stats[id];
        }
    }
    var entry = { uptime24: null, avgPing: null, certDays: null };
    var existing = stats[String(monitorId)];
    if (existing) {
        entry.uptime24 = existing.uptime24;
        entry.avgPing = existing.avgPing;
        entry.certDays = existing.certDays;
    }
    entry[key] = value;
    next[String(monitorId)] = entry;
    return next;
}

/**
 * Fold an `uptime` event in.
 *
 * Uptime Kuma reports 24 hours, 30 days and a year; only the day is kept,
 * because only the day answers "is this normal for it right now".
 *
 * @param {Record<string, MonitorStats>} stats the stats map
 * @param {number} monitorId which monitor
 * @param {number|string} period `24`, `720` or `"1y"`
 * @param {number} ratio 0.0–1.0
 * @returns {object} an amended map, or the one given when nothing was recorded
 */
function applyUptime(stats, monitorId, period, ratio) {
    if (String(period) !== "24" || typeof ratio !== "number") {
        return stats;
    }
    return _withStat(stats, monitorId, "uptime24", ratio);
}

/**
 * Fold an `avgPing` event in.
 *
 * @param {Record<string, MonitorStats>} stats the stats map
 * @param {number} monitorId which monitor
 * @param {number} ms the average over the last 24 hours
 * @returns {object} an amended map, or the one given when nothing was recorded
 */
function applyAvgPing(stats, monitorId, ms) {
    if (typeof ms !== "number" || isNaN(ms)) {
        return stats;
    }
    return _withStat(stats, monitorId, "avgPing", ms);
}

/**
 * Fold a `certInfo` event in.
 *
 * The event carries a JSON string describing the whole chain; all that is kept
 * is how long the leaf has left, which is the only part of it that becomes an
 * outage on a date nobody wrote down.
 *
 * @param {Record<string, MonitorStats>} stats the stats map
 * @param {number} monitorId which monitor
 * @param {string} tlsInfoJson the event's payload
 * @returns {object} an amended map, or the one given when nothing was recorded
 */
function applyCertInfo(stats, monitorId, tlsInfoJson) {
    var info;
    try {
        info = JSON.parse(String(tlsInfoJson || ""));
    } catch (e) {
        info = null;
    }
    if (!info || !info.certInfo || typeof info.certInfo.daysRemaining !== "number") {
        return stats;
    }
    return _withStat(stats, monitorId, "certDays", info.certInfo.daysRemaining);
}

/**
 * One monitor, reduced to what the Pane renders.
 *
 * Everything the detail view shows is derived here rather than there: the
 * Pane owns no arithmetic, and every line of this is testable without a shell.
 *
 * @param {KumaMonitor} monitor a monitor as it appears in `monitorList`
 * @param {KumaHeartbeat[]} beats its heartbeat history, oldest first
 * @param {MonitorStats|null} stat what `uptime`, `avgPing` and `certInfo` said about it
 * @param {number} nowMs the current time
 * @returns {MonitorView} the row
 */
function toRow(monitor, beats, stat, nowMs) {
    var history = beats || [];
    var last = history.length ? history[history.length - 1] : null;
    var extra = stat || {};
    var status = statusOf(monitor, last);
    var ping = last && typeof last.ping === "number" ? last.ping : null;
    var uptime24 = typeof extra.uptime24 === "number" ? extra.uptime24 : null;
    var avgPing = typeof extra.avgPing === "number" ? extra.avgPing : null;
    var certDays = typeof extra.certDays === "number" ? extra.certDays : null;
    return {
        id: monitor.id,
        name: monitor.name,
        status: status,
        statusText: STATUS_LABEL[status],
        error: last && last.msg ? last.msg : "",
        ping: ping,
        latencyText: formatLatency(ping),
        time: last ? last.time : null,
        since: statusSince(monitor, history),
        held: heldText(monitor, history, nowMs),
        uptime24: uptime24,
        uptimeText: formatPercent(uptime24),
        avgPing: avgPing,
        avgPingText: formatLatency(avgPing),
        certDays: certDays,
        certText: formatCertDays(certDays),
        samples: sparkline(monitor, history),
        beats: history,
    };
}

/**
 * Turn a raw `monitorList` and its heartbeats into the shape the Pane shows.
 *
 * Paused monitors are dropped from the tree entirely and survive only as a
 * count: Uptime Kuma is not checking them, so they have nothing to report and
 * would only dilute a view whose job is finding the broken ones.
 *
 * @param {Record<string, KumaMonitor>} monitorList monitors keyed by id, as Uptime Kuma sends them
 * @param {Record<string, KumaHeartbeat[]>} beatsById heartbeat history keyed by monitor id
 * @param {Record<string, MonitorStats>} statsById uptime, latency and certificate figures by id
 * @param {number} nowMs the current time, against which ages are measured
 * @returns {object} `{groups, ungrouped, problems, counts}`
 */
function buildView(monitorList, beatsById, statsById, nowMs) {
    var beats = beatsById || {};
    var stats = statsById || {};
    var now = typeof nowMs === "number" ? nowMs : Date.now();
    var all = [];
    var key;
    for (key in monitorList) {
        if (Object.prototype.hasOwnProperty.call(monitorList, key)) {
            all.push(monitorList[key]);
        }
    }

    var live = [];
    var pausedCount = 0;
    for (var i = 0; i < all.length; i++) {
        if (isPaused(all[i])) {
            pausedCount++;
        } else {
            live.push(all[i]);
        }
    }

    var groups = [];
    var ungrouped = [];
    var problems = [];
    var counts = { up: 0, degraded: 0, down: 0, paused: pausedCount, total: 0 };

    for (var g = 0; g < live.length; g++) {
        var monitor = live[g];
        if (monitor.type === "group") {
            groups.push({
                id: monitor.id,
                name: monitor.name,
                status: "up",
                children: [],
            });
        }
    }

    var groupById = {};
    for (var h = 0; h < groups.length; h++) {
        groupById[groups[h].id] = groups[h];
    }

    for (var j = 0; j < live.length; j++) {
        var m = live[j];
        if (m.type === "group") {
            continue;
        }
        var row = toRow(m, beats[m.id], stats[m.id], now);
        counts[row.status]++;
        counts.total++;
        if (row.status === "down") {
            problems.push(row);
        }
        var parent = m.parent !== null && m.parent !== undefined ? groupById[m.parent] : null;
        if (parent) {
            parent.children.push(row);
        } else {
            ungrouped.push(row);
        }
    }

    for (var k = 0; k < groups.length; k++) {
        groups[k].status = worstStatus(
            groups[k].children.map(function (child) {
                return child.status;
            }),
        );
    }

    for (var s = 0; s < groups.length; s++) {
        groups[s].children = byName(groups[s].children);
    }

    return {
        groups: byName(groups),
        ungrouped: byName(ungrouped),
        problems: byName(problems),
        counts: counts,
    };
}

if (typeof module !== "undefined") {
    module.exports = {
        isPaused: isPaused,
        statusOf: statusOf,
        worstStatus: worstStatus,
        buildView: buildView,
        parseTime: parseTime,
        formatDuration: formatDuration,
        formatPercent: formatPercent,
        formatLatency: formatLatency,
        formatCertDays: formatCertDays,
        statusSince: statusSince,
        heldText: heldText,
        sparkline: sparkline,
        applyUptime: applyUptime,
        applyAvgPing: applyAvgPing,
        applyCertInfo: applyCertInfo,
    };
}
