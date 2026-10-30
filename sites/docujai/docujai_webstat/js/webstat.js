// webstat beacon for docujai.com, after the one on klimaleksikon.dk
// (klimaleksikon repo, tools/drupal/klimaleksikon_webstat/js/webstat.js).
// Everything goes to /nyt.php on the site itself (the first-party
// collector, which passes it on to webstat), as text/plain beacons: no CORS
// preflight, and they survive the reader moving on. Nothing is stored on the
// reader's device; the view id lives only as long as the page.
//
// Reports: the page view; reading 50 and 100 percent of the body; the
// seconds the page was visible (when it is hidden or left); contact clicks
// (/contact, /kontakt, mail and phone links).
(function () {
  if (!navigator.sendBeacon || navigator.webdriver || document.visibilityState === 'prerender') { return; }
  var collector = '/nyt.php';
  var view = Math.random().toString(36).slice(2, 10);
  var path = location.pathname;
  try { path = decodeURIComponent(path); } catch (e) {}

  function send(kind, extra) {
    var data = {kind: kind, view: view, path: path};
    for (var k in extra) { data[k] = extra[k]; }
    navigator.sendBeacon(collector, new Blob([JSON.stringify(data)], {type: 'text/plain'}));
  }

  function hostOf(url) {
    try { return new URL(url).hostname.replace(/^www\./, ''); } catch (e) { return ''; }
  }

  function start() {
    var settings = window.drupalSettings || {};
    var current = (settings.path && settings.path.currentPath) || '';
    var match = current.match(/^node\/(\d+)$/);
    var nid = match ? parseInt(match[1], 10) : null;
    var node = nid && document.querySelector('article.node');
    var typeMatch = node && node.className.match(/node--type-([a-z_-]+)/);
    var heading = document.querySelector('h1.title') || document.querySelector('h1');
    var here = location.hostname.replace(/^www\./, '');
    var refHost = hostOf(document.referrer);
    var from = null;
    if (refHost === here) {
      try { from = decodeURIComponent(new URL(document.referrer).pathname); } catch (e) {}
    }
    var width = window.innerWidth;
    send('view', {
      nid: nid,
      type: typeMatch ? typeMatch[1] : null,
      title: heading ? heading.textContent.trim() : null,
      ref: refHost && refHost !== here ? refHost : null,
      from: from,
      device: width < 768 ? 'mobile' : width < 1200 ? 'tablet' : 'desktop',
      lang: document.documentElement.lang || null
    });

    // Reading depth through the body: halfway and the end.
    var body = node && node.querySelector('.field--name-body');
    if (body) {
      var reached = {};
      var waiting = false;
      var depth = function () {
        var box = body.getBoundingClientRect();
        var seen = (window.innerHeight - box.top) / Math.max(box.height, 1);
        [50, 100].forEach(function (d) {
          if (!reached[d] && seen >= (d === 100 ? 0.95 : 0.5)) { reached[d] = true; send('read', {depth: d}); }
        });
        if (reached[100]) { window.removeEventListener('scroll', onScroll); }
      };
      var onScroll = function () {
        if (waiting) { return; }
        waiting = true;
        setTimeout(function () { waiting = false; depth(); }, 250);
      };
      window.addEventListener('scroll', onScroll, {passive: true});
      depth();
    }

    // Contact clicks: the contact page, mail and phone. The target is the
    // path, or "mail" or "phone" (never the address itself).
    document.addEventListener('click', function (e) {
      var a = e.target.closest && e.target.closest('a[href]');
      if (!a) { return; }
      var url;
      try { url = new URL(a.href); } catch (err) { return; }
      var target = null;
      if (url.protocol === 'mailto:') {
        target = 'mail';
      } else if (url.protocol === 'tel:') {
        target = 'phone';
      } else if (url.hostname.replace(/^www\./, '') === here && /^(\/da)?\/(contact|kontakt)/.test(url.pathname)) {
        target = url.pathname;
      }
      if (target) { send('click', {target: target}); }
    }, true);
  }

  // Seconds the page was visible, sent each time it is hidden (the latest
  // report per view counts).
  var visibleSince = document.visibilityState === 'visible' ? Date.now() : null;
  var visible = 0;
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') {
      if (visibleSince) { visible += Date.now() - visibleSince; visibleSince = null; }
      var seconds = Math.round(visible / 1000);
      if (seconds >= 1) { send('leave', {seconds: Math.min(seconds, 7200)}); }
    } else {
      visibleSince = Date.now();
    }
  });

  if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', start); } else { start(); }
})();
