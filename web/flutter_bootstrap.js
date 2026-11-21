{{flutter_js}}
{{flutter_build_config}}

// Cache only public app files. Account records live separately in IndexedDB.
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('relay-sw.js').catch(() => {
    // An unavailable browser cache never prevents an online launch.
  });
}
// Use the same locally cached renderer on every browser, including iPhone.
_flutter.loader.load({
  config: {canvasKitBaseUrl: 'canvaskit/', canvasKitVariant: 'full'},
});
