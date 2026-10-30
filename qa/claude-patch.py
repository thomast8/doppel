"""Check Claude control-point substitutions, including module-qualified calls."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('patcher', repo / 'engine/patch-deep-link.py')
patcher = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = patcher
spec.loader.exec_module(patcher)

for expression in [b'K().autoUpdate.disabled', b't.Jat().autoUpdate.disabled', b'ns.t.Jat().autoUpdate.disabled']:
    original = b'const disabled=' + expression + b';'
    changed, count = patcher.CLAUDE_UPDATE.subn(patcher.CLAUDE_UPDATE_MARKER, original)
    assert count == 1
    assert changed == b'const disabled=' + patcher.CLAUDE_UPDATE_MARKER + b';'
    subprocess.run(['node', '--check'], input=changed, check=True)
assert not patcher.CLAUDE_UPDATE.search(b't?.Jat().autoUpdate.disabled')
assert not patcher.CLAUDE_UPDATE.search(b'getConfig().nested.Jat().autoUpdate.disabled')

source = Path('/Applications/Claude.app/Contents/Resources/app.asar')
archive = patcher.read_archive(source)
count = auth_count = 0
with tempfile.TemporaryDirectory(prefix='doppel-claude-syntax-') as scratch:
    for member in patcher.members(archive):
        if not member.path.startswith('.vite/build/index') or not member.path.endswith('.js'):
            continue
        data = patcher.read_member(archive, member)
        data, sites = patcher.CLAUDE_UPDATE.subn(patcher.CLAUDE_UPDATE_MARKER, data)
        count += sites
        data, auth_sites = patcher.CLAUDE_AUTH.subn(rb'\1' + patcher.CLAUDE_AUTH_MARKER + rb'\2', data)
        auth_count += auth_sites
        bootstrap = member.path == '.vite/build/index.pre.js'
        if bootstrap:
            data = patcher.CLAUDE_BOOTSTRAP + data
        if sites or auth_sites or bootstrap:
            target = Path(scratch) / Path(member.path).name
            target.write_bytes(data)
            # Syntax-check without executing vendor code or displaying source dumps.
            result = subprocess.run(['node', '--check', str(target)], capture_output=True)
            assert result.returncode == 0, f'Invalid patched JavaScript in {member.path}'
assert (count, auth_count) == (15, 1)
print('Claude patch QA passed: qualified calls, unsupported shapes and syntax of every changed vendor module')
