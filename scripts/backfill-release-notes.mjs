#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
    DEFAULT_MODEL,
    DEFAULT_REASONING_EFFORT,
    generateReleaseNotes,
} from "./release-notes-lib.mjs";

const hasFlag = (flag) => process.argv.includes(flag);
const valueAfter = (name) => {
    const index = process.argv.indexOf(name);
    return index === -1 ? undefined : process.argv[index + 1];
};
const repository = valueAfter("--repository") ?? "crmitchelmore/justspeaktoit";
const outputDirectory = resolve(
    valueAfter("--output-dir") ?? join(tmpdir(), "justspeaktoit-release-notes-backfill"),
);
const apply = hasFlag("--apply");
const force = hasFlag("--force");
const model = valueAfter("--model") ?? DEFAULT_MODEL;
const reasoningEffort = valueAfter("--reasoning-effort") ?? DEFAULT_REASONING_EFFORT;
const onlyTag = valueAfter("--tag");

const gh = (args) => execFileSync("gh", args, {
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
}).trim();
const releaseLines = gh([
    "api",
    "--paginate",
    `repos/${repository}/releases`,
    "--jq",
    ".[] | @base64",
]).split("\n").filter(Boolean);
const releases = releaseLines
    .map((line) => JSON.parse(Buffer.from(line, "base64").toString("utf8")))
    .filter((release) => !release.draft)
    .sort((left, right) => new Date(left.published_at ?? left.created_at) - new Date(right.published_at ?? right.created_at));

const queue = releases
    .filter((release) => !onlyTag || release.tag_name === onlyTag)
    .map((release) => ({ release }));

await mkdir(outputDirectory, { recursive: true });
console.error(`${apply ? "Backfilling" : "Generating"} ${queue.length} release(s) with ${model} (${reasoningEffort})`);

let updated = 0;
let skipped = 0;
for (const [index, item] of queue.entries()) {
    const tag = item.release.tag_name;
    const outputPath = resolve(outputDirectory, `${tag.replaceAll("/", "_")}.md`);
    let notes;
    if (!force) {
        try {
            notes = await readFile(outputPath, "utf8");
        } catch {
            // Generate below.
        }
    }

    if (!notes) {
        try {
            const result = await generateReleaseNotes({
                tag,
                repository,
                apiKey: process.env.OPENAI_API_KEY,
                model,
                reasoningEffort,
                onFallback: (error) => console.error(`  warning: ${error.message}; using deterministic notes`),
            });
            notes = result.notes;
            await writeFile(outputPath, notes, "utf8");
        } catch (error) {
            console.error(`[${index + 1}/${queue.length}] ${tag}: skipped (${error.message})`);
            skipped += 1;
            continue;
        }
    }

    if (apply) {
        gh(["release", "edit", tag, "--repo", repository, "--notes-file", outputPath]);
        updated += 1;
        console.error(`[${index + 1}/${queue.length}] ${tag}: updated`);
    } else {
        console.error(`[${index + 1}/${queue.length}] ${tag}: generated ${outputPath}`);
    }
}
console.error(`Finished: ${updated} updated, ${skipped} skipped, ${queue.length - updated - skipped} generated only`);
