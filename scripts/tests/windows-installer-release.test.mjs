import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { bundleFileName, canPromote, installerReceipt, packageVersion, rehearsalTag,
    validateInstallerReceipt } from '../windows-installer-release.mjs';

const manifest = {tag: 'alpha-build-44', build: '202610301641', source: '4'.repeat(40)};
const publisher = 'CN=Example Ltd, O=Example Ltd, L=London, C=GB';
const release = 'https://github.com/crmitchelmore/justspeaktoit/releases/download/alpha-build-44/';

test('package versions mirror the Python helper and rise with the manifest build', () => {
    assert.equal(packageVersion('202610301641'), '2026.1030.1641.0');
    assert.equal(packageVersion('000000000000'), '0.0.0.0');
    assert.equal(packageVersion('999999999999'), '9999.9999.9999.0');
    for (const bad of ['20261030164', '2026103016410', '2026-1030-16', undefined]) assert.throws(() => packageVersion(bad));
    assert.equal(bundleFileName('2026.1030.1641.0'), 'JustSpeakToIt-windows_2026.1030.1641.0.msixbundle');
});

function signRecord(overrides = {}) {
    const directory = mkdtempSync(join(tmpdir(), 'installer-test-'));
    const sign = join(directory, 'sign.json');
    const appInstaller = join(directory, 'JustSpeakToIt.appinstaller');
    writeFileSync(sign, JSON.stringify({
        method: 'Azure Artifact Signing', publisher, certificate: {subject: publisher, thumbprint: 'A'.repeat(40)},
        timestampUrl: 'http://timestamp.acs.microsoft.com',
        signedBundle: {name: 'JustSpeakToIt-windows_2026.1030.1641.0.msixbundle', sha256: 'b'.repeat(64)},
        verification: {signed: true}, ...overrides}));
    writeFileSync(appInstaller, '<AppInstaller/>');
    return {sign, appInstaller};
}

test('the receipt records only an Artifact Signing signature by the bundle publisher', () => {
    const {sign, appInstaller} = signRecord();
    const recorded = installerReceipt(manifest, sign, appInstaller, '123');
    assert.equal(recorded.bundle.uri, release + 'JustSpeakToIt-windows_2026.1030.1641.0.msixbundle');
    assert.deepEqual(recorded.cleanInstall, {x64: {status: 'passed', run: 123}, arm64: {status: 'passed', run: 123}});
    assert.match(recorded.appInstaller.sha256, /^[0-9a-f]{64}$/);
    for (const bad of [
        {method: 'CI rehearsal certificate'}, {verification: {signed: false}},
        {certificate: {subject: 'CN=Someone Else'}},
        {signedBundle: {name: 'JustSpeakToIt-windows_2026.1030.1640.0.msixbundle', sha256: 'b'.repeat(64)}},
    ]) {
        const record = signRecord(bad);
        assert.throws(() => installerReceipt(manifest, record.sign, record.appInstaller, '123'), /signing record/);
    }
});

function receipt(overrides = {}) {
    return {schemaVersion: 1, tag: manifest.tag, build: manifest.build, source: manifest.source,
        version: '2026.1030.1641.0', publisher,
        bundle: {name: 'JustSpeakToIt-windows_2026.1030.1641.0.msixbundle',
            uri: release + 'JustSpeakToIt-windows_2026.1030.1641.0.msixbundle', sha256: 'b'.repeat(64)},
        appInstaller: {name: 'JustSpeakToIt.appinstaller', sha256: 'c'.repeat(64)},
        signing: {method: 'Azure Artifact Signing'},
        cleanInstall: {x64: {status: 'passed', run: 1}, arm64: {status: 'passed', run: 1}}, ...overrides};
}

test('a receipt needs a matching bundle, Artifact Signing and both clean installs', () => {
    assert.equal(validateInstallerReceipt(manifest, receipt()).version, '2026.1030.1641.0');
    for (const bad of [
        {tag: 'alpha-build-43'}, {version: '2026.1030.1641.1'}, {publisher: 'Example'},
        {signing: {method: 'CI rehearsal certificate'}},
        {bundle: {...receipt().bundle, uri: 'https://example.com/x.msixbundle'}},
        {cleanInstall: {x64: {status: 'passed', run: 1}}},
        {cleanInstall: {x64: {status: 'passed', run: 1}, arm64: {status: 'failed', run: 1}}},
    ]) assert.throws(() => validateInstallerReceipt(manifest, receipt(bad)), /installer/);
});

test('the public pointer only moves to a newer manifest build', () => {
    assert.ok(canPromote(null, {build: '202610301641'}));
    assert.ok(canPromote({build: '202610301640'}, {build: '202610301641'}));
    assert.ok(!canPromote({build: '202610301641'}, {build: '202610301641'}));
    assert.ok(!canPromote({build: '202610301700'}, {build: '202610301641'}));
});

function fakeReleases(pointer, qualified) {
    return (command, args) => {
        assert.equal(command, 'gh');
        if (args[1] === 'download') {
            writeFileSync(join(args[args.indexOf('--dir') + 1], 'alpha-pointer.json'), JSON.stringify({tag: pointer}));
            return '';
        }
        if (args[1] === 'view') {
            const assets = qualified.includes(args[2]) ? [{name: 'desktop-qualification.json'}] : [];
            return JSON.stringify({assets});
        }
        if (args[1] === 'list') {
            return JSON.stringify(['alpha-build-69', 'alpha-build-70', 'alpha-build-71', 'mac-v1.0.0']
                .map(tagName => ({tagName, isDraft: tagName === 'alpha-build-71'})));
        }
        throw Error(`unexpected gh ${args.join(' ')}`);
    };
}

test('rehearsals use the Alpha pointer when it is qualified', () => {
    assert.equal(rehearsalTag(fakeReleases('alpha-build-70', ['alpha-build-70'])), 'alpha-build-70');
});

test('rehearsals fall back to the newest published, qualified Alpha', () => {
    assert.equal(rehearsalTag(fakeReleases('alpha-build-70', ['alpha-build-69', 'alpha-build-71'])), 'alpha-build-69');
    assert.throws(() => rehearsalTag(fakeReleases('alpha-build-70', [])), /No qualified Alpha/);
});
