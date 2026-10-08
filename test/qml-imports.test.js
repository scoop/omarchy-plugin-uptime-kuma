// Qt 6.12's QtQuick ships its own Color type, which hides the qs.Commons
// Color singleton: every bare `Color.x` then reads as undefined.
import { test, expect } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..");
const files = readdirSync(ROOT).filter((name) => name.endsWith(".qml"));

for (const name of files) {
    const source = readFileSync(join(ROOT, name), "utf8").replace(/\/\/.*$/gm, "");

    test(`${name} reaches Color only through the Commons namespace`, () => {
        expect(source.match(/(?<![\w.])Color\.\w+/g) ?? []).toEqual([]);
        if (source.includes("Commons.Color")) {
            expect(source).toMatch(/^import qs\.Commons as Commons$/m);
        }
    });
}
