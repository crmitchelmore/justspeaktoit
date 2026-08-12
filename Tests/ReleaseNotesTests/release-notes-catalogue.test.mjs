import assert from "node:assert/strict";
import test from "node:test";
import {
    buildCatalogue,
    catalogueEntry,
    compareVersions,
    mergeEntries,
    normaliseVersion,
    parseCatalogue,
    sanitiseNotes,
    serialiseCatalogue,
} from "../../scripts/release-notes-catalogue-lib.mjs";

test("versions normalise across tag families", () => {
    assert.equal(normaliseVersion("mac-v2.45.0"), "2.45.0");
    assert.equal(normaliseVersion("ios-v0.9.1"), "0.9.1");
    assert.equal(normaliseVersion(" v1.2.3 "), "1.2.3");
});

test("versions sort newest first using numeric components", () => {
    const versions = ["2.9.0", "2.41.1", "2.10.0", "2.41.0"].sort(compareVersions);
    assert.deepEqual(versions, ["2.41.1", "2.41.0", "2.10.0", "2.9.0"]);
});

test("release-page furniture is stripped from bundled notes", () => {
    const notes = sanitiseNotes([
        "## Overview",
        "",
        "Faster startup.",
        "",
        "**Full changelog:** https://github.com/example/repo/compare/mac-v1...mac-v2",
        "",
        "<!-- release-notes: model=gpt-5.6-luna effort=medium -->",
        "",
    ].join("\n"));

    assert.equal(notes, "## Overview\n\nFaster startup.");
});

test("entries default their tag and reject empty notes", () => {
    const entry = catalogueEntry({ version: "2.46.0", publishedAt: "2026-08-09T00:00:00Z", markdown: "## Overview\n\nNew." });
    assert.deepEqual(entry, {
        version: "2.46.0",
        tag: "mac-v2.46.0",
        publishedAt: "2026-08-09T00:00:00Z",
        markdown: "## Overview\n\nNew.",
    });
    assert.throws(() => catalogueEntry({ version: "2.46.0", markdown: "<!-- only a comment -->" }), /empty/);
    assert.throws(() => catalogueEntry({ markdown: "## Overview" }), /version/);
});

test("merging replaces a version in place, orders newest first and honours the limit", () => {
    const existing = [
        { version: "2.44.0", tag: "mac-v2.44.0", publishedAt: "b", markdown: "old" },
        { version: "2.43.0", tag: "mac-v2.43.0", publishedAt: "a", markdown: "older" },
    ];
    const merged = mergeEntries(existing, [
        { version: "2.44.0", tag: "mac-v2.44.0", publishedAt: "b", markdown: "regenerated" },
        { version: "2.45.0", tag: "mac-v2.45.0", publishedAt: "c", markdown: "newest" },
    ], 2);

    assert.deepEqual(merged.map((entry) => entry.version), ["2.45.0", "2.44.0"]);
    assert.equal(merged[1].markdown, "regenerated");
});

test("catalogue round-trips through the shipped JSON shape", () => {
    const catalogue = buildCatalogue({
        entries: [catalogueEntry({ version: "mac-v2.45.0", markdown: "## Overview\n\nShipped." })],
        generatedAt: "2026-08-09T00:00:00Z",
    });
    const parsed = parseCatalogue(serialiseCatalogue(catalogue));

    assert.equal(parsed.schemaVersion, 1);
    assert.equal(parsed.generatedAt, "2026-08-09T00:00:00Z");
    assert.deepEqual(parsed.entries.map((entry) => entry.version), ["2.45.0"]);
    assert.deepEqual(parseCatalogue(null).entries, []);
});
