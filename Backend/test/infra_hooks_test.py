import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest


class BackendHooksTest(unittest.TestCase):
    def test_backup_precedes_owner_migration_and_acceptance(self):
        with tempfile.TemporaryDirectory() as folder:
            platform = Path(folder)
            app = platform / 'apps' / 'fixture-api'
            app.mkdir(parents=True)
            (app / 'backend.json').write_text(json.dumps({'database': 'fixture', 'ownerRole': 'fixture_owner'}))
            password = platform / 'projects' / 'fixture' / 'owner-password'
            password.parent.mkdir(parents=True)
            password.write_text('test:owner/password')
            (app / 'state').mkdir()
            (app / 'state/recovery-proof.json').write_text('{}')
            events = []

            def run(command):
                if 'scripts/recovery-proof.ts' in command:
                    events.append('verify-offhost')
                    self.assertIn('none', command)
                    self.assertNotIn('--env-file', command)
                    return
                events.append('migrate')
                self.assertIn('platform-db', command)
                self.assertEqual(command[-2:], ['bun', 'scripts/migrate.ts'])
                env = Path(command[command.index('--env-file') + 1])
                self.assertEqual(env.stat().st_mode & 0o777, 0o600)
                self.assertEqual(env.read_text(), 'DATABASE_URL=postgresql://fixture_owner:test%3Aowner%2Fpassword@postgres:5432/fixture\n')
                self.assertNotIn('test:owner/password', ' '.join(command))

            core = types.SimpleNamespace(APP=app, CONFIG=types.SimpleNamespace(service='fixture-api'), protected_file=lambda path, _: path,
                backup_database=lambda database: events.append('backup:' + database),
                run=run, compose=lambda *args, **kwargs: events.append(('accept', args)))
            previous = sys.modules.get('deploy_core')
            sys.modules['deploy_core'] = core
            try:
                backend = Path(__file__).resolve().parents[1]
                hook = next((backend / 'deploy/deploy-core-candidate/app_hooks').glob('*/hooks.py'))
                spec = importlib.util.spec_from_file_location('candidate_backend_hooks', hook)
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                module.prepare('candidate-image', 'current-image')
                module.accept('candidate-image')
                self.assertEqual(events[:3], ['backup:fixture', 'verify-offhost', 'migrate'])
                self.assertEqual(events[3][1], ('exec', '-T', 'fixture-api', 'bun', 'deploy/verify.ts'))
                (app / 'backend.json').write_text(json.dumps({'database': '../other', 'ownerRole': 'fixture_owner'}))
                with self.assertRaises(RuntimeError):
                    module.prepare('candidate-image', 'current-image')
            finally:
                if previous is None:
                    sys.modules.pop('deploy_core', None)
                else:
                    sys.modules['deploy_core'] = previous


if __name__ == '__main__':
    unittest.main()
