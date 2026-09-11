#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { runReleaseCommand } from './release-command.mjs';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseCommits } from './release-notes-lib.mjs';
import { buildCatalogue, mergeEntries } from './release-notes-catalogue-lib.mjs';
import { digest, validateManifest, surfaces, notesFor, notesHTML, nextAllocation, canAdvance, assertStableVersionAdvance } from './release-train-lib.mjs';

const repo = process.env.GITHUB_REPOSITORY ?? 'crmitchelmore/justspeaktoit';
const run = runReleaseCommand;
const gh = (...args) => run('gh', args);
const git = (...args) => run('git', args);
const temp = mkdtempSync(join(tmpdir(), 'release-train-'));
const [command, ...args] = process.argv.slice(2);
const option = (name, fallback) => { const index = args.indexOf(`--${name}`); return index < 0 ? fallback : args[index+1]; };
const required = name => { const value=option(name); if(!value) throw Error(`--${name} required`); return value; };
const json = path => JSON.parse(readFileSync(path,'utf8'));
const save = (name, value) => { const path=join(temp,name); writeFileSync(path, typeof value === 'string' ? value : JSON.stringify(value,null,2)+'\n'); return path; };
const api = path => JSON.parse(gh('api', path));
const releases = () => JSON.parse(gh('api','--paginate','--slurp',`repos/${repo}/releases?per_page=100`)).flat();
function manifestFor(tag) {
    if (!/^(alpha-build|stable-candidate)-[1-9][0-9]*$/.test(tag)) throw Error('Invalid manifest tag');
    const annotation=git('for-each-ref','--format=%(contents)',`refs/tags/${tag}`);
    const manifest=validateManifest(JSON.parse(annotation));
    if(manifest.tag !== tag || git('rev-parse',`${tag}^{commit}`) !== manifest.source) throw Error('Manifest/tag source mismatch');
    return manifest;
}
function upload(tag, name, value, clobber=false) {
    gh('release','upload',tag,save(name,value),'--repo',repo,...(clobber?['--clobber']:[]));
}
function output(name,value) { if(process.env.GITHUB_OUTPUT) writeFileSync(process.env.GITHUB_OUTPUT,`${name}=${value}\n`,{flag:'a'}); else console.log(`${name}=${value}`); }
function ci(source) {
    if(!/^[a-f0-9]{40}$/.test(source)) throw Error('Full source SHA required');
    git('merge-base','--is-ancestor',source,'origin/main');
    const runs=api(`repos/${repo}/actions/workflows/ci.yml/runs?head_sha=${source}&event=push&branch=main&per_page=100`).workflow_runs;
    const latest=runs.sort((a,b)=>b.run_number-a.run_number)[0];
    if(!latest || latest.conclusion !== 'success' || latest.status !== 'completed' || latest.head_repository.full_name !== repo) throw Error(`No successful main CI for ${source}`);
    return {id:latest.id,attempt:latest.run_attempt,url:latest.html_url};
}
function baseline(all, surface) {
    // Only a public non-prerelease receipt advances an Apple boundary. A
    // candidate, upload or review submission never counts as publication.
    if(surface === 'mac-direct') {
        const release=all.find(r=>!r.draft && !r.prerelease && /^mac-v\d+\.\d+\.\d+$/.test(r.tag_name));
        if(release) return git('rev-parse',`${release.tag_name}^{commit}`);
    }
    const receipt=all.find(r=>!r.draft && !r.prerelease && r.tag_name.startsWith(`published-${surface}-`));
    if(receipt) return git('rev-parse',`${receipt.tag_name}^{commit}`);
    const configured=json('Config/ReleasePipeline.json').publishedBaselines[surface];
    if(configured) return git('rev-parse',`${configured}^{commit}`);
    // No version has ever been published on this surface: full initial range.
    return git('rev-list','--max-parents=0','HEAD').split('\n')[0];
}
function ensureRelease(manifest, all) {
    if(all.some(r=>r.tag_name===manifest.tag)) return;
    const bytes=JSON.stringify(manifest,null,2)+'\n';
    const body=`${manifest.tag}\n\nSource: ${manifest.source}\n\nManifest SHA-256: ${digest(bytes)}\n\n${surfaces.map(s=>`## ${s} ${manifest.surfaces[s].version} (${manifest.surfaces[s].build})\n${manifest.surfaces[s].notes}`).join('\n')}`;
    gh('release','create',manifest.tag,save('release-manifest.json',bytes),'--repo',repo,'--draft','--prerelease','--latest=false','--title',manifest.tag,'--notes-file',save('review.md',body));
}
if(command === 'allocate' || command === 'prepare') {
    const all=releases();
    const train=command === 'allocate' ? 'alpha' : 'stable';
    const alpha=train === 'stable' ? manifestFor(required('alpha')) : null;
    const source=alpha?.source ?? required('source');
    const proof=ci(source);
    if(alpha) {
        if(alpha.train !== 'alpha') throw Error('Select an Alpha build');
        const release=all.find(r=>r.tag_name===alpha.tag);
        for(const surface of surfaces) {
            const asset=release?.assets.find(a=>a.name===`${surface}-receipt.json`);
            if(!asset) throw Error(`Selected Alpha has no delivery receipt: ${surface}`);
            const receipt=JSON.parse(gh('api',`repos/${repo}/releases/assets/${asset.id}`,'-H','Accept: application/octet-stream'));
            if(receipt.status !== 'verified' || receipt.source !== alpha.source || receipt.build !== alpha.surfaces[surface].build || receipt.notesHash !== alpha.surfaces[surface].notesHash) throw Error(`Selected Alpha is not verified: ${surface}`);
        }
    }
    const tagNames=git('tag','--list',train === 'alpha'?'alpha-build-*':'stable-candidate-*').split('\n').filter(Boolean);
    // Annotated tags are the durable allocation ledger, including a crash
    // between pushing a tag and creating its draft GitHub release.
    const manifests=tagNames.map(tag=>manifestFor(tag));
    if(train === 'alpha') {
        const same=manifests.filter(m=>m.source === source).sort((a,b)=>b.ordinal-a.ordinal)[0];
        if(same && option('rebuild','false') !== 'true') {
            ensureRelease(same,all); output('tag',same.tag); output('source',source); process.exit(0);
        }
    }
    const allocation=nextAllocation(manifests,train);
    const tag=`${train === 'alpha'?'alpha-build':'stable-candidate'}-${allocation.ordinal}`;
    const config=json('Config/ReleasePipeline.json');
    const versions=train === 'alpha' ? config.versions : {mac:required('mac-version'),ios:required('ios-version')};
    const manifest={schema:1,train,tag,source,...allocation,createdAt:new Date().toISOString(),ci:proof,
        selectedAlpha:alpha?.tag ?? null,toolchain:'Xcode 26.2',dependenciesHash:digest(git('show',`${source}:Package.resolved`)),surfaces:{}};
    for(const surface of surfaces) {
        const platform=surface === 'ios'?'ios':'mac';
        const base=train === 'alpha' ? git('rev-parse', `${source}^1`) : baseline(all,surface);
        git('merge-base','--is-ancestor',base,source);
        const commits=parseCommits(git('log','--first-parent','--reverse','--format=%H%x1f%s%x1f%b%x1e',`${base}..${source}`));
        const notes=notesFor(commits,platform,`https://github.com/${repo}/compare/${base}...${source}`);
        const storeNotes=notes.length <= 4000 ? notes : notes.slice(0,3900)+'\nFull release notes are available in the app.';
        manifest.surfaces[surface]={build:surface === "mac-direct" ? allocation.build : `${1000+Math.floor(allocation.ordinal/10000)}.${Math.floor(allocation.ordinal/100)%100}.${allocation.ordinal%100}`,version:versions[platform],baseline:base,notes,notesHash:digest(notes),storeNotes,storeNotesHash:digest(storeNotes)};
    }
    validateManifest(manifest);
    if(train === 'stable') assertStableVersionAdvance(versions.mac, all.filter(r=>!r.draft && !r.prerelease && /^mac-v\d+\.\d+\.\d+$/.test(r.tag_name)).map(r=>r.tag_name.slice(5)));
    git('config','user.name','github-actions[bot]'); git('config','user.email','github-actions[bot]@users.noreply.github.com');
    git('tag','-a',tag,source,'-F',save('allocation.json',manifest)); git('push','origin',`refs/tags/${tag}`);
    ensureRelease(manifest,all);
    output('tag',tag); output('source',source);
} else if(command === 'configure') {
    const manifest=manifestFor(required('tag')); const surface=required('surface');
    if(!surfaces.includes(surface)) throw Error('Invalid surface');
    if(git('rev-parse','HEAD') !== manifest.source) throw Error('Worker checked out wrong source');
    if(digest(readFileSync('Package.resolved','utf8').trim()) !== manifest.dependenciesHash) throw Error('Dependency lock does not match tested source');
    const config=json('Sources/SpeakCore/Resources/ReleaseTrains.json')[manifest.train];
    const item=manifest.surfaces[surface];
    const values={TUIST_RELEASE_TRAIN:manifest.train,RELEASE_TRAIN:manifest.train,RELEASE_TAG:manifest.tag,
        RELEASE_SOURCE:manifest.source,RELEASE_VERSION:item.version,BUILD_NUMBER:item.build,
        DOWNLOAD_TAG:manifest.train === "alpha" ? manifest.tag : `mac-v${item.version}`,
        CLI_VERSION:manifest.train === "alpha" ? `${item.version}-alpha.${manifest.ordinal}` : item.version,
        BUNDLE_ID:config[surface==='ios'?'iosBundleIdentifier':surface==='mac-store'?'storeMacBundleIdentifier':'directMacBundleIdentifier'],
        PRODUCT_NAME:surface==='ios'?config.directMacProductName:config[surface==='mac-store'?'storeMacProductName':'directMacProductName'],
        IOS_APP_GROUP:config.iosAppGroup,IOS_CLOUD_CONTAINER:config.iosCloudContainer,MAC_CLOUD_CONTAINER:config.macCloudContainer,
        FEED_URL:config.feedURL,ARM64_FEED_URL:config.arm64FeedURL,TRAIN_DISPLAY_NAME:config.displayName,TRANSPORT_SERVICE:config.transportServiceType};
    if(!process.env.GITHUB_ENV) throw Error('Configure runs inside a release job');
    for(const [key,value] of Object.entries(values)) writeFileSync(process.env.GITHUB_ENV,`${key}=${value}\n`,{flag:'a'});
    writeFileSync('VERSION',item.version+'\n');
    const cataloguePath='Sources/SpeakCore/Resources/ReleaseNotes.json';
    const existing=json(cataloguePath).entries.filter(e=>(e.train??'stable') === manifest.train);
    if(manifest.train === 'alpha') {
        const published=new Set(releases().filter(r=>!r.draft && r.tag_name.startsWith('alpha-build-')).map(r=>r.tag_name));
        const history=git('tag','--list','alpha-build-*').split('\n').filter(tag=>published.has(tag))
            .map(manifestFor).filter(m=>m.ordinal < manifest.ordinal).sort((a,b)=>b.ordinal-a.ordinal).slice(0,12);
        for(const prior of history) {
            try { git('merge-base','--is-ancestor',prior.source,manifest.source); } catch { continue; }
            const previous=prior.surfaces[surface];
            existing.push({platform:surface==='ios'?'ios':'mac',train:'alpha',build:previous.build,version:previous.version,
                tag:prior.tag,publishedAt:prior.createdAt,markdown:previous.notes});
        }
    }
    const entry={platform:surface==='ios'?'ios':'mac',train:manifest.train,build:item.build,version:item.version,tag:manifest.tag,publishedAt:manifest.createdAt,markdown:item.notes};
    writeFileSync(cataloguePath,JSON.stringify(buildCatalogue({entries:mergeEntries(existing,[entry])}),null,2)+'\n');
    writeFileSync(join(process.env.RUNNER_TEMP,'release-notes.md'),item.notes);
    writeFileSync(join(process.env.RUNNER_TEMP,'release-notes.html'),notesHTML(manifest,surface));
    writeFileSync(join(process.env.RUNNER_TEMP,'release-manifest.json'),JSON.stringify(manifest,null,2)+'\n');
} else if(command === 'status') {
    const manifest=manifestFor(required('tag')); const surface=required('surface');
    const release=releases().find(r=>r.tag_name===manifest.tag);
    const asset=release?.assets.find(a=>a.name===`${surface}-receipt.json`);
    let status='missing';
    if(asset) {
        const receipt=JSON.parse(gh('api',`repos/${repo}/releases/assets/${asset.id}`,'-H','Accept: application/octet-stream'));
        if(receipt.source === manifest.source && receipt.build === manifest.surfaces[surface].build && receipt.notesHash === manifest.surfaces[surface].notesHash) status=receipt.status;
    }
    output('status',status);
} else if(command === 'receipt') {
    const manifest=manifestFor(required('tag')); const surface=required('surface');
    const receipt={source:manifest.source,build:manifest.surfaces[surface].build,notesHash:manifest.surfaces[surface].notesHash,run:process.env.GITHUB_RUN_ID,status:required('status'),assets:{}};
    for(const path of args.filter((v,i)=>i>0 && args[i-1]==='--asset')) receipt.assets[path.split('/').at(-1)]=digest(readFileSync(path));
    upload(manifest.tag,`${surface}-receipt.json`,receipt,true);
} else if(command === 'publish-alpha') {
    const manifest=manifestFor(required('tag')); if(manifest.train !== 'alpha') throw Error('Alpha only');
    ci(manifest.source);
    const receiptAsset=releases().find(r=>r.tag_name===manifest.tag)?.assets.find(a=>a.name==='mac-direct-receipt.json');
    if(!receiptAsset) throw Error('No verified direct Alpha receipt');
    const receipt=JSON.parse(gh('api',`repos/${repo}/releases/assets/${receiptAsset.id}`,'-H','Accept: application/octet-stream'));
    if(receipt.status !== 'verified' || receipt.source !== manifest.source || receipt.build !== manifest.surfaces['mac-direct'].build || receipt.notesHash !== manifest.surfaces['mac-direct'].notesHash) throw Error('Direct Alpha is not verified');
    gh('release','edit',manifest.tag,'--repo',repo,'--draft=false','--prerelease','--latest=false');
    // Mutable pointer uses an explicit prerelease, never GitHub Latest.
    const all=releases(); const pointer=all.find(r=>r.tag_name==='alpha-latest');
    let current;
    if(pointer) { const directory=join(temp,'pointer'); mkdirSync(directory); gh('release','download','alpha-latest','--repo',repo,'--pattern','alpha-pointer.json','--dir',directory); current=json(join(directory,'alpha-pointer.json')); }
    if(current) {
        try { git('merge-base','--is-ancestor',current.source,manifest.source); }
        catch { console.log('Older source completed late; keeping newer Alpha pointer'); process.exit(0); }
    }
    if(canAdvance(current,manifest)) {
        if(!pointer) gh('release','create','alpha-latest','--repo',repo,'--target',manifest.source,'--prerelease','--latest=false','--title','Latest Alpha downloads','--notes','Alpha only. Stable downloads remain on the website.');
        // Single JSON pointer is atomically replaced. Website worker resolves
        // all assets against it, so feeds and CLI never mix two releases.
        upload('alpha-latest','alpha-pointer.json',{tag:manifest.tag,build:manifest.build,source:manifest.source},true);
    }
} else if(command === 'publish') {
    if(process.env.GITHUB_ACTOR !== repo.split('/')[0]) throw Error('Only the repository owner may approve Stable');
    const manifest=manifestFor(required('tag'));
    if(manifest.train !== 'stable') throw Error('Stable candidate required');
    const bytes=JSON.stringify(manifest,null,2)+'\n';
    if(required('approved-hash') !== digest(bytes)) throw Error('Approval does not match the frozen manifest');
    ci(manifest.source);
    const all=releases();
    for(const release of all.filter(r=>r.tag_name.startsWith('stable-candidate-'))) {
        const newer=manifestFor(release.tag_name);
        if(newer.ordinal > manifest.ordinal && surfaces.some(s=>newer.surfaces[s].version === manifest.surfaces[s].version)) {
            throw Error('A newer candidate supersedes this platform/version; prepare it again to select this source explicitly');
        }
    }
    const directory=join(temp,'approved'); mkdirSync(directory);
    gh('release','download',manifest.tag,'--repo',repo,'--dir',directory);
    for(const surface of surfaces) {
        const receipt=json(join(directory,`${surface}-receipt.json`));
        if(receipt.source !== manifest.source || receipt.build !== manifest.surfaces[surface].build || receipt.notesHash !== manifest.surfaces[surface].notesHash || receipt.status !== 'verified') throw Error(`Candidate not verified: ${surface}`);
        for(const [asset,hash] of Object.entries(receipt.assets)) {
            if(digest(readFileSync(join(directory,asset))) !== hash) throw Error(`Candidate asset changed: ${asset}`);
        }
    }
    const direct=json(join(directory,'mac-direct-receipt.json'));
    if(Object.keys(direct.assets).length !== 8) throw Error('Direct Mac candidate must have both DMGs, feeds and signed CLI');
    const tag=`mac-v${manifest.surfaces['mac-direct'].version}`;
    const prior=all.find(r=>r.tag_name===tag);
    assertStableVersionAdvance(manifest.surfaces['mac-direct'].version, all.filter(r=>!r.draft && !r.prerelease && /^mac-v\d+\.\d+\.\d+$/.test(r.tag_name)).map(r=>r.tag_name.slice(5)), !!prior);
    if(prior && git('rev-parse',`${tag}^{commit}`) !== manifest.source) throw Error('Stable version already belongs to different source');
    upload(manifest.tag,'approval.json',{manifestHash:digest(bytes),actor:process.env.GITHUB_ACTOR,run:process.env.GITHUB_RUN_ID,approvedAt:new Date().toISOString()},true);
    if(!prior) {
        const existingTag=git('tag','--list',tag);
        if(existingTag && git('rev-parse',`${tag}^{commit}`) !== manifest.source) throw Error('Stable tag belongs to different source');
        if(!existingTag) git('tag',tag,manifest.source);
        git('push','origin',`refs/tags/${tag}`);
        gh('release','create',tag,...Object.keys(direct.assets).map(a=>join(directory,a)),save('release-manifest.json',manifest),
            '--repo',repo,'--draft','--latest=false','--title',tag,'--notes-file',save('notes.md',manifest.surfaces['mac-direct'].notes));
    }
    gh('release','edit',tag,'--repo',repo,'--draft=false','--prerelease=false','--latest=true');
    writeFileSync(join(process.env.RUNNER_TEMP,'release-manifest.json'),bytes);
    const assets=Object.keys(direct.assets);
    const arm=assets.find(a=>a.endsWith('-arm64.dmg')), universal=assets.find(a=>a.endsWith('-universal.dmg'));
    const cliArm=assets.find(a=>a.endsWith('-arm64.zip')), cliIntel=assets.find(a=>a.endsWith('-x86_64.zip'));
    execFileSync('bash',['scripts/update-homebrew-tap.sh',manifest.surfaces['mac-direct'].version,direct.assets[arm],direct.assets[universal],direct.assets[cliArm],direct.assets[cliIntel]],{stdio:'inherit',env:{...process.env,GH_TOKEN:process.env.HOMEBREW_TOKEN}});
    console.log(`Published verified Stable ${tag}; Apple review follows independently`);
 } else if(command === 'withdraw') {
    const manifest=manifestFor(required('tag'));
    if(manifest.train !== 'stable') throw Error('Stable only');
    const all=releases();
    const approvalAsset=all.find(r=>r.tag_name===manifest.tag)?.assets.find(a=>a.name==='approval.json');
    if(!approvalAsset) process.exit(0);
    const approval=JSON.parse(gh('api',`repos/${repo}/releases/assets/${approvalAsset.id}`,'-H','Accept: application/octet-stream'));
    if(approval.run !== process.env.GITHUB_RUN_ID || approval.manifestHash !== digest(JSON.stringify(manifest,null,2)+'\n')) process.exit(0);
    const tag=`mac-v${manifest.surfaces['mac-direct'].version}`;
    if(all.some(r=>r.tag_name===tag && !r.draft)) gh('release','edit',tag,'--draft=true','--repo',repo);
} else if(command === 'reconcile') {
    const config=json('Config/ReleasePipeline.json');
    if(!config.enabled) { console.log('Alpha activation awaits archive/device verification'); process.exit(0); }
    const adoption=git('log','--first-parent','--diff-filter=A','--format=%H','origin/main','--','scripts/release-train.mjs').split('\n')[0];
    if(!adoption) throw Error('Cannot determine Alpha adoption boundary');
    const runs=JSON.parse(gh('api','--paginate','--slurp',`repos/${repo}/actions/workflows/ci.yml/runs?event=push&branch=main&status=success&per_page=100`)).flatMap(p=>p.workflow_runs);
    const existing=releases();
    const pointerAsset=existing.find(r=>r.tag_name==='alpha-latest')?.assets.find(a=>a.name==='alpha-pointer.json');
    const pointer=pointerAsset ? JSON.parse(gh('api',`repos/${repo}/releases/assets/${pointerAsset.id}`,'-H','Accept: application/octet-stream')) : null;
    const allocated=new Map(existing.filter(r=>r.tag_name.startsWith('alpha-build-')).sort((a,b)=>Number(a.tag_name.split('-').at(-1))-Number(b.tag_name.split('-').at(-1))).map(r=>[git('rev-parse',`${r.tag_name}^{commit}`),r]));
    const active=api(`repos/${repo}/actions/workflows/alpha-release.yml/runs?per_page=100`).workflow_runs.filter(r=>r.status !== 'completed');
    const seen=new Set();
    for(const r of runs.reverse()) {
        try {git('merge-base','--is-ancestor',adoption,r.head_sha);} catch {continue;}
        if(seen.has(r.head_sha)) continue;
        seen.add(r.head_sha);
        if(active.some(a=>a.display_title === `Alpha ${r.head_sha}`)) continue;
        const allocatedRelease=allocated.get(r.head_sha);
        if(allocatedRelease) {
            const allocatedManifest=manifestFor(allocatedRelease.tag_name);
            let complete=true;
            for(const surface of surfaces) {
                const asset=allocatedRelease.assets.find(a=>a.name===`${surface}-receipt.json`);
                if(!asset) {complete=false;break;}
                const receipt=JSON.parse(gh('api',`repos/${repo}/releases/assets/${asset.id}`,'-H','Accept: application/octet-stream'));
                const item=allocatedManifest.surfaces[surface];
                if(receipt.status !== 'verified' || receipt.source !== allocatedManifest.source || receipt.build !== item.build || receipt.notesHash !== item.notesHash) {complete=false;break;}
            }
            if(complete && !allocatedRelease.draft && pointer && !canAdvance(pointer,allocatedManifest)) continue;
        }
        gh('workflow','run','alpha-release.yml','--repo',repo,'--ref','main','-f',`source=${r.head_sha}`);
    }
} else { throw Error(`Unknown command ${command}`); }
