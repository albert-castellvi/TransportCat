// TransportCat — one orchestrated reveal per section, nothing else.
// The 'js' class gates the hidden state: without JavaScript everything is
// simply visible. No animation when the visitor prefers reduced motion.
document.documentElement.classList.add('js');
(function () {
  var targets = document.querySelectorAll('.reveal');
  if (!('IntersectionObserver' in window) || !targets.length) return;
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) {
        entry.target.classList.add('in');
        io.unobserve(entry.target);
      }
    });
  }, { rootMargin: '0px 0px -12% 0px' });
  targets.forEach(function (el) { io.observe(el); });
  // Belt and braces: anything already inside the viewport must never stay
  // hidden, even if the observer never fires.
  setTimeout(function () {
    targets.forEach(function (el) {
      if (!el.classList.contains('in') && el.getBoundingClientRect().top < window.innerHeight) {
        el.classList.add('in');
        io.unobserve(el);
      }
    });
  }, 1000);
})();
