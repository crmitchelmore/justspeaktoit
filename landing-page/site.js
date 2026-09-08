// An illustrative example: no audio capture, network request or provider claim.
const examples = {
  message: {
    spoken: '“Hey, just a thought. What if we moved the catch-up to Friday? Gives us a bit more time to get the first version ready.”',
    result: 'Could we move the catch-up to Friday? That gives us a little more time to get the first version ready.',
  },
  note: {
    spoken: '“Okay, so we agreed to try the smaller version first. I’ll put a draft together, and we’ll check in again on Thursday.”',
    result: 'Agreed: try the smaller version first.\nNext: put a draft together.\nCheck-in: Thursday.',
  },
  draft: {
    spoken: '“I think what I’m trying to say is, we don’t need to make it bigger. We need to make the part people use every day feel really good.”',
    result: 'We don’t need to make it bigger. We need to make the part people use every day feel really good.',
  },
};
const demo = document.querySelector('.demo');
demo.dataset.interactive = 'true';
const choices = document.querySelectorAll('[data-scenario]');
const spoken = document.querySelector('#spoken-text');
const result = document.querySelector('#result-text');
const play = document.querySelector('#play-demo');
const playLabel = play.querySelector('.play-label');
const status = document.querySelector('#demo-status');
let selected = 'message';
let timer;
function finish() {
  clearTimeout(timer);
  result.textContent = examples[selected].result;
  demo.classList.remove('is-playing');
  play.removeAttribute('aria-disabled');
  playLabel.textContent = 'Replay the demo';
}
for (const choice of choices) {
  choice.addEventListener('click', () => {
    selected = choice.dataset.scenario;
    finish();
    for (const other of choices) other.setAttribute('aria-pressed', String(other === choice));
    spoken.textContent = examples[selected].spoken;
    playLabel.textContent = 'Try the demo';
    status.textContent = `${choice.textContent} selected. ${examples[selected].result}`;
  });
}
play.addEventListener('click', () => {
  if (play.getAttribute('aria-disabled') === 'true') return;
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    finish();
    status.textContent = `Example complete. ${examples[selected].result}`;
    return;
  }
  clearTimeout(timer);
  demo.classList.add('is-playing');
  play.setAttribute('aria-disabled', 'true');
  playLabel.textContent = 'Putting it into words…';
  status.textContent = 'Playing the dictation example.';
  const words = examples[selected].result.split(/(?<=\s)/);
  let position = 0;
  result.textContent = '';
  const step = () => {
    result.textContent += words[position++];
    if (position < words.length) timer = setTimeout(step, 65);
    else {
      finish();
      status.textContent = `Example complete. ${examples[selected].result}`;
    }
  };
  timer = setTimeout(step, 250);
});
