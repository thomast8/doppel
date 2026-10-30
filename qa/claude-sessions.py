"""Test account-scoped history copying against real files, without vendor accounts."""
import importlib.util
import json
import os
import subprocess
import shutil
from pathlib import Path
import tempfile

spec = importlib.util.spec_from_file_location('history_import', Path(__file__).resolve().parents[1] / 'engine/claude-sessions.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
account = '11111111-1111-4111-8111-111111111111'
other = '22222222-2222-4222-8222-222222222222'
org = '33333333-3333-4333-8333-333333333333'
session = '44444444-4444-4444-8444-444444444444'
existing = '55555555-5555-4555-8555-555555555555'


def fixture(root, transcript=True):
    roots = [root / name for name in ['original', 'original-code', 'instance', 'instance-code']]
    source, code, target, target_code = roots
    for profile in [source, target]:
        (profile / 'claude-code-sessions' / account / org).mkdir(parents=True)
    scope = source / 'claude-code-sessions' / account / org
    destination = target / 'claude-code-sessions' / account / org
    record = dict(sessionId='local_' + session, cliSessionId=session, cwd=str(root), title='Old work')
    (scope / ('local_' + session + '.json')).write_text(json.dumps(record))
    keep = dict(sessionId='local_' + existing, cliSessionId=existing, title='New work in this instance')
    (destination / ('local_' + existing + '.json')).write_text(json.dumps(keep))
    (scope / ('local_' + existing + '.json')).write_text(json.dumps({**keep, 'title': 'Older source title'}))
    foreign = source / 'claude-code-sessions' / other / org
    foreign.mkdir(parents=True)
    (foreign / ('local_' + session + '.json')).write_text(json.dumps(record))
    (code / 'projects/project').mkdir(parents=True)
    if transcript:
        (code / 'projects/project' / (session + '.jsonl')).write_text('{"message":"Old transcript"}\n')
    sidecar = code / 'projects/project' / session / 'subagents'
    sidecar.mkdir(parents=True)
    (sidecar / 'agent.jsonl').write_text('{"message":"Subagent history"}\n')
    target_code.mkdir()
    (code / '.credentials.json').write_text('source credential sentinel')
    (target_code / '.credentials.json').write_text('destination credential sentinel')
    return roots, scope, destination


def refuses(call):
    try:
        call()
    except (module.ImportFailure, OSError):
        return
    raise AssertionError('Unsafe import was accepted')


with tempfile.TemporaryDirectory(prefix='doppel-history-qa-') as temporary:
    root = Path(temporary)
    roots, source, destination = fixture(root / 'happy')
    original = (source / ('local_' + session + '.json')).read_bytes()
    plan = module.plan_import(*roots, active=set())
    assert (plan['sessions'], plan['existing'], plan['kept_sessions']) == (1, 1, 1)
    assert not (destination / ('local_' + session + '.json')).exists(), 'Planning wrote session data'
    module.apply_plan(plan, root / 'audit')
    assert (source / ('local_' + session + '.json')).read_bytes() == original
    assert (destination / ('local_' + session + '.json')).read_bytes() == original
    assert json.loads((destination / ('local_' + existing + '.json')).read_text())['title'] == 'New work in this instance'
    assert not (roots[2] / 'claude-code-sessions' / other).exists(), 'Another account was copied'
    assert (roots[3] / '.credentials.json').read_text() == 'destination credential sentinel'
    assert (roots[3] / 'projects/project' / session / 'subagents/agent.jsonl').exists()
    assert module.plan_import(*roots, active=set())['sessions'] == 0, 'Re-import is not idempotent'

    roots, source, destination = fixture(root / 'active')
    refuses(lambda: module.plan_import(roots[0], roots[1], roots[2], Path('.'), active=set()))
    refuses(lambda: module.plan_import(*roots, active={session}))
    assert not (destination / ('local_' + session + '.json')).exists()

    roots, source, destination = fixture(root / 'missing', transcript=False)
    plan = module.plan_import(*roots, active=set())
    assert plan['sessions'] == 0 and plan['missing_transcripts'] == 1

    roots, source, destination = fixture(root / 'symlink')
    (roots[1] / 'projects/project' / session / 'outside').symlink_to(root / 'happy', target_is_directory=True)
    refuses(lambda: module.plan_import(*roots, active=set()))

    roots, source, destination = fixture(root / 'changed')
    plan = module.plan_import(*roots, active=set())
    (roots[1] / 'projects/project' / (session + '.jsonl')).write_text('changed source transcript')
    refuses(lambda: module.apply_plan(plan, root / 'changed-audit'))
    assert not (destination / ('local_' + session + '.json')).exists()

    roots, source, destination = fixture(root / 'collision')
    plan = module.plan_import(*roots, active=set())
    conflict = roots[3] / 'projects/project' / (session + '.jsonl')
    conflict.parent.mkdir(parents=True)
    conflict.write_text('new destination work')
    refuses(lambda: module.apply_plan(plan, root / 'collision-audit'))
    assert conflict.read_text() == 'new destination work'
    assert not (destination / ('local_' + session + '.json')).exists()

    # Automatic import runs at launch, so every refusal must leave no files and
    # no marker, letting a later launch try again once the instance is ready.
    roots, source, destination = fixture(root / 'auto-signed-out')
    for scope in (roots[2] / 'claude-code-sessions').iterdir():
        shutil.rmtree(scope)
    state = root / 'auto-signed-out-state'
    assert module.auto_import(*roots, state, active=set()).startswith('waiting')
    assert not (state / 'auto-import.json').exists()

    roots, source, destination = fixture(root / 'auto-mismatch')
    shutil.rmtree(roots[2] / 'claude-code-sessions' / account)
    (roots[2] / 'claude-code-sessions' / '66666666-6666-4666-8666-666666666666' / org).mkdir(parents=True)
    state = root / 'auto-mismatch-state'
    assert module.auto_import(*roots, state, active=set()).startswith('waiting')
    assert not (state / 'auto-import.json').exists()
    assert not list((roots[2] / 'claude-code-sessions').rglob('local_' + session + '.json')), 'Another account received history'

    roots, source, destination = fixture(root / 'auto-active')
    state = root / 'auto-active-state'
    assert module.auto_import(*roots, state, active={session}).startswith('waiting')
    assert not (state / 'auto-import.json').exists()
    assert not (destination / ('local_' + session + '.json')).exists()
    assert module.auto_import(*roots, state, active=set()).startswith('imported 1')
    assert (destination / ('local_' + session + '.json')).exists()
    assert json.loads((state / 'auto-import.json').read_text())['scope'] == f'{account}/{org}'

    later = '77777777-7777-4777-8777-777777777777'
    (source / ('local_' + later + '.json')).write_text(json.dumps(dict(sessionId='local_' + later, cliSessionId=later)))
    (roots[1] / 'projects/project' / (later + '.jsonl')).write_text('{"message":"Later work"}\n')
    assert module.auto_import(*roots, state, active=set()) == 'already imported'
    assert not (destination / ('local_' + later + '.json')).exists(), 'Automatic import ran twice'

    roots, source, destination = fixture(root / 'auto-nothing')
    (destination / ('local_' + session + '.json')).write_bytes((source / ('local_' + session + '.json')).read_bytes())
    state = root / 'auto-nothing-state'
    assert module.auto_import(*roots, state, active=set()).startswith('imported 0')
    assert (state / 'auto-import.json').exists()

    # Slugs are reused when an instance is recreated under the same name, so
    # removing one must take its import marker along with its definition.
    home = root / 'remove-home'
    instance = home / 'instances/qa-claude'
    instance.mkdir(parents=True)
    (instance / 'instance-config.zsh').write_text(
        f"DOPPEL_APP_KIND=claude\nDOPPEL_DISPLAY_NAME='QA Claude'\nDOPPEL_BUNDLE_ID=ai.doppel.qa.removed\n"
        f"DOPPEL_PROFILE_ROOT='{root / 'remove-profile'}'\nDOPPEL_CLAUDE_CONFIG_DIR='{root / 'remove-code'}'\n")
    (instance / 'install-root').write_text(str(root / 'remove-apps') + '\n')
    imports = home / 'state/imports/qa-claude'
    imports.mkdir(parents=True)
    (imports / 'auto-import.json').write_text('{}')
    env = dict(os.environ, DOPPEL_DEV='1', DOPPEL_IAB_DRY_RUN='1', DOPPEL_HOME=str(home))
    removed = subprocess.run([str(Path(__file__).resolve().parents[1] / 'bin/doppel'), '--app', 'claude', 'remove', 'QA Claude'],
                             env=env, capture_output=True, text=True)
    assert removed.returncode == 0, removed.stderr
    assert not imports.exists(), 'A removed instance left its import marker for the next instance with that name'
    assert list((home / 'state/Removed').glob('qa-claude.*/imports/auto-import.json')), 'The import record was not kept with the removed definition'

print('Claude history QA passed: account isolation, existing work, credentials, sidecars, idempotence, active sessions, missing history, symlinks, source changes, collisions, automatic import and removal')
