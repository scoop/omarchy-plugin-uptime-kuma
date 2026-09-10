import { test, expect } from "bun:test";
import { flatten } from "../src/rows.js";

const view = {
    counts: { up: 2, degraded: 0, down: 1, paused: 0, total: 3 },
    groups: [
        {
            id: 10,
            name: "Immich",
            status: "down",
            children: [
                { id: 1, name: "immich-web", status: "down", error: "ECONNREFUSED", ping: null },
                { id: 2, name: "immich-db", status: "up", error: "", ping: 12 },
            ],
        },
        {
            id: 20,
            name: "Neon",
            status: "up",
            children: [{ id: 3, name: "neon-api", status: "up", error: "", ping: 40 }],
        },
    ],
    ungrouped: [{ id: 4, name: "standalone", status: "up", error: "", ping: 5 }],
    problems: [{ id: 1, name: "immich-web", status: "down", error: "ECONNREFUSED", ping: null }],
};

test("Problems come first, before any group", () => {
    const rows = flatten(view, "", {});

    expect(rows[0].id).toBe(1);
    expect(rows[0].type).toBe("monitor");
});

test("a problem row names the group it came from, since it was pulled out of it", () => {
    expect(flatten(view, "", {})[0].detail).toBe("Immich");
});

test("groups follow, each carrying how many of its children are down", () => {
    const rows = flatten(view, "", {});
    const immich = rows.find((r) => r.type === "group" && r.id === 10);

    expect(immich.detail).toBe("1 down / 2");
});

test("a collapsed group hides its children but stays visible itself", () => {
    const rows = flatten(view, "", { 10: true });

    expect(rows.some((r) => r.type === "group" && r.id === 10)).toBe(true);
    expect(rows.some((r) => r.type === "monitor" && r.id === 2)).toBe(false);
});

test("ungrouped monitors are listed after the groups", () => {
    const rows = flatten(view, "", {});
    const lastGroup = rows.map((r) => r.type).lastIndexOf("group");

    expect(rows.findIndex((r) => r.id === 4 && r.type === "monitor")).toBeGreaterThan(lastGroup);
});

test("a filter narrows to matching monitors and drops groups with no match", () => {
    const rows = flatten(view, "neon", {});

    expect(rows.some((r) => r.label === "neon-api")).toBe(true);
    expect(rows.some((r) => r.label === "Immich")).toBe(false);
});

test("a filter matches regardless of case", () => {
    expect(flatten(view, "IMMICH-WEB", {}).some((r) => r.label === "immich-web")).toBe(true);
});

test("filtering expands a collapsed group, or its match would be unreachable", () => {
    const rows = flatten(view, "immich-db", { 10: true });

    expect(rows.some((r) => r.label === "immich-db")).toBe(true);
});

test("a group whose own name matches keeps all of its children", () => {
    const rows = flatten(view, "neon", {});

    expect(rows.filter((r) => r.type === "monitor" && r.label === "neon-api").length).toBe(1);
});

test("an absent view yields no rows rather than throwing", () => {
    expect(flatten(null, "", {})).toEqual([]);
});
