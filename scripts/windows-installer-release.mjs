#!/usr/bin/env node
// Moves the qualified Windows runtime bundles of one Alpha or Stable candidate
// manifest into the signed beta installer, and advances the public installer
// pointer only after the published App Installer route installs on clean
// x64 and ARM64 runners.
//
//   sources <manifest-tag> <dir>        download both qualified runtime bundles
//   rehearsal-tag                       the current Alpha (for unsigned rehearsals)
//   receipt <manifest-tag> <sign.json> <appinstaller> <run> <out>
//                                       record a signed, clean-installed release
//   promote <manifest-tag> <receipt>    advance windows-installer-pointer.json
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runReleaseCommand as run } from './release-command.mjs';
import { validateManifest } from './release-train-lib.mjs';
import { desktopDownloadFile, desktopDownloads, liveArtifact, validateDesktopReceipt,
    verifyDesktopDownload } from './desktop-release-lib.mjs';

const repo = process.env.GITHUB_REPOSITORY ?? 'crmitchelmore/justspeaktoit';
const json = path => JSON.parse(readFileSync(path, 'utf8'));
export const pointerAsset = 'windows-installer-pointer.json';
export const appInstallerAsset = 'JustSpeakToIt.appinstaller';
export const receiptAsset = 'windows-installer.json';
export const runtimePolicyPath = 'scripts/windows-bundle/runtime-policy.json';
const tagPattern = /^(alpha-build|stable-candidate)-[1-9][0-9]*$/;

// Mirrors windows_installer.package_version: a 12-digit YYYYMMDDhhmm build
// becomes YYYY.MMDD.hhmm.0, so package versions rise with manifest builds.
export function packageVersion(build) {
    if (!/^[0-9]{12}$/.test(build ?? '')) throw Error(`Manifest build must have 12 digits: ${build}`);
    return [build.slice(0, 4), build.slice(4, 8), build.slice(8, 12)].map(part => String(Number(part))).join('.') + '.0';
}

export function bundleFileName(version) { return `JustSpeakToIt-windows_${version}.msixbundle`; }

export function readManifest(tag, command = run) {
    if (!tagPattern.test(tag ?? '')) throw Error('Immutable manifest tag required');
    const manifest = validateManifest(JSON.parse(command('git', ['for-each-ref', '--format=%(contents)', `refs/tags/${tag}`])));
    if (manifest.tag !== tag || command('git', ['rev-parse', `${tag}^{commit}`]) !== manifest.source) {
        throw Error('Manifest source mismatch');
    }
    return manifest;
}

export function windowsSources(tag, directory, command = run) {
    const gh = (...args) => command('gh', args);
    const manifest = readManifest(tag, command);
    const scratch = mkdtempSync(join(tmpdir(), 'windows-installer-'));
    try {
        gh('release', 'download', tag, '--repo', repo, '--pattern', 'desktop-qualification.json', '--dir', scratch);
        const receipt = validateDesktopReceipt(manifest, json(join(scratch, 'desktop-qualification.json')), repo);
        const sources = {schemaVersion: 1, tag, build: manifest.build, source: manifest.source,
            version: packageVersion(manifest.build), bundles: {}};
        for (const spec of desktopDownloads.filter(item => item.kind === 'windows')) {
            const published = receipt.downloads?.[spec.asset];
            const runID = receipt.runs[spec.workflow]?.id;
            if (!published || published.run !== runID) throw Error(`${tag} did not publish ${spec.asset} from its qualified run`);
            const listed = JSON.parse(gh('api', `repos/${repo}/actions/runs/${runID}/artifacts?per_page=100`));
            if (!liveArtifact(listed.artifacts, spec.artifact)) {
                throw Error(`${spec.workflow} run ${runID} has no live ${spec.artifact}; rebuild the manifest to package it`);
            }
            const target = join(directory, spec.architecture);
            mkdirSync(target, {recursive: true});
            gh('run', 'download', String(runID), '--repo', repo, '--name', spec.artifact, '--dir', target);
            const evidence = json(join(target, 'bundle-evidence.json'));
            const built = receipt.runs[spec.workflow].head_sha;
            const file = desktopDownloadFile(spec, manifest, evidence, built);
            const sha256 = createHash('sha256').update(readFileSync(join(target, file))).digest('hex');
            verifyDesktopDownload(spec, manifest, evidence, sha256, built);
            // The installer must hold the same bytes the developer download published.
            if (sha256 !== published.sha256) throw Error(`${spec.asset} differs from the bytes ${tag} published`);
            sources.bundles[spec.architecture] = {workflow: spec.workflow, run: runID, commit: built, artifact: spec.artifact, zip: file, sha256};
        }
        writeFileSync(join(directory, 'sources.json'), JSON.stringify(sources, null, 2) + '\n');
        return sources;
    } finally {
        rmSync(scratch, {recursive: true, force: true});
    }
}

export function rehearsalTag(command = run) {
    const scratch = mkdtempSync(join(tmpdir(), 'windows-installer-'));
    try {
        command('gh', ['release', 'download', 'alpha-latest', '--repo', repo, '--pattern', 'alpha-pointer.json', '--dir', scratch]);
        const {tag} = json(join(scratch, 'alpha-pointer.json'));
        if (!/^alpha-build-[1-9][0-9]*$/.test(tag ?? '')) throw Error('Invalid Alpha pointer');
        // The pointer can name an Alpha whose desktop qualification failed or
        // has not finished, or whose bundles were assembled under an older
        // runtime policy, which the current packaging tools reject. Rehearse
        // the newest published Alpha that is both qualified and compatible;
        // with none, report '' so the workflow skips the rehearsal.
        const qualified = name => JSON.parse(command('gh', ['release', 'view', name, '--repo', repo, '--json', 'assets']))
            .assets.some(asset => asset.name === 'desktop-qualification.json');
        const compatible = name => {
            try {
                command('git', ['diff', '--quiet', `${name}^{commit}`, 'HEAD', '--', runtimePolicyPath]);
                return true;
            } catch {
                return false;
            }
        };
        const usable = name => qualified(name) && compatible(name);
        if (usable(tag)) return tag;
        const candidates = JSON.parse(command('gh', ['release', 'list', '--repo', repo, '--limit', '40',
            '--json', 'tagName,isDraft']))
            .filter(release => !release.isDraft && /^alpha-build-[1-9][0-9]*$/.test(release.tagName))
            .map(release => release.tagName)
            .sort((a, b) => Number(b.slice(12)) - Number(a.slice(12)));
        const fallback = candidates.find(usable) ?? '';
        console.error(fallback
            ? `Alpha pointer ${tag} is unqualified or predates the runtime policy; rehearsing ${fallback}`
            : `No qualified Alpha matches the current runtime policy (pointer ${tag}); skipping the rehearsal`);
        return fallback;
    } finally {
        rmSync(scratch, {recursive: true, force: true});
    }
}

export function validateInstallerReceipt(manifest, receipt) {
    const version = packageVersion(manifest.build);
    const bundle = bundleFileName(version);
    const base = `https://github.com/${repo}/releases/download/${manifest.tag}/`;
    if (receipt?.schemaVersion !== 1 || receipt.tag !== manifest.tag || receipt.build !== manifest.build ||
        receipt.source !== manifest.source || receipt.version !== version || receipt.bundle?.name !== bundle ||
        receipt.bundle?.uri !== base + bundle || !/^[0-9a-f]{64}$/.test(receipt.bundle?.sha256 ?? '') ||
        receipt.appInstaller?.name !== appInstallerAsset || !/^[0-9a-f]{64}$/.test(receipt.appInstaller?.sha256 ?? '') ||
        typeof receipt.publisher !== 'string' || !receipt.publisher.startsWith('CN=') ||
        receipt.signing?.method !== 'Azure Artifact Signing') {
        throw Error('Invalid Windows installer receipt');
    }
    for (const architecture of ['x64', 'arm64']) {
        const check = receipt.cleanInstall?.[architecture];
        if (check?.status !== 'passed' || !Number.isSafeInteger(check.run)) {
            throw Error(`Windows installer has no passing ${architecture} clean install`);
        }
    }
    return receipt;
}

// Called only after both clean-install jobs passed in workflow run `run`.
export function installerReceipt(manifest, signPath, appInstallerPath, runID) {
    const tag = manifest.tag;
    const signed = json(signPath);
    const version = packageVersion(manifest.build);
    const name = bundleFileName(version);
    if (signed.signedBundle?.name !== name || signed.method !== 'Azure Artifact Signing' ||
        signed.verification?.signed !== true || signed.publisher !== signed.certificate?.subject) {
        throw Error('The signing record does not describe this release');
    }
    const run = Number(runID);
    const receipt = {schemaVersion: 1, tag, build: manifest.build, source: manifest.source, version,
        publisher: signed.publisher,
        bundle: {name, uri: `https://github.com/${repo}/releases/download/${tag}/${name}`, sha256: signed.signedBundle.sha256},
        appInstaller: {name: appInstallerAsset,
            sha256: createHash('sha256').update(readFileSync(appInstallerPath)).digest('hex')},
        signing: {method: signed.method, certificate: signed.certificate, timestampUrl: signed.timestampUrl,
            account: signed.account},
        cleanInstall: {x64: {status: 'passed', run}, arm64: {status: 'passed', run}}};
    return validateInstallerReceipt(manifest, receipt);
}

// Advances only to a newer manifest build, so a delayed or re-run older
// release can never move the public installer backwards.
export function canPromote(current, receipt) { return !current || BigInt(receipt.build) > BigInt(current.build); }

export function promote(tag, receiptPath, command = run) {
    const gh = (...args) => command('gh', args);
    const manifest = readManifest(tag, command);
    const receipt = validateInstallerReceipt(manifest, json(receiptPath));
    const scratch = mkdtempSync(join(tmpdir(), 'windows-installer-'));
    try {
        let current = null;
        const release = JSON.parse(gh('release', 'view', 'alpha-latest', '--repo', repo, '--json', 'assets'));
        if (release.assets?.some(asset => asset.name === pointerAsset)) {
            gh('release', 'download', 'alpha-latest', '--repo', repo, '--pattern', pointerAsset, '--dir', scratch);
            current = json(join(scratch, pointerAsset));
        }
        if (!canPromote(current, receipt)) {
            console.log(`Installer pointer stays at ${current.tag}; ${tag} is not newer.`);
            return current;
        }
        const pointer = {schemaVersion: 1, tag, build: receipt.build, version: receipt.version, publisher: receipt.publisher,
            bundle: receipt.bundle, appInstaller: receipt.appInstaller};
        const path = join(scratch, 'next', pointerAsset);
        mkdirSync(join(scratch, 'next'));
        writeFileSync(path, JSON.stringify(pointer, null, 2) + '\n');
        gh('release', 'upload', 'alpha-latest', path, '--repo', repo, '--clobber');
        console.log(`Windows installer now points at ${tag} (${receipt.version}).`);
        return pointer;
    } finally {
        rmSync(scratch, {recursive: true, force: true});
    }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
    const [command, ...args] = process.argv.slice(2);
    if (command === 'sources') console.log(JSON.stringify(windowsSources(args[0], args[1])));
    else if (command === 'rehearsal-tag') console.log(rehearsalTag());
    else if (command === 'receipt') writeFileSync(args[4], JSON.stringify(installerReceipt(readManifest(args[0]), ...args.slice(1, 4)), null, 2) + '\n');
    else if (command === 'promote') promote(args[0], args[1]);
    else if (command === 'version') console.log(packageVersion(args[0]));
    else { console.error('usage: windows-installer-release.mjs sources|rehearsal-tag|promote|version'); process.exit(2); }
}
