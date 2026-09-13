import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,chmodSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
test('architecture gate reads Alpha executable metadata and still rejects wrong slices', {skip:process.platform !== 'darwin'}, t=>{
 const root=mkdtempSync(join(tmpdir(),'alpha-arch-'));t.after(()=>rmSync(root,{recursive:true,force:true}));
 const app=join(root,'Alpha.app');mkdirSync(join(app,'Contents/MacOS'),{recursive:true});
 writeFileSync(join(app,'Contents/MacOS/JustSpeakToItAlpha'),'fixture');
 const plist=join(app,'Contents/Info.plist');
 execFileSync('python3',['-c','import plistlib,sys;plistlib.dump({"CFBundleExecutable":"JustSpeakToItAlpha"},open(sys.argv[1],"wb"))',plist]);
 writeFileSync(join(root,'lipo'),'#!/bin/sh\necho arm64\n');chmodSync(join(root,'lipo'),0o755);
 const verify=variant=>execFileSync('bash',['scripts/verify-architecture.sh',app,variant,'no-embedded-cli'],{env:{...process.env,PATH:root+':'+process.env.PATH},stdio:'pipe'});
 assert.match(verify('arm64').toString(),/Architecture verified/);
 assert.throws(()=>verify('universal'),e=>e.stderr.toString().includes('must contain exactly'));
});
