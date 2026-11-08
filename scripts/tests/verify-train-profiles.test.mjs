import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,rmSync,chmodSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';

test('iOS profiles may add the shared container, and must once the build uses it',t=>{
 const root=mkdtempSync(join(tmpdir(),'train-profiles-'));t.after(()=>rmSync(root,{recursive:true,force:true}));
 const plist=(path,obj)=>execFileSync('python3',['-c','import plistlib,json,sys;open(sys.argv[1],"wb").write(plistlib.dumps(json.loads(sys.argv[2])))',path,JSON.stringify(obj)]);
 const env={BUNDLE_ID:'com.justspeaktoit.ios.alpha',IOS_APP_GROUP:'group.com.justspeaktoit.ios.alpha',
  IOS_CLOUD_CONTAINER:'iCloud.com.justspeaktoit.ios.alpha',MAC_CLOUD_CONTAINER:'iCloud.com.justspeaktoit.alpha'};
 const write=containers=>{
  for(const [name,suffix] of [['ios-appstore',''],['ios-widget-appstore','.JustSpeakToItWidgetExtension'],['ios-keyboard-appstore','.keyboard']]){
   const entitlements={'application-identifier':'TEAM.'+env.BUNDLE_ID+suffix,'com.apple.security.application-groups':[env.IOS_APP_GROUP]};
   if(name==='ios-appstore')entitlements['com.apple.developer.icloud-container-identifiers']=containers;
   plist(join(root,name+'.provisionprofile'),{Entitlements:entitlements});
  }
 };
 writeFileSync(join(root,'security'),'#!/bin/sh\ncat "$4"\n');chmodSync(join(root,'security'),0o755);
 const verify=(shared='0')=>execFileSync('python3',['scripts/verify-train-profiles.py','ios',root],
  {env:{...process.env,...env,TUIST_IOS_SHARED_CLOUD_CONTAINER:shared,PATH:root+':'+process.env.PATH},stdio:'pipe'});
 const wrong=error=>error.stderr.toString().includes('wrong CloudKit container');
 write([env.IOS_CLOUD_CONTAINER]);assert.match(verify().toString(),/Validated/);
 assert.throws(()=>verify('1'),wrong);
 write([env.IOS_CLOUD_CONTAINER,env.MAC_CLOUD_CONTAINER]);
 assert.match(verify().toString(),/Validated/);assert.match(verify('1').toString(),/Validated/);
 write([env.IOS_CLOUD_CONTAINER,'iCloud.com.justspeaktoit']);assert.throws(()=>verify(),wrong);
});
