"""Shared API hooks, installed only in a reviewed immutable deploy-core release."""
import json
import re
import tempfile
from pathlib import Path
from urllib.parse import quote
import deploy_core as core


def configuration():
    path = core.protected_file(core.APP / 'backend.json', 'Backend inventory')
    value = json.loads(path.read_text())
    for key in ('database', 'ownerRole'):
        if not re.fullmatch(r'[a-z][a-z0-9_]{0,62}', value.get(key, '')):
            raise RuntimeError('Invalid backend inventory')
    return value


def accept(image):
    core.compose('exec', '-T', 'api', 'bun', 'deploy/verify.ts', image=image)


def prepare(candidate, current):
    config = configuration()
    core.backup_database(config['database'])
    proof = core.protected_file(core.APP / 'state/recovery-proof.json', 'Off-host recovery proof')
    password = core.protected_file(
        core.APP.parents[1] / 'projects' / config['database'] / 'owner-password',
        'Migration credential',
    )
    with tempfile.TemporaryDirectory(prefix='backend-owner-migration-') as folder:
        verified = Path(folder) / 'proof.json'
        verified.write_text(proof.read_text())
        verified.chmod(0o444)
        core.run(['docker', 'run', '--rm', '--read-only', '--cap-drop', 'ALL',
                  '--security-opt', 'no-new-privileges:true', '--network', 'none',
                  '--memory', '128m', '--cpus', '0.5', '--mount',
                  'type=bind,src=' + str(verified) + ',dst=/run/recovery-proof.json,readonly',
                  candidate, 'bun', 'scripts/recovery-proof.ts', '/run/recovery-proof.json'])
        path = Path(folder) / 'migration.env'
        path.write_text('DATABASE_URL=postgresql://' + config['ownerRole'] + ':' +
                        quote(password.read_text().strip(), safe='') +
                        '@postgres:5432/' + config['database'] + '\n')
        path.chmod(0o600)
        core.run(['docker', 'run', '--rm', '--read-only', '--cap-drop', 'ALL',
                  '--security-opt', 'no-new-privileges:true', '--network', 'platform-db',
                  '--memory', '256m', '--cpus', '0.5', '--env-file', str(path),
                  candidate, 'bun', 'scripts/migrate.ts'])
