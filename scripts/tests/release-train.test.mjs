import test from 'node:test';
import assert from 'node:assert/strict';
import {digest, validateManifest, frozenSurfaces, stablePublicationSurfaces, nextAllocation, effectiveCommits, notesFor, canAdvance} from '../release-train-lib.mjs';
import {mergeEntries} from '../release-notes-catalogue-lib.mjs';
const source='a'.repeat(40), prior='b'.repeat(40);
test('manifest rejects changed frozen notes and moving source refs',()=>{
 const entry={version:'3.2.0',build:'1001',baseline:prior,notes:'Frozen',notesHash:digest('Frozen'),storeNotes:'Short',storeNotesHash:digest('Short')};
 const m={schema:1,train:'stable',tag:'stable-candidate-1',source,ordinal:1,dependenciesHash:digest('lock'),build:'202609091400',surfaces:Object.fromEntries(['mac-direct','mac-store','ios'].map(s=>[s,{...entry}]))};
 m.surfaces['mac-direct'].build=m.build;
 assert.equal(validateManifest(m),m); m.surfaces.ios.notes='Later change';assert.throws(()=>validateManifest(m),/hash/);
 m.surfaces.ios.notes='Frozen';m.source='main';assert.throws(()=>validateManifest(m),/immutable/);
});
test('Stable freezes retired surfaces only for Alpha sources that still validate them',()=>{
 assert.deepEqual(frozenSurfaces(null),['mac-direct','ios']);
 assert.deepEqual(frozenSurfaces({surfaces:{'mac-direct':{},ios:{}}}),['mac-direct','ios']);
 assert.deepEqual(frozenSurfaces({surfaces:{'mac-direct':{},'mac-store':{},ios:{}}}),['mac-direct','ios','mac-store']);
 const entry={version:'3.2.0',build:'1000.0.2',baseline:prior,notes:'Frozen',notesHash:digest('Frozen'),storeNotes:'Short',storeNotesHash:digest('Short')};
 const m={schema:1,train:'stable',tag:'stable-candidate-2',source,ordinal:2,dependenciesHash:digest('lock'),build:'202609091400',surfaces:{'mac-direct':{...entry,build:'202609091400'},ios:{...entry}}};
 assert.equal(validateManifest(m),m);
 m.surfaces['mac-store']={...entry,notes:'Changed',retired:true};
 assert.throws(()=>validateManifest(m),/mac-store/);
});
test('Stable direct Mac publishes independently of an unverified Apple candidate',()=>{
 const m={source,surfaces:{'mac-direct':{build:'1',notesHash:'m'},ios:{build:'2',notesHash:'i'}}};
 const mac={status:'verified',source,build:'1',notesHash:'m'}, ios={status:'verified',source,build:'2',notesHash:'i'};
 assert.deepEqual(stablePublicationSurfaces(m,{'mac-direct':mac,ios}),['mac-direct','ios']);
 assert.deepEqual(stablePublicationSurfaces(m,{'mac-direct':mac}),['mac-direct']);
 assert.deepEqual(stablePublicationSurfaces(m,{'mac-direct':mac,ios:{...ios,status:'invalid'}}),['mac-direct']);
 assert.throws(()=>stablePublicationSurfaces(m,{ios}),/mac-direct/);
 assert.throws(()=>stablePublicationSurfaces(m,{'mac-direct':{...mac,status:'invalid'},ios}),/mac-direct/);
 assert.throws(()=>stablePublicationSurfaces(m,{'mac-direct':mac,ios:{...ios,build:'3'}}),/does not match/);
});
test('allocation advances despite same minute retries and never uses Alpha ordinal for Stable',()=>{
 const old={train:'alpha',ordinal:42,build:'202609091400'};
 const next=nextAllocation([old],'alpha',Date.parse('2026-09-09T14:00:01Z'));
 assert.equal(next.ordinal,43);assert.equal(next.build,'202609091401');
 assert.equal(nextAllocation([old],'stable').ordinal,1);
 assert.equal(canAdvance(old,{build:'202609091359'}),false);
});
test('Alpha notes do not replace siblings or Stable notes with the same version',()=>{
 const entries=[{platform:'mac',version:'3.2.0',train:'stable'},...[1,2].map(build=>({platform:'mac',version:'3.2.0',train:'alpha',build:String(build)}))];
 assert.equal(mergeEntries(entries,[]).length,3);
 assert.equal(mergeEntries(entries,[{...entries[1],markdown:'updated'}]).length,3);
 assert.throws(()=>mergeEntries([],[{platform:'ios',version:'3.2.0',train:'alpha'}]),/build/);
});
test('cumulative notes remove paired reverts, preserve reverts of published behaviour and platform scope',()=>{
 const added={sha:source,subject:'feat(mac): transient feature',body:''};
 const revert={sha:'c'.repeat(40),subject:'revert: remove transient feature',body:`This reverts commit ${source}.`};
 assert.equal(effectiveCommits([added,revert]).length,0);
 assert.equal(effectiveCommits([revert]).length,1);
 const notes=notesFor([added,{sha:prior,subject:'fix(ios): keyboard',body:''},{sha:'d'.repeat(40),subject:'fix: shared credentials',body:''}],'mac');
 assert.match(notes,/shared credentials/);assert.doesNotMatch(notes,/keyboard/);
});

test('reverting a revert restores the original release note',()=>{
 const original={sha:source,subject:'feat(mac): restored feature',body:''};
 const revert={sha:prior,subject:'revert: feature',body:`This reverts commit ${source}.`};
 const restored={sha:'c'.repeat(40),subject:'revert: restore feature',body:`This reverts commit ${prior}.`};
 assert.deepEqual(effectiveCommits([original,revert,restored]),[original]);
});

test('cumulative platform notes respect legacy bracket tags',()=>{
 const notes=notesFor([{sha:source,subject:'fix: [ios] keyboard handoff',body:''},
  {sha:prior,subject:'fix: [mac] desktop capture',body:''}],'mac');
 assert.doesNotMatch(notes,/keyboard handoff/);assert.match(notes,/desktop capture/);
});
