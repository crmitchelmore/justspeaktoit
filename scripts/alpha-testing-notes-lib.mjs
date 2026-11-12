// Human checks run after merge, on the first Alpha that contains them. A
// check belongs to the change that added it to Docs/manual-checks.yml, so the
// "Please test" section lists the checks whose ids are new since the previous
// Alpha delivered on that surface.
import { catalogueItems, loadCatalogue } from '../landing-page/qa/manual-checks.mjs';

export const CATALOGUE_PATH = 'Docs/manual-checks.yml';
export const QA_URL = 'https://justspeaktoit.com/qa';
export const MAX_LISTED_CHECKS = 6;

const DEVICES = { mac: ['Mac'], ios: ['iPhone', 'Watch'] };

// Ids only, so an older catalogue that no longer validates still counts.
export const catalogueIds = (source) => new Set(
    [...String(source ?? '').matchAll(/^\s*- id: "([a-z0-9-]+)"\s*$/gm)].map((match) => match[1]),
);

// `owner-` items are owner setup tasks and decisions need the owner, so
// neither is shown to Alpha testers.
export const newAlphaChecks = ({ previous, current, platform }) => {
    let catalogue;
    try {
        catalogue = loadCatalogue(String(current ?? ''));
    } catch {
        return [];
    }
    const before = catalogueIds(previous);
    return Object.values(catalogueItems(catalogue)).filter((item) => item.kind === 'check'
        && DEVICES[platform]?.includes(item.device)
        && !item.id.startsWith('owner-')
        && !before.has(item.id));
};

// The newest earlier Alpha whose delivery receipt for this surface exists and
// whose source is an ancestor. Superseded or undelivered builds don't count,
// so their checks carry forward to the next build testers actually receive.
export const previousDeliveredSource = ({ manifests, releases, surface, source, isAncestor }) => {
    const delivered = new Set(releases
        .filter((release) => release.assets?.some((asset) => asset.name === `${surface}-receipt.json`))
        .map((release) => release.tag_name));
    return [...manifests]
        .filter((manifest) => manifest.train === 'alpha' && manifest.source !== source && delivered.has(manifest.tag))
        .sort((a, b) => b.ordinal - a.ordinal)
        .find((manifest) => isAncestor(manifest.source, source))?.source ?? null;
};

export const pleaseTestMarkdown = (checks) => {
    if (!checks.length) return '';
    const listed = checks.slice(0, MAX_LISTED_CHECKS).map((item) => `- **${item.title}** (about ${item.minutes} min): ${QA_URL}#${item.id}`);
    const more = checks.length - listed.length;
    return [
        '## Please test',
        'New human checks in this Alpha. Each link has the steps and expected result; report problems in a GitHub issue.',
        ...listed,
        ...(more > 0 ? [`- ${more} more: ${QA_URL}`] : []),
    ].join('\n');
};
