// Flatten the view into the single list the Pane renders and the keyboard
// moves through. Pure — the Pane owns no layout logic of its own.

/** Case-insensitive substring match, tolerant of missing text. */
function matches(text, filter) {
    return (
        String(text || "")
            .toLowerCase()
            .indexOf(filter) !== -1
    );
}

/** How many children of a group are Down. */
function downCount(children) {
    var n = 0;
    for (var i = 0; i < children.length; i++) {
        if (children[i].status === "down") {
            n++;
        }
    }
    return n;
}

/** What a group says about itself on the right-hand side. */
function groupDetail(children) {
    var down = downCount(children);
    if (down === 0) {
        return String(children.length);
    }
    return down + " down / " + children.length;
}

/** The right-hand text on a monitor row: latency when we have it. */
function monitorDetail(monitor) {
    if (typeof monitor.ping === "number") {
        return monitor.ping + " ms";
    }
    return "";
}

function monitorRow(monitor, detail, depth) {
    return {
        type: "monitor",
        id: monitor.id,
        label: monitor.name,
        detail: detail,
        // How far in the Pane sets the row. Indentation is the only thing
        // saying what a row hangs off, so a monitor with no group sits at the
        // top level beside the groups rather than inside whichever one the
        // list last drew.
        depth: depth,
        status: monitor.status,
        error: monitor.error || "",
        // The whole monitor rides along, so the Pane can hand the selected row
        // to the detail view without going back to the model to look it up.
        monitor: monitor,
        selectable: true,
    };
}

/** A heading. Announces a section; the keyboard passes over it. */
function sectionRow(id, label, status) {
    return {
        type: "section",
        id: id,
        label: label,
        detail: "",
        depth: 0,
        status: status,
        error: "",
        monitor: null,
        selectable: false,
    };
}

/**
 * Build the flat row list.
 *
 * Problems are listed first and repeated inside their group. The duplication is
 * deliberate: the top of the list answers "what is broken right now", and the
 * tree below still shows where it sits.
 *
 * @param {View|null} view output of `buildView`
 * @param {string} filterText what the operator has typed, if anything
 * @param {Record<string, boolean>} opened group ids the operator has folded open
 * @returns {Row[]} rows, in display order
 */
function flatten(view, filterText, opened) {
    if (!view) {
        return [];
    }

    var filter = String(filterText || "")
        .toLowerCase()
        .trim();
    var unfolded = opened || {};
    var rows = [];
    var groups = view.groups || [];
    var i;
    var j;

    // Which group each problem came from, so a pinned row can say where it sits.
    var groupNameFor = {};
    for (i = 0; i < groups.length; i++) {
        for (j = 0; j < groups[i].children.length; j++) {
            groupNameFor[groups[i].children[j].id] = groups[i].name;
        }
    }

    var problems = view.problems || [];
    var problemRows = [];
    for (i = 0; i < problems.length; i++) {
        if (filter && !matches(problems[i].name, filter)) {
            continue;
        }
        problemRows.push(monitorRow(problems[i], groupNameFor[problems[i].id] || "", 0));
    }
    if (problemRows.length > 0) {
        rows.push(sectionRow("problems", "Problems", "down"));
        for (i = 0; i < problemRows.length; i++) {
            rows.push(problemRows[i]);
        }
    }

    rows.push(sectionRow("monitors", "Monitors", "up"));

    for (i = 0; i < groups.length; i++) {
        var group = groups[i];
        var groupMatches = filter === "" || matches(group.name, filter);
        var children = [];

        for (j = 0; j < group.children.length; j++) {
            var child = group.children[j];
            if (filter === "" || groupMatches || matches(child.name, filter)) {
                children.push(child);
            }
        }

        if (filter !== "" && !groupMatches && children.length === 0) {
            continue;
        }

        rows.push({
            type: "group",
            id: group.id,
            label: group.name,
            depth: 0,
            // A healthy group has nothing to report but its size. Saying
            // "0 down" on eleven groups buries the one that says "1 down".
            detail: groupDetail(group.children),
            status: group.status,
            error: "",
            // A Group is a place, not a thing that was checked: it has no
            // heartbeats of its own worth detailing.
            monitor: null,
            selectable: true,
        });

        // Groups start folded shut — a healthy instance should be a dozen
        // rows, not a wall. A filter always opens what it matched: hiding the
        // hit behind a fold the operator cannot see makes the search useless.
        if (!unfolded[group.id] && filter === "") {
            continue;
        }

        for (j = 0; j < children.length; j++) {
            rows.push(monitorRow(children[j], monitorDetail(children[j]), 1));
        }
    }

    var ungrouped = view.ungrouped || [];
    for (i = 0; i < ungrouped.length; i++) {
        if (filter && !matches(ungrouped[i].name, filter)) {
            continue;
        }
        rows.push(monitorRow(ungrouped[i], monitorDetail(ungrouped[i]), 0));
    }

    return rows;
}

if (typeof module !== "undefined") {
    module.exports = { flatten: flatten };
}
