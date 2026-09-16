#!/usr/bin/env python3
"""Persist non-secret container settings for SSH/PAM and sudo-based helpers."""
import os
from pathlib import Path
import shlex


NAMES = ('ANSIBLE_CONFIG', 'CONTROLLER_CONFIG_DIR', 'CONTROLLER_LOG_DIR',
         'CONTROLLER_USER', 'CONTROLLER_HOME')


def configure(environ, root=Path('/')):
    values = {name: environ[name] for name in NAMES if environ.get(name)}
    for name, value in values.items():
        # PAM environment files are not shell scripts. Keep their quoted values
        # literal, and reject ambiguous paths before writing either representation.
        if any(c in value for c in '\r\n\x00"\\$`'):
            raise ValueError(f'{name} contains unsupported environment-file characters')
        if name != 'CONTROLLER_USER' and not value.startswith('/'):
            raise ValueError(f'{name} must be an absolute path')
    environment = root / 'etc/environment'
    existing = environment.read_text().splitlines() if environment.exists() else []
    kept = [line for line in existing if line.split('=', 1)[0] not in NAMES]
    environment.write_text('\n'.join(kept + [f'{k}="{v}"' for k, v in values.items()]) + '\n')
    profile = root / 'etc/profile.d/ansible-controller.sh'
    profile.parent.mkdir(parents=True, exist_ok=True)
    profile.write_text('# Generated non-secret controller settings.\n' + ''.join(
        f'if [ "${{{k}+x}}" != x ]; then export {k}={shlex.quote(v)}; fi\n'
        for k, v in values.items()
    ))
    profile.chmod(0o644)


if __name__ == '__main__':
    configure(os.environ)
