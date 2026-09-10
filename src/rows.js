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

/** The right-hand text on a monitor row: latency when we have it. */
function monitorDetail(monitor) {
    if (typeof monitor.ping === "number") {
        return monitor.ping + " ms";
    }
    return "";
}

function monitorRow(monitor, detail) {
    return {
        type: "monitor",
        id: monitor.id,
        label: monitor.name,
        detail: detail,
        status: monitor.status,
        error: monitor.error || "",
    };
}

/**
 * Build the flat row list.
 *
 * Problems are listed first and repeated inside their group. The duplication is
 * deliberate: the top of the list answers "what is broken right now", and the
 * tree below still shows where it sits.
 *
 * @param {object|null} view output of `buildView`
 * @param {string} filterText what the operator has typed, if anything
 * @param {object} collapsed group ids the operator has folded shut
 * @returns {Array} rows, in display order
 */
function flatten(view, filterText, collapsed) {
    if (!view) {
        return [];
    }

    var filter = String(filterText || "")
        .toLowerCase()
        .trim();
    var folded = collapsed || {};
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
    for (i = 0; i < problems.length; i++) {
        if (filter && !matches(problems[i].name, filter)) {
            continue;
        }
        rows.push(monitorRow(problems[i], groupNameFor[problems[i].id] || ""));
    }

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
            detail: downCount(group.children) + " down / " + group.children.length,
            status: group.status,
            error: "",
        });

        // A filter always opens what it matched: hiding the hit behind a fold
        // the operator cannot see would make the search useless.
        if (folded[group.id] && filter === "") {
            continue;
        }

        for (j = 0; j < children.length; j++) {
            rows.push(monitorRow(children[j], monitorDetail(children[j])));
        }
    }

    var ungrouped = view.ungrouped || [];
    for (i = 0; i < ungrouped.length; i++) {
        if (filter && !matches(ungrouped[i].name, filter)) {
            continue;
        }
        rows.push(monitorRow(ungrouped[i], monitorDetail(ungrouped[i])));
    }

    return rows;
}

if (typeof module !== "undefined") {
    module.exports = { flatten: flatten };
}
