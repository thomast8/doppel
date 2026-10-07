#!/usr/bin/env python3
"""Exercise Creator Micro assignment through the real CLI in isolated state."""
import os
from pathlib import Path
import subprocess
import tempfile


cli = Path(__file__).resolve().parents[1] / "bin/doppel"
with tempfile.TemporaryDirectory(prefix="doppel-micro-") as scratch:
    root = Path(scratch)
    environment = {**os.environ, "DOPPEL_HOME": scratch, "DOPPEL_DEV": "1"}
    for slug, name in [("personal", "ChatGPT Personal"), ("veridue", "ChatGPT Veridue")]:
        instance = root / "instances" / slug
        instance.mkdir(parents=True)
        (instance / "instance-config.zsh").write_text(f'DOPPEL_DISPLAY_NAME="{name}"\n')

    def run(*arguments, success=True):
        result = subprocess.run(["/bin/zsh", str(cli), "micro", *arguments],
                                env=environment, capture_output=True, text=True)
        assert (result.returncode == 0) == success, result.stderr
        return result.stdout

    assert run("status", "--porcelain") == "owner\t\n"
    run("assign", "ChatGPT Veridue")
    assert run("status", "--porcelain") == "owner\tveridue\n"
    assert "Creator Micro: ChatGPT Veridue\n" in run("status")
    run("assign", "ChatGPT Personal")
    assert run("status", "--porcelain") == "owner\tpersonal\n"
    run("assign", "Missing Instance", success=False)
    assert run("status", "--porcelain") == "owner\tpersonal\n"
    run("release")
    assert run("status", "--porcelain") == "owner\t\n"
    for invalid in ["missing-instance", "../personal"]:
        (root / "state" / "codex-micro-owner").write_text(invalid + "\n")
        assert run("status", "--porcelain") == "owner\t\n"
    run("status", "--bad-option", success=False)

print("Creator Micro CLI QA passed")
