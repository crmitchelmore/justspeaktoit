import { MAX_ISSUE_URL_LENGTH, formatResultsIssue, newIssueUrl } from './results-format.js';

const STORAGE_KEY = 'jsti-manual-qa-v1';
const data = JSON.parse(document.getElementById('qa-data').textContent);
const itemsById = Object.fromEntries(data.items.map(item => [item.id, item]));
const progress = document.getElementById('qa-progress');
const progressBar = document.getElementById('qa-progress-bar');
const status = document.getElementById('qa-status');
const submit = document.getElementById('qa-submit');
const copy = document.getElementById('qa-copy');

function load() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}');
    return Object.fromEntries(Object.entries(saved.answers || {}).filter(([id]) => itemsById[id]));
  } catch {
    return {};
  }
}

let answers = load();

function save() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ answers }));
  } catch {
    status.textContent = 'Could not save answers on this device; submit before leaving the page.';
  }
}

function results() {
  return data.items.filter(item => answers[item.id]).map(item => {
    const answer = answers[item.id];
    if (item.kind === 'decision') return { id: item.id, choice: answer.choice };
    const note = answer.result === 'fail' ? (answer.note || '').trim() : '';
    return note ? { id: item.id, result: answer.result, note } : { id: item.id, result: answer.result };
  });
}

function render() {
  const answered = data.items.filter(item => answers[item.id]).length;
  const remaining = data.items.filter(item => !answers[item.id]).reduce((sum, item) => sum + item.minutes, 0);
  progress.textContent = `${answered} of ${data.items.length} answered · ~${remaining} min left`;
  progressBar.value = answered;
  submit.disabled = answered === 0;
  copy.disabled = answered === 0;
  submit.textContent = answered ? `Submit ${answered} result${answered === 1 ? '' : 's'}` : 'Submit results';
  for (const article of document.querySelectorAll('.qa-item')) {
    const answer = answers[article.dataset.id];
    article.classList.toggle('is-answered', Boolean(answer));
    const note = article.querySelector('.qa-note');
    if (note) note.hidden = answer?.result !== 'fail';
  }
}

function restore() {
  for (const [id, answer] of Object.entries(answers)) {
    const value = answer.result || answer.choice;
    const input = document.querySelector(`input[name="result-${CSS.escape(id)}"][value="${CSS.escape(value)}"]`);
    if (input) input.checked = true;
    const note = document.getElementById(`note-${id}`);
    if (note && answer.note) note.value = answer.note;
  }
}

document.addEventListener('change', event => {
  const input = event.target;
  if (!(input instanceof HTMLInputElement) || !input.name.startsWith('result-')) return;
  const id = input.name.slice('result-'.length);
  const item = itemsById[id];
  if (!item) return;
  answers[id] = item.kind === 'decision' ? { choice: input.value } : { result: input.value, note: answers[id]?.note || '' };
  save();
  render();
  if (input.value === 'fail') document.getElementById(`note-${id}`)?.focus();
});

document.addEventListener('input', event => {
  const area = event.target;
  if (!(area instanceof HTMLTextAreaElement) || !area.id.startsWith('note-')) return;
  const id = area.id.slice('note-'.length);
  if (answers[id]) {
    answers[id].note = area.value;
    save();
  }
});

function issue(compact = false) {
  return formatResultsIssue({
    catalogue: data.catalogue, results: results(), items: itemsById, date: new Date().toISOString().slice(0, 10), compact,
  });
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

submit.addEventListener('click', async () => {
  const report = issue();
  const url = [newIssueUrl(report), newIssueUrl(issue(true))].find(candidate => candidate.length <= MAX_ISSUE_URL_LENGTH);
  if (url) {
    window.open(url, '_blank', 'noopener');
    status.textContent = 'Opened GitHub with your results. Press "Submit new issue" there to finish.';
    return;
  }
  // Start the copy and open the tab within the tap so Safari keeps both allowed.
  const copying = copyText(report.body);
  window.open(newIssueUrl({ title: report.title, body: 'Replace this text by pasting the copied manual QA results.' }), '_blank', 'noopener');
  const copied = await copying;
  status.textContent = copied
    ? 'Results were too long for a link, so they are on your clipboard. Replace the issue text with a paste, then submit.'
    : 'Results were too long for a link and could not be copied automatically. Use Copy results, then paste into the issue.';
});

copy.addEventListener('click', async () => {
  const report = issue();
  status.textContent = await copyText(`${report.title}\n\n${report.body}`)
    ? 'Results copied. Paste them into a new issue labelled manual-qa-results.'
    : 'Copy failed. Your browser blocked clipboard access.';
});

document.getElementById('qa-clear').addEventListener('click', () => {
  if (!window.confirm('Clear every answer saved on this device?')) return;
  answers = {};
  save();
  for (const input of document.querySelectorAll('input[name^="result-"]')) input.checked = false;
  for (const area of document.querySelectorAll('.qa-note textarea')) area.value = '';
  status.textContent = 'Answers cleared.';
  render();
});

restore();
render();
