"""Exercise history publication across an actual mounted filesystem boundary."""
import errno
import os
from pathlib import Path
import runpy
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
tests = runpy.run_path(str(repo / 'qa/claude-sessions.py'))
module, fixture = tests['module'], tests['fixture']
build_root = repo / 'qa/.build'
build_root.mkdir(parents=True, exist_ok=True)
work = Path(tempfile.mkdtemp(prefix='claude-history-volume-', dir=build_root))
mount = work / 'mounted'
mount.mkdir()
image = work / 'test.dmg'
subprocess.run(['hdiutil', 'create', '-size', '32m', '-fs', 'HFS+', '-volname',
                'Doppel History QA', str(image)], check=True, stdout=subprocess.DEVNULL)
subprocess.run(['hdiutil', 'attach', '-nobrowse', '-mountpoint', str(mount), str(image)],
               check=True, stdout=subprocess.DEVNULL)
try:
    assert work.stat().st_dev != mount.stat().st_dev
    control = work / 'cross-volume-control'
    control.write_text('control')
    try:
        os.link(control, mount / 'control')
    except OSError as error:
        assert error.errno == errno.EXDEV
    else:
        raise AssertionError('The control did not reproduce the cross-volume hard-link failure')
    for external_profile in [False, True]:
        case = 'profile-external' if external_profile else 'code-external'
        roots, source, destination = fixture(work / case)
        target_index = 2 if external_profile else 3
        external = mount / case
        subprocess.run(['ditto', str(roots[target_index]), str(external)], check=True)
        roots[target_index] = external
        plan = module.plan_import(*roots, active=set())
        module.apply_plan(plan, work / (case + '-audit'))
        registry = roots[2] / 'claude-code-sessions' / tests['account'] / tests['org']
        assert (registry / ('local_' + tests['session'] + '.json')).exists()
        assert (roots[3] / 'projects/project' / (tests['session'] + '.jsonl')).exists()
        assert module.plan_import(*roots, active=set())['sessions'] == 0
    print('Cross-volume history QA passed: EXDEV control, external profile, external Code directory and repeat import')
finally:
    subprocess.run(['hdiutil', 'detach', str(mount)], check=True, stdout=subprocess.DEVNULL)
print(f'QA disk image retained at {image}')
