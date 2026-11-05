import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,rmSync,chmodSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {digest} from '../release-train-lib.mjs';
test('archive verifier accepts duplicate extension resources and rejects Stable storage or changed notes',t=>{
 const root=mkdtempSync(join(tmpdir(),'train-archive-'));t.after(()=>rmSync(root,{recursive:true,force:true}));
 const app=join(root,'Alpha.app'),ext=join(app,'PlugIns/Keyboard.appex');mkdirSync(ext,{recursive:true});
 const source='a'.repeat(40),notes='Frozen notes',item={version:'3.2.0',build:'1000.0.1',notesHash:digest(notes)};
 const manifest=join(root,'manifest.json');writeFileSync(manifest,JSON.stringify({source,train:'alpha',surfaces:{ios:item}}));
 const plist=(path,obj)=>execFileSync('python3',['-c','import plistlib,json,sys;open(sys.argv[1],"wb").write(plistlib.dumps(json.loads(sys.argv[2])))',path,JSON.stringify(obj)]);
 const info={CFBundleIdentifier:'com.justspeaktoit.ios.alpha',SpeakReleaseTrain:'alpha',CFBundleShortVersionString:item.version,CFBundleVersion:item.build,GitCommitSHA:source};
 plist(join(app,'Info.plist'),info);plist(join(ext,'Info.plist'),{...info,CFBundleIdentifier:info.CFBundleIdentifier+'.keyboard'});
 const entitlements={'com.apple.developer.icloud-container-identifiers':['iCloud.com.justspeaktoit.ios.alpha'],'com.apple.developer.ubiquity-kvstore-identifier':'TEAM.com.justspeaktoit.ios.alpha','com.apple.security.application-groups':['group.com.justspeaktoit.ios.alpha']};
 plist(join(app,'signed.plist'),entitlements);plist(join(ext,'signed.plist'),{'com.apple.security.application-groups':entitlements['com.apple.security.application-groups']});
 const catalogue={entries:[{platform:'ios',train:'alpha',build:item.build,markdown:notes}]};
 for(const dir of [app,ext])writeFileSync(join(dir,'ReleaseNotes.json'),JSON.stringify(catalogue));
 writeFileSync(join(root,'codesign'),'#!/usr/bin/env python3\nimport sys,pathlib\nsys.stdout.buffer.write((pathlib.Path(sys.argv[-1])/"signed.plist").read_bytes())\n');chmodSync(join(root,'codesign'),0o755);
 const verify=()=>execFileSync('python3',['scripts/verify-release-train-archive.py',app,manifest,'ios'],{env:{...process.env,PATH:root+':'+process.env.PATH},stdio:'pipe'});
 assert.match(verify().toString(),/Verified ios alpha/);
 for(const [key,value] of [['NSLocalNetworkUsageDescription','Internal OpenClaw gateway'],['NSBonjourServices',['_jsti._tcp']]]){
  plist(join(app,'Info.plist'),{...info,[key]:value});
  assert.throws(verify,error=>error.stderr.toString().includes('unavailable local-network feature'));
 }
 plist(join(app,'Info.plist'),info);assert.match(verify().toString(),/Verified ios alpha/);
 plist(join(app,'signed.plist'),{...entitlements,'com.apple.developer.ubiquity-kvstore-identifier':'TEAM.com.justspeaktoit.ios'});
 assert.throws(verify,error=>error.stderr.toString().includes('wrong iCloud key-value store'));
 plist(join(app,'signed.plist'),entitlements);catalogue.entries[0].markdown='Changed';writeFileSync(join(ext,'ReleaseNotes.json'),JSON.stringify(catalogue));
 assert.throws(verify,error=>error.stderr.toString().includes('notes do not match'));
});

test('Stable archive accepts the actual widget and keyboard source plists',t=>{
 const root=mkdtempSync(join(tmpdir(),'stable-archive-'));t.after(()=>rmSync(root,{recursive:true,force:true}));
 const app=join(root,'Stable.app');mkdirSync(app,{recursive:true});
 const config=JSON.parse(readFileSync('Sources/SpeakCore/Resources/ReleaseTrains.json','utf8')).stable;
 const source='b'.repeat(40),notes='Stable notes',item={version:'3.2.0',build:'1000.0.4',notesHash:digest(notes)};
 const manifest=join(root,'manifest.json');writeFileSync(manifest,JSON.stringify({source,train:'stable',surfaces:{ios:item}}));
 const plist=(path,obj)=>execFileSync('python3',['-c','import plistlib,json,sys;open(sys.argv[1],"wb").write(plistlib.dumps(json.loads(sys.argv[2])))',path,JSON.stringify(obj)]);
 plist(join(app,'Info.plist'),{CFBundleIdentifier:config.iosBundleIdentifier,SpeakReleaseTrain:'stable',CFBundleShortVersionString:item.version,CFBundleVersion:item.build,GitCommitSHA:source});
 plist(join(app,'signed.plist'),{'com.apple.developer.icloud-container-identifiers':[config.iosCloudContainer],'com.apple.developer.ubiquity-kvstore-identifier':'TEAM.'+config.iosKVStoreIdentifier,'com.apple.security.application-groups':[config.iosAppGroup]});
 writeFileSync(join(app,'ReleaseNotes.json'),JSON.stringify({entries:[{platform:'ios',train:'stable',build:item.build,markdown:notes}]}));
 for(const [directory,suffix] of [['JustSpeakToItWidgetExtension','JustSpeakToItWidgetExtension'],['JustSpeakKeyboard','keyboard']]){
  const ext=join(app,'PlugIns',directory+'.appex');mkdirSync(ext,{recursive:true});
  const settings={PRODUCT_BUNDLE_IDENTIFIER:config.iosBundleIdentifier+'.'+suffix,MARKETING_VERSION:item.version,CURRENT_PROJECT_VERSION:item.build,SPEAK_RELEASE_TRAIN:'stable',SPEAK_GIT_COMMIT_SHA:source};
  const template=readFileSync(directory+'/Info.plist','utf8');
  writeFileSync(join(ext,'Info.plist'),template.replace(/\$\(([^)]+)\)/g,(original,key)=>settings[key]??original));
  plist(join(ext,'signed.plist'),{'com.apple.security.application-groups':[config.iosAppGroup]});
 }
 writeFileSync(join(root,'codesign'),'#!/usr/bin/env python3\nimport sys,pathlib\nsys.stdout.buffer.write((pathlib.Path(sys.argv[-1])/"signed.plist").read_bytes())\n');chmodSync(join(root,'codesign'),0o755);
 const verify=()=>execFileSync('python3',['scripts/verify-release-train-archive.py',app,manifest,'ios'],{env:{...process.env,PATH:root+':'+process.env.PATH},stdio:'pipe'});
 assert.match(verify().toString(),/Verified ios stable/);
 const widget=join(app,'PlugIns/JustSpeakToItWidgetExtension.appex/Info.plist');
 writeFileSync(widget,readFileSync(widget,'utf8').replace('<string>stable</string>','<string>alpha</string>'));
 assert.throws(verify,error=>error.stderr.toString().includes('Extension SpeakReleaseTrain mismatch'));
});
