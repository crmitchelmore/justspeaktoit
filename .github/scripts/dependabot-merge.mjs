// Trusted default-branch policy only. No pull-request source, artifact or dependency is executed.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';

export function countedPages(pages,key){
 assert.ok(Array.isArray(pages)&&pages.length,'Missing paginated evidence');
 const total=pages[0].total_count;
 assert.ok(Number.isSafeInteger(total)&&total>=0&&total<=1000,'Unbounded or missing count');
 const rows=pages.flatMap(page=>{assert.equal(page.total_count,total,'Count changed during discovery');assert.ok(Array.isArray(page[key]),'Missing page rows');return page[key];});
 assert.equal(rows.length,total,'Incomplete paginated evidence');
 assert.equal(new Set(rows.map(row=>row.id)).size,rows.length,'Duplicate or missing rows');
 assert.ok(rows.every(row=>Number.isSafeInteger(row.id)),'Missing row identity');
 return rows;
}
export function arrayPages(pages){
 assert.ok(Array.isArray(pages)&&pages.length&&pages.every(Array.isArray),'Missing array pages');
 const rows=pages.flat();assert.ok(rows.length<=1000,'Unbounded discovery');return rows;
}
export function eligiblePull(pull,repo){
 return Number.isSafeInteger(pull?.number)&&pull.number>0&&pull.state==='open'&&pull.draft===false&&
 pull.user?.login==='dependabot[bot]'&&pull.user?.type==='Bot'&&pull.base?.ref==='main'&&
 pull.base?.repo?.full_name===repo&&pull.head?.repo?.full_name===repo&&/^[a-f0-9]{40}$/.test(pull.head?.sha??'');
}
export function allowedUpdates(commits){
 if(!Array.isArray(commits)||!commits.length)return false;
 return commits.every(commit=>{
  // Human edits and merge commits need ordinary review; no broad multi-parent exemption.
  if(commit.author?.login!=='dependabot[bot]'||commit.author?.type!=='Bot'||commit.parents?.length!==1||commit.commit?.verification?.verified!==true||!['dependabot[bot]','web-flow'].includes(commit.committer?.login)||!/^[a-f0-9]{40}$/.test(commit.sha??'')||!/^[a-f0-9]{40}$/.test(commit.parents[0]?.sha??''))return false;
  const message=commit.commit?.message;
  if(typeof message!=='string')return false;
  const types=[...message.matchAll(/^\s*update-type:\s*(\S+)\s*$/gm)].map(match=>match[1]);
  const dependencies=[...message.matchAll(/^\s*-?\s*dependency-name:\s*.+$/gm)];
  if(!types.length||types.length!==dependencies.length||!types.every(type=>['version-update:semver-patch','version-update:semver-minor'].includes(type)))return false;
  const plain=message.replace(/\[([^\]\n]+)\]\([^\n)]*\)/g,'$1');
  const pairs=[...plain.matchAll(/\bfrom v?(\d+)\.(\d+)\.(\d+)([-+][0-9A-Za-z.-]+)? to v?(\d+)\.(\d+)\.(\d+)([-+][0-9A-Za-z.-]+)?(?=\.(?![0-9A-Za-z.+-])|[\s,)]|$)/g)];
  if(pairs.length<dependencies.length)return false;
  return pairs.every(pair=>{
   if(pair[4]||pair[8])return false;
   const old=[pair[1],pair[2],pair[3]],next=[pair[5],pair[6],pair[7]];
   if([...old,...next].some(n=>!Number.isSafeInteger(Number(n))||! /^(0|[1-9][0-9]*)$/.test(n)))return false;
   const [a,b,c]=old.map(Number),[x,y,z]=next.map(Number);
   return a===x&&(a!==0||b===y)&&(y>b||(y===b&&z>c));
  });
 });
}
export function reviewEligible(review,sha){
 return review?.headRefOid===sha&&review.baseRefName==='main'&&review.isDraft===false&&['','APPROVED','REVIEW_REQUIRED'].includes(review.reviewDecision);
}
export function completeCommits(commits,pull){
 assert.ok(Number.isSafeInteger(pull.commits)&&pull.commits>0&&pull.commits<=250&&commits.length===pull.commits,'Incomplete commit evidence');
 assert.equal(new Set(commits.map(c=>c.sha)).size,commits.length,'Duplicate commit identity');
 assert.equal(commits.at(-1)?.sha,pull.head.sha,'Commit evidence missing PR head');
 assert.ok(commits.every((c,i)=>i===0||c.parents?.length===1&&c.parents[0]?.sha===commits[i-1].sha),'Nonlinear commit evidence');
 return commits;
}
export function publicationApi(api){
 return async path=>{
  if(!path.includes('/actions/workflows/')||!path.includes('/runs?'))return api(path);
  const status=new URLSearchParams(path.split('?')[1]).get('status');
  assert.ok(['queued','in_progress','waiting','pending','requested'].includes(status),'Unexpected publication status');
  const rows=countedPages(await api(path,true),'workflow_runs');
  assert.ok(rows.every(run=>run.status===status&&typeof run.head_branch==='string'&&run.head_branch.length>0&&typeof run.event==='string'&&run.event.length>0),'Unknown publication identity');
  return {total_count:rows.length,workflow_runs:rows};
 };
}
export function checksPassed(runs,checks,status,sha,ciPath){
 const allowed=new Set(['success','neutral','skipped']);
 assert.ok(runs.every(run=>run.head_sha===sha),'Foreign workflow evidence');
 assert.ok(checks.every(check=>check.head_sha===sha),'Foreign check evidence');
 const ci=runs.filter(run=>run.path?.split('@')[0]===ciPath&&run.event==='pull_request');
 if(!ci.length||!ci.every(run=>run.status==='completed'&&run.conclusion==='success'))return false;
 if(![...runs,...checks].every(row=>row.status==='completed'&&allowed.has(row.conclusion)))return false;
 assert.ok(Number.isSafeInteger(status.total_count)&&status.total_count>=0&&typeof status.state==='string','Missing status evidence');
 return status.total_count===0||status.state==='success';
}

export async function reconcile({repo,api,gh,publicationGate,limit=10}){
 assert.match(repo,/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/);
 const pulls=arrayPages(await api(`repos/${repo}/pulls?state=open&base=main&per_page=100`,true));
 const candidates=pulls.filter(pull=>eligiblePull(pull,repo)).slice(0,limit);
 for(const candidate of candidates){
  const number=String(candidate.number),sha=candidate.head.sha;
  const pull=await api(`repos/${repo}/pulls/${number}`);
  if(!eligiblePull(pull,repo)||pull.head.sha!==sha)continue;
  const review=JSON.parse(await gh(['pr','view',number,'--repo',repo,'--json','headRefOid,baseRefName,isDraft,reviewDecision']));
  if(!reviewEligible(review,sha))continue;
  const commits=arrayPages(await api(`repos/${repo}/pulls/${number}/commits?per_page=100`,true));
  completeCommits(commits,pull);
  if(!allowedUpdates(commits))continue;
  const runs=countedPages(await api(`repos/${repo}/actions/runs?head_sha=${sha}&per_page=100`,true),'workflow_runs');
  const checks=countedPages(await api(`repos/${repo}/commits/${sha}/check-runs?per_page=100&filter=latest`,true),'check_runs');
  const status=await api(`repos/${repo}/commits/${sha}/status`);
  if(!checksPassed(runs,checks,status,sha,'.github/workflows/ci.yml'))continue;
  // Existing policy owns publication exclusion; never execute its PR revision under the write token.
  if(publicationGate)await publicationGate(number,sha);
  const final=await api(`repos/${repo}/pulls/${number}`);
  const finalReview=JSON.parse(await gh(['pr','view',number,'--repo',repo,'--json','headRefOid,baseRefName,isDraft,reviewDecision']));
  if(!eligiblePull(final,repo)||final.head.sha!==sha||!reviewEligible(finalReview,sha))continue;
  await gh(['pr','merge',number,'--repo',repo,'--squash','--match-head-commit',sha]);
  // One merge per run. Publication requires its own source-bound receipt; this result proves only the merge.
  return {merged:candidate.number,sha};
 }
 return {merged:null};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 const config=JSON.parse(readFileSync(new URL('./dependabot-merge.json',import.meta.url),'utf8'));
 const repo=process.env.GITHUB_REPOSITORY;
 assert.equal(repo,config.repository,'Wrong trusted policy repository');
 assert.equal(typeof config.enabled,'boolean','Missing adoption state');
 if(!config.enabled){console.log('Dependency auto-merge is held until token-safe main CI and publication are commissioned.');process.exit(0);}
 const gh=async args=>execFileSync('gh',args,{encoding:'utf8',timeout:60000,maxBuffer:16*1024*1024});
 const api=async(path,paginate=false)=>JSON.parse(await gh(['api',...(paginate?['--paginate','--slurp']:[]),path]));
 let publicationGate;
 if(config.publicationGate){
  const {verifyMergeWindow,publicationWorkflows}=await import('../../scripts/ci-merge-after-release.mjs');
  publicationGate=async()=>{
   const main=await api(`repos/${repo}/git/ref/heads/main`);
   const files=await api(`repos/${repo}/contents/.github/workflows?ref=${main.object.sha}`);
   assert.ok(Array.isArray(files),'Missing publication workflow inventory');
   await verifyMergeWindow({api:publicationApi(api),repo,expectedMain:main.object.sha,workflows:publicationWorkflows.filter(name=>files.some(file=>file.name===name))});
  };
 }
 const result=await reconcile({repo,api,gh,publicationGate});
 console.log(result.merged?`Merged dependency PR #${result.merged} at ${result.sha}`:'No dependency PR has complete passing merge evidence.');
}
