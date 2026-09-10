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
};

test("buildView nests monitors under their parent group", () => {
    const view = buildView(monitors, { 2: [beat(1)], 3: [beat(1)], 5: [beat(1)] });
    const immich = view.groups.find((g) => g.id === 1);

    expect(immich.children.map((m) => m.name)).toEqual(["immich-web", "immich-db"]);
});

test("a group reports the worst status among its children", () => {
    const view = buildView(monitors, { 2: [beat(1)], 3: [beat(0)], 5: [beat(1)] });

    expect(view.groups.find((g) => g.id === 1).status).toBe("down");
});

test("a monitor with no parent stands at the top level", () => {
    const view = buildView(monitors, { 2: [beat(1)], 3: [beat(1)], 5: [beat(1)] });

    expect(view.ungrouped.map((m) => m.name)).toEqual(["standalone"]);
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
