#!/usr/bin/env python3
"""Offline regression checks for the actual IPE prerequisite and Git fixture."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

root = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('model_profile', root / 'lib/model-profile.py')
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class FixtureTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.home = Path(directory.name)
        environment = patch.dict(os.environ, HOME=str(self.home),
                                 IPE_LLM_CREDENTIAL_ENV='OPENROUTER_API_KEY',
                                 OPENROUTER_API_KEY='fixture-private-value',
                                 IPE_MACHTIANI_PROVIDER_ID='openrouter',
                                 IPE_LLM_MODEL='z-ai/glm-5.3', IPE_LLM_REASONING='high')
        environment.start()
        self.addCleanup(environment.stop)

    def write_configs(self):
        documented = (root.parent.parent / 'docs/installation-procedure.md').read_text()
        config = documented.split('```toml\n', 1)[1].split('```', 1)[0]
        config = config.replace('<selected-model-id>', os.environ['IPE_LLM_MODEL'])
        config = config.replace('<selected-reasoning-effort>', os.environ['IPE_LLM_REASONING'])
        self.configs = [self.home / path for path in
                        ('.config/machtiani/config.toml', '.config/dearmachine/machtiani/config.toml')]
        for path in self.configs:
            profile.private_write(path, config)

    def test_prerequisite_leaves_product_configuration_to_agent(self):
        profile.seed()
        path, credential = profile.paths()
        self.assertNotIn(os.environ['OPENROUTER_API_KEY'], path.read_text())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(credential.stat().st_mode & 0o777, 0o600)
        self.assertFalse((self.home / '.config/machtiani/config.toml').exists())
        with self.assertRaises(FileExistsError):
            profile.seed()

    def test_documented_model_host_configuration_passes(self):
        profile.seed()
        self.write_configs()
        profile.check()

    def test_deepinfra_uses_custom_endpoint_and_private_credential_reference(self):
        with patch.dict(os.environ, IPE_MACHTIANI_PROVIDER_ID='custom-openai-remote',
                        IPE_LLM_CREDENTIAL_ENV='DEEPINFRA_API_KEY',
                        DEEPINFRA_API_KEY='fixture-deepinfra-value',
                        IPE_LLM_MODEL='zai-org/GLM-5.3-Flash'):
            profile.seed()
            self.write_configs()
            profile.check()
            path, credential = profile.paths()
            selected = json.loads(path.read_text())
            self.assertEqual(selected['driver'], 'openai-compatible')
            self.assertEqual(selected['authMethod'], 'optional_api_key')
            self.assertEqual(selected['customProvider']['chatCompletionsEndpoint'],
                             'https://api.deepinfra.com/v1/openai/chat/completions')
            self.assertEqual(selected['credential']['variable'], 'MACHTIANI_CUSTOM_OPENAI_REMOTE_API_KEY')
            self.assertEqual(credential.read_text(),
                             'MACHTIANI_CUSTOM_OPENAI_REMOTE_API_KEY=fixture-deepinfra-value\n')
            self.assertNotIn('fixture-deepinfra-value', path.read_text())

    def test_forge_deepinfra_override_rejects_endpoint_changes(self):
        profile.seed_forge()
        profile.check_forge()
        path = self.home / '.forge/provider.json'
        saved = json.loads(path.read_text())
        self.assertEqual(saved[0]['api_key_vars'], 'DEEPINFRA_API_KEY')
        saved[0]['url'] = 'https://router.requesty.ai/v1/chat/completions'
        path.write_text(json.dumps(saved))
        with self.assertRaisesRegex(ValueError, 'endpoint or credential'):
            profile.check_forge()

    def test_both_consumers_must_use_selected_model_host(self):
        profile.seed()
        self.write_configs()
        for path in self.configs:
            original = path.read_text()
            for before, after in [('model-host', 'openai'),
                                  ('"@machtiani/planner"', '"z-ai/glm-5.3"'),
                                  ('model = "@machtiani/planner"',
                                   'model = "@machtiani/planner"\nparams = { reasoning = { effort = "high" } }'),
                                  ('shell_agent_model = "dearmachine-shell-agent"', 'shell_agent_model = "dearmachine"')]:
                with self.subTest(path=path.name, mutation=before):
                    path.write_text(original.replace(before, after))
                    with self.assertRaises(ValueError):
                        profile.check()
            path.write_text(original)

    def test_rejects_changed_profile_credentials_and_public_files(self):
        profile.seed()
        self.write_configs()
        path, credential = profile.paths()
        saved = path.read_text()
        changed = json.loads(saved)
        changed['model'] = 'wrong-model'
        path.write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, 'profile changed'):
            profile.check()
        path.write_text(saved)
        credential.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'mode-0600'):
            profile.check()

    def test_reconstructed_archive_tracks_new_and_ignored_files(self):
        checkout = self.home / 'snapshot'
        checkout.mkdir()
        modules = ['machtiani-harness', 'dearmachine', 'dearmachine-concierge']
        (checkout / '.gitmodules').write_text(''.join(
            f'[submodule "{name}"]\n\tpath = {name}\n\turl = https://example.invalid/{name}\n'
            for name in modules))
        for directory in [checkout] + [checkout / name for name in modules]:
            directory.mkdir(exist_ok=True)
            (directory / '.gitignore').write_text('tracked-ignored.txt\n')
            (directory / 'tracked-ignored.txt').write_text('tracked in the source archive\n')
            (directory / 'LICENSE').write_text('fixture\n')
            (directory / 'NEW-DOCUMENT.md').write_text('new tracked file\n')
        source = (root / 'container-agent.sh').read_text().split('assemble_forge_prompt() {', 1)[0]
        result = subprocess.run(['bash', '-c', source + '\numbrella=$1\nprepare_checkout',
                                 'fixture', str(checkout)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for directory in [checkout] + [checkout / name for name in modules]:
            files = subprocess.check_output(['git', '-C', str(directory), 'ls-files'], text=True)
            self.assertIn('tracked-ignored.txt', files)
            self.assertEqual(subprocess.check_output(['git', '-C', str(directory), 'status', '--porcelain']), b'')


if __name__ == '__main__':
    unittest.main()
