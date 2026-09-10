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

test("a Problems section is announced, then its monitors", () => {
    const rows = flatten(view, "", {});

    expect(rows[0]).toEqual({
        type: "section",
        id: "problems",
        label: "Problems",
        detail: "",
        status: "down",
        error: "",
        monitor: null,
        selectable: false,
    });
    expect(rows[1].id).toBe(1);
    expect(rows[1].type).toBe("monitor");
});

test("a problem row names the group it came from, since it was pulled out of it", () => {
    expect(flatten(view, "", {})[1].detail).toBe("Immich");
});

test("the tree is introduced by its own section header", () => {
    const rows = flatten(view, "", {});
    const section = rows.find((r) => r.type === "section" && r.id === "monitors");

    expect(section.label).toBe("Monitors");
    expect(rows.indexOf(section)).toBeLessThan(rows.findIndex((r) => r.type === "group"));
});

test("with nothing wrong, there is no Problems section at all", () => {
    const healthy = { ...view, problems: [] };
    const rows = flatten(healthy, "", {});

    expect(rows.some((r) => r.id === "problems")).toBe(false);
    expect(rows[0].id).toBe("monitors");
});

test("section rows are not selectable", () => {
    const rows = flatten(view, "", {});

    expect(rows.filter((r) => r.selectable === false).every((r) => r.type === "section")).toBe(
        true,
    );
    expect(rows.find((r) => r.type === "monitor").selectable).toBe(true);
});

test("groups follow, each carrying how many of its children are down", () => {
    const rows = flatten(view, "", {});
    const immich = rows.find((r) => r.type === "group" && r.id === 10);

    expect(immich.detail).toBe("1 down / 2");
});

test("groups are folded shut by default, so a healthy instance is a short list", () => {
    const rows = flatten(view, "", {});

    expect(rows.some((r) => r.type === "group" && r.id === 10)).toBe(true);
    expect(rows.some((r) => r.type === "monitor" && r.id === 2)).toBe(false);
});

test("an opened group shows its children", () => {
    const rows = flatten(view, "", { 10: true });

    expect(rows.some((r) => r.type === "monitor" && r.id === 2)).toBe(true);
});

test("ungrouped monitors are listed after the groups", () => {
    const rows = flatten(view, "", { 10: true, 20: true });
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

test("filtering opens a folded group, or its match would be unreachable", () => {
    const rows = flatten(view, "immich-db", {});

    expect(rows.some((r) => r.label === "immich-db")).toBe(true);
});

test("a group whose own name matches keeps all of its children", () => {
    const rows = flatten(view, "neon", {});

    expect(rows.filter((r) => r.type === "monitor" && r.label === "neon-api").length).toBe(1);
});

test("an absent view yields no rows rather than throwing", () => {
    expect(flatten(null, "", {})).toEqual([]);
});

test("a healthy group shows only how many monitors it holds", () => {
    const rows = flatten(view, "", {});

    expect(rows.find((r) => r.type === "group" && r.id === 20).detail).toBe("1");
});

test("a monitor row carries the monitor itself, for the detail the pane shows", () => {
    const rows = flatten(view, "", { 10: true });
    const row = rows.find((r) => r.type === "monitor" && r.id === 2);

    expect(row.monitor).toBe(view.groups[0].children[1]);
});

test("nothing but a monitor row has a monitor to detail", () => {
    const rows = flatten(view, "", { 10: true });

    expect(rows.find((r) => r.type === "section").monitor).toBe(null);
    expect(rows.find((r) => r.type === "group").monitor).toBe(null);
});
