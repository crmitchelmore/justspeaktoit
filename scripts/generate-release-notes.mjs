#!/usr/bin/env node

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import {
    DEFAULT_MODEL,
    DEFAULT_REASONING_EFFORT,
    generateReleaseNotes,
    markdownToHTML,
} from "./release-notes-lib.mjs";

const valueAfter = (name) => {
    const index = process.argv.indexOf(name);
    return index === -1 ? undefined : process.argv[index + 1];
};
const tag = valueAfter("--tag") ?? process.env.GITHUB_REF_NAME;
const previousTag = valueAfter("--previous-tag");
const output = valueAfter("--output");
const htmlOutput = valueAfter("--html-output");
const repository = valueAfter("--repository") ?? process.env.GITHUB_REPOSITORY ?? "crmitchelmore/justspeaktoit";
const model = valueAfter("--model") ?? process.env.RELEASE_NOTES_MODEL ?? DEFAULT_MODEL;
const reasoningEffort = valueAfter("--reasoning-effort")
    ?? process.env.RELEASE_NOTES_REASONING_EFFORT
    ?? DEFAULT_REASONING_EFFORT;

if (!tag) {
    console.error("Usage: generate-release-notes.mjs --tag <tag> [--previous-tag <tag>] [--output <path>]");
    process.exit(2);
}

const result = await generateReleaseNotes({
    tag,
    previousTag,
    repository,
    apiKey: process.env.OPENAI_API_KEY,
    model,
    reasoningEffort,
    onFallback: (error) => console.error(`::warning::${error.message}; using deterministic release notes`),
});
if (output) {
    const outputPath = resolve(output);
    await mkdir(dirname(outputPath), { recursive: true });
    await writeFile(outputPath, result.notes, "utf8");
    console.error(`Wrote ${result.usedFallback ? "fallback" : "LLM"} release notes to ${outputPath}`);
} else {
    process.stdout.write(result.notes);
}
if (htmlOutput) {
    const htmlOutputPath = resolve(htmlOutput);
    await mkdir(dirname(htmlOutputPath), { recursive: true });
    await writeFile(htmlOutputPath, markdownToHTML(result.notes), "utf8");
    console.error(`Wrote Sparkle HTML release notes to ${htmlOutputPath}`);
}
