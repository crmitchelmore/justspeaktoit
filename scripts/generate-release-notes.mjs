#!/usr/bin/env node

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import {
    cumulativeSparkleHTML,
    DEFAULT_MODEL,
    DEFAULT_REASONING_EFFORT,
    fetchPublishedSparkleReleases,
    generateReleaseNotes,
    markdownToHTML,
    releaseTrack,
} from "./release-notes-lib.mjs";

const valueAfter = (name) => {
    const index = process.argv.indexOf(name);
    return index === -1 ? undefined : process.argv[index + 1];
};
const tag = valueAfter("--tag") ?? process.env.GITHUB_REF_NAME;
const previousTag = valueAfter("--previous-tag");
const output = valueAfter("--output");
const htmlOutput = valueAfter("--html-output");
const buildNumber = valueAfter("--build-number");
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
    let html = markdownToHTML(result.notes);
    if (buildNumber && releaseTrack(tag) === "mac") {
        try {
            const warnings = [];
            const history = await fetchPublishedSparkleReleases({
                repository,
                token: process.env.GH_TOKEN ?? process.env.GITHUB_TOKEN,
                onWarning: (warning) => warnings.push(warning),
            });
            warnings.forEach((warning) => console.error(`::warning::${warning}`));
            html = cumulativeSparkleHTML({
                releases: [{
                    tag,
                    version: tag.slice("mac-v".length),
                    buildNumber,
                    markdown: result.notes,
                }, ...history],
                fullReleaseNotesURL: `https://github.com/${repository}/releases`,
            });
        } catch (error) {
            console.error(`::warning::Could not build cumulative Sparkle notes: ${error.message}`);
        }
    }
    await writeFile(htmlOutputPath, html, "utf8");
    console.error(`Wrote Sparkle HTML release notes to ${htmlOutputPath}`);
}
