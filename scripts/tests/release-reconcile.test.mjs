import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,mkdirSync,readFileSync,rmSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {execFileSync} from 'node:child_process';

test('reconciliation sees active sources beyond page one and bounds recoverable catch-up', t=>{
 const root=mkdtempSync(join(tmpdir(),'release-reconcile-'));
 t.after(()=>rmSync(root,{recursive:true,force:true}));
 const bin=join(root,'bin');mkdirSync(bin);mkdirSync(join(root,'Config'));
 writeFileSync(join(root,'Config/ReleasePipeline.json'),JSON.stringify({enabled:true}));
 const log=join(root,'calls');
 writeFileSync(join(bin,'git'),'#!/bin/sh\nif [ "$1" = log ]; then echo adoption; fi\n',{mode:0o755});
 writeFileSync(join(bin,'gh'),`#!/usr/bin/env node
const fs=require('node:fs');const a=process.argv.slice(2);
fs.appendFileSync(process.env.CALL_LOG,JSON.stringify(a)+'\\n');
if(a[0]==='workflow') process.exit(0);
const path=a.at(-1);
if(path.includes('/releases?')) console.log('[[]]');
else if(path.includes('/ci.yml/')) console.log(JSON.stringify([{workflow_runs:[5,4,3,2,1,0].map(n=>({head_sha:'source'+n}))}]));
else if(path.includes('/alpha-release.yml/')) {
 const pages=[{workflow_runs:Array.from({length:100},(_,n)=>({status:'in_progress',display_title:'unrelated'+n}))},{workflow_runs:[{status:'queued',display_title:'Alpha source0'}]}];
 console.log(JSON.stringify(a.includes('--paginate')?pages:pages[0]));
} else process.exit(2);
`,{mode:0o755});
 execFileSync(process.execPath,[resolve('scripts/release-train.mjs'),'reconcile'],{
  cwd:root,env:{...process.env,PATH:bin+':'+process.env.PATH,CALL_LOG:log},stdio:'pipe'});
 const calls=readFileSync(log,'utf8').trim().split('\n').map(JSON.parse);
 const dispatches=calls.filter(a=>a[0]==='workflow').map(a=>a.at(-1));
 assert.deepEqual(dispatches,['source=source1','source=source2','source=source3']);
 assert.equal(calls.filter(a=>a[0]==='release').length,0,'undispatched sources are not marked delivered');
});
