// webstat beacon for folkets.dk. Goes inside the palette block's <script>
// (folkets-palette.php), so it runs on pages LiteSpeed has cached too.
// Everything goes to /nyt.php on folkets.dk itself (the first-party
// collector, which passes it on to webstat), as text/plain beacons: no CORS
// preflight, and they survive the reader moving on. Nothing is stored on the
// reader's device; the view id lives only as long as the page.
//
// Reports: the page view; reading 50 and 100 percent of an article; the
// seconds the page was visible (when it is hidden or left); clicks on
// support and subscription links. On the front page it also puts webstat's
// hot list above "Ugens eftertragtede".
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

  // The script sits in the header; the node and drupalSettings come later
  // in the page, so wait for the document.
  function start() {
    var settings = window.drupalSettings || {};
    var current = (settings.path && settings.path.currentPath) || '';
    var match = current.match(/^node\/(\d+)$/);
    var nid = match ? parseInt(match[1], 10) : null;
    var node = nid && document.querySelector('[data-history-node-id="' + nid + '"]');
    var typeMatch = node && node.className.match(/node--type-([a-z_-]+)/);
    var heading = document.querySelector('h1.title');
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

    // Reading depth through the article body: halfway and the end.
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

    // Support and subscription clicks.
    document.addEventListener('click', function (e) {
      var a = e.target.closest && e.target.closest('a[href]');
      if (!a) { return; }
      var url;
      try { url = new URL(a.href); } catch (err) { return; }
      var target = null;
      if (url.hostname.replace(/^www\./, '') === here && /^\/(abonnent|stot|støt)/.test(decodeURIComponent(url.pathname))) {
        target = decodeURIComponent(url.pathname) + url.search;
      } else if (/(^|\.)stripe\.com$/.test(url.hostname)) {
        target = 'stripe';
      }
      if (target) { send('click', {target: target}); }
    }, true);

    showHot();
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

  // The front page: "Hot lige nu" above "Ugens eftertragtede".
  function showHot() {
    var anchor = document.getElementById('block-bootstrap-barrio-views-block-ga-block-1');
    if (!anchor || !window.fetch) { return; }
    fetch(collector + '?hot').then(function (r) { return r.ok ? r.json() : []; }).then(function (items) {
      items = (items || []).filter(function (i) { return i.title && i.name !== '/' && i.name.indexOf('/abonnent') !== 0; });
      if (items.length < 3) { return; }
      var block = document.createElement('div');
      block.className = 'block folkets-hot';
      var h = document.createElement('h2');
      h.textContent = 'Hot lige nu';
      var list = document.createElement('ol');
      list.className = 'list-group list-group-flush folkets-top';
      items.slice(0, 5).forEach(function (i) {
        var li = document.createElement('li');
        li.className = 'list-group-item px-0';
        var h5 = document.createElement('h5');
        var a = document.createElement('a');
        a.href = i.name;
        a.textContent = i.title;
        h5.appendChild(a);
        li.appendChild(h5);
        list.appendChild(li);
      });
      block.appendChild(h);
      block.appendChild(list);
      anchor.parentNode.insertBefore(block, anchor);
    }).catch(function () {});
  }

  if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', start); } else { start(); }
})();
