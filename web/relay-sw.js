/* Public app-shell cache. Never cache auth, RPCs, feedback, or account records. */
const CACHE = 'relay-shell-1.18.0-23';
const CORE = [
  './', 'index.html', 'flutter_bootstrap.js', 'main.dart.js',
  'manifest.json', 'favicon.png',
  'assets/AssetManifest.bin.json', 'assets/FontManifest.json',
  'assets/assets/Manrope.ttf', 'assets/assets/relay_icon.png',
  'assets/fonts/MaterialIcons-Regular.otf',
  'assets/packages/cupertino_icons/assets/CupertinoIcons.ttf',
  'canvaskit/canvaskit.js', 'canvaskit/canvaskit.wasm',
  'icons/Icon-192.png', 'icons/Icon-512.png',
  'icons/Icon-maskable-192.png', 'icons/Icon-maskable-512.png',
];

const base = new URL('./', self.registration.scope);
const shell = new URL('index.html', base).href;
const isStatic = url => url.origin === base.origin &&
  url.pathname.startsWith(base.pathname) &&
  (CORE.some(path => new URL(path, base).pathname === url.pathname) ||
    ['assets/', 'canvaskit/', 'icons/'].some(path =>
      url.pathname.startsWith(new URL(path, base).pathname)));

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    // Cache.addAll commits as one batch. A failed download leaves the working
    // cache intact and rejects installation instead of activating a partial app.
    await cache.addAll(CORE.map(path => new Request(new URL(path, base), {cache: 'reload'})));
    // Existing pages finish on their own version. Activate after they close.
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) {
      if (key.startsWith('relay-shell-') && key !== CACHE) await caches.delete(key);
    }
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== base.origin) return;
  // A cached app shell may open offline; authenticated requests are never here.
  if (request.mode === 'navigate' &&
      (url.pathname === base.pathname || url.pathname === new URL('index.html', base).pathname)) {
    event.respondWith((async () => {
      const cache = await caches.open(CACHE);
      try {
        const response = await fetch(request);
        // Leave the installed shell unchanged until a full new cache activates.
        if (response.ok) return response;
      } catch (_) { /* Offline: use the complete installed app shell. */ }
      return await cache.match(shell) || await cache.match(new URL('./', base).href) || Response.error();
    })());
    return;
  }
  if (!isStatic(url)) return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const cached = await cache.match(request, {ignoreSearch: true});
    if (cached) return cached;
    const response = await fetch(request);
    if (response.ok && response.type !== 'opaque') await cache.put(request, response.clone());
    return response;
  })());
});
