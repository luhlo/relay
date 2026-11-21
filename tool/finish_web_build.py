"""Validate the offline shell and prepare Flutter output for GitHub Pages."""
import re
import shutil
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
build = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'build/web'
worker = (root / 'web/relay-sw.js').read_text()
core = re.findall(r"'([^']+)'", worker.split('const CORE = [', 1)[1].split('];', 1)[0])
missing = [path for path in core if not (build / ('index.html' if path == './' else path)).is_file()]
if missing:
    raise SystemExit(f'Offline shell is incomplete: {missing}')
bootstrap = (build / 'flutter_bootstrap.js').read_text()
if "register('relay-sw.js')" not in bootstrap or "canvasKitBaseUrl: 'canvaskit/'" not in bootstrap:
    raise SystemExit('Build must use the Relay bootstrap and local CanvasKit renderer')
# Flutter overwrites its legacy worker even with --pwa-strategy=none, so this
# compatibility entrypoint must be installed AFTER the Flutter build command.
shutil.copyfile(root / 'tool/legacy_service_worker.js', build / 'flutter_service_worker.js')
shutil.copyfile(build / 'index.html', build / '404.html')
(build / '.nojekyll').touch()
print(f'PASS: {len(core)} offline shell files, local renderer, legacy PWA upgrade and Pages routes prepared')
