import assert from 'node:assert/strict';
import {test} from 'node:test';
import {allowedUpdates,checksPassed,countedPages,eligiblePull,reconcile,completeCommits,publicationApi,reviewEligible} from './dependabot-merge.mjs';
const repo='owner/project',sha='a'.repeat(40);
const pull={number:9,commits:1,state:'open',draft:false,user:{login:'dependabot[bot]',type:'Bot'},base:{ref:'main',repo:{full_name:repo}},head:{sha,repo:{full_name:repo}}};
const commit=(from='1.2.3',to='1.2.4',type='patch')=>({sha,author:{login:'dependabot[bot]',type:'Bot'},committer:{login:'web-flow'},parents:[{sha:'d'.repeat(40)}],commit:{verification:{verified:true},message:`Bumps a from ${from} to ${to}.\n---\nupdated-dependencies:\n- dependency-name: a\n  update-type: version-update:semver-${type}\n`}});
const run={id:1,head_sha:sha,path:'.github/workflows/ci.yml',event:'pull_request',status:'completed',conclusion:'success'};
const check={id:2,head_sha:sha,status:'completed',conclusion:'success'};
function fixture(changes={}){
 const commands=[];let reviews=0;
 const api=async path=>{
  if(changes.error&&path.includes(changes.error))throw Error('HTTP503');
  if(path.includes('/pulls?'))return [[pull]];
  if(path.endsWith('/commits?per_page=100'))return [changes.commits??[commit()]];
  if(path.includes('/actions/runs?'))return [{total_count:1,workflow_runs:[run]}];
  if(path.includes('/check-runs?'))return changes.pages??[{total_count:1,check_runs:[check]}];
  if(path.endsWith('/status'))return {total_count:0,state:'pending'};
  if(path.endsWith('/pulls/9'))return changes.pull??pull;
  throw Error('Unexpected API path '+path);
 };
 const gh=async args=>{commands.push(args);if(args[1]==='view'){reviews++;return JSON.stringify(reviews===2&&changes.finalReview?changes.finalReview:{headRefOid:sha,baseRefName:'main',isDraft:false,reviewDecision:changes.review??''});}return '';};
 return {api,gh,commands};
}
test('only exact same-repository bot PRs targeting main qualify',()=>{
 assert.equal(eligiblePull(pull,repo),true);
 for(const p of [{...pull,draft:true},{...pull,user:{login:'someone-dependabot',type:'Bot'}},{...pull,head:{...pull.head,repo:{full_name:'fork/project'}}},{...pull,base:{...pull.base,ref:'stable'}}])assert.equal(eligiblePull(p,repo),false);
});
test('only explicit stable patch/minor metadata qualifies; unknown, major, prerelease and pre1.0 minor refuse',()=>{
 assert.equal(allowedUpdates([commit()]),true);assert.equal(allowedUpdates([commit('1.2.3','1.3.0','minor')]),true);assert.equal(allowedUpdates([commit('0.2.3','0.2.4')]),true);
 for(const c of [commit('0.2.3','0.3.0','minor'),commit('1.0.0','2.0.0','major'),commit('1.0.0','1.0.1-rc.1'),commit('1.0.0','1.0.1','unknown'),{...commit(),parents:[{},{}]},{...commit(),author:{login:'owner',type:'User'}}])assert.equal(allowedUpdates([c]),false);
});
test('missing, duplicate, changing and truncated pagination refuses',()=>{
 for(const p of [[],[{total_count:2,check_runs:[check]}],[{total_count:2,check_runs:[check,check]}],[{total_count:1,check_runs:[check]},{total_count:2,check_runs:[]}],[{check_runs:[check]}]])assert.throws(()=>countedPages(p,'check_runs'));
 assert.deepEqual(countedPages([{total_count:1,check_runs:[check]}],'check_runs'),[check]);
});
test('CI is mandatory even when another arbitrary check succeeds; pending/failing/foreign evidence refuses',()=>{
 assert.equal(checksPassed([run],[check],{total_count:0,state:'pending'},sha,run.path),true);
 assert.equal(checksPassed([{...run,path:'other.yml'}],[check],{total_count:0,state:'pending'},sha,run.path),false);
 assert.equal(checksPassed([run],[{...check,status:'in_progress'}],{total_count:0,state:'pending'},sha,run.path),false);
 assert.equal(checksPassed([run],[check],{total_count:1,state:'failure'},sha,run.path),false);
 assert.throws(()=>checksPassed([run],[{...check,head_sha:'b'.repeat(40)}],{total_count:0,state:'pending'},sha,run.path));
});
for(const error of ['/check-runs?','/actions/runs?','/status','/commits?per_page'])test(`API failure ${error} cannot reach merge`,async()=>{
 const f=fixture({error});await assert.rejects(reconcile({repo,...f}));assert.equal(f.commands.some(args=>args[1]==='merge'),false);
});
test('a partial successful response cannot reach merge',async()=>{
 const f=fixture({pages:[{total_count:2,check_runs:[check]}]});await assert.rejects(reconcile({repo,...f}));assert.equal(f.commands.some(args=>args[1]==='merge'),false);
});
test('publication contention and requested changes refuse merge',async()=>{
 const f=fixture();await assert.rejects(reconcile({repo,...f,publicationGate:async()=>{throw Error('release active');}}));assert.equal(f.commands.some(args=>args[1]==='merge'),false);
 const review=fixture({review:'CHANGES_REQUESTED'});assert.deepEqual(await reconcile({repo,...review}),{merged:null});
});
test('complete evidence passes the publication gate and merges once at the verified SHA',async()=>{
 const f=fixture();let gate=0;
 assert.deepEqual(await reconcile({repo,...f,publicationGate:async()=>{gate++;}}),{merged:9,sha});assert.equal(gate,1);
 assert.deepEqual(f.commands.filter(args=>args[1]==='merge'),[['pr','merge','9','--repo',repo,'--squash','--match-head-commit',sha]]);
});

test('late draft/base changes and absent review fields never reach merge',async()=>{
 for(const finalReview of [{headRefOid:sha,baseRefName:'stable',isDraft:false,reviewDecision:''},{headRefOid:sha,baseRefName:'main',isDraft:true,reviewDecision:''},{headRefOid:sha,baseRefName:'main',reviewDecision:''},{headRefOid:sha,baseRefName:'main',isDraft:false}]){
  const f=fixture({finalReview});assert.deepEqual(await reconcile({repo,...f}),{merged:null});assert.equal(f.commands.some(a=>a[1]==='merge'),false);
 }
 assert.equal(eligiblePull({...pull,draft:undefined},repo),false);
 assert.equal(reviewEligible({headRefOid:sha,baseRefName:'main',isDraft:false,reviewDecision:null},sha),false);
});
test('commit census requires unique identities, the actual head and linear parents',()=>{
 const first={...commit(),sha:'b'.repeat(40)},last={...commit(),parents:[{sha:first.sha}]};
 assert.deepEqual(completeCommits([first,last],{...pull,commits:2}),[first,last]);
 for(const cs of [[first,first],[last,first],[first,commit()]])assert.throws(()=>completeCommits(cs,{...pull,commits:2}));
 assert.throws(()=>completeCommits([first],pull));
});
test('malformed, unchanged and downgraded versions and unverifiable signatures refuse',()=>{
 for(const c of [commit('1.02.3','1.2.4'),commit('1.2.3','1.2.4.5'),commit('1.2.3','1.2.4junk'),commit('1.2.4','1.2.3'),commit('1.3.0','1.2.9'),commit('1.2.3','1.2.3'),{...commit(),commit:{...commit().commit,verification:{verified:'true'}}}])assert.equal(allowedUpdates([c]),false);
});
test('publication discovery preserves every page and refuses inconsistent or unknown rows',async()=>{
 const path='repos/owner/project/actions/workflows/ci.yml/runs?status=queued&per_page=100';
 const rows=Array.from({length:101},(_,i)=>({id:i+1,status:'queued',head_branch:i===100?'main':'feature',event:i===100?'push':'pull_request'}));
 let requested=false;const adapted=publicationApi(async(p,paginated)=>{assert.equal(p,path);requested=paginated;return [{total_count:101,workflow_runs:rows.slice(0,100)},{total_count:101,workflow_runs:rows.slice(100)}];});
 const result=await adapted(path);assert.equal(requested,true);assert.equal(result.workflow_runs.length,101);assert.equal(result.workflow_runs.at(-1).head_branch,'main');
 for(const pages of [[{total_count:1,workflow_runs:[]}],[{total_count:1,workflow_runs:[{id:1,status:'queued'}]}],[{total_count:1,workflow_runs:[{...rows[0],status:'completed'}]}]])await assert.rejects(publicationApi(async()=>pages)(path));
});
