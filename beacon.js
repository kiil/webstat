// webstat beacon for folkets.dk. Goes inside the palette block's <script>
// (folkets-palette.php), so it runs on pages LiteSpeed has cached too.
// One POST per page view, as text/plain so the browser sends it without a
// CORS preflight, and with sendBeacon so it survives the reader moving on.
// Nothing is stored on the reader's device.
(function () {
  if (!navigator.sendBeacon || navigator.webdriver || document.visibilityState === 'prerender') { return; }
  // The script sits in the header; the node and drupalSettings come later
  // in the page, so wait for the document.
  function send() {
    var settings = window.drupalSettings || {};
    var current = (settings.path && settings.path.currentPath) || '';
    var match = current.match(/^node\/(\d+)$/);
    var nid = match ? parseInt(match[1], 10) : null;
    var type = null;
    var node = nid && document.querySelector('[data-history-node-id="' + nid + '"]');
    var typeMatch = node && node.className.match(/node--type-([a-z_-]+)/);
    if (typeMatch) { type = typeMatch[1]; }
    var ref = null;
    try {
      var r = new URL(document.referrer);
      if (r.hostname.replace(/^www\./, '') !== location.hostname.replace(/^www\./, '')) { ref = r.hostname.replace(/^www\./, ''); }
    } catch (e) {}
    var path = location.pathname;
    try { path = decodeURIComponent(path); } catch (e) {}
    var width = window.innerWidth;
    var data = {
      path: path,
      nid: nid,
      type: type,
      ref: ref,
      device: width < 768 ? 'mobile' : width < 1200 ? 'tablet' : 'desktop',
      lang: document.documentElement.lang || null
    };
    navigator.sendBeacon('https://webstat.kiil.cross.stream/hit', new Blob([JSON.stringify(data)], {type: 'text/plain'}));
  }
  if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', send); } else { send(); }
})();
