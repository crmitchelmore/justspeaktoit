import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { processResultsIssue } from '../../.github/scripts/manual-qa-results.mjs';
import {
  catalogueItems, loadCatalogue, parseResults, parseYamlSubset, planActions,
} from '../../landing-page/qa/manual-checks.mjs';
import { encodeResultsBlock, formatResultsIssue } from '../../landing-page/qa/results-format.mjs';

const FIXTURE = `# Fixture catalogue
version: 1
updated: "2026-11-04"
sessions:
  - id: "iphone"
    device: "iPhone"
    title: "iPhone session"
    setup:
      - "Install the build."
    items:
      - id: "iphone-a"
        issue: 10
        title: "First gate"
        minutes: 3
        build: "TestFlight"
        prerequisites:
          - "Key set"
        steps:
          - "One."
          - "Two \\"quoted\\"."
          - "Three: done."
        expected: "It works."
        final_gate: true
      - id: "iphone-b"
        issue: 10
        title: "Second gate"
        minutes: 2
        build: "TestFlight"
        steps:
          - "One."
          - "Two."
          - "Three."
        expected: "Also works."
        final_gate: false
      - id: "iphone-c"
        issue: 11
        title: "Not final"
        minutes: 2
        build: "TestFlight"
        steps:
          - "One."
          - "Two."
          - "Three."
        expected: "Fine."
        final_gate: false
  - id: "decisions"
    device: "Decision"
    title: "Decisions"
    items:
      - id: "decision-x"
        issue: 12
        title: "Pick"
        minutes: 1
        question: "Which?"
        context: "Context."
        options:
          - id: "yes"
            label: "Yes"
            consequence: "Go."
            recommended: true
          - id: "no"
            label: "No"
            consequence: "Stop."
`;

const catalogue = loadCatalogue(FIXTURE);
const body = results => formatResultsIssue({
  catalogue: catalogue.hash, results, items: catalogueItems(catalogue), date: '2026-11-04',
}).body;

test('the YAML subset parses maps, lists, escapes and comments', () => {
  const parsed = parseYamlSubset(FIXTURE);
  assert.equal(parsed.sessions[0].items[0].steps[1], 'Two "quoted".');
  assert.equal(parsed.sessions[0].items[0].steps[2], 'Three: done.');
  assert.equal(parsed.sessions[1].items[0].options[0].recommended, true);
  assert.equal(catalogue.hash.length, 12);
});

test('the YAML subset rejects anything it would otherwise have to guess', () => {
  for (const [source, message] of [
    ['a: plain text', /double-quoted/],
    ['a: "x"\na: "y"', /duplicate key/],
    ['a:\n\t- "x"', /tabs/],
    ['a: "x"\n   b: "y"', /indentation/],
    ['a: [1, 2]', /double-quoted/],
    ['a: |', /double-quoted/],
    ['a:', /no value/],
  ]) assert.throws(() => parseYamlSubset(source), message, source);
});

test('catalogue validation enforces the schema', () => {
  const broken = edit => () => loadCatalogue(FIXTURE.replace(...edit));
  assert.throws(broken(['device: "iPhone"', 'device: "Phone"']), /expected one of/);
  assert.throws(broken(['        final_gate: true', '        final_gate: "yes"']), /final_gate/);
  assert.throws(broken(['id: "iphone-b"', 'id: "iphone-a"']), /duplicate id/);
  assert.throws(broken(['            recommended: true\n', '']), /exactly one option/);
  assert.throws(broken(['          - "Three: done."\n', '']), /3-7 strings/);
  assert.throws(broken(['        expected: "It works."', '        expected: "It works."\n        surprise: "x"']), /unknown key/);
});

test('the committed catalogue is valid and every check is actionable', async () => {
  const source = await readFile(new URL('../../Docs/manual-checks.yml', import.meta.url), 'utf8');
  const real = loadCatalogue(source);
  const items = Object.values(catalogueItems(real));
  assert.ok(items.length > 0);
  for (const item of items.filter(entry => entry.kind === 'check')) {
    assert.ok(item.steps.length >= 3 && item.steps.length <= 7, item.id);
  }
});

test('results round-trip through the issue body, including hostile notes', () => {
  const note = 'Saw ``` and </script> @someone fixes #10';
  const parsed = parseResults(body([
    { id: 'iphone-a', result: 'pass' },
    { id: 'iphone-b', result: 'fail', note },
    { id: 'decision-x', choice: 'no' },
  ]), catalogue);
  assert.equal(parsed.stale, false);
  assert.equal(parsed.results[1].note, note);
  assert.equal(parsed.results[2].option.id, 'no');
});

test('results parsing is strict', () => {
  const block = results => encodeResultsBlock(catalogue.hash, results);
  for (const [text, message] of [
    ['no block here', /exactly one/],
    [`${block([{ id: 'iphone-a', result: 'pass' }])}\n${block([{ id: 'iphone-a', result: 'pass' }])}`, /exactly one/],
    [block([{ id: 'nope', result: 'pass' }]), /unknown id/],
    [block([{ id: 'iphone-a', result: 'maybe' }]), /pass, fail or skip/],
    [block([{ id: 'iphone-a', result: 'pass' }, { id: 'iphone-a', result: 'fail' }]), /duplicate id/],
    [block([{ id: 'iphone-a', result: 'pass', note: 'x' }]), /only failures/],
    [block([{ id: 'iphone-a', result: 'fail', note: 'x'.repeat(2001) }]), /at most 2000/],
    [block([{ id: 'decision-x', choice: 'maybe' }]), /unknown choice/],
    [block([{ id: 'decision-x', result: 'pass' }]), /missing "choice"/],
    [block([{ id: 'iphone-a', result: 'pass', extra: 1 }]), /unknown key/],
    [block([]), /No results/],
    ['```manual-qa-results\n{not json}\n```', /not valid JSON/],
  ]) assert.throws(() => parseResults(text, catalogue), message, text);
});

test('an issue closes only when every catalogue check for it passed', () => {
  const plan = results => planActions(parseResults(body(results), catalogue), catalogue, 99);
  const partial = plan([{ id: 'iphone-a', result: 'pass' }, { id: 'iphone-b', result: 'skip' }]);
  assert.deepEqual(partial.close, []);
  assert.match(partial.comments[0].body, /PASS/);
  assert.match(partial.comments[0].body, /Keeping this issue open/);
  const complete = plan([{ id: 'iphone-a', result: 'pass' }, { id: 'iphone-b', result: 'pass' }, { id: 'iphone-c', result: 'pass' }]);
  assert.deepEqual(complete.close, [10], 'issue 11 has no final gate');
  const failed = plan([{ id: 'iphone-b', result: 'fail', note: 'Ping @x and close #10' }, { id: 'decision-x', choice: 'yes' }]);
  assert.deepEqual(failed.close, []);
  assert.match(failed.comments[0].body, /@\u200bx/);
  assert.match(failed.comments[0].body, /#\u200b10/);
  assert.match(failed.comments[1].body, /Chosen: \*\*Yes\*\*/);
  assert.match(failed.summary, /manual-qa-processed/);
  const skipped = plan([{ id: 'iphone-c', result: 'skip' }]);
  assert.deepEqual(skipped.comments, []);
});

function fakeGitHub(state = {}) {
  const calls = [];
  const request = async (method, path, payload) => {
    calls.push([method, path, payload]);
    if (method === 'GET' && path.endsWith('/comments?per_page=100')) return state.comments || [];
    if (method === 'GET') return { state: 'open' };
    return {};
  };
  return { calls, request };
}

const event = (overrides = {}) => ({
  sender: { login: 'crmitchelmore' },
  issue: {
    number: 99, state: 'open', user: { login: 'crmitchelmore' }, labels: [{ name: 'manual-qa-results' }],
    body: body([{ id: 'iphone-a', result: 'pass' }, { id: 'iphone-b', result: 'pass' }]),
    ...overrides,
  },
});

test('the processor comments, closes completed issues and closes the results issue', async () => {
  const github = fakeGitHub();
  const outcome = await processResultsIssue({ event: event(), catalogueSource: FIXTURE, request: github.request, log: () => {} });
  assert.deepEqual(outcome.closed, [10]);
  assert.deepEqual(github.calls.map(([method, path]) => `${method} ${path}`), [
    'GET /issues/99/comments?per_page=100',
    'POST /issues/10/comments',
    'GET /issues/10',
    'PATCH /issues/10',
    'POST /issues/99/comments',
    'PATCH /issues/99',
  ]);
});

test('the processor ignores other authors, senders and already-processed issues', async () => {
  for (const [input, state] of [
    [event({ user: { login: 'someone' } }), {}],
    [{ ...event(), sender: { login: 'someone' } }, {}],
    [event({ labels: [] }), {}],
    [event({ state: 'closed' }), {}],
    [event(), { comments: [{ user: { type: 'Bot' }, body: '<!-- manual-qa-processed -->' }] }],
  ]) {
    const github = fakeGitHub(state);
    const outcome = await processResultsIssue({ event: input, catalogueSource: FIXTURE, request: github.request });
    assert.ok(outcome.skipped);
    assert.ok(github.calls.every(([method]) => method === 'GET'));
  }
});

test('the processor explains invalid results and changes nothing else', async () => {
  const github = fakeGitHub();
  await assert.rejects(
    processResultsIssue({ event: event({ body: 'nothing' }), catalogueSource: FIXTURE, request: github.request }),
    /exactly one/,
  );
  assert.deepEqual(github.calls.map(([method, path]) => `${method} ${path}`), [
    'GET /issues/99/comments?per_page=100', 'POST /issues/99/comments',
  ]);
});
