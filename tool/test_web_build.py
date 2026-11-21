import hashlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class WebBuildTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.build = Path(self.temp.name)
        worker = (ROOT / 'web/relay-sw.js').read_text()
        core = re.findall(r"'([^']+)'", worker.split('const CORE = [', 1)[1].split('];', 1)[0])
        for name in core:
            file = self.build / ('index.html' if name == './' else name)
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('public fixture')
        (self.build / 'index.html').write_text('<script src="flutter_bootstrap.js" async></script>')
        (self.build / 'flutter_bootstrap.js').write_text(
            '_flutter.buildConfig={"builds":[{"mainJsPath":"main.dart.js"}]};'
            "navigator.serviceWorker.register('relay-sw.js');"
            "_flutter.loader.load({config:{canvasKitBaseUrl: 'canvaskit/'}});"
        )

    def finish(self):
        return subprocess.run([sys.executable, str(ROOT / 'tool/finish_web_build.py'), str(self.build)],
                              capture_output=True, text=True, check=True)

    def test_entrypoints_are_versioned_and_available_offline(self):
        self.finish()
        index = (self.build / 'index.html').read_text()
        entry = re.search(r'src="([^"]+)"', index)[1]
        self.assertRegex(entry, r'^relay-bootstrap-[a-f0-9]{12}\.js$')
        bootstrap = (self.build / entry).read_text()
        main = re.search(r'"mainJsPath":"([^"]+)"', bootstrap)[1]
        self.assertRegex(main, r'^relay-main-[a-f0-9]{12}\.js$')
        self.assertEqual((self.build / main).read_bytes(), (self.build / 'main.dart.js').read_bytes())
        worker = (self.build / 'relay-sw.js').read_text()
        self.assertIn(entry, worker)
        self.assertIn(main, worker)
        self.assertIn("importScripts('./relay-sw.js')", (self.build / 'flutter_service_worker.js').read_text())
        self.assertEqual(index, (self.build / '404.html').read_text())

    def test_rerunning_the_finish_step_is_idempotent(self):
        self.finish()
        before = {p.name: p.read_bytes() for p in self.build.iterdir() if p.is_file()}
        self.finish()
        after = {p.name: p.read_bytes() for p in self.build.iterdir() if p.is_file()}
        self.assertEqual(before, after)

    def test_app_change_produces_new_names_and_cache(self):
        self.finish()
        old_index = (self.build / 'index.html').read_text()
        old_worker = (self.build / 'relay-sw.js').read_text()
        (self.build / 'main.dart.js').write_text('new public app')
        self.finish()
        self.assertNotEqual(old_index, (self.build / 'index.html').read_text())
        self.assertNotEqual(old_worker.splitlines()[1], (self.build / 'relay-sw.js').read_text().splitlines()[1])

    def test_incomplete_shell_fails_the_build(self):
        (self.build / 'canvaskit/canvaskit.wasm').unlink()
        with self.assertRaises(subprocess.CalledProcessError):
            self.finish()


if __name__ == '__main__':
    unittest.main()
