"""Open the real creation form in the separate QA build."""
from pathlib import Path
import os
import signal
import subprocess
import time

app = Path(__file__).resolve().parent / '.build/claude-menu/Doppel.app'
executable = str(app / 'Contents/MacOS/Doppel')
assert app.is_dir()
assert subprocess.check_output(['plutil', '-extract', 'CFBundleIdentifier', 'raw',
                                str(app / 'Contents/Info.plist')], text=True).strip() == 'ai.doppel.menubar.claudeqa'
for line in subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines():
    fields = line.strip().split(maxsplit=1)
    if len(fields) == 2 and fields[1] == executable:
        os.kill(int(fields[0]), signal.SIGTERM)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(int(fields[0]), 0)
            except ProcessLookupError:
                break
            time.sleep(.1)
        else:
            raise RuntimeError('The previous QA app did not quit; the installed Doppel app was not touched')
subprocess.run(['open', '-n', '-a', str(app), '--args', '--create-instance-qa'], check=True)
print(f'Opened the real New Instance form in {app}')
