import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,mkdirSync,readFileSync,rmSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {execFileSync} from 'node:child_process';
import {digest,surfaces} from '../release-train-lib.mjs';

test('failed publication withdraws only the candidate approved by this workflow run', t=>{
 const root=mkdtempSync(join(tmpdir(),'release-withdraw-'));t.after(()=>rmSync(root,{recursive:true,force:true}));
 const git=(...args)=>execFileSync('git',args,{cwd:root,encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();
 git('init');git('config','user.name','Test');git('config','user.email','test@example.invalid');git('commit','--allow-empty','-m','fixture');
 const source=git('rev-parse','HEAD');
 const entry={version:'1.9.0',build:'1001',baseline:source,notes:'Frozen',notesHash:digest('Frozen'),storeNotes:'Frozen',storeNotesHash:digest('Frozen')};
 const m={schema:1,train:'stable',tag:'stable-candidate-1',source,ordinal:1,dependenciesHash:digest('lock'),build:'202609091400',surfaces:Object.fromEntries(surfaces.map(s=>[s,{...entry}]))};
 m.surfaces['mac-direct'].build=m.build;
 const bytes=JSON.stringify(m,null,2)+'\n';const file=join(root,'manifest.json');writeFileSync(file,bytes);git('tag','-a',m.tag,'-F',file);
 const bin=join(root,'bin');mkdirSync(bin);const log=join(root,'calls');
 writeFileSync(join(bin,'gh'),`#!/usr/bin/env node
const fs=require('node:fs');const a=process.argv.slice(2);fs.appendFileSync(process.env.CALL_LOG,JSON.stringify(a)+'\\n');
if(a[0]==='api' && a.includes('--paginate')) console.log(JSON.stringify([[{tag_name:'stable-candidate-1',assets:process.env.APPROVAL_MODE==='absent'?[]:[{id:1,name:'approval.json'}]},{tag_name:'mac-v1.9.0',draft:false,assets:[]}]]));
else if(a[0]==='api') console.log(JSON.stringify({run:process.env.APPROVAL_MODE==='old'?'previous-run':'42',manifestHash:process.env.MANIFEST_HASH}));
else if(a[0]!=='release'||a[1]!=='edit') process.exit(2);
`,{mode:0o755});
 for(const mode of ['absent','old','current']) {
  writeFileSync(log,'');
  execFileSync(process.execPath,[resolve('scripts/release-train.mjs'),'withdraw','--tag',m.tag],{cwd:root,env:{...process.env,PATH:bin+':'+process.env.PATH,GITHUB_RUN_ID:'42',APPROVAL_MODE:mode,MANIFEST_HASH:digest(bytes),CALL_LOG:log},stdio:'pipe'});
  const edits=readFileSync(log,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse).filter(a=>a[0]==='release');
  assert.equal(edits.length,mode==='current'?1:0);
  if(edits.length) assert.ok(edits[0].includes('--draft=true'));
 }
});
