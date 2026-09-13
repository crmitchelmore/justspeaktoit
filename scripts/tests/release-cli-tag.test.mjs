import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
test('CLI verifier accepts the configured Alpha tag and rejects a different release', {skip:process.platform !== 'darwin'},t=>{
 const root=mkdtempSync(join(tmpdir(),'cli-tag-'));t.after(()=>rmSync(root,{recursive:true,force:true}));
 const version='3.2.0-alpha.12', tag='alpha-build-12';
 const archives=['arm64','x86_64'].map(architecture=>{
  const name=`speak-${version}-${architecture}.zip`,data=Buffer.from(architecture);
  writeFileSync(join(root,name),data);
  return {architecture,url:`https://github.com/crmitchelmore/justspeaktoit/releases/download/${tag}/${name}`,byteCount:data.length,sha256:createHash('sha256').update(data).digest('hex')};
 });
 const manifest=join(root,'manifest.json');
 writeFileSync(manifest,JSON.stringify({schemaVersion:1,version,automationSchemaVersion:1,assets:archives}));
 const verify=downloadTag=>execFileSync('xcrun',['swift','scripts/verify-cli-manifest.swift',manifest,'-','-',version,'1',...archives.map(a=>join(root,new URL(a.url).pathname.split('/').at(-1)))],{env:{...process.env,DOWNLOAD_TAG:downloadTag},stdio:'pipe'});
 assert.doesNotThrow(()=>verify(tag));
 assert.throws(()=>verify('alpha-build-13'),e=>e.stderr.toString().includes('must be published at'));
 assert.throws(()=>verify(''),e=>e.stderr.toString().includes('mac-v3.2.0-alpha.12'));
 assert.throws(()=>verify('../other'),e=>e.stderr.toString().includes('plain tag name'));
});
