import assert from "node:assert/strict";
import test from "node:test";
import {
    buildPrompt,
    deterministicNotes,
    generateReleaseNotes,
    markdownToHTML,
    parseCommits,
    releaseTrack,
} from "../../scripts/release-notes-lib.mjs";

const context = {
    tag: "mac-v2.0.0",
    previousTag: "mac-v1.9.0",
    compareURL: "https://github.com/example/repo/compare/mac-v1.9.0...mac-v2.0.0",
    fileSummary: "2 files changed",
    commits: [
        { sha: "abc", subject: "feat(mac): add history search", body: "Search past transcripts." },
        { sha: "def", subject: "fix: prevent an empty transcript", body: "" },
    ],
};

test("parseCommits preserves subjects and multi-line bodies", () => {
    const commits = parseCommits("abc\x1ffeat: useful change\x1fLine one\nLine two\x1e");
    assert.deepEqual(commits, [{ sha: "abc", subject: "feat: useful change", body: "Line one\nLine two" }]);
});

test("deterministic fallback groups conventional commits", () => {
    const notes = deterministicNotes(context);
    assert.match(notes, /### New and improved\n- add history search/);
    assert.match(notes, /### Fixes\n- prevent an empty transcript/);
    assert.match(notes, /\*\*Full changelog:\*\*/);
});

test("prompt asks for detailed user-facing notes and isolates source data", () => {
    const prompt = buildPrompt(context);
    assert.match(prompt, /Begin with \"## Overview\"/);
    assert.match(prompt, /why users should care/);
    assert.match(prompt, /<release-data>/);
    assert.match(prompt, /Search past transcripts/);
});

test("generator requests Luna medium and appends the changelog", async () => {
    let request;
    const fetchImpl = async (_url, options) => {
        request = JSON.parse(options.body);
        return {
            ok: true,
            json: async () => ({
                output: [{
                    type: "message",
                    content: [{
                        type: "output_text",
                        text: "## Overview\n\nThis release makes transcript history easier to use and prevents empty results.\n\n## Highlights\n\n- Search past transcripts more quickly.",
                    }],
                }],
            }),
        };
    };

    const result = await generateReleaseNotes({ context, apiKey: "test", fetchImpl });
    assert.equal(request.model, "gpt-5.6-luna");
    assert.deepEqual(request.reasoning, { effort: "medium" });
    assert.match(result.notes, /Full changelog/);
    assert.match(result.notes, /model=gpt-5\.6-luna effort=medium/);
    assert.equal(result.usedFallback, false);
});

test("generator falls back without an API key", async () => {
    const result = await generateReleaseNotes({ context });
    assert.equal(result.usedFallback, true);
    assert.match(result.notes, /### New and improved/);
    assert.match(result.notes, /fallback=deterministic/);
});

test("release tracks keep macOS, iOS, and legacy histories separate", () => {
    assert.equal(releaseTrack("mac-v2.0.0"), "mac");
    assert.equal(releaseTrack("ios-v2.0.0"), "ios");
    assert.equal(releaseTrack("v0.1.0"), "legacy");
});

test("Markdown notes are converted to safe Sparkle HTML", () => {
    const html = markdownToHTML("## Overview\n\nA safer & **clearer** update.\n\n- First change\n- Second change\n");
    assert.match(html, /<h2>Overview<\/h2>/);
    assert.match(html, /A safer &amp; <strong>clearer<\/strong> update\./);
    assert.match(html, /<ul>\n<li>First change<\/li>/);
    assert.doesNotMatch(html, /## Overview/);
});
