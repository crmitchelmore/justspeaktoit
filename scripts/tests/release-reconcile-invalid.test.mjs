import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,mkdirSync,readFileSync,rmSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {execFileSync} from 'node:child_process';
import {digest} from '../release-train-lib.mjs';

function reconcile(t, {surface='ios', status='invalid', mismatch}={}) {
 const root=mkdtempSync(join(tmpdir(),'release-invalid-'));
 t.after(()=>rmSync(root,{recursive:true,force:true}));
 const bin=join(root,'bin');mkdirSync(bin);mkdirSync(join(root,'Config'));
 writeFileSync(join(root,'Config/ReleasePipeline.json'),JSON.stringify({enabled:true}));
 const source='a'.repeat(40);
 const item={version:'3.2.0',build:'1000.0.41',baseline:'f'.repeat(40),
  notes:'Frozen notes',notesHash:digest('Frozen notes'),storeNotes:'Frozen review',storeNotesHash:digest('Frozen review')};
 const manifest={schema:1,train:'alpha',tag:'alpha-build-41',source,ordinal:41,
  dependenciesHash:digest('lock'),build:'202610270543',surfaces:{
   'mac-direct':{...item,build:'202610270543'},'mac-store':{...item},ios:{...item}}};
 const receipt={source,build:manifest.surfaces[surface].build,notesHash:item.notesHash,status};
 if(mismatch) receipt[mismatch]='different';
 const fixture=join(root,'fixture.json'), log=join(root,'calls');
 writeFileSync(fixture,JSON.stringify({manifest,receipt,surface}));
 writeFileSync(join(bin,'git'),`#!/usr/bin/env node
const f=require(process.env.FIXTURE);const a=process.argv.slice(2);
if(a[0]==='log') console.log('adoption');
else if(a[0]==='for-each-ref') console.log(JSON.stringify(f.manifest));
else if(a[0]==='rev-parse') console.log(f.manifest.source);
`,{mode:0o755});
 writeFileSync(join(bin,'gh'),`#!/usr/bin/env node
const fs=require('node:fs');const f=require(process.env.FIXTURE);const a=process.argv.slice(2);
fs.appendFileSync(process.env.CALL_LOG,JSON.stringify(a)+'\\n');
if(a[0]==='workflow') process.exit(0);
const path=a.find(x=>x.startsWith('repos/'));
if(path.includes('/releases?')) console.log(JSON.stringify([[{
 tag_name:f.manifest.tag,draft:true,assets:[{name:f.surface+'-receipt.json',id:41}]
}]]));
else if(path.includes('/releases/assets/')) console.log(JSON.stringify(f.receipt));
else if(path.includes('/ci.yml/')) console.log(JSON.stringify([{workflow_runs:
 ['a','b','c','d','e'].map((s,i)=>({run_number:10-i,head_sha:s.repeat(40)}))
}]));
else if(path.includes('/alpha-release.yml/')) console.log('[{"workflow_runs":[]}]');
else process.exit(2);
`,{mode:0o755});
 const output=execFileSync(process.execPath,[resolve('scripts/release-train.mjs'),'reconcile'],{
  cwd:root,env:{...process.env,PATH:bin+':'+process.env.PATH,FIXTURE:fixture,CALL_LOG:log},encoding:'utf8'});
 const calls=readFileSync(log,'utf8').trim().split('\n').map(JSON.parse);
 return {output,calls,dispatches:calls.filter(a=>a[0]==='workflow').map(a=>a.at(-1))};
}

test('source-bound invalid ios skips frozen retry without consuming newer-source slots',t=>{
 const result=reconcile(t,{surface:'ios'});
 assert.deepEqual(result.dispatches,['b','c','d'].map(s=>'source='+s.repeat(40)));
 assert.match(result.output,/invalid Apple upload requires an explicit new build attempt/);
 assert.equal(result.calls.some(a=>a[0]==='release'),false,'retain existing release evidence');
});

test('a retired mac-store receipt neither blocks nor suppresses its source',t=>{
 const result=reconcile(t,{surface:'mac-store'});
 assert.deepEqual(result.dispatches,['a','b','c'].map(s=>'source='+s.repeat(40)));
 assert.doesNotMatch(result.output,/invalid Apple upload requires/);
});

for(const mismatch of ['source','build','notesHash']) {
 test(`an invalid receipt with mismatched ${mismatch} cannot suppress its source`,t=>{
  const result=reconcile(t,{mismatch});
  assert.deepEqual(result.dispatches,['a','b','c'].map(s=>'source='+s.repeat(40)));
  assert.doesNotMatch(result.output,/invalid Apple upload requires/);
 });
}

for(const status of ['processing','beta_processing']) {
 test(`${status} remains eligible for normal catch-up`,t=>{
  assert.deepEqual(reconcile(t,{status}).dispatches,['a','b','c'].map(s=>'source='+s.repeat(40)));
 });
}

test('direct build failure is not classified as a terminal Apple upload',t=>{
 assert.deepEqual(reconcile(t,{surface:'mac-direct'}).dispatches,['a','b','c'].map(s=>'source='+s.repeat(40)));
});
