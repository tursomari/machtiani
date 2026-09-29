"""Exercise the verifier's actual TOML-to-Agent-Manager selection boundary."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

script = pathlib.Path(__file__).with_name('verify-installation.sh').read_text()
selection = script.split("<<'BACKEND_SELECTION_PY'\n", 1)[1].split('\nBACKEND_SELECTION_PY', 1)[0]
resolved = script.split('selected_backend=$(python3', 1)[1].split("<<'PY'\n", 1)[1].split('\nPY', 1)[0]


class BackendSelectionTest(unittest.TestCase):
    def selection(self, configuration):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'config.toml'
            path.write_text(configuration)
            return subprocess.run([sys.executable, '-c', selection, str(path)], capture_output=True, text=True)

    def test_configured_selection_overrides_ambient_detection(self):
        result = self.selection('version = 1\nbackends = ["custom-worker", "forge"]\nresponse_tier = "formatted"\n')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), '["custom-worker", "forge"]')

    def test_missing_empty_and_malformed_selections_fail(self):
        for value in ('version = 1', 'backends = []', 'backends = "forge"', 'backends = [""]', 'backends = [123]'):
            with self.subTest(value=value):
                self.assertNotEqual(self.selection(value).returncode, 0)

    def test_resolved_selection_uses_actual_line_oriented_cli_output(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'resolved.txt'
            for content, expected in [('forge\n', 'forge'), ('custom-worker\nforge\n', 'custom-worker'), ('', None), ('[]\n', None)]:
                with self.subTest(content=content):
                    path.write_text(content)
                    result = subprocess.run([sys.executable, '-c', resolved, str(path)], capture_output=True, text=True)
                    if expected is None:
                        self.assertNotEqual(result.returncode, 0)
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout.strip(), expected)


if __name__ == '__main__':
    unittest.main()
