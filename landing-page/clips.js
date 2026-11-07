// Clips already use preload="none"; this also defers each poster image until the
// clip nears the viewport, so the page only downloads media people scroll to.
const clips = document.querySelectorAll('video[data-poster]');
const showPoster = video => {
  video.poster = video.dataset.poster;
  video.removeAttribute('data-poster');
};

if ('IntersectionObserver' in window) {
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      showPoster(entry.target);
      observer.unobserve(entry.target);
    }
  }, { rootMargin: '600px 0px' });
  clips.forEach(video => observer.observe(video));
} else {
  clips.forEach(showPoster);
}

// Playing one clip pauses the others.
document.addEventListener('play', event => {
  document.querySelectorAll('video.clip-video').forEach(video => {
    if (video !== event.target) video.pause();
  });
}, true);
