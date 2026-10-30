#!/usr/bin/env python3
"""Exercise Creator Micro assignment through the real CLI in isolated state."""
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile


cli = Path(__file__).resolve().parents[1] / "bin/doppel"
with tempfile.TemporaryDirectory(prefix="doppel-micro-") as scratch:
    root = Path(scratch)
    environment = {**os.environ, "DOPPEL_HOME": scratch, "DOPPEL_DEV": "1",
                   "CLAUDE_CONFIG_DIR": f"{scratch}/claude", "XDG_CONFIG_HOME": f"{scratch}/xdg"}
    for slug, name in [("personal", "ChatGPT Personal"), ("veridue", "ChatGPT Veridue")]:
        instance = root / "instances" / slug
        instance.mkdir(parents=True)
        (instance / "instance-config.zsh").write_text(
            f'DOPPEL_DISPLAY_NAME="{name}"\n'
            f'DOPPEL_BUNDLE_ID="ai.doppel.fixture.{slug}"\n')
        (instance / "install-root").write_text(str(root / "apps") + "\n")

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
    owner_file = root / "state" / "codex-micro-owner"
    previous_stamp = owner_file.stat().st_mtime_ns
    assert "already assigned" in run("assign", "ChatGPT Personal")
    assert owner_file.stat().st_mtime_ns == previous_stamp
    run("assign", "Missing Instance", success=False)
    assert run("status", "--porcelain") == "owner\tpersonal\n"
    run("release")
    assert run("status", "--porcelain") == "owner\t\n"
    for invalid in ["missing-instance", "../personal"]:
        (root / "state" / "codex-micro-owner").write_text(invalid + "\n")
        assert run("status", "--porcelain") == "owner\t\n"
        run("release")
        assert not (root / "state" / "codex-micro-owner").exists()
    run("status", "--bad-option", success=False)
    channels = root / "state" / "codex-micro-channels"
    assert run("channel") == "Creator Micro channels: none set\n"
    # The menu bar app reads channels by slug, not by display name.
    assert run("channel", "--porcelain") == "claude\toff\n"
    run("channel", "ChatGPT Veridue", "1")
    run("channel", "ChatGPT Personal", "3")
    assert run("channel") == "ChatGPT Personal: 3\nChatGPT Veridue: 1\n"
    assert run("channel", "--porcelain") == "instance\tpersonal\t3\ninstance\tveridue\t1\nclaude\toff\n"
    assert (channels / "veridue").read_text() == "1\n"
    run("channel", "ChatGPT Personal", "1", success=False)
    for invalid in ["0", "4", "9", "10", "x", "../1"]:
        run("channel", "ChatGPT Veridue", invalid, success=False)
    run("channel", "Missing Instance", "2", success=False)
    (channels / "removed-instance").write_text("2\n")
    run("channel", "ChatGPT Personal", "2")
    run("channel", "ChatGPT Personal", "3")
    run("channel", "ChatGPT Veridue", "1")
    assert run("channel") == "ChatGPT Personal: 3\nChatGPT Veridue: 1\n"
    run("channel", "ChatGPT Personal", "any")
    assert not (channels / "personal").exists()
    run("channel", "ChatGPT Veridue", "any")
    assert run("channel") == "Creator Micro channels: none set\n"

    # Claude Code setup, against a stand-in claude CLI that records each call
    # and edits the throwaway settings the way the real one would.
    claude_home, xdg = root / "claude", root / "xdg"
    claude_home.mkdir()
    settings = claude_home / "settings.json"
    settings.write_text(json.dumps({"env": {"KEEP": "1"}, "theme": "dark"}))
    (xdg / "codex-micro").mkdir(parents=True)
    pad_config = xdg / "codex-micro" / "config.toml"
    pad_config.write_text('[keys]\nfast = "approve"\n')
    calls = root / "claude-calls"
    stub = root / "claude-stub"
    stub.write_text(f'''#!/usr/bin/python3
import json, sys
args = " ".join(sys.argv[1:])
open({str(calls)!r}, "a").write(args + "\\n")
path = {str(settings)!r}
data = json.load(open(path))
if args == "--version":
    print("2.1.252 (Claude Code)")
elif args.startswith("plugin marketplace add "):
    data.setdefault("extraKnownMarketplaces", {{}})["codex-micro"] = {{
        "source": {{"source": "github", "repo": sys.argv[4]}}}}
elif args == "plugin marketplace remove codex-micro":
    data["extraKnownMarketplaces"].pop("codex-micro")
    data.get("enabledPlugins", {{}}).pop("codex-micro@codex-micro", None)
elif args == "plugin install codex-micro@codex-micro":
    data.setdefault("enabledPlugins", {{}})["codex-micro@codex-micro"] = True
else:
    sys.exit("unexpected: " + args)
json.dump(data, open(path, "w"))
''')
    stub.chmod(0o755)
    environment.update(CLAUDE_CONFIG_DIR=str(claude_home), XDG_CONFIG_HOME=str(xdg),
                       DOPPEL_CLAUDE_CLI=str(stub))
    called = lambda: calls.read_text().splitlines() if calls.exists() else []

    assert run("claude") == "Claude Code: not set up\n"
    run("channel", "ChatGPT Veridue", "1")
    run("claude", "1", "--yes", success=False)
    run("claude", "4", "--plan", success=False)
    plan = run("claude", "2", "--plan")
    for step in ["add the codex-micro marketplace from thomast8/codex-micro-for-claude-code",
                 "install the codex-micro plugin",
                 "turn on CLAUDE_CODE_ENABLE_FUNCTION_HOOKS",
                 "keep the plugin to Bluetooth channel 2",
                 "older than 2.1.303"]:
        assert step in plan, (step, plan)
    assert called() == ["--version"]
    assert pad_config.read_text() == '[keys]\nfast = "approve"\n'
    run("claude", "2", success=False)
    assert called() == ["--version", "--version"]
    run("claude", "2", "--yes")
    assert called()[2:] == ["--version", "plugin marketplace add thomast8/codex-micro-for-claude-code",
                            "plugin install codex-micro@codex-micro"], called()
    data = json.loads(settings.read_text())
    assert data["env"] == {"KEEP": "1", "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS": "1"}
    assert data["theme"] == "dark"
    assert pad_config.read_text() == '[keys]\nfast = "approve"\n\n[pad]\nchannel = 2\n'
    assert run("claude") == "Claude Code: channel 2\n"
    assert run("channel", "--porcelain") == "instance\tveridue\t1\nclaude\t2\n"
    assert "nothing to change" in run("claude", "2", "--plan")
    assert run("channel") == "ChatGPT Veridue: 1\nClaude Code: 2\n"
    run("channel", "ChatGPT Personal", "2", success=False)
    run("claude", "3", "--yes")
    assert pad_config.read_text() == '[keys]\nfast = "approve"\n\n[pad]\nchannel = 3\n'
    data["extraKnownMarketplaces"]["codex-micro"]["source"]["repo"] = "dustinwdev/codex-micro-for-claude-code"
    settings.write_text(json.dumps(data))
    calls.unlink()
    assert "point the codex-micro marketplace at thomast8/codex-micro-for-claude-code" in run("claude", "3", "--plan")
    run("claude", "3", "--yes")
    assert called()[1:] == ["--version", "plugin marketplace remove codex-micro",
                            "plugin marketplace add thomast8/codex-micro-for-claude-code",
                            "plugin install codex-micro@codex-micro"], called()
    run("claude", "any", "--yes")
    assert "channel" not in pad_config.read_text()
    assert run("claude") == "Claude Code: every channel\n"
    run("channel", "ChatGPT Veridue", "any")

print("Creator Micro CLI QA passed")

# Exercise the actual lifecycle functions with controlled process/AppleEvent
# boundaries; the real CLI checks above cover dispatch, locking and persistence.
source = cli.read_text()
functions = "\n".join(re.search(rf"^{name}\(\) \{{.*?^\}}", source, re.M | re.S)[0]
                      for name in ["reopen_clone_instances", "cmd_micro_change", "cmd_micro",
                                   "cmd_browser_assign", "cmd_browser_release"])
stubs = r'''
set -eu
INSTANCES_ROOT="$QA_ROOT/instances"
CODEX_MICRO_OWNER_FILE="$QA_ROOT/state/owner"
IAB_SLOT_FILE="$QA_ROOT/state/browser"
PRIMARY_APP=official
PRIMARY_BUNDLE_ID=official
mkdir -p "$INSTANCES_ROOT/old" "$INSTANCES_ROOT/new" "$QA_ROOT/state"
die() { print -u2 -r -- "$*"; exit 1; }
config_value() { print -r -- "${1:t}"; }
app_path_for() { print -r -- "${1:t}"; }
is_instance_dir() { [[ -d "$1" ]]; }
instance_dir_for() { [[ -d "$INSTANCES_ROOT/$1" ]] || die unknown; print -r -- "$INSTANCES_ROOT/$1"; }
with_iab_operation_lock() { "$@"; }
clone_instance_is_running() { [[ -f "$QA_ROOT/running-${1:t}" ]]; }
any_chatgpt_process_uses_profile() { clone_instance_is_running "$1" || vendor_instance_is_running "$1"; }
vendor_instance_is_running() { [[ -f "$QA_ROOT/vendor-${1:t}" ]]; }
quit_instance() {
    print -r -- "quit:$1" >> "$QA_ROOT/events"
    [[ "$1" != "${QA_REFUSE:-}" ]] || die refused
    if [[ "$1" == official ]]; then
        rm -f "$QA_ROOT"/vendor-*(N)
    else
        rm -f "$QA_ROOT/running-$1"
    fi
}
launch_clone_instance() {
    print -r -- "clone:${1:t}" >> "$QA_ROOT/events"
    [[ "${1:t}" != "${QA_FAIL_LAUNCH:-}" ]] || die launch-failed
    touch "$QA_ROOT/running-${1:t}"
}
launch_vendor_instance() { print -r -- "vendor:${1:t}" >> "$QA_ROOT/events"; touch "$QA_ROOT/vendor-${1:t}"; }
validate_vendor_app() { return 0; }
require_transparent_router_profile() { return 0; }
require_compatible_transparent_router_profile() { return 0; }
require_vendor_compatible_profile() { return 0; }
iab_slot_slug() { cat "$IAB_SLOT_FILE" 2>/dev/null || true; }
write_iab_slot() { print -r -- "$1" > "$IAB_SLOT_FILE"; }
clear_iab_slot() { rm -f "$IAB_SLOT_FILE"; }
raw_vendor_profile_pids() { vendor_instance_is_running "$1" && print -r -- 123 || true; }
other_vendor_engine_is_running() { [[ -f "$QA_ROOT/vendor-other" ]]; }
vendor_main_pids() { [[ -n "$(print -r -- "$QA_ROOT"/vendor-*(N))" ]] && print -r -- 123 || true; }
write_iab_runtime_receipt() { :; }
primary_version() { print -r -- 1; }
'''


def lifecycle(command, *, owner="old", browser="", running=(), vendor=(),
              refuse="", fail_launch="", success=True, events=(), expected_owner="old",
              expected_browser=""):
    with tempfile.TemporaryDirectory(prefix="doppel-restart-") as scratch:
        root = Path(scratch)
        (root / "state").mkdir()
        if owner:
            (root / "state/owner").write_text(owner + "\n")
        if browser:
            (root / "state/browser").write_text(browser + "\n")
        for name in running:
            (root / f"running-{name}").touch()
        for name in vendor:
            (root / f"vendor-{name}").touch()
        result = subprocess.run(["/bin/zsh", "-c", stubs + functions + "\n" + command],
                                env={**os.environ, "QA_ROOT": scratch, "QA_REFUSE": refuse,
                                     "QA_FAIL_LAUNCH": fail_launch}, capture_output=True, text=True)
        assert (result.returncode == 0) == success, (command, result.stderr)
        log = root / "events"
        assert (log.read_text().splitlines() if log.exists() else []) == list(events), command
        for path, expected in [("owner", expected_owner), ("browser", expected_browser)]:
            record = root / "state" / path
            assert (record.read_text().strip() if record.exists() else "") == expected, command


lifecycle("cmd_micro assign new", running=("old", "new", "unrelated"),
          events=("quit:old", "quit:new", "clone:old", "clone:new"), expected_owner="new")
lifecycle("cmd_micro assign new", running=("old",),
          events=("quit:old", "clone:old"), expected_owner="new")
lifecycle("cmd_micro assign old", running=("old",))
lifecycle("cmd_micro release", running=("old",), events=("quit:old", "clone:old"), expected_owner="")
lifecycle("cmd_micro assign new", running=("old", "new"), refuse="new", success=False,
          events=("quit:old", "quit:new", "clone:old"))
lifecycle("cmd_micro assign new", running=("old", "new"), fail_launch="old", success=False,
          events=("quit:old", "quit:new", "clone:old", "clone:new"), expected_owner="new")
lifecycle("cmd_browser_assign --quit-running new", browser="old", vendor=("old",), running=("new",),
          events=("quit:official", "quit:new", "clone:old", "vendor:new"), expected_browser="new")
lifecycle('touch "$QA_ROOT/no-dir"; CODEX_MICRO_OWNER_FILE="$QA_ROOT/no-dir/owner"; cmd_micro assign new',
          running=("new",), success=False, events=("quit:new", "clone:new"))
lifecycle("cmd_browser_assign --quit-running new", browser="old", expected_browser="new")
lifecycle("cmd_browser_release --quit-running", browser="old", vendor=("old",),
          events=("quit:official", "clone:old"))
lifecycle("cmd_browser_release", browser="old", vendor=("old",), success=False, expected_browser="old")
lifecycle("cmd_browser_release --quit-running", browser="old", vendor=("old",), refuse="official",
          success=False, events=("quit:official",), expected_browser="old")
lifecycle("cmd_browser_release --quit-running", browser="old")
print("Automatic restart lifecycle QA passed")
