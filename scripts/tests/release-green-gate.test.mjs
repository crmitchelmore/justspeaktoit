import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {digest} from '../release-train-lib.mjs';

// Alpha may ship before main CI finishes (10% broken is acceptable), but
// TestFlight and every Stable surface ship only a fully green main source.
const script=resolve('scripts/release-train.mjs');
const source='a'.repeat(40), baseline='b'.repeat(40);
const workflow=readFileSync(resolve('.github/workflows/alpha-release.yml'),'utf8');

function fixture(t, train, ciRun) {
 const root=mkdtempSync(join(tmpdir(),'release-green-'));
 t.after(()=>rmSync(root,{recursive:true,force:true}));
 const bin=join(root,'bin'); mkdirSync(bin);
 const entry={version:'3.2.0',build:'1000.0.1',baseline,notes:'n',notesHash:digest('n'),storeNotes:'s',storeNotesHash:digest('s')};
 const tag=train === 'alpha' ? 'alpha-build-1' : 'stable-candidate-1';
 const manifest={schema:1,train,tag,source,ordinal:1,build:'202611020001',dependenciesHash:digest('lock'),surfaces:{'mac-direct':{...entry,build:'202611020001'},ios:{...entry}}};
 writeFileSync(join(root,'state.json'),JSON.stringify({manifest,ciRun}));
 const harness=`#!${process.execPath}
import fs from 'node:fs';
import path from 'node:path';
const args=process.argv.slice(2), tool=path.basename(process.argv[1]);
const {manifest,ciRun}=JSON.parse(fs.readFileSync(path.join(process.env.FIXTURE_ROOT,'state.json'),'utf8'));
const out=v=>process.stdout.write(typeof v==='string'?v:JSON.stringify(v));
if(tool==='git') { if(args[0]==='for-each-ref') out(manifest); else if(args[0]==='rev-parse') out(manifest.source); else if(args[0]!=='merge-base') process.exit(3); }
else if(args[0]==='api' && args.includes('--paginate')) out([[]]);
else if(args[0]==='api' && args[1].includes('/actions/workflows/ci.yml/runs')) out({workflow_runs:ciRun?[{id:7,run_number:7,run_attempt:1,html_url:'https://example.test/ci',head_repository:{full_name:'owner/repo'},...ciRun}]:[]});
else process.exit(4);
`;
 for(const tool of ['git','gh']) writeFileSync(join(bin,tool),harness,{mode:0o755});
 const env={...process.env,PATH:bin+':'+process.env.PATH,FIXTURE_ROOT:root,GITHUB_REPOSITORY:'owner/repo',GITHUB_ENV:join(root,'env')};
 return (...args)=>spawnSync(process.execPath,[script,...args,'--tag',tag],{cwd:root,encoding:'utf8',env});
}
const green={status:'completed',conclusion:'success'}, running={status:'in_progress',conclusion:null}, red={status:'completed',conclusion:'failure'};

test('TestFlight requires a green main run, even for an Alpha',t=>{
 for(const ciRun of [running, red, null]) {
  const result=fixture(t,'alpha',ciRun)('configure','--surface','ios');
  assert.notEqual(result.status,0); assert.match(result.stderr,/No successful main CI/);
 }
 assert.doesNotMatch(fixture(t,'alpha',green)('configure','--surface','ios').stderr,/No successful main CI/);
});

test('every Stable surface requires a green main run',t=>{
 assert.match(fixture(t,'stable',running)('configure','--surface','mac-direct').stderr,/No successful main CI/);
});

test('the direct Mac Alpha may build before main CI finishes',t=>{
 assert.doesNotMatch(fixture(t,'alpha',running)('configure','--surface','mac-direct').stderr,/No successful main CI/);
});

test('a direct Alpha is not published once its main CI has failed',t=>{
 const failed=fixture(t,'alpha',red)('publish-alpha');
 assert.notEqual(failed.status,0); assert.match(failed.stderr,/Main CI failed/);
 for(const ciRun of [running, green, null]) {
  const result=fixture(t,'alpha',ciRun)('publish-alpha');
  assert.match(result.stderr,/No verified direct Alpha receipt/, 'reaches the receipt check');
 }
});

test('only the fast phase allocates before CI, and only green runs ship TestFlight, Windows and Flatpak',()=>{
 assert.match(workflow,/REQUIRE_CI=true\n\s+\[ "\$EVENT_NAME" = "push" \] && REQUIRE_CI=false/);
 assert.match(workflow,/--require-ci "\$REQUIRE_CI"/);
 assert.match(workflow,/green: \$\{\{ github\.event_name != 'push' \}\}/);
 for(const job of ['ios','windows-installer','linux-flatpak-repo']) {
  const body=workflow.split(`\n  ${job}:\n`)[1].split(/\n  [a-z-]+:\n/)[0];
  assert.match(body,/needs\.allocate\.outputs\.green == 'true'/,job);
 }
 assert.match(workflow,/group: alpha-\$\{\{ github\.event_name == 'push' && 'fast' \|\| github\.run_id \}\}\n  cancel-in-progress: false/);
});
