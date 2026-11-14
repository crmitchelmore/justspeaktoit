// Shared by the browser checklist and the results workflow, so it must stay dependency-free.
export const RESULTS_FORMAT = 1;
export const RESULTS_FENCE = 'manual-qa-results';
export const RESULTS_LABEL = 'manual-qa-results';
export const REPOSITORY = 'crmitchelmore/justspeaktoit';
export const MAX_NOTE_LENGTH = 2000;
export const MAX_ISSUE_URL_LENGTH = 7500;

// Backticks would let a note close the fence, so encode them inside the JSON.
// compact moves passes and skips into id lists, so a full run's link grows by
// little more than each check's id.
export function encodeResultsBlock(catalogue, results, compact = false) {
  const block = { format: RESULTS_FORMAT, catalogue, results };
  if (compact) {
    const ids = kind => results.filter(entry => entry.result === kind && !entry.note).map(entry => entry.id);
    block.results = results.filter(entry => !(entry.result === 'pass' || entry.result === 'skip') || entry.note);
    for (const kind of ['pass', 'skip']) if (ids(kind).length) block[kind] = ids(kind);
  }
  const json = JSON.stringify(block).replace(/`/g, '\\u0060');
  return `\`\`\`${RESULTS_FENCE}\n${json}\n\`\`\``;
}

function quote(text) {
  return text.split(/\r?\n/).map(line => `> ${line}`).join('\n');
}

// results: [{ id, result: 'pass'|'fail'|'skip', note? } | { id, choice }]
// items: catalogue items keyed by id, used only for human-readable titles.
// compact lists only failures and decisions so a full run still fits in a link.
export function formatResultsIssue({ catalogue, results, items, date, compact = false }) {
  const count = kind => results.filter(entry => entry.result === kind).length;
  const decisions = results.filter(entry => entry.choice !== undefined).length;
  const summary = [`${count('pass')} pass`, `${count('fail')} fail`, `${count('skip')} skip`];
  if (decisions) summary.push(`${decisions} decision${decisions === 1 ? '' : 's'}`);
  const title = `Manual QA results ${date} (${summary.join(', ')})`;
  const lines = ['Submitted from https://justspeaktoit.com/qa. The results workflow comments on each linked issue.', ''];
  for (const entry of results) {
    const item = items[entry.id] || {};
    const reference = item.issues?.length ? ` (${item.issues.map(issue => `#${issue}`).join(', ')})` : '';
    if (entry.choice !== undefined) {
      const option = (item.options || []).find(candidate => candidate.id === entry.choice);
      lines.push(`- **Decision** ${item.title || entry.id}${reference}: ${option ? option.label : entry.choice}`);
    } else if (!compact || entry.result === 'fail') {
      lines.push(`- **${entry.result.toUpperCase()}** ${item.title || entry.id}${reference}`);
      if (entry.note) lines.push('', quote(entry.note), '');
    }
  }
  if (compact) lines.push(`- Passes and skips: see the results block (${summary.join(', ')}).`);
  lines.push('', '<!-- Machine-readable results: do not edit below this line. -->', encodeResultsBlock(catalogue, results, compact));
  return { title, body: lines.join('\n') };
}

export function newIssueUrl({ title, body }) {
  const query = new URLSearchParams({ labels: RESULTS_LABEL, title, body });
  return `https://github.com/${REPOSITORY}/issues/new?${query}`;
}
