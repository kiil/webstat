// The service worker: what makes Webstat installable, lets it open without a
// network, and shows the morning report.
//
// It is deliberately not a caching layer for the app. The board is rendered
// on the server and every change arrives over SSE, so it caches two things
// only:
//
//   1. the shell (Datastar, the manifest, the icons);
//   2. the last board the server rendered for each view (`/` and each
//      `/?site=`), as a fallback for when there is no network. The stream
//      corrects it the moment the network is back.
//
// Everything is network-first: the cache is a safety net, never a speed-up.
// A request this worker does not call respondWith on goes straight to the
// network, which is right for /hit and the /api routes, and for /updates and
// /refresh, streams that must not be buffered.

const VERSION = "webstat-v1";
const SHELL = [
  "/manifest.webmanifest",
  "/icons/icon.svg",
  "/icons/badge-96.png",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
  "/icons/apple-touch-icon.png",
];

// The page tells the worker which Datastar bundle it loaded, so the version
// lives in one place (serve.nu) instead of being repeated here.
self.addEventListener("message", (e) => {
  if (e.data?.type === "cache-asset" && e.data.url) {
    e.waitUntil(caches.open(VERSION).then((c) => c.add(e.data.url)).catch(() => {}));
  }
});

self.addEventListener("install", (e) => {
  // Individually, so one missing file cannot fail the whole install.
  e.waitUntil(
    caches.open(VERSION)
      .then((c) => Promise.all(SHELL.map((u) => c.add(u).catch(() => {}))))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

// The network's answer, kept in the cache when it is a good one.
async function fresh(req) {
  const res = await fetch(req);
  if (res.ok) {
    const copy = res.clone();
    caches.open(VERSION).then((c) => c.put(req, copy)).catch(() => {});
  }
  return res;
}

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  if (req.mode === "navigate") {
    if (url.pathname !== "/") return;
    e.respondWith(
      fresh(req).catch(async () =>
        (await caches.match(req)) ?? (await caches.match("/")) ?? offline()),
    );
    return;
  }

  if (["script", "image", "manifest"].includes(req.destination)) {
    e.respondWith(
      fresh(req).catch(async () => (await caches.match(req)) ?? Response.error()),
    );
  }
});

// The push carries nothing: it says there is news, and the news is fetched
// from the server. `userVisibleOnly` was promised at subscribe time,
// so every push must end in a notification, also when the fetch fails.
self.addEventListener("push", (e) => {
  e.waitUntil(
    fetch("/api/notice", { cache: "no-store" })
      .then((r) => r.json())
      .catch(() => null)
      .then((r) => self.registration.showNotification(r?.title ?? "Webstat", {
        body: r?.body ?? "Morgenrapporten er slået til.",
        tag: r?.tag ?? "webstat-morning",
        icon: "/icons/icon-192.png",
        // Not icon-192: Android keeps only this file's alpha channel, so a
        // colour icon arrives in the status bar as a solid square.
        badge: "/icons/badge-96.png",
        data: { url: r?.url ?? "/" },
      })),
  );
});

// An article opens; the report focuses the app if it is open anywhere, rather
// than opening a second window.
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = e.notification.data?.url ?? "/";
  if (url !== "/") {
    e.waitUntil(self.clients.openWindow(url));
    return;
  }
  e.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((cs) =>
      cs.length ? cs[0].focus() : self.clients.openWindow("/")),
  );
});

// Only reached on a cold start with an empty cache; otherwise the cached page
// is the offline view, and it has an actual board in it.
function offline() {
  return new Response(
    `<!doctype html><meta charset="utf-8">
     <meta name="viewport" content="width=device-width,initial-scale=1">
     <title>Webstat</title>
     <style>body{margin:0;display:grid;place-items:center;height:100dvh;
       font:16px/1.5 Georgia,serif;background:#191816;color:#F1EDE4}
       p{color:#A39C90}</style>
     <div><h1>Webstat</h1><p>Ingen forbindelse til serveren.</p></div>`,
    { status: 503, headers: { "Content-Type": "text/html; charset=utf-8" } },
  );
}
