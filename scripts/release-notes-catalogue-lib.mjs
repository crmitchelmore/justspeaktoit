// Shared helpers for the bundled in-app release-note catalogue.
//
// The catalogue is a small JSON file compiled into SpeakCore's resource bundle
// so the app can show the notes for the installed version offline. It is built
// from the same Markdown that `generate-release-notes.mjs` produces for the
// GitHub release, so there is a single release-note source.

export const CATALOGUE_SCHEMA_VERSION = 2;
export const DEFAULT_CATALOGUE_PATH = "Sources/SpeakCore/Resources/ReleaseNotes.json";
export const DEFAULT_ENTRY_LIMIT = 12;
export const RELEASE_PLATFORMS = Object.freeze(["mac", "ios"]);

export const normalisePlatform = (value) => {
    const platform = String(value ?? "").trim().toLowerCase();
    if (!RELEASE_PLATFORMS.includes(platform)) {
        throw new Error(`Release-note platform must be mac or ios, got "${value ?? ""}"`);
    }
    return platform;
};

export const platformForTag = (tag, fallback = "mac") => {
    const match = String(tag ?? "").trim().match(/^(mac|ios)-v/i);
    return match ? match[1].toLowerCase() : normalisePlatform(fallback);
};

export const normaliseVersion = (value) => String(value ?? "")
    .trim()
    .replace(/^(mac|ios)-/i, "")
    .replace(/^v/i, "")
    .trim();

const versionComponents = (value) => normaliseVersion(value)
    .split(/[.\-+]/)
    .map((part) => Number.parseInt(part, 10))
    .filter((part) => Number.isFinite(part));

/** Newest first: returns a negative number when `a` is the more recent version. */
export const compareVersions = (a, b) => {
    const left = versionComponents(a);
    const right = versionComponents(b);
    const length = Math.max(left.length, right.length);
    for (let index = 0; index < length; index += 1) {
        const difference = (right[index] ?? 0) - (left[index] ?? 0);
        if (difference !== 0) return difference;
    }
    return normaliseVersion(b).localeCompare(normaliseVersion(a));
};

/**
 * Removes release-page furniture that is meaningless inside the app: the
 * generator's HTML provenance comment and the compare-URL footer, in both the
 * generator's `**Full changelog:**` form and GitHub's auto-generated
 * `**Full Changelog**:` form.
 */
export const sanitiseNotes = (markdown) => String(markdown ?? "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .split("\n")
    .filter((line) => !/^\s*\*\*Full\s+changelog:?\*\*:?/i.test(line))
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

export const catalogueEntry = ({ platform, version, tag, publishedAt, markdown }) => {
    const resolvedVersion = normaliseVersion(version ?? tag);
    if (!resolvedVersion) throw new Error("A release-note entry needs a version");
    const resolvedPlatform = normalisePlatform(platform ?? platformForTag(tag));
    const notes = sanitiseNotes(markdown);
    if (!notes) throw new Error(`Release notes for ${resolvedVersion} were empty`);
    return {
        platform: resolvedPlatform,
        version: resolvedVersion,
        tag: tag ?? `${resolvedPlatform}-v${resolvedVersion}`,
        publishedAt: publishedAt ?? new Date().toISOString(),
        markdown: notes,
    };
};

export const mergeEntries = (existing, incoming, limit = DEFAULT_ENTRY_LIMIT) => {
    const byPlatformVersion = new Map();
    const add = (entry) => {
        if (!entry?.version) return;
        const platform = normalisePlatform(entry.platform ?? platformForTag(entry.tag));
        const version = normaliseVersion(entry.version);
        byPlatformVersion.set(`${platform}:${version}`, { ...entry, platform, version });
    };
    for (const entry of existing ?? []) {
        add(entry);
    }
    for (const entry of incoming ?? []) {
        add(entry);
    }
    const counts = new Map();
    return [...byPlatformVersion.values()]
        .sort((a, b) => compareVersions(a.version, b.version) || a.platform.localeCompare(b.platform))
        .filter((entry) => {
            const count = counts.get(entry.platform) ?? 0;
            counts.set(entry.platform, count + 1);
            return count < Math.max(1, limit);
        });
};

export const buildCatalogue = ({ entries, generatedAt = new Date().toISOString() }) => ({
    schemaVersion: CATALOGUE_SCHEMA_VERSION,
    generatedAt,
    entries,
});

export const parseCatalogue = (json) => {
    if (!json) return { schemaVersion: CATALOGUE_SCHEMA_VERSION, entries: [] };
    const parsed = typeof json === "string" ? JSON.parse(json) : json;
    return { ...parsed, entries: Array.isArray(parsed.entries) ? parsed.entries : [] };
};

export const serialiseCatalogue = (catalogue) => `${JSON.stringify(catalogue, null, 2)}\n`;
