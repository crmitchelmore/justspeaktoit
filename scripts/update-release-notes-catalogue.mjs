#!/usr/bin/env node

// Updates the bundled in-app release-note catalogue
// (Sources/SpeakCore/Resources/ReleaseNotes.json).
//
// Release usage (runs before the app is archived so the shipped build contains
// the notes for its own version):
//
//   node scripts/update-release-notes-catalogue.mjs \
//     --version 2.46.0 --tag mac-v2.46.0 --notes-file "$RUNNER_TEMP/release-notes.md"
//
// Backfill from published GitHub releases (requires the `gh` CLI):
//
//   node scripts/update-release-notes-catalogue.mjs --backfill --limit 12

import { execFileSync } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import {
    DEFAULT_CATALOGUE_PATH,
    DEFAULT_ENTRY_LIMIT,
    buildCatalogue,
    catalogueEntry,
    mergeEntries,
    normaliseVersion,
    parseCatalogue,
    serialiseCatalogue,
} from "./release-notes-catalogue-lib.mjs";

const valueAfter = (name) => {
    const index = process.argv.indexOf(name);
    return index === -1 ? undefined : process.argv[index + 1];
};
const hasFlag = (name) => process.argv.includes(name);

const cataloguePath = resolve(valueAfter("--catalogue") ?? DEFAULT_CATALOGUE_PATH);
// A non-numeric --limit must stop the run: `Math.max(1, NaN)` is NaN, so the
// catalogue would otherwise be silently rewritten with no entries at all.
const requestedLimit = valueAfter("--limit");
const limit = hasFlag("--limit") ? Number.parseInt(requestedLimit ?? "", 10) : DEFAULT_ENTRY_LIMIT;
if (!Number.isFinite(limit) || limit < 1) {
    console.error(`--limit must be a positive whole number, got "${requestedLimit ?? ""}"`);
    process.exit(2);
}
const repository = valueAfter("--repository") ?? process.env.GITHUB_REPOSITORY ?? "crmitchelmore/justspeaktoit";

const readCatalogue = async () => {
    try {
        return parseCatalogue(await readFile(cataloguePath, "utf8"));
    } catch {
        return parseCatalogue(null);
    }
};

const gh = (args) => execFileSync("gh", args, { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });

const backfillEntries = () => {
    const releases = JSON.parse(gh([
        "release", "list",
        "--repo", repository,
        "--limit", `${Math.max(limit * 3, 30)}`,
        "--json", "tagName,publishedAt,isDraft",
    ]));
    return releases
        .filter((release) => !release.isDraft && release.tagName.startsWith("mac-v"))
        .slice(0, limit)
        .map((release) => {
            const { body } = JSON.parse(gh([
                "release", "view", release.tagName,
                "--repo", repository,
                "--json", "body",
            ]));
            return catalogueEntry({
                version: release.tagName,
                tag: release.tagName,
                publishedAt: release.publishedAt,
                markdown: body,
            });
        });
};

const singleEntry = async () => {
    const notesFile = valueAfter("--notes-file");
    const version = valueAfter("--version") ?? process.env.GITHUB_REF_NAME;
    if (!notesFile || !version) {
        console.error(
            "Usage: update-release-notes-catalogue.mjs --version <version> --notes-file <path> [--tag <tag>]"
            + "\n   or: update-release-notes-catalogue.mjs --backfill [--limit <count>]"
        );
        process.exit(2);
    }
    return [catalogueEntry({
        version,
        tag: valueAfter("--tag") ?? `mac-v${normaliseVersion(version)}`,
        publishedAt: valueAfter("--published-at"),
        markdown: await readFile(resolve(notesFile), "utf8"),
    })];
};

const incoming = hasFlag("--backfill") ? backfillEntries() : await singleEntry();
const existing = await readCatalogue();
const entries = mergeEntries(existing.entries, incoming, limit);
const catalogue = buildCatalogue({ entries });

await mkdir(dirname(cataloguePath), { recursive: true });
await writeFile(cataloguePath, serialiseCatalogue(catalogue), "utf8");
console.error(`Wrote ${entries.length} release-note entries to ${cataloguePath}`);
console.error(`Latest bundled version: ${entries[0]?.version ?? "none"}`);
