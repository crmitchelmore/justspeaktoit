// Applies owner manual QA results submitted from justspeaktoit.com/qa.
// Issue text is only ever parsed as data; nothing from it is executed.
import { readFile } from 'node:fs/promises';
import { loadCatalogue, parseResults, planActions } from '../../landing-page/qa/manual-checks.mjs';
import { RESULTS_LABEL } from '../../landing-page/qa/results-format.mjs';

export const ALLOWED_AUTHORS = ['crmitchelmore', 'bravostation'];
const PROCESSED = '<!-- manual-qa-processed -->';

export function githubClient({ token, repository, fetchImpl = fetch }) {
  return async (method, path, body) => {
    const response = await fetchImpl(`https://api.github.com/repos/${repository}${path}`, {
      method,
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
        'X-GitHub-Api-Version': '2022-11-28',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!response.ok) throw new Error(`GitHub ${method} ${path} failed with ${response.status}`);
    return response.status === 204 ? null : response.json();
  };
}

export async function processResultsIssue({ event, catalogueSource, request, log = console.log }) {
  const issue = event.issue;
  if (!issue || issue.pull_request) return { skipped: 'not an issue' };
  if (!ALLOWED_AUTHORS.includes(issue.user?.login) || !ALLOWED_AUTHORS.includes(event.sender?.login)) {
    return { skipped: 'author or sender is not allowed' };
  }
  if (!issue.labels?.some(label => label.name === RESULTS_LABEL)) return { skipped: 'missing label' };
  if (issue.state !== 'open') return { skipped: 'issue is closed' };

  const comments = await request('GET', `/issues/${issue.number}/comments?per_page=100`);
  if (comments.some(comment => comment.user?.type === 'Bot' && comment.body?.includes(PROCESSED))) {
    return { skipped: 'already processed' };
  }

  const catalogue = loadCatalogue(catalogueSource);
  let parsed;
  try {
    parsed = parseResults(issue.body, catalogue);
  } catch (error) {
    const reason = String(error.message).replace(/[`@]/g, '');
    await request('POST', `/issues/${issue.number}/comments`, {
      body: `These results could not be processed: ${reason}\n\nEdit the issue body to fix the results block and the workflow will retry.`,
    });
    throw error;
  }

  const plan = planActions(parsed, catalogue, issue.number);
  for (const comment of plan.comments) {
    await request('POST', `/issues/${comment.issue}/comments`, { body: comment.body });
    log(`Commented on #${comment.issue}`);
  }
  const closed = [];
  for (const number of plan.close) {
    const target = await request('GET', `/issues/${number}`);
    if (target.state === 'open' && !target.pull_request) {
      await request('PATCH', `/issues/${number}`, { state: 'closed', state_reason: 'completed' });
      closed.push(number);
      log(`Closed #${number}`);
    }
  }
  await request('POST', `/issues/${issue.number}/comments`, { body: plan.summary });
  await request('PATCH', `/issues/${issue.number}`, { state: 'closed', state_reason: 'completed' });
  return { commented: plan.comments.map(comment => comment.issue), closed };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const event = JSON.parse(await readFile(process.env.GITHUB_EVENT_PATH, 'utf8'));
  const catalogueSource = await readFile(new URL('../../Docs/manual-checks.yml', import.meta.url), 'utf8');
  const request = githubClient({ token: process.env.GITHUB_TOKEN, repository: process.env.GITHUB_REPOSITORY });
  const outcome = await processResultsIssue({ event, catalogueSource, request });
  console.log(JSON.stringify(outcome));
}
