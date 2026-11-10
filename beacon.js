// webstat beacon for folkets.dk. Goes inside the palette block's <script>
// (folkets-palette.php), so it runs on pages LiteSpeed has cached too.
// Everything goes to /nyt.php on folkets.dk itself (the first-party
// collector, which passes it on to webstat), as text/plain beacons: no CORS
// preflight, and they survive the reader moving on. Nothing is stored on the
// reader's device; the view id lives only as long as the page.
//
// Reports: the page view; reading 50 and 100 percent of an article; the
// seconds the page was visible (when it is hidden or left), with where in
// the article the reader rested and stopped and which landmarks (video,
// embeds, images, quotes, subheadings) held them; clicks on support and
// subscription links; on the front page, the teasers seen and clicked. On
// the front page it also puts webstat's hot list above "Ugens eftertragtede"
// (when at least two articles are hot).
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

    if (body) { watchAttention(body); }
    if (path === '/') { watchTeasers(); }
    showHot();
  }

  // Where the reader rests and stops in the article. Once a second, while
  // the page is visible and the reader has done something in the last 30
  // seconds (or is inside an embed, e.g. watching a video), the scroll
  // position counts as rest when it has not moved for 1.2 seconds. The
  // reading line is 40 percent down the window; the band of the body under
  // it gets the second. Landmarks (video, other embeds, images, quotes,
  // tables, subheadings) get the second when they are in the middle of the
  // window. Sent with each leave report.
  var attention = null;

  function watchAttention(body) {
    var a = {body: body, rest: [], depth: 0, at: null, marks: [], lastMove: Date.now(), lastActive: Date.now()};
    for (var i = 0; i < 20; i++) { a.rest.push(0); }
    attention = a;

    function kindOf(el) {
      var tag = el.tagName;
      if (tag === 'IFRAME') {
        var host = hostOf(el.src);
        return /youtube|youtu\.be|vimeo|dailymotion|dr\.dk|tv2\.dk|twitch|ted\.com/.test(host) || /plugins\/video/.test(el.src) ? 'v' : 'e';
      }
      return {VIDEO: 'v', AUDIO: 'a', FIGURE: 'i', IMG: 'i', PICTURE: 'i', TABLE: 't', BLOCKQUOTE: 'q', H2: 'h', H3: 'h', H4: 'h'}[tag] || null;
    }
    function labelOf(el, kind) {
      var text = '';
      if (kind === 'v' || kind === 'e') { text = el.tagName === 'IFRAME' ? hostOf(el.src) || el.title || '' : (el.title || ''); }
      else if (kind === 'i') { var cap = el.querySelector && el.querySelector('figcaption'); var img = el.tagName === 'IMG' ? el : el.querySelector && el.querySelector('img'); text = (cap && cap.textContent) || (img && img.alt) || ''; }
      else { text = el.textContent || ''; }
      return text.replace(/\s+/g, ' ').trim().slice(0, 40);
    }
    // Landmarks in order down the body, the outermost element of each; run
    // again after load, when embeds have replaced their placeholders.
    function collect() {
      var known = a.marks.map(function (m) { return m.el; });
      body.querySelectorAll('iframe, video, audio, figure, picture, img, table, blockquote, h2, h3, h4').forEach(function (el) {
        if (a.marks.length >= 12 || known.indexOf(el) >= 0) { return; }
        for (var j = 0; j < known.length; j++) { if (known[j].contains(el) || el.contains(known[j])) { return; } }
        var kind = kindOf(el);
        if (!kind) { return; }
        if (kind === 'i' && el.getBoundingClientRect().height > 0 && el.getBoundingClientRect().height < 80) { return; }
        if (el.tagName === 'VIDEO' || el.tagName === 'AUDIO') {
          el.addEventListener('play', function () { mark.engaged = 1; });
        }
        var mark = {el: el, kind: kind, label: labelOf(el, kind), dwell: 0, engaged: 0};
        a.marks.push(mark);
        known.push(el);
      });
      a.marks.sort(function (x, y) { return x.el.compareDocumentPosition(y.el) & 2 ? 1 : -1; });
    }
    collect();
    window.addEventListener('load', collect);

    var moved = function () { a.lastMove = Date.now(); a.lastActive = a.lastMove; };
    var active = function () { a.lastActive = Date.now(); };
    window.addEventListener('scroll', moved, {passive: true});
    ['mousemove', 'keydown', 'touchstart', 'wheel'].forEach(function (e) { window.addEventListener(e, active, {passive: true}); });
    // A click into an embed moves focus into its iframe and blurs the page.
    window.addEventListener('blur', function () {
      setTimeout(function () {
        var el = document.activeElement;
        a.marks.forEach(function (m) { if (m.el === el || (m.el.contains && m.el.contains(el))) { m.engaged = 1; } });
      }, 0);
    });

    setInterval(function () {
      if (document.visibilityState !== 'visible') { return; }
      var inEmbed = document.activeElement && document.activeElement.tagName === 'IFRAME';
      var now = Date.now();
      if (!inEmbed && now - a.lastActive > 30000) { return; }
      var box = body.getBoundingClientRect();
      if (box.height <= 0) { return; }
      var vh = window.innerHeight;
      var seen = Math.round(Math.min(Math.max((vh - box.top) / box.height, 0), 1) * 100);
      if (seen > a.depth) { a.depth = seen; }
      if (!inEmbed && now - a.lastMove < 1200) { return; }
      var p = (vh * 0.4 - box.top) / box.height;
      if (p < 0 || p > 1) { return; }
      a.rest[Math.min(19, Math.floor(p * 20))] += 1;
      a.at = Math.round(p * 100);
      a.marks.forEach(function (m) {
        var r = m.el.getBoundingClientRect();
        if (r.height > 0 && r.bottom > vh * 0.15 && r.top < vh * 0.85) { m.dwell += 1; }
      });
    }, 1000);
  }

  function attentionReport() {
    var a = attention;
    if (!a) { return {}; }
    var box = a.body.getBoundingClientRect();
    var marks = [];
    a.marks.forEach(function (m) {
      var r = m.el.getBoundingClientRect();
      if (box.height <= 0 || (r.height === 0 && r.width === 0)) { return; }
      var pos = Math.round(Math.min(Math.max((r.top - box.top) / box.height, 0), 1) * 100);
      marks.push([m.kind, pos, m.label, Math.min(m.dwell, 7200), m.engaged]);
    });
    var out = {depth: a.depth, rest: a.rest.map(function (x) { return Math.min(x, 7200); })};
    if (a.at !== null) { out.at = a.at; }
    if (marks.length) { out.marks = marks; }
    return out;
  }

  // Front page teasers: one counts as seen when half of it has been in the
  // window for a second, once per page view. Sent when the page is hidden;
  // a click on one is sent at once. The module is one letter (f the
  // showcase, k Kort nyt, a the archive bands, u Ugens eftertragtede, h Hot
  // lige nu), the place counts from 1 within it, and the headline goes with
  // it.
  var teaserUnits = [
    ['.fs-item', 'f'], ['.kn-item', 'k'], ['.band-item', 'a'],
    ['#block-bootstrap-barrio-views-block-ga-block-1 li', 'u'], ['.folkets-hot li', 'h']
  ];
  var teaserSeen = {};
  var teaserPending = [];
  var teaserObserver = null;
  var teaserTimers = typeof WeakMap === 'function' ? new WeakMap() : null;

  function teaserOf(el) {
    for (var i = 0; i < teaserUnits.length; i++) {
      var unit = el.closest && el.closest(teaserUnits[i][0]);
      if (!unit) { continue; }
      var all = Array.prototype.slice.call(document.querySelectorAll(teaserUnits[i][0]));
      var a = unit.querySelector('a[href]');
      if (!a) { return null; }
      var target;
      try { var u = new URL(a.href); if (u.hostname !== location.hostname) { return null; } target = decodeURIComponent(u.pathname); } catch (e) { return null; }
      if (target === '/') { return null; }
      var head = unit.querySelector('h2, h3, h4, h5, .fs-title, .kn-title, .band-title') || a;
      return [target, teaserUnits[i][1], all.indexOf(unit) + 1, (head.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 120)];
    }
    return null;
  }

  function watchTeasers() {
    if (!('IntersectionObserver' in window) || !teaserTimers) { return; }
    if (!teaserObserver) {
      teaserObserver = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          var el = e.target;
          if (e.intersectionRatio >= 0.5) {
            if (teaserTimers.get(el)) { return; }
            teaserTimers.set(el, setTimeout(function () {
              var t = teaserOf(el);
              var key = t && t.slice(0, 3).join('|');
              if (t && !teaserSeen[key]) { teaserSeen[key] = true; teaserPending.push(t); }
              teaserObserver.unobserve(el);
            }, 1000));
          } else if (teaserTimers.get(el)) {
            clearTimeout(teaserTimers.get(el));
            teaserTimers.delete(el);
          }
        });
      }, {threshold: [0, 0.5]});
      document.addEventListener('click', function (e) {
        var a = e.target.closest && e.target.closest('a[href]');
        var t = a && teaserOf(a);
        if (t) { send('tclick', {target: t[0], mod: t[1], pos: t[2]}); }
      }, true);
    }
    teaserUnits.forEach(function (u) {
      document.querySelectorAll(u[0]).forEach(function (el) { teaserObserver.observe(el); });
    });
  }

  // Seen teasers in reports under nyt.php's 4096 bytes.
  function bytes(x) { return unescape(encodeURIComponent(JSON.stringify(x))).length; }
  function flushTeasers() {
    while (teaserPending.length) {
      var chunk = [];
      var size = 80;
      while (teaserPending.length && size + bytes(teaserPending[0]) < 3500) {
        var t = teaserPending.shift();
        size += bytes(t) + 1;
        chunk.push(t);
      }
      if (!chunk.length) { teaserPending.shift(); continue; }
      send('teasers', {seen: chunk});
    }
  }

  // Seconds the page was visible, sent each time it is hidden (the latest
  // report per view counts).
  var visibleSince = document.visibilityState === 'visible' ? Date.now() : null;
  var visible = 0;
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') {
      if (visibleSince) { visible += Date.now() - visibleSince; visibleSince = null; }
      var seconds = Math.round(visible / 1000);
      if (seconds >= 1) {
        var report = attentionReport();
        report.seconds = Math.min(seconds, 7200);
        send('leave', report);
      }
      flushTeasers();
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
      if (items.length < 2) { return; }
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
      watchTeasers();
    }).catch(function () {});
  }

  if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', start); } else { start(); }
})();
