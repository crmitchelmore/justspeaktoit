import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {spawnSync} from 'node:child_process';

const script = resolve('scripts/release-train.mjs');
const workflowPath = resolve('.github/workflows/alpha-release.yml');
const source = '1'.repeat(40);
const parent = '2'.repeat(40);
const tagObjectSha = '3'.repeat(40);

function fixture(t, {tagShaResponse = tagObjectSha, failRefCreate = false} = {}) {
    const root = mkdtempSync(join(tmpdir(), 'alpha-tag-allocation-'));
    t.after(() => rmSync(root, {recursive: true, force: true}));
    const bin = join(root, 'bin');
    mkdirSync(bin);
    mkdirSync(join(root, 'Config'));
    writeFileSync(join(root, 'Config', 'ReleasePipeline.json'), JSON.stringify({
        versions: {mac: '3.2.0', ios: '3.2.0'},
        publishedBaselines: {ios: null, 'mac-store': null}
    }));

    const harness = `#!${process.execPath}
import fs from 'node:fs';
import path from 'node:path';

const root = process.env.FIXTURE_ROOT;
const args = process.argv.slice(2);
const tool = path.basename(process.argv[1]);
fs.appendFileSync(path.join(root, 'commands.jsonl'), JSON.stringify({tool, args}) + '\\n');
const tagsPath = path.join(root, 'tags.json');
const tags = fs.existsSync(tagsPath) ? JSON.parse(fs.readFileSync(tagsPath, 'utf8')) : {};
const result = value => process.stdout.write(typeof value === 'string' ? value : JSON.stringify(value));

if (tool === 'git') {
    if (args[0] === 'tag' && args[1] === '--list') {
        result(Object.keys(tags).join('\\n'));
    } else if (args[0] === 'rev-parse') {
        const arg = args.at(-1);
        result(arg === '${source}^1' ? '${parent}' : '${source}');
    } else if (args[0] === 'merge-base') {
        // Ancestor check succeeds cleanly.
    } else if (args[0] === 'show') {
        result('lock');
    } else if (args[0] === 'log') {
        result('${source}\\x1ffix(ci): allocate via git data api\\x1f\\x1e');
    } else if (args[0] === 'ls-tree') {
        result('');
    } else if (args[0] === 'fetch' && args[1] === '--no-tags') {
        const refSpec = args.at(-1);
        const tag = refSpec.split(':')[0].split('/').at(-1);
        const pendingPath = path.join(root, 'pending-tag.json');
        if (fs.existsSync(pendingPath)) {
            const pending = JSON.parse(fs.readFileSync(pendingPath, 'utf8'));
            if (pending.tag === tag) {
                tags[tag] = pending.message;
                fs.writeFileSync(tagsPath, JSON.stringify(tags));
            }
        }
    } else if (args[0] === 'for-each-ref') {
        const tag = args.at(-1).split('/').at(-1);
        if (!tags[tag]) throw Error('Missing fetched tag: ' + tag);
        result(tags[tag]);
    } else {
        throw Error('Unexpected git command: ' + args.join(' '));
    }
} else if (tool === 'gh') {
    if (args[0] === 'api') {
        const methodIndex = args.indexOf('--method');
        const method = methodIndex < 0 ? 'GET' : args[methodIndex + 1];
        const endpoint = methodIndex < 0 ? args[1] : args[methodIndex + 2];
        if (args.includes('--paginate')) {
            result([[]]);
        } else if (endpoint.includes('/actions/workflows/ci.yml/runs')) {
            result({
                workflow_runs: [{
                    id: 99,
                    run_number: 99,
                    run_attempt: 1,
                    html_url: 'https://example.test/ci/99',
                    status: 'completed',
                    conclusion: 'success',
                    head_repository: {full_name: 'owner/repo'}
                }]
            });
        } else if (method === 'POST' && endpoint === 'repos/owner/repo/git/tags') {
            const payload = JSON.parse(fs.readFileSync(args[args.indexOf('--input') + 1], 'utf8'));
            fs.writeFileSync(path.join(root, 'tag-payload.json'), JSON.stringify(payload));
            fs.writeFileSync(path.join(root, 'pending-tag.json'), JSON.stringify({tag: payload.tag, message: payload.message}));
            result({sha: process.env.TAG_SHA_RESPONSE});
        } else if (method === 'POST' && endpoint === 'repos/owner/repo/git/refs') {
            const payload = JSON.parse(fs.readFileSync(args[args.indexOf('--input') + 1], 'utf8'));
            fs.writeFileSync(path.join(root, 'ref-payload.json'), JSON.stringify(payload));
            if (process.env.FAIL_REF_CREATE === '1') {
                process.stderr.write('ref creation failed');
                process.exit(1);
            }
            result({ref: payload.ref, object: {sha: payload.sha}});
        } else {
            throw Error('Unexpected gh api call: ' + args.join(' '));
        }
    } else if (args[0] === 'release' && args[1] === 'create') {
        fs.copyFileSync(args[3], path.join(root, 'created-release-manifest.json'));
        result('created release');
    } else {
        throw Error('Unexpected gh command: ' + args.join(' '));
    }
}
`;

    for (const tool of ['git', 'gh']) {
        writeFileSync(join(bin, tool), harness, {mode: 0o755});
    }
    const outputFile = join(root, 'github-output');
    const run = () => spawnSync(
        process.execPath,
        [script, 'allocate', '--source', source, '--rebuild', 'false', '--require-ci', 'true'],
        {
            cwd: root,
            encoding: 'utf8',
            env: {
                ...process.env,
                PATH: `${bin}:${process.env.PATH}`,
                FIXTURE_ROOT: root,
                GITHUB_REPOSITORY: 'owner/repo',
                GITHUB_OUTPUT: outputFile,
                RUNNER_TEMP: root,
                TAG_SHA_RESPONSE: tagShaResponse,
                FAIL_REF_CREATE: failRefCreate ? '1' : '0'
            }
        }
    );
    const commands = () => readFileSync(join(root, 'commands.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
    return {root, run, commands, output: () => readFileSync(outputFile, 'utf8')};
}

test('allocate creates immutable annotated tag via Git Data API without git push', t => {
    const f = fixture(t);
    const result = f.run();
    assert.equal(result.status, 0, result.stderr);
    assert.equal(f.output(), `tag=alpha-build-1\nsource=${source}\n`);

    const tagPayload = JSON.parse(readFileSync(join(f.root, 'tag-payload.json'), 'utf8'));
    assert.equal(tagPayload.tag, 'alpha-build-1');
    assert.equal(tagPayload.object, source);
    assert.equal(tagPayload.type, 'commit');
    assert.equal(tagPayload.tagger.name, 'github-actions[bot]');
    assert.equal(tagPayload.tagger.email, 'github-actions[bot]@users.noreply.github.com');
    assert.match(tagPayload.tagger.date, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    const parsedManifest = JSON.parse(tagPayload.message);
    assert.equal(parsedManifest.tag, 'alpha-build-1');
    assert.equal(parsedManifest.source, source);

    const refPayload = JSON.parse(readFileSync(join(f.root, 'ref-payload.json'), 'utf8'));
    assert.equal(refPayload.ref, 'refs/tags/alpha-build-1');
    assert.equal(refPayload.sha, tagObjectSha);

    const commands = f.commands();
    assert.ok(commands.every(c => !(c.tool === 'git' && (c.args[0] === 'push' || (c.args[0] === 'tag' && c.args[1] === '-a')))));
    assert.ok(commands.some(c => c.tool === 'git' && c.args[0] === 'fetch' && c.args.includes('refs/tags/alpha-build-1:refs/tags/alpha-build-1')));
    assert.ok(commands.some(c => c.tool === 'gh' && c.args[0] === 'release' && c.args[1] === 'create' && c.args[2] === 'alpha-build-1'));
});

test('allocate fails closed when Git Data API returns an invalid tag SHA', t => {
    const f = fixture(t, {tagShaResponse: 'not-a-sha'});
    const result = f.run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Failed to create annotated tag object for alpha-build-1/);
    const commands = f.commands();
    assert.ok(commands.every(c => !c.args.includes('repos/owner/repo/git/refs')));
    assert.ok(commands.every(c => !(c.tool === 'gh' && c.args[0] === 'release' && c.args[1] === 'create')));
});

test('allocate fails closed when git ref creation fails before creating a release', t => {
    const f = fixture(t, {failRefCreate: true});
    const result = f.run();
    assert.notEqual(result.status, 0);
    const commands = f.commands();
    assert.ok(commands.every(c => !(c.tool === 'gh' && c.args[0] === 'release' && c.args[1] === 'create')));
});

test('alpha-release workflow allocates with GITHUB_TOKEN without elevated workflow token', () => {
    const workflow = readFileSync(workflowPath, 'utf8');
    assert.match(workflow, /GH_TOKEN:\s+\$\{\{\s*github\.token\s*\}\}/);
    assert.ok(!workflow.includes('workflows: write'));
});
