#!/usr/bin/env python3
"""Sign personal builds with a persistent identity; no system trust settings are changed."""
import hashlib
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
STATE = Path.home() / 'Library/Application Support/LocalFlow/Signing'
KEYCHAIN = STATE / 'LocalFlow-build.keychain-db'
CERT = STATE / 'certificate.pem'
PASSWORD = STATE / 'keychain-password'


def run(args, **kwargs):
    result = subprocess.run([str(a) for a in args], **kwargs)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed with exit code {result.returncode}; arguments are omitted to protect signing credentials')
    return result


def ensure_identity():
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(STATE, 0o700)
    if not KEYCHAIN.exists():
        password = secrets.token_urlsafe(32)
        PASSWORD.write_text(password)
        os.chmod(PASSWORD, 0o600)
        search_list = shlex.split(subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))
        try:
            run(['security', 'create-keychain', '-p', password, KEYCHAIN], stdout=subprocess.DEVNULL)
        finally:
            run(['security', 'list-keychains', '-d', 'user', '-s', *search_list])
        with tempfile.TemporaryDirectory(prefix='localflow-signing-') as temp:
            key = Path(temp) / 'key.pem'
            bundle = Path(temp) / 'identity.p12'
            config = Path(temp) / 'openssl.cnf'
            config.write_text('''[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = LocalFlow Local Development
O = LocalFlow Personal Build
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
''')
            run(['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-x509', '-sha256', '-days', '3650', '-config', config, '-keyout', key, '-out', CERT], stderr=subprocess.DEVNULL)
            run(['openssl', 'pkcs12', '-export', '-macalg', 'sha1', '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-inkey', key, '-in', CERT, '-out', bundle, '-passout', 'file:' + str(PASSWORD)])
            run(['security', 'unlock-keychain', '-p', password, KEYCHAIN])
            run(['security', 'import', bundle, '-k', KEYCHAIN, '-P', password, '-T', '/usr/bin/codesign'], stdout=subprocess.DEVNULL)
            run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, KEYCHAIN], stdout=subprocess.DEVNULL)
    if not CERT.exists() or not PASSWORD.exists():
        raise RuntimeError('Incomplete signing identity. Restore the LocalFlow Signing directory; do not silently rotate its key.')
    run(['security', 'unlock-keychain', '-p', PASSWORD.read_text().strip(), KEYCHAIN])
    der = subprocess.check_output(['openssl', 'x509', '-in', str(CERT), '-outform', 'DER'])
    return hashlib.sha1(der).hexdigest().upper()


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: Scripts/sign-local.py /path/to/LocalFlow.app')
    app = Path(sys.argv[-1]).resolve()
    identity = ensure_identity()
    ready = STATE / 'ready'
    if ready.exists() and ready.read_text().strip() != identity:
        raise RuntimeError('Signing identity changed. Restore the original signing state before building an update.')
    # codesign resolves the certificate chain through the search list, even with
    # --keychain. A self-signed identity does not need a system trust exception.
    search_list = shlex.split(subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))
    added = str(KEYCHAIN) not in search_list
    try:
        if added:
            run(['security', 'list-keychains', '-d', 'user', '-s', *search_list, KEYCHAIN])
        run(['codesign', '--force', '--sign', identity, '--keychain', KEYCHAIN, '--timestamp=none', '--options', 'runtime', '--entitlements', ROOT / 'Resources/LocalFlow.entitlements', app])
    finally:
        if added:
            current = shlex.split(subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))
            run(['security', 'list-keychains', '-d', 'user', '-s', *[item for item in current if item != str(KEYCHAIN)]])
    run(['codesign', '--verify', '--deep', '--strict', app])
    run(['codesign', '-d', '-r-', app])
    (STATE / 'ready').write_text(identity)
    print('Signed with the persistent LocalFlow identity. The signing key stays on this Mac.')
