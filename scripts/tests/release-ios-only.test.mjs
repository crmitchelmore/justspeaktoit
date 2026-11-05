import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {digest} from '../release-train-lib.mjs';

const script=resolve('scripts/release-train.mjs');
const source='a'.repeat(40), baseline='b'.repeat(40);
function fixture(t, {receiptStatus='verified', newer=false, newerIosVersion='3.3.0', prepare=false}={}) {
 const root=mkdtempSync(join(tmpdir(),'ios-only-release-'));
 t.after(()=>rmSync(root,{recursive:true,force:true}));
 const bin=join(root,'bin'), assets=join(root,'assets'); mkdirSync(bin); mkdirSync(assets);
 const entry={version:'3.2.0',build:'1000.0.1',baseline,notes:'Frozen iOS notes',notesHash:digest('Frozen iOS notes'),storeNotes:'Short',storeNotesHash:digest('Short')};
 const manifest={schema:1,train:'stable',publicationScope:'ios-only',tag:'stable-candidate-1',source,ordinal:1,build:'202611020001',dependenciesHash:digest('lock'),surfaces:{'mac-direct':{...entry,build:'202611020001'},ios:{...entry}}};
 const manifests={[manifest.tag]:manifest};
 if(prepare) {
  manifests['alpha-build-1']={...manifest,train:'alpha',publicationScope:undefined,desktopQualification:1,tag:'alpha-build-1'};
  mkdirSync(join(root,'Config'));
  writeFileSync(join(root,'Config','ReleasePipeline.json'),JSON.stringify({publishedBaselines:{ios:null}}));
 }
 if(newer) manifests['stable-candidate-2']={...manifest,publicationScope:'all',ordinal:2,tag:'stable-candidate-2',surfaces:{...manifest.surfaces,ios:{...entry,version:newerIosVersion}}};
 writeFileSync(join(root,'manifests.json'),JSON.stringify(manifests));
 writeFileSync(join(assets,'ios-receipt.json'),JSON.stringify({status:receiptStatus,source,build:entry.build,notesHash:entry.notesHash,assets:{}}));
 const harness=`#!${process.execPath}
import fs from 'node:fs';
import path from 'node:path';
const root=process.env.FIXTURE_ROOT, args=process.argv.slice(2), tool=path.basename(process.argv[1]);
fs.appendFileSync(path.join(root,'commands.jsonl'),JSON.stringify({tool,args})+'\\n');
const manifests=JSON.parse(fs.readFileSync(path.join(root,'manifests.json'),'utf8'));
const preparing=process.env.EXPECT_PREPARE==='1';
const result=value=>process.stdout.write(typeof value==='string'?value:JSON.stringify(value));
if(tool==='git') {
 if(args[0]==='for-each-ref') result(manifests[args.at(-1).split('/').at(-1)]);
 else if(args[0]==='rev-parse') result('${source}');
 else if(preparing && args[0]==='tag' && args[1]==='--list') result(Object.keys(manifests).filter(t=>t.startsWith('stable-candidate-')).join('\\n'));
 else if(preparing && args[0]==='tag' && args[1]==='-a') fs.copyFileSync(args[args.indexOf('-F')+1],path.join(root,'prepared-manifest.json'));
 else if(preparing && args[0]==='show') result('lock');
 else if(preparing && args[0]==='rev-list') result('${baseline}');
 else if(preparing && ['config','push','log'].includes(args[0])) {}
 else if(args[0]!=='merge-base') throw Error('Unexpected git mutation: '+args.join(' '));
} else if(args[0]==='api') {
 if(args.includes('--paginate')) result([Object.keys(manifests).map(tag_name=>({tag_name,assets:tag_name.startsWith('alpha-')?[{name:'ios-receipt.json',id:'ios-alpha-receipt'}]:[]}))]);
 else if(args[1].includes('/actions/workflows/ci.yml/runs')) result({workflow_runs:[{id:7,run_number:7,run_attempt:1,html_url:'https://example.test/ci',status:'completed',conclusion:'success',head_repository:{full_name:'owner/repo'}}]});
 else if(preparing && args[1].endsWith('/releases/assets/ios-alpha-receipt')) result(fs.readFileSync(path.join(root,'assets','ios-receipt.json'),'utf8'));
 else throw Error('Unexpected API request');
} else if(args[0]==='release' && args[1]==='download') {
 const dest=args[args.indexOf('--dir')+1];
 for(const name of fs.readdirSync(path.join(root,'assets'))) fs.copyFileSync(path.join(root,'assets',name),path.join(dest,name));
} else if(args[0]==='release' && args[1]==='upload' && path.basename(args[3])==='approval.json') {
 fs.copyFileSync(args[3],path.join(root,'observed-approval.json'));
} else if(preparing && args[0]==='release' && args[1]==='create' && args[2].startsWith('stable-candidate-')) {
 result('created draft candidate');
} else throw Error('Unexpected publication side effect: '+args.join(' '));
`;
 for(const tool of ['git','gh']) writeFileSync(join(bin,tool),harness,{mode:0o755});
 const outputFile=join(root,'github-output');
 const env={...process.env,PATH:bin+':'+process.env.PATH,FIXTURE_ROOT:root,GITHUB_REPOSITORY:'owner/repo',GITHUB_OUTPUT:outputFile,RUNNER_TEMP:root};
 const run=(command='publish',hash=digest(JSON.stringify(manifest,null,2)+'\n'),actor='owner')=>spawnSync(process.execPath,[script,command,'--tag',manifest.tag,'--approved-hash',hash],{cwd:root,encoding:'utf8',env:{...env,GITHUB_ACTOR:actor,GITHUB_RUN_ID:'17'}});
 const runPrepare=()=>spawnSync(process.execPath,[script,'prepare','--alpha','alpha-build-1','--ios-version','3.3.0','--scope','ios-only'],{cwd:root,encoding:'utf8',env:{...env,EXPECT_PREPARE:'1'}});
 const commands=()=>readFileSync(join(root,'commands.jsonl'),'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
 return {root,manifest,run,runPrepare,commands,output:()=>readFileSync(outputFile,'utf8')};
}
test('iOS-only preparation freezes scope without Mac version, receipt or desktop qualification',t=>{
 const f=fixture(t,{prepare:true}), result=f.runPrepare();
 assert.equal(result.status,0,result.stderr);
 const manifest=JSON.parse(readFileSync(join(f.root,'prepared-manifest.json'),'utf8'));
 assert.equal(manifest.publicationScope,'ios-only');
 assert.equal(manifest.desktopQualification,undefined);
 assert.equal(manifest.surfaces.ios.version,'3.3.0');
 assert.equal(manifest.surfaces['mac-direct'].version,'3.2.0');
 assert.equal(manifest.surfaces['mac-direct'].baseline,baseline);
 assert.equal(f.output(),`tag=stable-candidate-2\nsource=${source}\n`);
 assert.ok(f.commands().every(c=>!c.args.some(a=>a.includes('desktop-qualification') || a.includes('mac-direct-receipt'))));
});
test('iOS-only preparation refuses an unverified Alpha before allocating a candidate',t=>{
 const f=fixture(t,{prepare:true,receiptStatus:'processing'}), result=f.runPrepare();
 assert.notEqual(result.status,0); assert.match(result.stderr,/Selected Alpha is not verified: ios/);
 assert.ok(f.commands().every(c=>!c.args.includes('-a') && !c.args.includes('create')));
});
test('iOS-only publication refuses a candidate superseded for the same iOS version',t=>{
 const f=fixture(t,{newer:true,newerIosVersion:'3.2.0'}), result=f.run();
 assert.notEqual(result.status,0);
 assert.match(result.stderr,/A newer candidate supersedes this platform\/version/);
 assert.ok(f.commands().every(c=>!c.args.includes('upload')));
});
test('iOS-only publication approves exact candidate and emits only iOS without Mac publication',t=>{
 const f=fixture(t,{newer:true}), result=f.run();
 assert.equal(result.status,0,result.stderr);
 assert.equal(f.output(),'apple=["ios"]\n');
 const approval=JSON.parse(readFileSync(join(f.root,'observed-approval.json'),'utf8'));
 assert.equal(approval.manifestHash,digest(JSON.stringify(f.manifest,null,2)+'\n'));
 assert.equal(approval.actor,'owner');
 assert.equal(f.commands().filter(c=>c.tool==='gh' && c.args[0]==='release' && c.args[1]==='upload').length,1);
 assert.ok(f.commands().every(c=>!c.args.some(a=>a.startsWith('mac-v') || a.includes('homebrew'))));
});
test('iOS-only publish refuses incomplete iOS receipt before writing approval',t=>{
 const f=fixture(t,{receiptStatus:'processing'}), result=f.run();
 assert.notEqual(result.status,0);assert.match(result.stderr,/Candidate not verified: ios/);
 assert.ok(f.commands().every(c=>!c.args.includes('upload')));
});
test('iOS-only publish still requires exact manifest hash and owner',t=>{
 const f=fixture(t);
 assert.match(f.run('publish','0'.repeat(64)).stderr,/Approval does not match/);
 assert.match(f.run('publish',undefined,'collaborator').stderr,/Only the repository owner/);
 assert.ok(f.commands().every(c=>!c.args.includes('upload')));
});
test('iOS-only withdrawal cannot hide any Mac release',t=>{
 const f=fixture(t), result=f.run('withdraw');
 assert.equal(result.status,0,result.stderr);
 assert.ok(f.commands().every(c=>c.tool!=='gh'));
});
