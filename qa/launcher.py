#!/usr/bin/env python3
"""Verify in-place launcher authorization and lock lifetime with real processes."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parents[1]
cli = repo / 'bin/doppel'
source = (repo / 'engine/doppel-engine.zsh').read_text()
functions = '\n'.join(re.search(rf'^{name}\(\) \{{.*?^\}}', source, re.M | re.S)[0]
                      for name in ('route_managed_engine', 'consume_clone_launch_authorization', 'exec_clone_binary'))

def wait_for(predicate, label):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        if predicate(): return
        time.sleep(.05)
    raise AssertionError(label)

with tempfile.TemporaryDirectory(prefix='doppel-launcher-qa.') as temporary:
    root = Path(temporary)
    home = root / 'home'
    instance = home / 'instances/fixture'
    instance.mkdir(parents=True)
    app = root / 'apps/Doppel Handoff QA.app'
    (app / 'Contents/MacOS').mkdir(parents=True)
    resources = app / 'Contents/Resources/Doppel'
    resources.mkdir(parents=True)
    values = {
        'DOPPEL_DISPLAY_NAME': 'Doppel Handoff QA', 'DOPPEL_BUNDLE_ID': 'ai.doppel.qa.handoff',
        'DOPPEL_URL_SCHEME': 'doppel-handoff-qa', 'DOPPEL_PROFILE_ROOT': str(root / 'profile'),
        'DOPPEL_CODEX_HOME': str(root / 'codex'), 'DOPPEL_TINT': 'original',
    }
    (instance / 'instance-config.zsh').write_text(''.join(f'{k}={shlex.quote(v)}\n' for k, v in values.items()))
    (instance / 'install-root').write_text(str(root / 'apps') + '\n')
    c = root / 'runtime.c'
    c.write_text('''#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(void) { FILE *f=fopen(getenv("DOPPEL_QA_RUNTIME_FILE"), "w"); if (!f) return 1;
 fprintf(f,"%d\\n",getpid()); fclose(f); alarm(30); for (;;) pause(); }
''')
    subprocess.run(['cc', '-o', str(app / 'Contents/MacOS/ChatGPT.real'), str(c)], check=True)
    engine = resources / 'doppel-engine.zsh'
    engine.write_text('''#!/bin/zsh
set -eu
managed_slug_for_this_profile() { print -r -- fixture; }
log_message() { :; }
fail_closed() { print -u2 -r -- "$*"; exit 1; }
codex_micro_owner_is_this_profile() { return 1; }
codex_micro_channel() { :; }
source_version() { print -r -- 1; }
''' + functions + '''
shift 2
route_managed_engine "$@"
print -r -- ready > "$DOPPEL_QA_READY"
while [[ ! -e "$DOPPEL_QA_GATE" ]]; do /bin/sleep .05; done
exec_clone_binary "$DOPPEL_QA_APP" "$@"
''')
    env = {**os.environ, **values, 'DOPPEL_HOME': str(home), 'DOPPEL_DEV': '1',
           'ROUTER_CLI': str(cli), 'PRIMARY_APP': '/Applications/ChatGPT.app',
           'PRIMARY_BUNDLE_ID': 'com.openai.codex', 'URL_HANDLER_HELPER': '/usr/bin/true',
           'DOPPEL_QA_APP': str(app), 'DOPPEL_QA_RUNTIME_FILE': str(root / 'runtime-pid'),
           'DOPPEL_QA_READY': str(root / 'ready'), 'DOPPEL_QA_GATE': str(root / 'gate')}
    lock = home / 'state/IABCoordinator.lock'
    authorization = home / 'state/clone-launch/fixture'
    rejected = subprocess.run([str(cli), '__route-launch-in-place', 'fixture', '1'], env=env,
                              capture_output=True, text=True)
    assert rejected.returncode != 0 and not lock.exists() and not authorization.exists()

    # A router that fails before the launcher reads its coprocess must still
    # fail closed without disturbing the operation already holding the lock.
    lock.mkdir(parents=True)
    (lock / 'pid').write_text(str(os.getpid()) + '\n')
    try:
        blocked = subprocess.run(['/bin/zsh', str(engine), 'launch', str(app), '--mute-audio'],
                                 env=env, capture_output=True, text=True, timeout=5)
        assert blocked.returncode != 0, 'a locked router unexpectedly authorized a runtime'
        assert 'another Doppel engine operation' in blocked.stderr, blocked.stderr
        assert (lock / 'pid').read_text().strip() == str(os.getpid()), 'another operation lost its lock'
        assert not authorization.exists() and not (root / 'ready').exists() and not (root / 'runtime-pid').exists()
    finally:
        (lock / 'pid').unlink()
        lock.rmdir()

    # Receipts remain available on rejection and are consumed only once after
    # the token, bundle, and live coordinator have all been verified.
    token = 'a' * 64
    receipt = f'{token}\t{values["DOPPEL_BUNDLE_ID"]}\n'
    authorization.parent.mkdir(parents=True, exist_ok=True)
    lock.mkdir()
    (lock / 'pid').write_text(str(os.getpid()) + '\n')
    consume = functions + '\nconsume_clone_launch_authorization "$1"\n'
    ended = subprocess.Popen(['/usr/bin/true'])
    ended.wait(timeout=5)
    try:
        for marker, contents, owner in (
            (f'fixture:{"b" * 64}', receipt, str(os.getpid())),
            (f'fixture:{token}', f'{token}\tai.doppel.qa.other\n', str(os.getpid())),
            (f'fixture:{token}', receipt.rstrip('\n') + '\textra\n', str(os.getpid())),
            (f'../fixture:{token}', receipt, str(os.getpid())),
            (f'fixture:{token}', receipt, '0'),
            (f'fixture:{token}', receipt, ''),
            (f'fixture:{token}', receipt, str(ended.pid)),
        ):
            authorization.write_text(contents)
            (lock / 'pid').write_text(owner + '\n')
            result = subprocess.run(['/bin/zsh', '-c', consume, 'doppel-auth-qa', marker],
                                    env=env, capture_output=True, text=True, timeout=5)
            assert result.returncode != 0, f'invalid authorization was accepted: {marker}, owner={owner!r}'
            assert authorization.read_text() == contents, 'rejected authorization was consumed'
        authorization.write_text(receipt)
        (lock / 'pid').write_text(str(os.getpid()) + '\n')
        for expected in (0, 1):
            result = subprocess.run(['/bin/zsh', '-c', consume, 'doppel-auth-qa', f'fixture:{token}'],
                                    env=env, capture_output=True, text=True, timeout=5)
            assert result.returncode == expected, result.stderr or 'authorization was reusable'
            assert not authorization.exists(), 'valid authorization was not consumed'
    finally:
        authorization.unlink(missing_ok=True)
        (lock / 'pid').unlink()
        lock.rmdir()

    # Fast-forward the real waiter beyond its former 300-poll timeout, then
    # hold it live before adoption: elapsed time cannot release this lock.
    waiter = re.search(r'^wait_for_in_place_clone_adoption\(\) \{.*?^\}', cli.read_text(), re.M | re.S)[0]
    waiter = waiter.replace('/bin/sleep 0.1', 'qa_poll').replace('/usr/sbin/lsof', 'qa_lsof')
    delayed = subprocess.Popen(['/bin/zsh', '-c', '''
set -eu
app="$1"; lock="$2"; checkpoint="$3"; gate="$4"
polls=0
process_start_fingerprint() { print -r -- frozen; }
qa_lsof() {
    if (( polls < 350 )); then print -r -- n/bin/zsh
    else print -r -- "n$app/Contents/MacOS/ChatGPT.real"; fi
}
qa_poll() {
    polls=$(( polls + 1 ))
    if (( polls == 350 )); then
        print -r -- ready > "$checkpoint"
        while [[ ! -e "$gate" ]]; do /bin/sleep .01; done
    fi
}
''' + waiter + '''
mkdir "$lock"
print -r -- "$$" > "$lock/pid"
trap 'rm -f "$lock/pid"; rmdir "$lock"' EXIT
wait_for_in_place_clone_adoption "$app" "$$" frozen "$gate.absent"
''', 'doppel-delayed-qa', str(app), str(lock), str(root / 'delayed-ready'), str(root / 'delayed-gate')],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        wait_for(lambda: (root / 'delayed-ready').exists() or delayed.poll() is not None,
                 'delayed launcher did not reach the old timeout boundary')
        assert delayed.poll() is None, 'live launcher lost its coordinator after 300 polls: ' + delayed.communicate()[1]
        assert (lock / 'pid').read_text().strip() == str(delayed.pid), 'delayed launcher lost its lock'
        blocked = subprocess.run([str(cli), 'browser', 'release'], env=env, capture_output=True, text=True)
        assert blocked.returncode != 0 and 'another Doppel engine operation' in blocked.stderr
        (root / 'delayed-gate').touch()
        assert delayed.wait(timeout=5) == 0, delayed.communicate()[1]
        assert not lock.exists(), 'adopted delayed launcher retained its lock'
    finally:
        if delayed.poll() is None: delayed.terminate()
        delayed.communicate(timeout=5)

    for cancel in (False, True):
        for name in ('ready', 'gate', 'runtime-pid'):
            (root / name).unlink(missing_ok=True)
        client = subprocess.Popen(['/bin/zsh', str(engine), 'launch', str(app), '--mute-audio'],
                                  env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for(lambda: (root / 'ready').exists() or client.poll() is not None, 'launcher authorization timed out')
            assert client.poll() is None, client.communicate()[1]
            assert lock.exists() and not authorization.exists(), 'lock was released before profile adoption'
            blocked = subprocess.run([str(cli), 'browser', 'release'], env=env, capture_output=True, text=True)
            assert blocked.returncode != 0 and 'another Doppel engine operation' in blocked.stderr
            if cancel:
                client.terminate()
                client.wait(timeout=5)
            else:
                (root / 'gate').touch()
                wait_for(lambda: (root / 'runtime-pid').exists(), 'runtime did not start')
                assert int((root / 'runtime-pid').read_text()) == client.pid, 'routing replaced the original process'
            wait_for(lambda: not lock.exists(), 'coordinator did not release its lock')
            assert not authorization.exists(), 'authorization survived the handoff'
        finally:
            if client.poll() is None: client.terminate()
            client.communicate(timeout=5)
    print('launcher QA passed: original PID, held lock beyond timeout, competing routing refusal, receipt validation, cancellation and one-shot cleanup')
