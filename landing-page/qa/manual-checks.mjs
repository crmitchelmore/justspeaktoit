import { createHash } from 'node:crypto';
import { MAX_NOTE_LENGTH, RESULTS_FENCE, RESULTS_FORMAT } from './results-format.mjs';

export const DEVICES = ['iPhone', 'Watch', 'Mac', 'Android', 'Decision'];
const ID = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

// Docs/manual-checks.yml uses a deliberately small YAML subset: block maps and
// lists, double-quoted (JSON-escaped) strings, integers and booleans. Anything
// else is rejected rather than guessed, so the catalogue cannot drift silently.
export function parseYamlSubset(text) {
  const lines = [];
  text.split(/\r?\n/).forEach((raw, index) => {
    if (/\t/.test(raw)) throw new Error(`Line ${index + 1}: tabs are not allowed`);
    const content = raw.trimEnd();
    const trimmed = content.trimStart();
    if (!trimmed || trimmed.startsWith('#')) return;
    const indent = content.length - trimmed.length;
    if (indent % 2) throw new Error(`Line ${index + 1}: indentation must be a multiple of two spaces`);
    lines.push({ indent, text: trimmed, number: index + 1 });
  });
  if (!lines.length) throw new Error('The catalogue is empty');
  const [value, next] = parseBlock(lines, 0, lines[0].indent);
  if (next !== lines.length) throw new Error(`Line ${lines[next].number}: unexpected indentation`);
  return value;
}

function parseScalar(text, number) {
  if (text.startsWith('"')) {
    try {
      const value = JSON.parse(text);
      if (typeof value === 'string') return value;
    } catch {}
    throw new Error(`Line ${number}: invalid double-quoted string`);
  }
  if (/^-?(0|[1-9]\d*)$/.test(text)) return Number(text);
  if (text === 'true' || text === 'false') return text === 'true';
  throw new Error(`Line ${number}: values must be double-quoted strings, integers or booleans`);
}

function parseBlock(lines, start, indent) {
  return lines[start].text.startsWith('- ') || lines[start].text === '-'
    ? parseList(lines, start, indent)
    : parseMap(lines, start, indent);
}

function parseEntry(line, map) {
  const match = /^([A-Za-z_][A-Za-z0-9_]*):(?: (.*))?$/.exec(line.text);
  if (!match) throw new Error(`Line ${line.number}: expected "key: value"`);
  const [, key, rest] = match;
  if (Object.hasOwn(map, key)) throw new Error(`Line ${line.number}: duplicate key "${key}"`);
  return { key, rest: rest === undefined || rest === '' ? undefined : rest };
}

function parseMap(lines, start, indent, initial = {}) {
  const map = initial;
  let i = start;
  while (i < lines.length && lines[i].indent === indent) {
    const line = lines[i];
    if (line.text.startsWith('-')) throw new Error(`Line ${line.number}: list item where a key was expected`);
    const { key, rest } = parseEntry(line, map);
    i += 1;
    if (rest !== undefined) {
      map[key] = parseScalar(rest, line.number);
    } else {
      if (i >= lines.length || lines[i].indent <= indent) throw new Error(`Line ${line.number}: "${key}" has no value`);
      [map[key], i] = parseBlock(lines, i, lines[i].indent);
    }
  }
  if (i < lines.length && lines[i].indent > indent) throw new Error(`Line ${lines[i].number}: unexpected indentation`);
  return [map, i];
}

function parseList(lines, start, indent) {
  const list = [];
  let i = start;
  while (i < lines.length && lines[i].indent === indent) {
    const line = lines[i];
    if (!line.text.startsWith('- ')) throw new Error(`Line ${line.number}: expected a list item`);
    const content = line.text.slice(2);
    i += 1;
    if (/^[A-Za-z_][A-Za-z0-9_]*:/.test(content)) {
      const first = { ...line, text: content, indent: indent + 2 };
      const map = {};
      const { key, rest } = parseEntry(first, map);
      if (rest !== undefined) {
        map[key] = parseScalar(rest, line.number);
      } else {
        if (i >= lines.length || lines[i].indent <= indent + 2) throw new Error(`Line ${line.number}: "${key}" has no value`);
        [map[key], i] = parseBlock(lines, i, lines[i].indent);
      }
      let item;
      [item, i] = i < lines.length && lines[i].indent === indent + 2 ? parseMap(lines, i, indent + 2, map) : [map, i];
      list.push(item);
    } else {
      list.push(parseScalar(content, line.number));
    }
  }
  if (i < lines.length && lines[i].indent > indent) throw new Error(`Line ${lines[i].number}: unexpected indentation`);
  return [list, i];
}

function fail(path, message) {
  throw new Error(`${path}: ${message}`);
}

function expectKeys(value, path, required, optional = []) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(path, 'expected a map');
  for (const key of required) if (!Object.hasOwn(value, key)) fail(path, `missing "${key}"`);
  for (const key of Object.keys(value)) {
    if (!required.includes(key) && !optional.includes(key)) fail(path, `unknown key "${key}"`);
  }
}

function text(value, path, max = 600) {
  if (typeof value !== 'string' || !value.trim()) fail(path, 'expected a non-empty string');
  if (value.length > max) fail(path, `longer than ${max} characters`);
  return value;
}

function integer(value, path, min, max) {
  if (!Number.isInteger(value) || value < min || value > max) fail(path, `expected an integer from ${min} to ${max}`);
  return value;
}

function strings(value, path, min, max) {
  if (!Array.isArray(value) || value.length < min || value.length > max) fail(path, `expected ${min}-${max} strings`);
  return value.map((entry, index) => text(entry, `${path}[${index}]`));
}

function issueList(value, path) {
  if (!Array.isArray(value) || value.length < 1 || value.length > 8) fail(path, 'expected 1-8 issue numbers');
  const issues = value.map((entry, index) => integer(entry, `${path}[${index}]`, 1, 1e7));
  if (new Set(issues).size !== issues.length) fail(path, 'duplicate issue number');
  return issues;
}

function identifier(value, path) {
  if (typeof value !== 'string' || !ID.test(value)) fail(path, 'expected a kebab-case id');
  return value;
}

function validateItem(item, path, device) {
  const common = ['id', 'issues', 'title', 'minutes', 'core'];
  if (typeof item?.core !== 'boolean') fail(`${path}.core`, 'expected a boolean');
  if (device === 'Decision') {
    expectKeys(item, path, [...common, 'question', 'context', 'options']);
    if (!Array.isArray(item.options) || item.options.length < 2 || item.options.length > 4) fail(`${path}.options`, 'expected 2-4 options');
    const options = item.options.map((option, index) => {
      const optionPath = `${path}.options[${index}]`;
      expectKeys(option, optionPath, ['id', 'label', 'consequence'], ['recommended']);
      if (option.recommended !== undefined && typeof option.recommended !== 'boolean') fail(`${optionPath}.recommended`, 'expected a boolean');
      return {
        id: identifier(option.id, `${optionPath}.id`),
        label: text(option.label, `${optionPath}.label`, 120),
        consequence: text(option.consequence, `${optionPath}.consequence`, 300),
        recommended: option.recommended === true,
      };
    });
    if (new Set(options.map(option => option.id)).size !== options.length) fail(`${path}.options`, 'duplicate option id');
    if (options.filter(option => option.recommended).length !== 1) fail(`${path}.options`, 'exactly one option must be recommended');
    return {
      kind: 'decision', id: identifier(item.id, `${path}.id`), issues: issueList(item.issues, `${path}.issues`), core: item.core,
      title: text(item.title, `${path}.title`, 90), minutes: integer(item.minutes, `${path}.minutes`, 1, 60),
      question: text(item.question, `${path}.question`, 300), context: text(item.context, `${path}.context`, 900), options,
    };
  }
  expectKeys(item, path, [...common, 'build', 'steps', 'expected', 'final_gate'], ['prerequisites']);
  if (typeof item.final_gate !== 'boolean') fail(`${path}.final_gate`, 'expected a boolean');
  return {
    kind: 'check', id: identifier(item.id, `${path}.id`), issues: issueList(item.issues, `${path}.issues`), core: item.core,
    title: text(item.title, `${path}.title`, 90), minutes: integer(item.minutes, `${path}.minutes`, 1, 60),
    build: text(item.build, `${path}.build`, 200),
    prerequisites: item.prerequisites === undefined ? [] : strings(item.prerequisites, `${path}.prerequisites`, 0, 8),
    steps: strings(item.steps, `${path}.steps`, 3, 7), expected: text(item.expected, `${path}.expected`),
    finalGate: item.final_gate,
  };
}

export function validateCatalogue(document) {
  expectKeys(document, 'catalogue', ['version', 'updated', 'sessions']);
  if (document.version !== 1) fail('catalogue.version', 'expected 1');
  if (typeof document.updated !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(document.updated)) fail('catalogue.updated', 'expected YYYY-MM-DD');
  if (!Array.isArray(document.sessions) || !document.sessions.length) fail('catalogue.sessions', 'expected at least one session');
  const seen = new Set();
  const sessions = document.sessions.map((session, index) => {
    const path = `sessions[${index}]`;
    expectKeys(session, path, ['id', 'device', 'title', 'items'], ['setup']);
    if (!DEVICES.includes(session.device)) fail(`${path}.device`, `expected one of ${DEVICES.join(', ')}`);
    if (!Array.isArray(session.items) || !session.items.length) fail(`${path}.items`, 'expected at least one item');
    const items = session.items.map((item, itemIndex) => validateItem(item, `${path}.items[${itemIndex}]`, session.device));
    for (const id of [session.id, ...items.map(item => item.id)]) {
      if (seen.has(id)) fail(path, `duplicate id "${id}"`);
      seen.add(id);
    }
    return {
      id: identifier(session.id, `${path}.id`), device: session.device, title: text(session.title, `${path}.title`, 90),
      setup: session.setup === undefined ? [] : strings(session.setup, `${path}.setup`, 0, 10), items,
    };
  });
  return { version: 1, updated: document.updated, sessions };
}

export function catalogueHash(source) {
  return createHash('sha256').update(source).digest('hex').slice(0, 12);
}

export function loadCatalogue(source) {
  return { ...validateCatalogue(parseYamlSubset(source)), hash: catalogueHash(source) };
}

export function catalogueItems(catalogue) {
  return Object.fromEntries(catalogue.sessions.flatMap(session => session.items.map(item => [item.id, { ...item, device: session.device }])));
}

// Strictly parse the one machine-readable results block in an issue body.
export function parseResults(body, catalogue) {
  if (typeof body !== 'string') throw new Error('The issue has no body');
  const fence = new RegExp(`^\`\`\`${RESULTS_FENCE}[ \\t]*\\r?\\n([^\\r\\n]*)\\r?\\n\`\`\`[ \\t]*$`, 'gm');
  const blocks = [...body.matchAll(fence)];
  if (blocks.length !== 1) throw new Error(`Expected exactly one ${RESULTS_FENCE} block, found ${blocks.length}`);
  if (blocks[0][1].length > 200000) throw new Error('The results block is too large');
  let data;
  try {
    data = JSON.parse(blocks[0][1]);
  } catch {
    throw new Error('The results block is not valid JSON');
  }
  expectKeys(data, 'results block', ['format', 'catalogue', 'results'], ['pass', 'skip']);
  if (data.format !== RESULTS_FORMAT) throw new Error(`Unsupported results format ${JSON.stringify(data.format)}`);
  if (typeof data.catalogue !== 'string' || !/^[a-f0-9]{12}$/.test(data.catalogue)) throw new Error('Invalid catalogue hash');
  if (!Array.isArray(data.results)) throw new Error('No results were submitted');
  // Compact links list passes and skips as bare ids; expand them to ordinary entries.
  const listed = ['pass', 'skip'].flatMap(kind => {
    if (data[kind] === undefined) return [];
    if (!Array.isArray(data[kind]) || !data[kind].length) fail(kind, 'expected a non-empty list of ids');
    return data[kind].map((id, index) => {
      if (typeof id !== 'string') fail(`${kind}[${index}]`, 'expected an id');
      return { id, result: kind };
    });
  });
  const submitted = [...data.results, ...listed];
  if (!submitted.length) throw new Error('No results were submitted');
  const items = catalogueItems(catalogue);
  const seen = new Set();
  const results = submitted.map((entry, index) => {
    const path = `results[${index}]`;
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) fail(path, 'expected an object');
    const item = items[entry.id];
    if (!item) fail(path, `unknown id ${JSON.stringify(entry.id)}`);
    if (seen.has(entry.id)) fail(path, `duplicate id "${entry.id}"`);
    seen.add(entry.id);
    if (item.kind === 'decision') {
      expectKeys(entry, path, ['id', 'choice']);
      const option = item.options.find(candidate => candidate.id === entry.choice);
      if (!option) fail(path, `unknown choice ${JSON.stringify(entry.choice)} for "${entry.id}"`);
      return { item, option };
    }
    expectKeys(entry, path, ['id', 'result'], ['note']);
    if (!['pass', 'fail', 'skip'].includes(entry.result)) fail(path, 'result must be pass, fail or skip');
    if (entry.note !== undefined && (typeof entry.note !== 'string' || entry.note.length > MAX_NOTE_LENGTH)) {
      fail(path, `note must be a string of at most ${MAX_NOTE_LENGTH} characters`);
    }
    if (entry.note !== undefined && entry.result !== 'fail') fail(path, 'only failures carry a note');
    return { item, result: entry.result, note: entry.note?.trim() || '' };
  });
  return { catalogue: data.catalogue, stale: data.catalogue !== catalogue.hash, results };
}

// Neutralise mentions and closing keywords so a note cannot ping people or close issues.
function quoteNote(note) {
  return note.replace(/@/g, '@\u200b').replace(/#(\d)/g, '#\u200b$1').split(/\r?\n/).map(line => `> ${line}`).join('\n');
}

// Turn validated results into one comment per linked issue, the issues to
// close and the summary for the results issue. An issue closes only when every
// catalogue check marked final_gate for it passed in this submission and none
// of its checks failed; other passes add evidence but never trigger closure.
export function planActions(parsed, catalogue, resultsIssue) {
  const items = catalogueItems(catalogue);
  const byIssue = new Map();
  for (const entry of parsed.results) {
    for (const issue of entry.item.issues) {
      if (!byIssue.has(issue)) byIssue.set(issue, []);
      byIssue.get(issue).push(entry);
    }
  }
  const comments = [];
  const close = [];
  for (const [issue, entries] of byIssue) {
    const lines = [];
    for (const entry of entries) {
      if (entry.option) {
        lines.push(`- **Decision** — ${entry.item.question}`, `  Chosen: **${entry.option.label}**. ${entry.option.consequence}`);
      } else if (entry.result === 'pass') {
        lines.push(`- **PASS** — ${entry.item.title}`, `  Build: ${entry.item.build}`, `  Observed as expected: ${entry.item.expected}`);
      } else if (entry.result === 'fail') {
        lines.push(`- **FAIL** — ${entry.item.title}`, `  Expected: ${entry.item.expected}`);
        if (entry.note) lines.push('', quoteNote(entry.note), '');
      }
    }
    if (!lines.length) continue;
    const gates = Object.values(items).filter(item => item.kind === 'check' && item.finalGate && item.issues.includes(issue));
    const passed = new Set(entries.filter(entry => entry.result === 'pass').map(entry => entry.item.id));
    const failed = entries.some(entry => entry.result === 'fail');
    const closes = !failed && gates.length > 0 && gates.every(item => passed.has(item.id));
    if (closes) close.push(issue);
    const footer = closes ? 'Every final manual gate in the catalogue passed; closing as verified.' : 'Keeping this issue open.';
    comments.push({ issue, body: [`Owner manual QA results from #${resultsIssue}:`, '', ...lines, '', footer].join('\n') });
  }
  const count = kind => parsed.results.filter(entry => entry.result === kind).length;
  const decisions = parsed.results.filter(entry => entry.option).length;
  const summary = [
    '<!-- manual-qa-processed -->',
    `Processed ${parsed.results.length} result${parsed.results.length === 1 ? '' : 's'}: ${count('pass')} pass, ${count('fail')} fail, ${count('skip')} skip, ${decisions} decision${decisions === 1 ? '' : 's'}.`,
    parsed.stale ? '\nNote: submitted against an older catalogue revision; ids were validated against the current catalogue.' : '',
    '',
    comments.length ? `Commented on ${comments.map(comment => `#${comment.issue}`).join(', ')}.` : 'No linked issues needed a comment.',
    close.length ? `Closed ${close.map(issue => `#${issue}`).join(', ')}; remove their checks from \`Docs/manual-checks.yml\`.` : '',
  ].filter(line => line !== '').join('\n');
  return { comments, close, summary };
}
