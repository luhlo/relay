"""Validate the offline shell and prepare Flutter output for GitHub Pages."""
import hashlib
import re
import shutil
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
build = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'build/web'
bootstrap = (build / 'flutter_bootstrap.js').read_text()
if "register('relay-sw.js')" not in bootstrap or "canvasKitBaseUrl: 'canvaskit/'" not in bootstrap:
    raise SystemExit('Build must use the Relay bootstrap and local CanvasKit renderer')

# Older service workers and HTTP caches recognize the unversioned Flutter file
# names. Unique content-based entrypoints let a fresh online navigation load the
# new app immediately, without deleting any account or device records.
main_bytes = (build / 'main.dart.js').read_bytes()
main_hash = hashlib.sha256(main_bytes).hexdigest()[:12]
main_name = f'relay-main-{main_hash}.js'
bootstrap, count = re.subn(
    r'("mainJsPath"\s*:\s*")(?:main\.dart\.js|relay-main-[a-f0-9]{12}\.js)(")',
    lambda match: match[1] + main_name + match[2], bootstrap,
)
if count != 1:
    raise SystemExit('Expected one JavaScript entrypoint in the Flutter build config')
bootstrap_hash = hashlib.sha256(bootstrap.encode()).hexdigest()[:12]
bootstrap_name = f'relay-bootstrap-{bootstrap_hash}.js'
index, count = re.subn(
    r'src="(?:flutter_bootstrap\.js|relay-bootstrap-[a-f0-9]{12}\.js)"',
    f'src="{bootstrap_name}"', (build / 'index.html').read_text(),
)
if count != 1:
    raise SystemExit('Expected one Flutter bootstrap script in index.html')
(build / main_name).write_bytes(main_bytes)
(build / bootstrap_name).write_text(bootstrap)
(build / 'flutter_bootstrap.js').write_text(bootstrap)
(build / 'index.html').write_text(index)

worker = (root / 'web/relay-sw.js').read_text()
worker = worker.replace("'main.dart.js',", f"'main.dart.js', '{bootstrap_name}', '{main_name}',", 1)
worker = re.sub(r"(const CACHE = ')([^']+)(';)",
                lambda match: match[1] + match[2] + '-' + bootstrap_hash + match[3], worker, count=1)
(build / 'relay-sw.js').write_text(worker)
core = re.findall(r"'([^']+)'", worker.split('const CORE = [', 1)[1].split('];', 1)[0])
missing = [path for path in core if not (build / ('index.html' if path == './' else path)).is_file()]
if missing:
    raise SystemExit(f'Offline shell is incomplete: {missing}')
# Flutter overwrites its legacy worker even with --pwa-strategy=none, so this
# compatibility entrypoint must be installed AFTER the Flutter build command.
shutil.copyfile(root / 'tool/legacy_service_worker.js', build / 'flutter_service_worker.js')
shutil.copyfile(build / 'index.html', build / '404.html')
(build / '.nojekyll').touch()
print(f'PASS: {len(core)} offline shell files, local renderer, legacy PWA upgrade and Pages routes prepared')
