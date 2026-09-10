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
 * @param {object} monitor a monitor as it appears in `monitorList`
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
 * @param {object} monitor a monitor as it appears in `monitorList`
 * @param {object|null} lastBeat its most recent heartbeat, if any
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
 * @param {Array} items anything carrying a `name`
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

/**
 * One monitor, reduced to what the Pane renders.
 *
 * @param {object} monitor a monitor as it appears in `monitorList`
 * @param {Array} beats its heartbeat history, oldest first
 * @returns {object} the row
 */
function toRow(monitor, beats) {
    var history = beats || [];
    var last = history.length ? history[history.length - 1] : null;
    return {
        id: monitor.id,
        name: monitor.name,
        status: statusOf(monitor, last),
        error: last && last.msg ? last.msg : "",
        ping: last && typeof last.ping === "number" ? last.ping : null,
        time: last ? last.time : null,
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
 * @param {object} monitorList monitors keyed by id, as Uptime Kuma sends them
 * @param {object} beatsById heartbeat history keyed by monitor id
 * @returns {object} `{groups, ungrouped, problems, counts}`
 */
function buildView(monitorList, beatsById) {
    var beats = beatsById || {};
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
        var row = toRow(m, beats[m.id]);
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
    };
}
