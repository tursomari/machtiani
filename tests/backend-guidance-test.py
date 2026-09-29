#!/usr/bin/env python3
"""Credential-free checks of the canonical backend discovery/setup guidance."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BackendGuidanceTests(unittest.TestCase):
    def test_explicit_email_roles_are_not_overridden_by_domain_inference(self):
        email = (ROOT / 'docs/installation/03-email.md').read_text()
        self.assertIn('An explicitly stated address role takes precedence', email)
        self.assertIn('Never infer the role from an address domain', email)
        self.assertIn('both addresses may use the same email service', email)

    def test_public_conversation_and_discovery_exclude_private_bookkeeping(self):
        contract = (ROOT / 'INSTALL.md').read_text()
        self.assertIn('Public replies are for the human, not a working notebook', contract)
        self.assertIn('Do not announce that you are following an instruction silently', contract)
        environment = (ROOT / 'docs/installation/01-environment.md').read_text()
        self.assertIn('Do not open credential files even to redact their contents', environment)
        self.assertIn('Do not enumerate variable names from', environment)

    def test_environment_lfs_check_does_not_create_state_in_source_snapshot(self):
        text = (ROOT / 'docs/installation/01-environment.md').read_text()
        for required in ('git lfs version', '`git lfs env` can create',
                         'disposable directory', 'source snapshot unchanged'):
            self.assertIn(required, text)

    def test_discovery_is_shared_and_does_not_confuse_path_with_absence(self):
        guide = (ROOT / 'docs/installation/backend-discovery.md').read_text()
        for required in ('command -v', '$HOME/.local/bin', '$HOME/.nix-profile/bin',
                         'Do not reinstall', 'preserve', 'No provider request'):
            self.assertIn(required, guide)
        for path in ('docs/installation/01-environment.md', 'docs/installation/04-backend.md', 'docs/backend-management.md'):
            self.assertIn('backend-discovery.md', (ROOT / path).read_text())

    def test_installation_owns_new_backend_setup_without_a_known_failure_probe(self):
        text = (ROOT / 'docs/installation/04-backend.md').read_text()
        for required in ('installed, configured, verified, and activated',
                         'Do not run a provider request merely to demonstrate',
                         'installation permission covers local version/help',
                         'reuse explicit choices and health-check permission'):
            self.assertIn(required, text)

    def test_omp_has_persistent_settings_and_scoped_credentials(self):
        forge = (ROOT / 'docs/installation/backends/forge.md').read_text()
        self.assertNotIn('`backendPreparation`', forge)
        self.assertIn('backendPreparations.forge.invocation', forge)
        text = (ROOT / 'docs/installation/backends/omp.md').read_text()
        for required in ('18.1.16', 'omp config get modelRoles', 'omp config set modelRoles',
                         '<provider>/<model-id>:<reasoning-level>', 'preserve other roles',
                         'fresh process', 'backendPreparations.forge', 'backend-management.md'):
            self.assertIn(required, text)

    def test_omp_does_not_treat_an_unconfigured_catalogue_as_a_model_rejection(self):
        text = (ROOT / 'docs/installation/backends/omp.md').read_text()
        self.assertIn('Finish the private credential-reference integration before querying', text)
        self.assertIn('An empty catalogue before that setup is not evidence', text)
        self.assertIn('a catalogue search is optional', text)

    def test_omp_verifies_reasoning_from_metadata_not_visible_thoughts(self):
        text = (ROOT / 'docs/installation/backends/omp.md').read_text()
        for required in ('model_change', 'thinking_level_change', 'thinkingLevel',
                         'Absence of visible reasoning text',
                         'Do not request or print private reasoning'):
            self.assertIn(required, text)

    def test_omp_distinguishes_remote_broker_status_from_local_login(self):
        text = (ROOT / 'docs/installation/backends/omp.md').read_text()
        for required in ('`omp auth-broker status --json`', '`not_configured`',
                         'not local subscription authentication',
                         'After the human confirms login, proceed to the consented functional OMP probe',
                         'only when functional verification reports an authentication failure',
                         'Do not inspect credential files or database contents'):
            self.assertIn(required, text)

    def test_manual_login_handoff_preserves_the_readiness_boundary(self):
        contract = (ROOT / 'INSTALL.md').read_text()
        self.assertIn('working trusted login integration', contract)
        text = (ROOT / 'docs/installation/04-backend.md').read_text()
        handoff = text.split('## Manual login handoff')[1].split('## Install a missing')[0]
        for required in ('same user account', 'backend profile', 'same container',
                         'End the turn and wait', 'still working', 'Do not poll, probe',
                         'report alone is not proof', 'functional health check',
                         'exited or timed-out', 'built-in and unfamiliar backends'):
            self.assertIn(required, handoff)
        self.assertNotIn('start the documented login or configuration flow yourself', text)
        self.assertLess(handoff.index("human's confirmation"), handoff.index('functional health check'))

    def test_backend_guides_use_the_shared_manual_handoff(self):
        for backend in ('omp', 'codex', 'claude'):
            guide = (ROOT / ('docs/installation/backends/' + backend + '.md')).read_text()
            self.assertIn('manual login handoff', ' '.join(guide.split()))
        omp = (ROOT / 'docs/installation/backends/omp.md').read_text()
        self.assertIn('verify the provider ID first', omp)
        self.assertIn('do not start a blocking `omp auth-broker login`', omp)

    def test_probe_prerequisites_are_at_the_point_of_use(self):
        backend = (ROOT / 'docs/installation/04-backend.md').read_text()
        self.assertIn('Do not pipe a live CLI into `head`', backend)
        omp = (ROOT / 'docs/installation/backends/omp.md').read_text()
        self.assertIn('A model catalogue is not a credential health check', omp)
        codex = (ROOT / 'docs/installation/backends/codex.md').read_text()
        self.assertIn('codex exec --help', codex)
        self.assertIn('Do not append interactive-only flags', codex)
        product = (ROOT / 'docs/installation/05-product-and-verification.md').read_text()
        self.assertLess(product.index('machtiani init --no-interactive'), product.index('\nmachtiani sync'))
        for path in ('docs/backend-management.md', 'docs/installation/05-product-and-verification.md'):
            text = (ROOT / path).read_text()
            self.assertIn('DEARMACHINE_BACKENDS=', text)
            self.assertIn('agent-manager backend health', text)


if __name__ == '__main__':
    unittest.main()
