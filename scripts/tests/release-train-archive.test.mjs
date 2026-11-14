import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,rmSync,chmodSync,copyFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {digest} from '../release-train-lib.mjs';
function writeIntents(resources) {
 const path=join(resources,'Metadata.appintents');mkdirSync(path,{recursive:true});
 const metadata={actions:{Record:{descriptionMetadata:{descriptionText:{key:'Records speech for dictation.',alternatives:[]}}}},autoShortcuts:[{phraseTemplates:[{key:'Record with ${applicationName}',alternatives:[]}]}]};
 writeFileSync(join(path,'extract.actionsdata'),JSON.stringify(metadata));
 return metadata;
}
test('archive verifier accepts duplicate extension resources and rejects Stable storage or changed notes',t=>{
 const root=mkdtempSync(join(tmpdir(),'train-archive-'));t.after(()=>rmSync(root,{recursive:true,force:true}));
 const app=join(root,'Alpha.app'),ext=join(app,'PlugIns/Keyboard.appex');mkdirSync(ext,{recursive:true});
 const source='a'.repeat(40),notes='Frozen notes',item={version:'3.2.0',build:'1000.0.1',notesHash:digest(notes)};
 const manifest=join(root,'manifest.json');writeFileSync(manifest,JSON.stringify({source,train:'alpha',surfaces:{ios:item}}));
 const plist=(path,obj)=>execFileSync('python3',['-c','import plistlib,json,sys;open(sys.argv[1],"wb").write(plistlib.dumps(json.loads(sys.argv[2])))',path,JSON.stringify(obj)]);
 const extInfo={CFBundleIdentifier:'com.justspeaktoit.ios.alpha',SpeakReleaseTrain:'alpha',CFBundleShortVersionString:item.version,CFBundleVersion:item.build,GitCommitSHA:source,NSMicrophoneUsageDescription:'Record speech for dictation.',NSSpeechRecognitionUsageDescription:'Recognize speech for dictation.'};
 const info={...extInfo,NSLocalNetworkUsageDescription:'Find your Mac to send it transcripts.',NSBonjourServices:['_speakalpha._tcp']};
 plist(join(app,'Info.plist'),info);plist(join(ext,'Info.plist'),{...extInfo,CFBundleIdentifier:info.CFBundleIdentifier+'.keyboard'});
 copyFileSync('SpeakiOSApp/PrivacyInfo.xcprivacy',join(app,'PrivacyInfo.xcprivacy'));
 copyFileSync('JustSpeakKeyboard/PrivacyInfo.xcprivacy',join(ext,'PrivacyInfo.xcprivacy'));
 const intentMetadata=writeIntents(app);
 const entitlements={'com.apple.developer.icloud-container-identifiers':['iCloud.com.justspeaktoit.alpha','iCloud.com.justspeaktoit.ios.alpha'],'com.apple.developer.ubiquity-kvstore-identifier':'TEAM.com.justspeaktoit.ios.alpha','com.apple.security.application-groups':['group.com.justspeaktoit.ios.alpha']};
 plist(join(app,'signed.plist'),entitlements);plist(join(ext,'signed.plist'),{'com.apple.security.application-groups':entitlements['com.apple.security.application-groups']});
 const catalogue={entries:[{platform:'ios',train:'alpha',build:item.build,markdown:notes}]};
 for(const dir of [app,ext])writeFileSync(join(dir,'ReleaseNotes.json'),JSON.stringify(catalogue));
 writeFileSync(join(root,'codesign'),'#!/usr/bin/env python3\nimport sys,pathlib\nsys.stdout.buffer.write((pathlib.Path(sys.argv[-1])/"signed.plist").read_bytes())\n');chmodSync(join(root,'codesign'),0o755);
 const verify=()=>execFileSync('python3',['scripts/verify-release-train-archive.py',app,manifest,'ios'],{env:{...process.env,PATH:root+':'+process.env.PATH},stdio:'pipe'});
 assert.match(verify().toString(),/Verified ios alpha/);
 const privacyPath=join(app,'PrivacyInfo.xcprivacy');
 const privacy=JSON.parse(execFileSync('python3',['-c','import json,plistlib,sys;print(json.dumps(plistlib.load(open(sys.argv[1],"rb"))))',privacyPath]));
 const framework=join(app,'Frameworks/Sentry.framework');mkdirSync(framework,{recursive:true});
 copyFileSync(privacyPath,join(framework,'PrivacyInfo.xcprivacy'));rmSync(privacyPath);
 assert.throws(verify,error=>error.stderr.toString().includes('Missing own-bundle privacy manifest'));
 writeFileSync(privacyPath,'not a plist');
 assert.throws(verify,error=>error.stderr.toString().includes('Invalid privacy manifest'));
 for(const [change,message] of [
  [p=>{p.NSPrivacyTracking=true;},'Unexpected tracking'],
  [p=>{p.NSPrivacyAccessedAPITypes=p.NSPrivacyAccessedAPITypes.filter(a=>a.NSPrivacyAccessedAPIType!=='NSPrivacyAccessedAPICategorySystemBootTime');},'Missing app required-reason'],
  [p=>{p.NSPrivacyAccessedAPITypes=p.NSPrivacyAccessedAPITypes.filter(a=>a.NSPrivacyAccessedAPIType!=='NSPrivacyAccessedAPICategoryActiveKeyboards');},'Missing app required-reason'],
  [p=>{p.NSPrivacyAccessedAPITypes.find(a=>a.NSPrivacyAccessedAPIType==='NSPrivacyAccessedAPICategoryActiveKeyboards').NSPrivacyAccessedAPITypeReasons=['3EC4.1'];},'Unaudited or invalid'],
  [p=>{p.NSPrivacyAccessedAPITypes[0].NSPrivacyAccessedAPITypeReasons=['not-approved'];},'Unaudited or invalid'],
  [p=>{p.NSPrivacyAccessedAPITypes[0].NSPrivacyAccessedAPITypeReasons='CA92.1';},'Unaudited or invalid'],
  [p=>{p.NSPrivacyCollectedDataTypes[0].NSPrivacyCollectedDataTypeLinked='false';},'Invalid collected-data'],
  [p=>{p.NSPrivacyCollectedDataTypes[0].NSPrivacyCollectedDataTypePurposes=[];},'Invalid collected-data'],
  [p=>{p.NSPrivacyCollectedDataTypes[0].NSPrivacyCollectedDataType='NSPrivacyCollectedDataTypeMadeUp';},'Invalid collected-data'],
  [p=>{p.NSPrivacyCollectedDataTypes.find(d=>d.NSPrivacyCollectedDataType==='NSPrivacyCollectedDataTypeCrashData').NSPrivacyCollectedDataTypeLinked=false;},'installation linkage'],
  [p=>{p.NSPrivacyCollectedDataTypes=[];},'Missing app collected-data']
 ]){
  const changed=structuredClone(privacy);change(changed);plist(privacyPath,changed);
  assert.throws(verify,error=>error.stderr.toString().includes(message));
 }
 plist(privacyPath,privacy);
 rmSync(join(ext,'PrivacyInfo.xcprivacy'));
 assert.throws(verify,error=>error.stderr.toString().includes('Missing own-bundle privacy manifest'));
 copyFileSync('JustSpeakKeyboard/PrivacyInfo.xcprivacy',join(ext,'PrivacyInfo.xcprivacy'));
 plist(join(app,'Info.plist'),{...info,NSMicrophoneUsageDescription:'  '});
 assert.throws(verify,error=>error.stderr.toString().includes('Missing or unresolved NSMicrophoneUsageDescription'));
 plist(join(app,'Info.plist'),info);
 const metadataPath=join(app,'Metadata.appintents/extract.actionsdata');
 rmSync(metadataPath);assert.throws(verify,error=>error.stderr.toString().includes('Missing App Intents metadata'));
 for(const [change,message] of [
  [m=>{m.actions.Record.descriptionMetadata.descriptionText.key='Records on an iPhOnE.';},'ITMS-90626'],
  [m=>{m.actions.Record.descriptionMetadata.descriptionText.key='Records with Siri.';},'ITMS-90626'],
  [m=>{m.actions.Record.parameters=[{title:{key:'Apple Watch',alternatives:[]}}];},'ITMS-90626'],
  [m=>{m.actions.Record.descriptionMetadata.descriptionText.key='Records speech';},'must end with a period'],
  [m=>{m.actions.Record.descriptionMetadata.descriptionText.alternatives=['Unexpected schema'];},'Unsupported localized'],
  [m=>{m.autoShortcuts=Array.from({length:11},()=>({phraseTemplates:[{key:'Record with ${applicationName}'}]}));},'maximum ten'],
  [m=>{m.autoShortcuts=[{phraseTemplates:[{key:'Record speech'}]}];},'must include the application name'],
  [m=>{m.autoShortcuts=[];},'registers no App Shortcuts']
 ]){
  const changed=structuredClone(intentMetadata);change(changed);writeFileSync(metadataPath,JSON.stringify(changed));
  assert.throws(verify,error=>error.stderr.toString().includes(message));
 }
 writeFileSync(metadataPath,JSON.stringify(intentMetadata));
 // Send to Mac (#1640): the iOS app must declare its own train's receiver service and a purpose string.
 for(const [change,message] of [
  [{NSBonjourServices:['_jsti._tcp']},'Bonjour service'],
  [{NSBonjourServices:['_speaktransport._tcp']},'Bonjour service'],
  [{NSBonjourServices:['_speakalpha._tcp','_jsti._tcp']},'Bonjour service'],
  [{NSBonjourServices:undefined},'Bonjour service'],
  [{NSLocalNetworkUsageDescription:undefined},'local-network purpose string'],
  [{NSLocalNetworkUsageDescription:'$(UNRESOLVED)'},'local-network purpose string']
 ]){
  plist(join(app,'Info.plist'),{...info,...change});
  assert.throws(verify,error=>error.stderr.toString().includes(message));
 }
 plist(join(app,'Info.plist'),info);assert.match(verify().toString(),/Verified ios alpha/);
 // The watch pair uses its own App Group, never the iPhone one.
 const watch=join(app,'Watch/JustSpeakToItWatch.app'),complication=join(watch,'PlugIns/JustSpeakWatchWidgetExtension.appex');mkdirSync(complication,{recursive:true});
 const watchGroup={'com.apple.security.application-groups':['group.com.justspeaktoit.watch.alpha']};
 plist(join(watch,'Info.plist'),{...info,CFBundleIdentifier:info.CFBundleIdentifier+'.watchkitapp',WKCompanionAppBundleIdentifier:info.CFBundleIdentifier});
 plist(join(complication,'Info.plist'),{...info,CFBundleIdentifier:info.CFBundleIdentifier+'.watchkitapp.widget'});
 copyFileSync('JustSpeakWatch/PrivacyInfo.xcprivacy',join(watch,'PrivacyInfo.xcprivacy'));
 copyFileSync('JustSpeakWatchWidget/PrivacyInfo.xcprivacy',join(complication,'PrivacyInfo.xcprivacy'));
 plist(join(watch,'signed.plist'),watchGroup);plist(join(complication,'signed.plist'),watchGroup);
 assert.match(verify().toString(),/Verified ios alpha/);
 plist(join(complication,'signed.plist'),{'com.apple.security.application-groups':entitlements['com.apple.security.application-groups']});
 assert.throws(verify,error=>error.stderr.toString().includes('Signed extension has the wrong App Groups'));
 plist(join(complication,'signed.plist'),watchGroup);
 plist(join(watch,'Info.plist'),{...info,CFBundleIdentifier:info.CFBundleIdentifier+'.watchkitapp',WKCompanionAppBundleIdentifier:'com.justspeaktoit.ios'});
 assert.throws(verify,error=>error.stderr.toString().includes('wrong companion identity'));
 rmSync(join(app,'Watch'),{recursive:true});
 // #1119: the shared container is required and the order is irrelevant.
 const reordered={...entitlements,'com.apple.developer.icloud-container-identifiers':['iCloud.com.justspeaktoit.ios.alpha','iCloud.com.justspeaktoit.alpha']};
 plist(join(app,'signed.plist'),reordered);assert.match(verify().toString(),/Verified ios alpha/);
 for(const containers of [['iCloud.com.justspeaktoit.ios.alpha'],['iCloud.com.justspeaktoit.alpha','iCloud.com.justspeaktoit']]){
  plist(join(app,'signed.plist'),{...entitlements,'com.apple.developer.icloud-container-identifiers':containers});
  assert.throws(verify,error=>error.stderr.toString().includes('wrong CloudKit containers'));
 }
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
 const info={CFBundleIdentifier:config.iosBundleIdentifier,SpeakReleaseTrain:'stable',CFBundleShortVersionString:item.version,CFBundleVersion:item.build,GitCommitSHA:source,NSMicrophoneUsageDescription:'Record speech for dictation.',NSSpeechRecognitionUsageDescription:'Recognize speech for dictation.'};
 plist(join(app,'Info.plist'),{...info,NSLocalNetworkUsageDescription:'Find your Mac to send it transcripts.',NSBonjourServices:[config.transportServiceType]});
 copyFileSync('SpeakiOSApp/PrivacyInfo.xcprivacy',join(app,'PrivacyInfo.xcprivacy'));
 writeIntents(app);
 plist(join(app,'signed.plist'),{'com.apple.developer.icloud-container-identifiers':[config.cloudContainer,config.iosCloudContainer],'com.apple.developer.ubiquity-kvstore-identifier':'TEAM.'+config.iosKVStoreIdentifier,'com.apple.security.application-groups':[config.iosAppGroup]});
 writeFileSync(join(app,'ReleaseNotes.json'),JSON.stringify({entries:[{platform:'ios',train:'stable',build:item.build,markdown:notes}]}));
 for(const [directory,suffix] of [['JustSpeakToItWidgetExtension','JustSpeakToItWidgetExtension'],['JustSpeakKeyboard','keyboard'],['JustSpeakShare','share']]){
  const ext=join(app,'PlugIns',directory+'.appex');mkdirSync(ext,{recursive:true});
  const settings={PRODUCT_BUNDLE_IDENTIFIER:config.iosBundleIdentifier+'.'+suffix,MARKETING_VERSION:item.version,CURRENT_PROJECT_VERSION:item.build,SPEAK_RELEASE_TRAIN:'stable',SPEAK_GIT_COMMIT_SHA:source};
  const template=readFileSync(directory+'/Info.plist','utf8');
  writeFileSync(join(ext,'Info.plist'),template.replace(/\$\(([^)]+)\)/g,(original,key)=>settings[key]??original));
  copyFileSync(directory+'/PrivacyInfo.xcprivacy',join(ext,'PrivacyInfo.xcprivacy'));
  plist(join(ext,'signed.plist'),{'com.apple.security.application-groups':[config.iosAppGroup]});
 }
 const watch=join(app,'Watch/Watch.app'),complication=join(watch,'PlugIns/Complication.appex');
 mkdirSync(complication,{recursive:true});
 plist(join(watch,'Info.plist'),{...info,CFBundleIdentifier:info.CFBundleIdentifier+'.watchkitapp',WKApplication:true,WKCompanionAppBundleIdentifier:info.CFBundleIdentifier});
 const watchSettings={PRODUCT_BUNDLE_IDENTIFIER:info.CFBundleIdentifier+'.watchkitapp.widget',MARKETING_VERSION:item.version,CURRENT_PROJECT_VERSION:item.build,SPEAK_RELEASE_TRAIN:'stable',SPEAK_GIT_COMMIT_SHA:source};
 writeFileSync(join(complication,'Info.plist'),readFileSync('JustSpeakWatchWidget/Info.plist','utf8').replace(/\$\(([^)]+)\)/g,(original,key)=>watchSettings[key]??original));
 copyFileSync('JustSpeakWatch/PrivacyInfo.xcprivacy',join(watch,'PrivacyInfo.xcprivacy'));
 copyFileSync('JustSpeakWatchWidget/PrivacyInfo.xcprivacy',join(complication,'PrivacyInfo.xcprivacy'));
 for(const bundle of [watch,complication])plist(join(bundle,'signed.plist'),{'com.apple.security.application-groups':[config.watchAppGroup]});
 writeFileSync(join(root,'codesign'),'#!/usr/bin/env python3\nimport sys,pathlib\nsys.stdout.buffer.write((pathlib.Path(sys.argv[-1])/"signed.plist").read_bytes())\n');chmodSync(join(root,'codesign'),0o755);
 const verify=()=>execFileSync('python3',['scripts/verify-release-train-archive.py',app,manifest,'ios'],{env:{...process.env,PATH:root+':'+process.env.PATH},stdio:'pipe'});
 assert.match(verify().toString(),/Verified ios stable/);
 const sharePrivacy=join(app,'PlugIns/JustSpeakShare.appex/PrivacyInfo.xcprivacy');
 plist(sharePrivacy,{NSPrivacyTracking:false,NSPrivacyTrackingDomains:[],NSPrivacyCollectedDataTypes:[],NSPrivacyAccessedAPITypes:[]});
 assert.throws(verify,error=>error.stderr.toString().includes('Missing extension defaults API declaration'));
 copyFileSync('JustSpeakShare/PrivacyInfo.xcprivacy',sharePrivacy);
 const keyboardPrivacy=join(app,'PlugIns/JustSpeakKeyboard.appex/PrivacyInfo.xcprivacy');
 plist(keyboardPrivacy,{NSPrivacyTracking:false,NSPrivacyTrackingDomains:[],NSPrivacyCollectedDataTypes:[],NSPrivacyAccessedAPITypes:[{NSPrivacyAccessedAPIType:'NSPrivacyAccessedAPICategoryUserDefaults',NSPrivacyAccessedAPITypeReasons:['1C8F.1']}]});
 assert.throws(verify,error=>error.stderr.toString().includes('Missing keyboard active-keyboards API declaration'));
 copyFileSync('JustSpeakKeyboard/PrivacyInfo.xcprivacy',keyboardPrivacy);
 plist(join(complication,'signed.plist'),{'com.apple.security.application-groups':[config.iosAppGroup]});
 assert.throws(verify,error=>error.stderr.toString().includes('wrong App Groups'));
 plist(join(complication,'signed.plist'),{'com.apple.security.application-groups':[config.watchAppGroup]});
 plist(join(watch,'Info.plist'),{...info,CFBundleIdentifier:info.CFBundleIdentifier+'.watchkitapp',WKApplication:true,WKCompanionAppBundleIdentifier:'another.app'});
 assert.throws(verify,error=>error.stderr.toString().includes('wrong companion identity'));
 plist(join(watch,'Info.plist'),{...info,CFBundleIdentifier:info.CFBundleIdentifier+'.watchkitapp',WKApplication:true,WKCompanionAppBundleIdentifier:info.CFBundleIdentifier});
 const widget=join(app,'PlugIns/JustSpeakToItWidgetExtension.appex/Info.plist');
 writeFileSync(widget,readFileSync(widget,'utf8').replace('<string>stable</string>','<string>alpha</string>'));
 assert.throws(verify,error=>error.stderr.toString().includes('Extension SpeakReleaseTrain mismatch'));
});

test('macOS archives require their own correctly placed privacy manifest and sandboxed Store channel',t=>{
 const root=mkdtempSync(join(tmpdir(),'mac-archive-'));t.after(()=>rmSync(root,{recursive:true,force:true}));
 const config=JSON.parse(readFileSync('Sources/SpeakCore/Resources/ReleaseTrains.json','utf8')).stable;
 const source='c'.repeat(40),notes='Mac notes',item={version:'3.2.0',build:'1000.0.5',notesHash:digest(notes)};
 const plist=(path,obj)=>execFileSync('python3',['-c','import plistlib,json,sys;open(sys.argv[1],"wb").write(plistlib.dumps(json.loads(sys.argv[2])))',path,JSON.stringify(obj)]);
 writeFileSync(join(root,'codesign'),'#!/usr/bin/env python3\nimport sys,pathlib\nsys.stdout.buffer.write((pathlib.Path(sys.argv[-1])/"signed.plist").read_bytes())\n');chmodSync(join(root,'codesign'),0o755);
 for(const [surface,channel,infoSource,id] of [
  ['mac-direct','Direct','Config/AppInfo.plist',config.directMacBundleIdentifier],
  ['mac-store','AppStore','Config/AppInfo.AppStore.plist',config.storeMacBundleIdentifier]
 ]){
  const app=join(root,channel+'.app'),resources=join(app,'Contents/Resources');mkdirSync(resources,{recursive:true});
  const manifest=join(root,channel+'.json');writeFileSync(manifest,JSON.stringify({source,train:'stable',surfaces:{[surface]:item}}));
  const settings={PRODUCT_BUNDLE_IDENTIFIER:id,MARKETING_VERSION:item.version,CURRENT_PROJECT_VERSION:item.build,SPEAK_RELEASE_TRAIN:'stable',SPEAK_GIT_COMMIT_SHA:source};
  writeFileSync(join(app,'Contents/Info.plist'),readFileSync(infoSource,'utf8').replace(/\$\(([^)]+)\)/g,(original,key)=>settings[key]??original));
  const infoPath=join(app,'Contents/Info.plist');
  const info=JSON.parse(execFileSync('python3',['-c','import json,plistlib,sys;print(json.dumps(plistlib.load(open(sys.argv[1],"rb"))))',infoPath]));
  plist(infoPath,{...info,SpeakReleaseTrain:'stable',GitCommitSHA:source,CFBundleShortVersionString:item.version,CFBundleVersion:item.build});
  copyFileSync('Sources/SpeakApp/Resources/'+channel+'/PrivacyInfo.xcprivacy',join(resources,'PrivacyInfo.xcprivacy'));
  writeIntents(resources);
  writeFileSync(join(resources,'ReleaseNotes.json'),JSON.stringify({entries:[{platform:'mac',train:'stable',build:item.build,markdown:notes}]}));
  const entitlements={'com.apple.developer.icloud-container-identifiers':[config.cloudContainer],'com.apple.developer.ubiquity-kvstore-identifier':'TEAM.'+config.macKVStoreIdentifier,'com.apple.security.app-sandbox':true};
  if(surface==='mac-store')plist(join(app,'signed.plist'),entitlements);
  const verify=()=>execFileSync('python3',['scripts/verify-release-train-archive.py',app,manifest,surface],{env:{...process.env,PATH:root+':'+process.env.PATH},stdio:'pipe'});
  assert.match(verify().toString(),new RegExp('Verified '+surface+' stable'));
  copyFileSync(join(resources,'PrivacyInfo.xcprivacy'),join(app,'PrivacyInfo.xcprivacy'));rmSync(join(resources,'PrivacyInfo.xcprivacy'));
  assert.throws(verify,error=>error.stderr.toString().includes('Missing own-bundle privacy manifest'));
  copyFileSync('Sources/SpeakApp/Resources/'+channel+'/PrivacyInfo.xcprivacy',join(resources,'PrivacyInfo.xcprivacy'));
  if(surface==='mac-store'){
   copyFileSync('Sources/SpeakApp/Resources/Direct/PrivacyInfo.xcprivacy',join(resources,'PrivacyInfo.xcprivacy'));
   assert.throws(verify,error=>error.stderr.toString().includes('excluded product analytics'));
   copyFileSync('Sources/SpeakApp/Resources/AppStore/PrivacyInfo.xcprivacy',join(resources,'PrivacyInfo.xcprivacy'));
   plist(join(app,'signed.plist'),{...entitlements,'com.apple.security.app-sandbox':false});
   assert.throws(verify,error=>error.stderr.toString().includes('not sandboxed'));
   plist(join(app,'signed.plist'),{...entitlements,'com.apple.security.network.server':true});
   assert.throws(verify,error=>error.stderr.toString().includes('network.server without a listener'));
   plist(join(app,'signed.plist'),entitlements);
   plist(infoPath,{...info,SpeakReleaseTrain:'stable',GitCommitSHA:source,CFBundleShortVersionString:item.version,CFBundleVersion:item.build,NSBonjourServices:['_speaktransport._tcp']});
   assert.throws(verify,error=>error.stderr.toString().includes('unavailable local-network feature'));
  }
 }
});
