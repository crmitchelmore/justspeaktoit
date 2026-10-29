import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {chmodSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {basename, join} from 'node:path';
import {backfillDesktopDownloads, publishDesktopDownloads} from '../publish-desktop-downloads.mjs';
import {desktopDownloads, desktopWorkflows} from '../desktop-release-lib.mjs';
import {digest} from '../release-train-lib.mjs';

const repo = process.env.GITHUB_REPOSITORY ?? 'crmitchelmore/justspeaktoit';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');

// No child processes, network, real Git tags or releases: the command boundary
// supplies artifact files and captures the actual bytes offered for upload.
function fixture() {
    const source = 'a'.repeat(40);
    const entry = {version:'3.2.0', build:'1001', baseline:'b'.repeat(40),
        notes:'Frozen', notesHash:digest('Frozen'), storeNotes:'Short', storeNotesHash:digest('Short')};
    const manifest = {schema:1, train:'alpha', tag:'alpha-build-2', ordinal:2, source,
        dependenciesHash:digest('lock'), build:'202610281200',
        surfaces:Object.fromEntries(['mac-direct','mac-store','ios'].map(s => [s, {...entry}]))};
    manifest.surfaces['mac-direct'].build = manifest.build;
    const runs = Object.fromEntries(desktopWorkflows.map((workflow, index) => [workflow,
        {id:index+1, head_sha:source, head_branch:'main', event:'push', status:'completed',
            conclusion:'success', repository:repo, path:`.github/workflows/${workflow}`, run_attempt:1}]));
    const live = Object.fromEntries(Object.values(runs).map(run => [run.id,
        {...run, head_repository:{full_name:repo}}]));
    const artifacts = Object.fromEntries(desktopDownloads.map(spec => {
        const bytes = Buffer.from(`bundle-${spec.architecture}`);
        const file = spec.kind === 'windows' ? `bundle-${spec.architecture}.zip` : 'JustSpeakToIt-x86_64.flatpak';
        const evidence = spec.kind === 'windows' ? {application:{sourceCommit:source},
            architecture:spec.architecture, zip:{name:file, sha256:hash(bytes)}} :
            {sourceSHA:source, builtRevision:source, bundleSHA256:hash(bytes)};
        return [spec.artifact, {spec, bytes, file, evidence}];
    }));
    const state = {manifest, runs, live, artifacts, target:source,
        receipt:{status:'verified', source, tag:manifest.tag, build:manifest.build, runs},
        commands:[], uploads:[], failUpload:undefined, receiptFailures:0};
    state.command = (command, args) => {
        state.commands.push([command, ...args]);
        if (command === 'git' && args[0] === 'for-each-ref') return JSON.stringify(state.manifest);
        if (command === 'git' && args[0] === 'rev-parse') return state.target;
        assert.equal(command, 'gh');
        if (args[0] === 'api') {
            const id = Number(args[1].match(/\/runs\/(\d+)/)?.[1]);
            if (!args[1].includes('/artifacts')) return JSON.stringify(state.live[id]);
            const spec = desktopDownloads.find(item => state.runs[item.workflow].id === id);
            return JSON.stringify({artifacts:[{name:spec.artifact, expired:false}]});
        }
        if (args[0] === 'run' && args[1] === 'download') {
            const item = state.artifacts[args[args.indexOf('--name')+1]];
            const directory = args[args.indexOf('--dir')+1];
            mkdirSync(directory, {recursive:true});
            writeFileSync(join(directory, item.spec.kind === 'windows' ? 'bundle-evidence.json' : 'build-provenance.json'),
                JSON.stringify(item.evidence));
            // Deliberately independent of the untrusted name in evidence.
            writeFileSync(join(directory, item.file), item.bytes);
            return '';
        }
        if (args[0] === 'release' && args[1] === 'download') {
            writeFileSync(join(args[args.indexOf('--dir')+1], 'desktop-qualification.json'), JSON.stringify(state.receipt));
            return '';
        }
        if (args[0] === 'release' && args[1] === 'upload') {
            const name = basename(args[3]);
            if (state.failUpload === name) throw Error('Synthetic upload failure');
            if (name === 'desktop-qualification.json' && state.receiptFailures > 0) {
                state.receiptFailures--;
                if (state.blockRestoreWrite) chmodSync(args[3], 0o400);
                state.receipt = undefined; // Model gh --clobber deleting the old asset first.
                throw Error('Synthetic receipt upload failure');
            }
            const bytes = readFileSync(args[3]);
            state.uploads.push({tag:args[2], name, bytes});
            if (name === 'desktop-qualification.json') state.receipt = JSON.parse(bytes);
            return '';
        }
        assert.fail(`Unexpected command: ${command} ${args.join(' ')}`);
    };
    return state;
}

test('backfill publishes accurate download records and upgrades legacy attempts idempotently', () => {
    const f = fixture();
    for (const run of Object.values(f.runs)) delete run.run_attempt;
    f.live[1].run_attempt = 2;
    const first = backfillDesktopDownloads(f.manifest.tag, f.command);
    assert.equal(f.uploads.length, 4);
    assert.equal(f.uploads.at(-1).name, 'desktop-qualification.json');
    assert.equal(first.runs[desktopWorkflows[0]].run_attempt, 2);
    assert.equal(first.checkedAt, f.receipt.checkedAt);
    for (const spec of desktopDownloads) {
        const item = f.artifacts[spec.artifact];
        assert.deepEqual(first.downloads[spec.asset], {workflow:spec.workflow,
            run:f.runs[spec.workflow].id, architecture:spec.architecture,
            bytes:item.bytes.length, sha256:hash(item.bytes)});
        assert.deepEqual(f.uploads.find(x => x.name === spec.asset).bytes, item.bytes);
    }
    const second = backfillDesktopDownloads(f.manifest.tag, f.command);
    assert.deepEqual(second.downloads, first.downloads);
    assert.deepEqual(second.runs, first.runs);
    assert.equal(f.uploads.length, 8);
    assert.ok(f.uploads.every(x => x.tag === f.manifest.tag));
});

test('requested tag and its source are admitted before any GitHub operation', () => {
    for (const mismatch of ['tag', 'source']) {
        const f = fixture();
        if (mismatch === 'tag') { f.manifest.tag = 'alpha-build-3'; f.manifest.ordinal = 3; }
        else f.target = 'b'.repeat(40);
        assert.throws(() => backfillDesktopDownloads('alpha-build-2', f.command), /Manifest source mismatch/);
        assert.equal(f.commands.filter(x => x[0] === 'gh').length, 0);
        assert.equal(f.uploads.length, 0);
    }
});

test('all five live workflows must match stored run identity, source, attempt and successful admission', () => {
    const patches = [{id:999}, {head_sha:'b'.repeat(40)}, {head_repository:{full_name:'fork/repo'}},
        {path:'.github/workflows/other.yml'}, {event:'pull_request'}, {head_branch:'branch'},
        {status:'in_progress', conclusion:null}, {conclusion:'failure'}, {conclusion:'cancelled'},
        {run_attempt:2}, {run_attempt:undefined}];
    for (const workflow of desktopWorkflows) for (const patch of patches) {
        const f = fixture();
        Object.assign(f.live[f.runs[workflow].id], patch);
        assert.throws(() => backfillDesktopDownloads(f.manifest.tag, f.command), /Desktop qualification/);
        assert.equal(f.uploads.length, 0);
        assert.equal(f.commands.filter(x => x[0] === 'gh' && x[1] === 'run').length, 0);
        assert.equal(f.commands.filter(x => x[2]?.includes('/artifacts')).length, 0);
    }
});

test('invalid stored qualification is rejected before live queries or publication', () => {
    const f = fixture();
    f.runs[desktopWorkflows.at(-1)].conclusion = 'failure';
    assert.throws(() => publishDesktopDownloads(f.manifest, f.runs, f.command), /Desktop qualification/);
    assert.equal(f.commands.length, 0);
});

test('metadata-selected filenames are rejected before reading them, with no partial publication', () => {
    for (const name of ['../outside.zip', '/outside.zip', '..\\outside.zip', 'sub/file.zip', null]) {
        const f = fixture();
        f.artifacts[desktopDownloads[1].artifact].evidence.zip.name = name;
        // An attempted read would throw ENOENT instead of this evidence error.
        assert.throws(() => backfillDesktopDownloads(f.manifest.tag, f.command), /bundle evidence does not match/);
        assert.equal(f.uploads.length, 0);
    }
});

test('all payload digests are verified before any upload', () => {
    for (const spec of desktopDownloads) {
        const f = fixture();
        f.artifacts[spec.artifact].bytes = Buffer.from('corrupt payload');
        assert.throws(() => backfillDesktopDownloads(f.manifest.tag, f.command), /payload digest/);
        assert.equal(f.uploads.length, 0);
    }
});

test('a failed asset upload never publishes a successful receipt', () => {
    const f = fixture();
    f.failUpload = desktopDownloads[1].asset;
    assert.throws(() => backfillDesktopDownloads(f.manifest.tag, f.command), /Synthetic upload failure/);
    assert.equal(f.uploads.filter(x => x.name === 'desktop-qualification.json').length, 0);
    assert.equal(f.receipt.downloads, undefined);
});


test('failed replacement restores the exact prior receipt bytes and still fails publication', () => {
    const f = fixture();
    const original = JSON.stringify(f.receipt);
    f.receiptFailures = 1;
    assert.throws(() => backfillDesktopDownloads(f.manifest.tag, f.command), /Synthetic receipt upload failure/);
    assert.equal(JSON.stringify(f.receipt), original);
    assert.equal(f.uploads.at(-1).bytes.toString(), original);
    assert.equal(f.commands.filter(x => x[1] === 'release' && x[2] === 'upload' &&
        x[4].endsWith('/desktop-qualification.json')).length, 2);
});

test('failed receipt restoration reports both failures without returning a verified receipt', () => {
    const f = fixture();
    f.receiptFailures = 2;
    assert.throws(() => backfillDesktopDownloads(f.manifest.tag, f.command), error => {
        assert.ok(error instanceof AggregateError);
        assert.equal(error.errors.length, 2);
        assert.ok(error.errors.every(item => item.message === 'Synthetic receipt upload failure'));
        return true;
    });
    assert.equal(f.receipt, undefined);
});


test('failed local receipt restoration retains the original upload failure', () => {
    const f = fixture();
    f.receiptFailures = 1;
    f.blockRestoreWrite = true;
    assert.throws(() => backfillDesktopDownloads(f.manifest.tag, f.command), error => {
        assert.ok(error instanceof AggregateError);
        assert.equal(error.errors.length, 2);
        assert.equal(error.errors[0].message, 'Synthetic receipt upload failure');
        assert.equal(error.errors[1].code, 'EACCES');
        return true;
    });
    assert.equal(f.receipt, undefined);
});
