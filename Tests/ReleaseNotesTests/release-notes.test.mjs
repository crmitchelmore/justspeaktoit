import assert from "node:assert/strict";
import test from "node:test";
import {
    appcastBuildNumber,
    buildPrompt,
    cumulativeSparkleHTML,
    deterministicNotes,
    fetchPublishedSparkleReleases,
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

test("Sparkle notes show every intervening release and compact entries after the newest two", () => {
    const html = cumulativeSparkleHTML({
        releases: [
            {
                tag: "mac-v2.1.0",
                version: "2.1.0",
                buildNumber: "202608120900",
                markdown: [
                    "## Overview",
                    "",
                    "Older summary.",
                    "",
                    "## Highlights",
                    "",
                    "- First key item",
                    "- Second key item",
                    "- Third key item",
                    "- Fourth detail omitted from the compact view",
                ].join("\n"),
            },
            {
                tag: "mac-v2.3.0",
                version: "2.3.0",
                buildNumber: "202608140900",
                markdown: "## Overview\n\nNewest detail.\n\n## Highlights\n\n- Newest feature\n",
            },
            {
                tag: "mac-v2.2.0",
                version: "2.2.0",
                buildNumber: "202608130900",
                markdown: "## Overview\n\nPrevious detail.\n\n## Fixes\n\n- Previous fix\n",
            },
        ],
        fullReleaseNotesURL: "https://github.com/example/repo/releases?view=all&kind=\"stable\"",
    });

    assert.match(html, /data-sparkle-version="202608140900"/);
    assert.match(html, /data-sparkle-version="202608130900"/);
    assert.match(html, /data-sparkle-version="202608120900"/);
    assert.ok(html.indexOf("202608140900") < html.indexOf("202608130900"));
    assert.ok(html.indexOf("202608130900") < html.indexOf("202608120900"));
    assert.match(html, /sparkle-installed-version ~ \.release \{ display: none; \}/);
    assert.match(html, /Newest feature/);
    assert.match(html, /Previous fix/);
    assert.match(html, /Older summary/);
    assert.match(html, /<h3>Key changes<\/h3>/);
    assert.doesNotMatch(html, /Fourth detail omitted/);
    assert.match(html, /View full release notes/);
    assert.match(html, /releases\?view=all&amp;kind=&quot;stable&quot;/);
});

test("appcast build extraction rejects display versions and malformed values", () => {
    assert.equal(appcastBuildNumber("<sparkle:version>202608140900</sparkle:version>"), "202608140900");
    assert.equal(appcastBuildNumber("<sparkle:shortVersionString>2.3.0</sparkle:shortVersionString>"), undefined);
    assert.equal(appcastBuildNumber("<sparkle:version>2.3.0</sparkle:version>"), undefined);
});

test("published Sparkle history keeps stable macOS releases with usable appcasts", async () => {
    const warnings = [];
    const releases = await fetchPublishedSparkleReleases({
        repository: "example/repo",
        token: "placeholder",
        onWarning: (warning) => warnings.push(warning),
        fetchImpl: async (url, options) => {
            if (url.includes("/releases?")) {
                return new Response(JSON.stringify([
                    {
                        tag_name: "mac-v2.2.0",
                        body: "## Overview\n\nA useful update.\n\n**Full changelog:** https://example.test/compare",
                        draft: false,
                        prerelease: false,
                        assets: [{ name: "appcast.xml", url: "https://api.example.test/assets/22" }],
                    },
                    {
                        tag_name: "ios-v2.2.0",
                        body: "iOS only",
                        draft: false,
                        prerelease: false,
                        assets: [],
                    },
                    {
                        tag_name: "mac-v2.1.0",
                        body: "",
                        draft: false,
                        prerelease: false,
                        assets: [{ name: "appcast.xml", url: "https://api.example.test/assets/21" }],
                    },
                ]), { status: 200 });
            }
            assert.equal(options.headers.Accept, "application/octet-stream");
            const buildNumber = url.endsWith("/22") ? "202608130900" : "202608120900";
            return new Response(`<sparkle:version>${buildNumber}</sparkle:version>`, { status: 200 });
        },
    });

    assert.deepEqual(releases, [
        {
            tag: "mac-v2.2.0",
            version: "2.2.0",
            buildNumber: "202608130900",
            markdown: "## Overview\n\nA useful update.",
        },
        {
            tag: "mac-v2.1.0",
            version: "2.1.0",
            buildNumber: "202608120900",
            markdown: "See the full release notes for details.",
        },
    ]);
    assert.deepEqual(warnings, [
        "mac-v2.1.0 has no release body; using a history-link placeholder",
    ]);
});

test("published Sparkle history fails closed when an installed-build marker cannot be recovered", async () => {
    await assert.rejects(
        fetchPublishedSparkleReleases({
            repository: "example/repo",
            fetchImpl: async () => new Response(JSON.stringify([{
                tag_name: "mac-v2.1.0",
                body: "Notes without build metadata",
                draft: false,
                prerelease: false,
                assets: [],
            }]), { status: 200 }),
        }),
        /mac-v2\.1\.0 has no appcast\.xml asset/
    );
});
