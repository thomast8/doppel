#!/usr/bin/env python3
"""Exercise the engine's Contents exchange without launching or building apps."""
from pathlib import Path
import re
import subprocess
import tempfile


engine = Path(__file__).resolve().parents[1] / 'engine/doppel-engine.zsh'
helper = re.search(r'^exchange_app_contents\(\) \{.*?^\}', engine.read_text(), re.M | re.S)[0]


def exchange(left, right, *, error='', fail_move=''):
    source = helper
    if error:
        source = source.replace('libc = ctypes.CDLL(None, use_errno=True)', '''
libc = ctypes.CDLL(None, use_errno=True)
def forced_swap_error(*arguments):
    ctypes.set_errno(errno.%s)
    return -1
libc.renamex_np = forced_swap_error
''' % error)
    else:
        source = source.replace('error = ctypes.get_errno()',
                                "raise AssertionError('real atomic exchange failed')")
    if fail_move:
        source = source.replace('left, right = sys.argv[1:]', '''
left, right = sys.argv[1:]
rename = os.rename
def forced_move_error(source, destination):
    if source == %s and destination == %s:
        raise OSError(errno.EIO, 'forced Contents promotion failure')
    rename(source, destination)
os.rename = forced_move_error
''' % (('right', 'left') if fail_move == 'new' else ("right + '.doppel-swap'", 'right')))
    return subprocess.run(['/bin/zsh', '-c', source + '\nexchange_app_contents "$1" "$2"',
                           'contents-qa', str(left), str(right)],
                          capture_output=True, text=True, timeout=10)


for error, fail_move in [('', ''), ('ENOTSUP', ''), ('EINVAL', ''),
                         ('ENOTSUP', 'new'), ('ENOTSUP', 'old'), ('EACCES', '')]:
    with tempfile.TemporaryDirectory(prefix='doppel-contents-') as scratch:
        left, right = (Path(scratch) / name for name in ('Installed.app', 'Staged.app'))
        for app, payload in [(left, b'original\x00bundle'), (right, b'replacement\x00bundle')]:
            (app / 'Contents/nested').mkdir(parents=True)
            (app / 'Contents/nested/payload').write_bytes(payload)
            (app / 'root-sentinel').write_text(app.name)
        roots = [app.stat().st_ino for app in (left, right)]
        contents = [(app / 'Contents').stat().st_ino for app in (left, right)]

        def check(swapped):
            assert [app.stat().st_ino for app in (left, right)] == roots, 'app root identity changed'
            expected = contents[::-1] if swapped else contents
            assert [(app / 'Contents').stat().st_ino for app in (left, right)] == expected
            payloads = [b'replacement\x00bundle', b'original\x00bundle'] if swapped else \
                       [b'original\x00bundle', b'replacement\x00bundle']
            for app, payload in zip((left, right), payloads):
                assert (app / 'Contents/nested/payload').read_bytes() == payload, 'bundle data changed'
                assert (app / 'root-sentinel').read_text() == app.name, 'root data changed'
            assert not (right / 'Contents.doppel-swap').exists(), 'temporary old Contents remained'

        result = exchange(left, right, error=error, fail_move=fail_move)
        succeeds = not fail_move and error != 'EACCES'
        assert (result.returncode == 0) == succeeds, result.stderr
        check(succeeds)
        if succeeds:
            result = exchange(left, right, error=error)
            assert result.returncode == 0, result.stderr
            check(False)

print('Contents exchange QA passed: atomic swap, unsupported fallback, promotion failures, errors and inverse rollback')
