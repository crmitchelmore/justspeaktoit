import assert from "node:assert/strict";
import test from "node:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
    appcastBuildNumber,
    buildPrompt,
    collectReleaseContext,
    commitPlatform,
    cumulativeSparkleHTML,
    deterministicNotes,
    fetchPublishedSparkleReleases,
    filterCommitsForTrack,
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

test("commit platform classification reads Conventional Commit scopes", () => {
    assert.equal(commitPlatform("feat(ios): add keyboard themes"), "ios");
    assert.equal(commitPlatform("fix(mac)!: rework the updater"), "mac");
    assert.equal(commitPlatform("perf(macos): faster launch"), "mac");
    assert.equal(commitPlatform("feat(mac,ios): shared history"), "shared");
    assert.equal(commitPlatform("fix: unscoped shared change"), "shared");
    assert.equal(commitPlatform("chore(deps): bump Sparkle"), "shared");
    assert.equal(commitPlatform("Merge branch 'main'"), "shared");
});

test("track filtering drops only the other platform's commits", () => {
    const commits = [
        { sha: "a", subject: "feat(mac): menu bar polish" },
        { sha: "b", subject: "fix(ios): keyboard crash" },
        { sha: "c", subject: "feat: shared transcription engine" },
        { sha: "d", subject: "perf(mac,ios): faster model load" },
    ];
    assert.deepEqual(filterCommitsForTrack(commits, "mac").map((commit) => commit.sha), ["a", "c", "d"]);
    assert.deepEqual(filterCommitsForTrack(commits, "ios").map((commit) => commit.sha), ["b", "c", "d"]);
    assert.deepEqual(filterCommitsForTrack(commits, "legacy"), commits);
});

test("mac release context excludes iOS-only commits from the prompt and fallback notes", () => {
    const repo = mkdtempSync(join(tmpdir(), "release-notes-test-"));
    const git = (...args) => execFileSync(
        "git",
        ["-c", "user.name=Test", "-c", "user.email=test@example.com", ...args],
        { cwd: repo, encoding: "utf8" }
    );
    try {
        git("init", "--initial-branch=main");
        writeFileSync(join(repo, "file.txt"), "one\n");
        git("add", "file.txt");
        git("commit", "-m", "chore: initial import");
        git("tag", "mac-v1.0.0");
        writeFileSync(join(repo, "file.txt"), "two\n");
        git("commit", "-am", "feat(mac): add dictation window");
        writeFileSync(join(repo, "file.txt"), "three\n");
        git("commit", "-am", "feat(ios): add keyboard themes");
        writeFileSync(join(repo, "file.txt"), "four\n");
        git("commit", "-am", "fix: stop dropping the final word");
        git("tag", "mac-v1.1.0");

        const releaseContext = collectReleaseContext({ tag: "mac-v1.1.0", cwd: repo });
        assert.equal(releaseContext.previousTag, "mac-v1.0.0");
        assert.deepEqual(releaseContext.commits.map((commit) => commit.subject), [
            "feat(mac): add dictation window",
            "fix: stop dropping the final word",
        ]);
        assert.doesNotMatch(buildPrompt(releaseContext), /keyboard themes/);
        assert.doesNotMatch(deterministicNotes(releaseContext), /keyboard themes/);
    } finally {
        rmSync(repo, { recursive: true, force: true });
    }
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
