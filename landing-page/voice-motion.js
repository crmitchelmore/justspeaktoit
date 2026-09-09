// Progressive enhancement: the example is complete and readable without JavaScript.
const demo = document.querySelector('.voice-demo');
const replay = demo?.querySelector('.voice-replay');
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
let animations = [];

function stop() {
  animations.forEach(animation => animation.cancel());
  animations = [];
}

function play() {
  stop();
  if (reducedMotion.matches || !demo) return;

  const animate = (element, frames, options) => {
    animations.push(element.animate(frames, options));
  };
  demo.querySelectorAll('.voice-wave i').forEach((bar, index) => {
    animate(bar, [
      { transform: 'scaleY(.35)' },
      { transform: 'scaleY(1.5)', offset: .35 },
      { transform: 'scaleY(.55)', offset: .7 },
      { transform: 'scaleY(1)' },
    ], { duration: 520 + index * 25, delay: index * 35, iterations: 3, easing: 'ease-in-out' });
  });
  demo.querySelectorAll('.voice-words [aria-hidden]').forEach((word, index) => {
    animate(word, [
      { opacity: 0, transform: 'translateY(7px)', filter: 'blur(3px)' },
      { opacity: 1, transform: 'translateY(0)', filter: 'blur(0)' },
    ], { duration: 420, delay: 350 + index * 280, fill: 'backwards', easing: 'cubic-bezier(.2,.8,.2,1)' });
  });
  animate(demo.querySelector('.voice-done'), [
    { opacity: 0, transform: 'scale(.6)' },
    { opacity: 1, transform: 'scale(1)' },
  ], { duration: 350, delay: 1850, fill: 'backwards', easing: 'cubic-bezier(.2,.8,.2,1)' });
}

if (replay && typeof Element.prototype.animate === 'function') {
  const syncPreference = () => {
    stop();
    replay.hidden = reducedMotion.matches;
  };
  syncPreference();
  reducedMotion.addEventListener('change', syncPreference);
  replay.addEventListener('click', play);
  // One short sequence on arrival, never a background loop.
  play();
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) stop();
  });
}
