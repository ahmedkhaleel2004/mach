// Keyboard first, like the app: 1 to 4 switch page, g opens the source, and a shortcut shown on the page lights up when pressed.
// The rest is the page's motion: things come in once as they are scrolled to. Without this file everything is simply visible.
(function () {
  var root = document.documentElement;
  var calm = matchMedia("(prefers-reduced-motion: reduce)").matches;
  root.classList.add("js");

  addEventListener("keydown", function (e) {
    if (e.metaKey || e.ctrlKey || e.altKey || e.defaultPrevented) return;
    var t = e.target;
    if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return;
    var to = { "1": "/", "2": "/privacy", "3": "/terms", "4": "/support", g: "https://github.com/ahmedkhaleel2004/mach" }[e.key];
    if (to) { location.href = to; return; }
    var name = e.key === "Escape" ? "esc" : e.key.toLowerCase();
    document.querySelectorAll(".keys kbd").forEach(function (k) {
      if (k.textContent.toLowerCase() !== name) return;
      k.classList.add("on");
      setTimeout(function () { k.classList.remove("on"); }, 180);
    });
  });

  function count(el) {
    var end = parseFloat(el.dataset.n), places = (el.dataset.n.split(".")[1] || "").length, t0 = performance.now(), ms = 900;
    (function tick(now) {
      var p = Math.min(1, (now - t0) / ms), v = end * (1 - Math.pow(1 - p, 4));
      el.textContent = p < 1 ? v.toFixed(places) : el.dataset.n;
      if (p < 1) requestAnimationFrame(tick);
    })(t0);
  }

  addEventListener("DOMContentLoaded", function () {
    var bar = document.querySelector(".bar");
    function edge() { bar.classList.toggle("lift", scrollY > 8); }
    if (bar) { addEventListener("scroll", edge, { passive: true }); edge(); }

    var els = document.querySelectorAll(".rv, .stag, .bench");
    if (!("IntersectionObserver" in window)) { els.forEach(function (el) { el.classList.add("in"); }); return; }
    var io = new IntersectionObserver(function (seen) {
      seen.forEach(function (s) {
        if (!s.isIntersecting) return;
        io.unobserve(s.target);
        s.target.classList.add("in");
        if (!calm && s.target.classList.contains("bench")) s.target.querySelectorAll("[data-n]").forEach(function (n, i) {
          n.textContent = "0";
          setTimeout(function () { count(n); }, i * 70);
        });
      });
    }, { rootMargin: "0px 0px -12% 0px", threshold: 0.12 });
    els.forEach(function (el) { io.observe(el); });
  });
})();
