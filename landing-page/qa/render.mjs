const escape = value => String(value)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');

const ISSUE_BASE = 'https://github.com/crmitchelmore/justspeaktoit/issues/';
const minutesLabel = minutes => `~${minutes} min`;

function renderCheck(item) {
  const prerequisites = item.prerequisites.length
    ? `<p class="qa-label">Before you start</p><ul class="qa-prereqs">${item.prerequisites.map(entry => `<li>${escape(entry)}</li>`).join('')}</ul>`
    : '';
  const choices = ['pass', 'fail', 'skip'].map(result => `
          <label class="qa-choice qa-choice-${result}">
            <input type="radio" name="result-${escape(item.id)}" value="${result}">
            <span>${result[0].toUpperCase()}${result.slice(1)}</span>
          </label>`).join('');
  return `
      <article class="qa-item" id="${escape(item.id)}" data-id="${escape(item.id)}" data-kind="check" data-minutes="${item.minutes}">
        <header class="qa-item-header">
          <h3>${escape(item.title)}</h3>
          <p class="qa-meta"><a href="${ISSUE_BASE}${item.issue}" target="_blank" rel="noopener">#${item.issue}</a> · ${minutesLabel(item.minutes)} · ${escape(item.build)}</p>
        </header>
        ${prerequisites}
        <ol class="qa-steps">${item.steps.map(step => `<li>${escape(step)}</li>`).join('')}</ol>
        <p class="qa-expected"><strong>Expected:</strong> ${escape(item.expected)}</p>
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
              <span class="qa-consequence">${escape(option.consequence)}</span></span>
          </label>`).join('');
  return `
      <article class="qa-item" id="${escape(item.id)}" data-id="${escape(item.id)}" data-kind="decision" data-minutes="${item.minutes}">
        <header class="qa-item-header">
          <h3>${escape(item.title)}</h3>
          <p class="qa-meta"><a href="${ISSUE_BASE}${item.issue}" target="_blank" rel="noopener">#${item.issue}</a> · ${minutesLabel(item.minutes)}</p>
        </header>
        <p>${escape(item.context)}</p>
        <fieldset class="qa-options">
          <legend>${escape(item.question)}</legend>${options}
        </fieldset>
      </article>`;
}

function renderSession(session) {
  const minutes = session.items.reduce((total, item) => total + item.minutes, 0);
  const setup = session.setup.length
    ? `<div class="qa-setup"><p class="qa-label">Set up once</p><ul>${session.setup.map(entry => `<li>${escape(entry)}</li>`).join('')}</ul></div>`
    : '';
  return `
    <section class="qa-session" id="session-${escape(session.id)}" aria-labelledby="heading-${escape(session.id)}">
      <h2 id="heading-${escape(session.id)}">${escape(session.title)} <span class="qa-session-meta">${session.items.length} · ${minutesLabel(minutes)}</span></h2>
      ${setup}${session.items.map(item => (item.kind === 'decision' ? renderDecision(item) : renderCheck(item))).join('')}
    </section>`;
}

// Embedded data only needs ids, kinds, titles, issues and options; escaping "<"
// keeps catalogue text from closing the script element.
function pageData(catalogue) {
  const items = catalogue.sessions.flatMap(session => session.items.map(item => ({
    id: item.id, kind: item.kind, title: item.title, issue: item.issue, minutes: item.minutes,
    ...(item.kind === 'decision' ? { options: item.options.map(({ id, label }) => ({ id, label })) } : {}),
  })));
  return JSON.stringify({ catalogue: catalogue.hash, items }).replace(/</g, '\\u003c');
}

export function renderQaPage(catalogue) {
  const total = catalogue.sessions.reduce((sum, session) => sum + session.items.length, 0);
  const minutes = catalogue.sessions.reduce((sum, session) => sum + session.items.reduce((inner, item) => inner + item.minutes, 0), 0);
  const nav = catalogue.sessions.map(session => {
    const sessionMinutes = session.items.reduce((sum, item) => sum + item.minutes, 0);
    return `<li><a href="#session-${escape(session.id)}">${escape(session.device)}</a> <span>${session.items.length} · ${minutesLabel(sessionMinutes)}</span></li>`;
  }).join('');
  return `<!doctype html>
<html lang="en-GB">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex, nofollow">
  <title>Manual QA · Just Speak to It</title>
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/qa/qa.css">
</head>
<body>
  <a class="visually-hidden" href="#main">Skip to checklist</a>
  <header class="qa-top">
    <h1>Manual QA</h1>
    <p id="qa-progress" class="qa-progress" aria-live="polite">0 of ${total} answered · ${minutesLabel(minutes)} left</p>
    <progress id="qa-progress-bar" max="${total}" value="0" aria-label="Answered checks"></progress>
  </header>
  <main id="main">
    <p class="qa-intro">Answers save on this device as you go, so you can stop and come back. Mark each check Pass, Fail or Skip, then press Submit once: it opens a prefilled GitHub issue that you create with one click. Catalogue updated ${escape(catalogue.updated)}.</p>
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
