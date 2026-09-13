import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,copyFileSync,readFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {execFileSync} from 'node:child_process';
test('both actual Mac source plists can be stamped before Alpha generation',t=>{
 const root=mkdtempSync(join(tmpdir(),'train-stamp-'));t.after(()=>rmSync(root,{recursive:true,force:true}));
 mkdirSync(join(root,'Config'));mkdirSync(join(root,'Sources/SpeakCore/Resources'),{recursive:true});
 copyFileSync('Sources/SpeakCore/Resources/ReleaseTrains.json',join(root,'Sources/SpeakCore/Resources/ReleaseTrains.json'));
 for(const [surface,file] of [['mac-direct','AppInfo.plist'],['mac-store','AppInfo.AppStore.plist']]){
  copyFileSync(`Config/${file}`,join(root,'Config',file));
  execFileSync('python3',[resolve('scripts/stamp-release-train.py'),surface],{cwd:root,env:{...process.env,RELEASE_TRAIN:'alpha',RELEASE_VERSION:'3.2.0',BUILD_NUMBER:'1000.0.1',RELEASE_SOURCE:'a'.repeat(40),GITHUB_ENV:join(root,'env')}});
  const plist=readFileSync(join(root,'Config',file),'utf8');assert.match(plist,/<string>alpha<\/string>/);assert.match(plist,/<string>3.2.0<\/string>/);
 }
});

test('Tuist receives the frozen commit through its exported environment namespace',()=>{
 const project=readFileSync('Project.swift','utf8');
 const configure=readFileSync('scripts/release-train.mjs','utf8');
 assert.match(configure,/TUIST_RELEASE_SOURCE:manifest\.source/);
 assert.doesNotMatch(project,/environment\["RELEASE_SOURCE"\]/);
 assert.equal((project.match(/environment\["TUIST_RELEASE_SOURCE"\]/g)||[]).length,3,
  'app, watch and keyboard metadata must all use the Tuist-visible commit');
});
