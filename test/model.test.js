import { test, expect } from "bun:test";
import { statusOf, isPaused, worstStatus, buildView } from "../src/model.js";

const beat = (status) => ({ status: status, time: "2026-09-10 12:00:00" });

test("a monitor whose last heartbeat succeeded is Up", () => {
    expect(statusOf({ active: true }, beat(1))).toBe("up");
});

test("a monitor whose last heartbeat failed is Down", () => {
    expect(statusOf({ active: true }, beat(0))).toBe("down");
});

test("a monitor retrying after a failure is Degraded", () => {
    expect(statusOf({ active: true }, beat(2))).toBe("degraded");
});

test("a monitor inside a maintenance window is Degraded", () => {
    expect(statusOf({ active: true }, beat(3))).toBe("degraded");
});

test("a monitor that has never been checked is Degraded, not Up", () => {
    expect(statusOf({ active: true }, null)).toBe("degraded");
});

test("a paused monitor is recognised regardless of its last heartbeat", () => {
    expect(isPaused({ active: false })).toBe(true);
    expect(isPaused({ active: true, forceInactive: true })).toBe(true);
    expect(isPaused({ active: true, forceInactive: false })).toBe(false);
});

test("worstStatus picks Down over Degraded over Up", () => {
    expect(worstStatus(["up", "degraded", "down"])).toBe("down");
    expect(worstStatus(["up", "degraded"])).toBe("degraded");
    expect(worstStatus(["up", "up"])).toBe("up");
});

test("worstStatus of nothing is Up, so an empty group does not raise alarm", () => {
    expect(worstStatus([])).toBe("up");
});

const monitors = {
    1: { id: 1, name: "Immich", type: "group", parent: null, active: true },
    2: { id: 2, name: "immich-web", parent: 1, active: true },
    3: { id: 3, name: "immich-db", parent: 1, active: true },
    4: { id: 4, name: "old-thing", parent: 1, active: false },
    5: { id: 5, name: "standalone", parent: null, active: true },
    // Deliberately created after Immich but sorting before it, and named with
    // stray whitespace of the kind Uptime Kuma happily accepts.
    6: { id: 6, name: " Audiobookshelf", type: "group", parent: null, active: true },
    7: { id: 7, name: "abs-web", parent: 6, active: true },
    8: { id: 8, name: "another-standalone", parent: null, active: true },
};

test("buildView nests monitors under their parent group", () => {
    const view = buildView(monitors, { 2: [beat(1)], 3: [beat(1)], 5: [beat(1)] });
    const immich = view.groups.find((g) => g.id === 1);

    expect(immich.children.map((m) => m.name)).toEqual(["immich-db", "immich-web"]);
});

test("groups are listed alphabetically, not in the order they were created", () => {
    const view = buildView(monitors, {});

    expect(view.groups.map((g) => g.name)).toEqual([" Audiobookshelf", "Immich"]);
});

test("sorting ignores stray whitespace around a name", () => {
    const view = buildView(monitors, {});

    // " Audiobookshelf" sorts under A, not ahead of everything.
    expect(view.groups[0].name).toBe(" Audiobookshelf");
    expect(view.groups[1].name).toBe("Immich");
});

test("sorting ignores case, so capitals do not clump", () => {
    const mixed = {
        1: { id: 1, name: "zebra", parent: null, active: true },
        2: { id: 2, name: "Apple", parent: null, active: true },
    };

    expect(buildView(mixed, {}).ungrouped.map((m) => m.name)).toEqual(["Apple", "zebra"]);
});

test("ungrouped monitors are alphabetical too", () => {
    const view = buildView(monitors, {});

    expect(view.ungrouped.map((m) => m.name)).toEqual(["another-standalone", "standalone"]);
});

test("Problems are alphabetical", () => {
    const view = buildView(monitors, { 2: [beat(0)], 3: [beat(0)], 5: [beat(0)] });

    expect(view.problems.map((m) => m.name)).toEqual(["immich-db", "immich-web", "standalone"]);
});

test("a group reports the worst status among its children", () => {
    const view = buildView(monitors, { 2: [beat(1)], 3: [beat(0)], 5: [beat(1)] });

    expect(view.groups.find((g) => g.id === 1).status).toBe("down");
});

test("a monitor with no parent stands at the top level", () => {
    const view = buildView(monitors, { 2: [beat(1)], 3: [beat(1)], 5: [beat(1)] });

    expect(view.ungrouped.map((m) => m.name)).toContain("standalone");
});

test("every Down monitor is listed in Problems, flattened out of its group", () => {
    const view = buildView(monitors, { 2: [beat(0)], 3: [beat(1)], 5: [beat(0)] });

    expect(view.problems.map((m) => m.name).sort()).toEqual(["immich-web", "standalone"]);
});

test("Paused monitors are hidden from the tree and counted apart", () => {
    const view = buildView(monitors, { 2: [beat(1)], 3: [beat(1)], 5: [beat(1)] });

    expect(view.counts.paused).toBe(1);
    expect(view.groups.find((g) => g.id === 1).children.map((m) => m.id)).not.toContain(4);
});

test("a monitor carries the error text of its last heartbeat", () => {
    const failing = { status: 0, time: "2026-09-10 12:00:00", msg: "connect ECONNREFUSED" };
    const view = buildView(monitors, { 2: [failing], 3: [beat(1)], 5: [beat(1)] });

    expect(view.problems[0].error).toBe("connect ECONNREFUSED");
});
