// Keyboard first, like the app: 1 to 4 switch page, g opens the source. Nothing else runs on this site.
addEventListener("keydown", function (e) {
  if (e.metaKey || e.ctrlKey || e.altKey || e.defaultPrevented) return;
  var t = e.target;
  if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return;
  var to = { "1": "/", "2": "/privacy", "3": "/terms", "4": "/support", g: "https://github.com/ahmedkhaleel2004/mach" }[e.key];
  if (to) location.href = to;
});
