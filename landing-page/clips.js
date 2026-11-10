// Each clip exists in light and dark appearance. Without JavaScript the <source>
// media queries pick one at load; this keeps the choice in step with the visitor's
// colour scheme, including when it changes while the page is open. Clips use
// preload="none" and posters load only as a clip nears the viewport, so the page
// downloads just the matching variant of media people scroll to.
const clips = [...document.querySelectorAll('video[data-clip]')];
const scheme = window.matchMedia('(prefers-color-scheme: dark)');
const probe = document.createElement('video');
const extension = probe.canPlayType('video/webm; codecs="av01.0.05M.08, opus"') ? 'webm' : 'mp4';
const visible = new WeakSet();

function apply(video) {
  const name = video.dataset.clip;
  const variant = scheme.matches ? 'dark' : 'light';
  const base = `/images/clips/${name}-${variant}`;
  if (visible.has(video)) video.poster = `${base}-poster.webp`;
  document.querySelectorAll(`a[data-clip-download="${name}"]`).forEach(link => { link.href = `${base}.mp4`; });
  const source = new URL(`${base}.${extension}`, location.href).href;
  if (video.currentSrc === source || video.getAttribute('src') === source) return;
  const time = video.currentTime;
  const playing = !video.paused && !video.ended;
  video.src = source;
  if (time > 0) video.currentTime = time;
  if (playing) video.play().catch(() => {});
}

function reveal(video) {
  visible.add(video);
  apply(video);
}

if ('IntersectionObserver' in window) {
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      reveal(entry.target);
      observer.unobserve(entry.target);
    }
  }, { rootMargin: '600px 0px' });
  clips.forEach(video => {
    apply(video);
    observer.observe(video);
  });
} else {
  clips.forEach(reveal);
}

scheme.addEventListener('change', () => clips.forEach(apply));

// Playing one clip pauses the others.
document.addEventListener('play', event => {
  clips.forEach(video => {
    if (video !== event.target) video.pause();
  });
}, true);
