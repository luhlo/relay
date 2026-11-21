import assert from 'node:assert/strict';
import {readFile, access} from 'node:fs/promises';
import {resolve} from 'node:path';
import vm from 'node:vm';

const source = await readFile(new URL('../web/relay-sw.js', import.meta.url), 'utf8');
const legacy = await readFile(new URL('legacy_service_worker.js', import.meta.url), 'utf8');
const scope = 'https://relay.example.invalid/relay/';
const handlers = new Map(), stores = new Map();
let network = true, installFails = false, claims = 0, fetches = 0;
const key = request => typeof request === 'string' ? request : request.url;
const cacheFor = name => {
  if (!stores.has(name)) stores.set(name, new Map());
  const entries = stores.get(name);
  return {
    async addAll(requests) {
      if (installFails) throw Error('Incomplete app download');
      for (const request of requests) entries.set(key(request), new Response(`cached:${new URL(key(request)).pathname}`));
    },
    async match(request, options = {}) {
      const wanted = new URL(key(request));
      for (const [url, response] of entries) {
        const stored = new URL(url);
        if (options.ignoreSearch) {wanted.search = ''; stored.search = '';}
        if (wanted.href === stored.href) return response.clone();
      }
    },
    async put(request, response) {entries.set(key(request), response);},
  };
};
const context = vm.createContext({
  URL, Request, Response,
  self: {registration: {scope}, clients: {claim: async () => claims++}, addEventListener: (name, fn) => handlers.set(name, fn)},
  caches: {open: async name => cacheFor(name), keys: async () => [...stores.keys()], delete: async name => stores.delete(name)},
  fetch: async request => {fetches++; if (!network) throw Error('Offline'); return new Response(`network:${key(request)}`);},
});
vm.runInContext(source, context);
const lifecycle = async name => {
  let work;
  handlers.get(name)({waitUntil: future => work = future});
  await work;
};
const get = async (path, options = {}) => {
  let response;
  handlers.get('fetch')({request: {url: new URL(path, scope).href, method: 'GET', mode: 'cors', ...options}, respondWith: future => response = future});
  return response ? (await response).text() : null;
};

stores.set('relay-shell-previous', new Map([['old', new Response('working')]]));
stores.set('another-app', new Map());
installFails = true;
await assert.rejects(lifecycle('install'), /Incomplete/);
assert(stores.has('relay-shell-previous'), 'A failed update must preserve the working shell');
installFails = false;
await lifecycle('install');
await lifecycle('activate');
assert(!stores.has('relay-shell-previous'));
assert(stores.has('another-app'));
assert.equal(claims, 1);

network = false;
assert.match(await get('./?code=private-login-code', {mode: 'navigate'}), /cached:.*index.html/);
assert.match(await get('main.dart.js?v=23'), /cached:.*main.dart.js/);
assert.match(await get('canvaskit/canvaskit.wasm'), /cached:.*canvaskit.wasm/);
const before = fetches;
assert.equal(await get('rest/v1/parent_records'), null);
assert.equal(await get('auth/v1/token'), null);
assert.equal(await get('functions/v1/relay-support'), null);
assert.equal(await get('https://project.supabase.co/rest/v1/parent_records'), null);
assert.equal(await get('main.dart.js', {method: 'POST'}), null);
assert.equal(fetches, before, 'Private requests must be left to the browser, never cached');
assert(![...stores.values()].some(entries => [...entries.keys()].some(url => url.includes('private-login-code'))));
network = true;
assert.match(await get('./', {mode: 'navigate'}), /network:/);
assert.match(await get('assets/new-optional-asset.png'), /network:/);
network = false;
assert.match(await get('assets/new-optional-asset.png'), /network:/, 'Public optional asset should be available after caching');

// A browser upgrading from the old Flutter worker URL gets the same complete
// install/activation path instead of an empty worker that drops offline access.
let legacyInstalled = false;
const upgradeContext = vm.createContext({importScripts: path => {
  assert.equal(path, './relay-sw.js');
  legacyInstalled = true;
}});
vm.runInContext(legacy, upgradeContext);
assert(legacyInstalled);

const buildDirectory = globalThis.process?.argv?.[2];
if (buildDirectory) {
  const core = vm.runInContext('CORE', context);
  for (const file of core) await access(resolve(buildDirectory, file === './' ? 'index.html' : file));
  console.log(`PASS: all ${core.length} app-shell files exist in the web build`);
}
console.log('PASS: offline navigation, renderer, private-request isolation, query-token exclusion, public asset caching, failed update recovery, scoped cache cleanup, legacy PWA upgrade');
