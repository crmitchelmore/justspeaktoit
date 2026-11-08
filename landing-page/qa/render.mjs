const escape = value => String(value)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');

// Link bare https URLs (never other schemes) and escape every part.
const rich = value => String(value).split(/(https:\/\/[^\s<>"']*[^\s<>"'.,;:)])/)
  .map((part, index) => (index % 2 ? `<a href="${escape(part)}" target="_blank" rel="noopener">${escape(part)}</a>` : escape(part)))
  .join('');

const ISSUE_BASE = 'https://github.com/crmitchelmore/justspeaktoit/issues/';
const minutesLabel = minutes => `~${minutes} min`;
const issueLinks = item => item.issues
  .map(issue => `<a href="${ISSUE_BASE}${issue}" target="_blank" rel="noopener">#${issue}</a>`).join(' ');
const sum = items => items.reduce((total, item) => total + item.minutes, 0);

function renderCheck(item) {
  const prerequisites = item.prerequisites.length
    ? `<p class="qa-label">Before you start</p><ul class="qa-prereqs">${item.prerequisites.map(entry => `<li>${rich(entry)}</li>`).join('')}</ul>`
    : '';
  const choices = ['pass', 'fail', 'skip'].map(result => `
          <label class="qa-choice qa-choice-${result}">
            <input type="radio" name="result-${escape(item.id)}" value="${result}">
            <span>${result[0].toUpperCase()}${result.slice(1)}</span>
          </label>`).join('');
  return `
      <article class="qa-item" id="${escape(item.id)}" data-id="${escape(item.id)}" data-kind="check" data-core="${item.core}" data-minutes="${item.minutes}">
        <header class="qa-item-header">
          <h3>${escape(item.title)}</h3>
          <p class="qa-meta">${issueLinks(item)} · ${minutesLabel(item.minutes)} · ${escape(item.build)}</p>
        </header>
        ${prerequisites}
        <ol class="qa-steps">${item.steps.map(step => `<li>${rich(step)}</li>`).join('')}</ol>
        <p class="qa-expected"><strong>Expected:</strong> ${rich(item.expected)}</p>
        <fieldset class="qa-choices">
          <legend class="visually-hidden">Result for ${escape(item.title)}</legend>${choices}
        </fieldset>
        <div class="qa-note" hidden>
          <label for="note-${escape(item.id)}">What happened instead?</label>
          <textarea id="note-${escape(item.id)}" rows="3" maxlength="2000"></textarea>
        </div>
      </article>`;
}

function renderDecision(item) {
  const options = item.options.map(option => `
          <label class="qa-option">
            <input type="radio" name="result-${escape(item.id)}" value="${escape(option.id)}">
            <span class="qa-option-text"><strong>${escape(option.label)}</strong>${option.recommended ? ' <span class="qa-badge">Recommended</span>' : ''}
              <span class="qa-consequence">${rich(option.consequence)}</span></span>
          </label>`).join('');
  return `
      <article class="qa-item" id="${escape(item.id)}" data-id="${escape(item.id)}" data-kind="decision" data-core="${item.core}" data-minutes="${item.minutes}">
        <header class="qa-item-header">
          <h3>${escape(item.title)}</h3>
          <p class="qa-meta">${issueLinks(item)} · ${minutesLabel(item.minutes)}</p>
        </header>
        <p>${rich(item.context)}</p>
        <fieldset class="qa-options">
          <legend>${escape(item.question)}</legend>${options}
        </fieldset>
      </article>`;
}

const renderItem = item => (item.kind === 'decision' ? renderDecision(item) : renderCheck(item));

// Core items close or unblock issues and stay visible; optional ones collapse.
function renderSession(session) {
  const core = session.items.filter(item => item.core);
  const optional = session.items.filter(item => !item.core);
  const setup = session.setup.length
    ? `<div class="qa-setup"><p class="qa-label">Set up once</p><ul>${session.setup.map(entry => `<li>${rich(entry)}</li>`).join('')}</ul></div>`
    : '';
  const extra = optional.length
    ? `
      <details class="qa-optional">
        <summary>Optional: ${optional.length} more · ${minutesLabel(sum(optional))}</summary>
        ${optional.map(renderItem).join('')}
      </details>`
    : '';
  return `
    <section class="qa-session" id="session-${escape(session.id)}" aria-labelledby="heading-${escape(session.id)}">
      <h2 id="heading-${escape(session.id)}">${escape(session.title)} <span class="qa-session-meta">${core.length} core · ${minutesLabel(sum(core))}</span></h2>
      ${setup}${core.map(renderItem).join('')}${extra}
    </section>`;
}

// Embedded data only needs ids, kinds, titles, issues and options; escaping "<"
// keeps catalogue text from closing the script element.
function pageData(catalogue) {
  const items = catalogue.sessions.flatMap(session => session.items.map(item => ({
    id: item.id, kind: item.kind, title: item.title, issues: item.issues, minutes: item.minutes, core: item.core,
    ...(item.kind === 'decision' ? { options: item.options.map(({ id, label }) => ({ id, label })) } : {}),
  })));
  return JSON.stringify({ catalogue: catalogue.hash, items }).replace(/</g, '\\u003c');
}

export function renderQaPage(catalogue) {
  const items = catalogue.sessions.flatMap(session => session.items);
  const core = items.filter(item => item.core);
  const devices = [...new Set(catalogue.sessions.map(session => session.device))];
  const totals = devices.map(device => {
    const coreItems = catalogue.sessions.filter(session => session.device === device).flatMap(session => session.items).filter(item => item.core);
    return `<li><strong>${escape(device)}</strong> ${minutesLabel(sum(coreItems))}</li>`;
  }).join('');
  const nav = catalogue.sessions.map(session => {
    const sessionCore = session.items.filter(item => item.core);
    return `<li><a href="#session-${escape(session.id)}">${escape(session.title)}</a> <span>${sessionCore.length} · ${minutesLabel(sum(sessionCore))}</span></li>`;
  }).join('');
  return `<!doctype html>
<html lang="en-GB">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex, nofollow">
  <meta name="color-scheme" content="light dark">
  <title>Manual QA · Just Speak to It</title>
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/qa/qa.css">
</head>
<body>
  <a class="visually-hidden" href="#main">Skip to checklist</a>
  <header class="qa-top">
    <h1>Manual QA</h1>
    <p id="qa-progress" class="qa-progress" aria-live="polite">0 of ${core.length} core answered · ${minutesLabel(sum(core))} left</p>
    <progress id="qa-progress-bar" max="${core.length}" value="0" aria-label="Answered core items"></progress>
  </header>
  <main id="main">
    <p class="qa-intro">Answers save on this device as you go, so you can stop and come back. Mark each check Pass, Fail or Skip, then press Submit once: it opens a prefilled GitHub issue that you create with one click. Catalogue updated ${escape(catalogue.updated)}.</p>
    <section class="qa-totals" aria-labelledby="qa-totals-heading">
      <h2 id="qa-totals-heading">Core time by device</h2>
      <ul>${totals}</ul>
      <p>Core items close or unblock an issue. Optional items are collapsed; open them only if you have spare time.</p>
    </section>
    <nav aria-label="Sessions"><ul class="qa-nav">${nav}</ul></nav>
    <noscript><p class="qa-warning">This checklist needs JavaScript to save answers and submit them.</p></noscript>
    ${catalogue.sessions.map(renderSession).join('')}
  </main>
  <footer class="qa-submit">
    <p id="qa-status" class="qa-status" role="status" aria-live="polite"></p>
    <div class="qa-actions">
      <button type="button" id="qa-submit" class="qa-primary" disabled>Submit results</button>
      <button type="button" id="qa-copy" class="qa-secondary" disabled>Copy results</button>
      <button type="button" id="qa-clear" class="qa-secondary">Clear</button>
    </div>
  </footer>
  <script id="qa-data" type="application/json">${pageData(catalogue)}</script>
  <script type="module" src="/qa/qa.js"></script>
</body>
</html>
`;
}
