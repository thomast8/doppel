#!/bin/zsh
# Focused regression check for per-instance OAuth/deep-link routing. This uses
# an APFS clone of the current vendor ASAR and never launches or edits an app.

set -u
setopt PIPE_FAIL

readonly REPO_ROOT="${0:A:h:h}"
readonly PATCHER="$REPO_ROOT/engine/patch-deep-link.py"
readonly PRIMARY_ASAR="${DOPPEL_PRIMARY_APP:-/Applications/ChatGPT.app}/Contents/Resources/app.asar"
readonly SCRATCH="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-deep-link.XXXXXXXX")"
readonly TEST_ASAR="$SCRATCH/app.asar"

typeset -i PASSED=0 FAILED=0
pass() { print -r -- "  ✓ $1"; (( PASSED += 1 )); return 0 }
fail() { print -r -- "  ✗ $1"; print -r -- "      $2"; (( FAILED += 1 )); return 0 }
cleanup() { /bin/rm -rf "$SCRATCH" 2>/dev/null || true }
trap cleanup EXIT

print -r -- "Doppel deep-link patch QA"

# Synthetic slots cover old releases, enabled validation and fail-closed cases.
if /usr/bin/python3 - "$PATCHER" "$SCRATCH" <<'PYDIGEST'
import hashlib, plistlib, runpy, sys
from pathlib import Path

module = runpy.run_path(sys.argv[1])
patch_digest, error = module["patch_integrity_digest"], module["PatchError"]
root = Path(sys.argv[2])
source, clone, framework = root / "source.plist", root / "clone.plist", root / "framework"
for path, value in ((source, "a"), (clone, "b")):
    path.write_bytes(plistlib.dumps({"ElectronAsarIntegrity": {
        "Resources/app.asar": {"algorithm": "SHA256", "hash": value * 64}}}))
digest = lambda value: hashlib.sha256(("Resources/app.asarSHA256" + value * 64).encode()).digest()
marker = b"AGbevlPCksUGKNL8TSn7wGmJEuJsXb2A"
slot = marker + b"\x01\x01" + digest("a")
framework.write_bytes(b"legacy framework")
assert not patch_digest(framework, source, clone)
framework.write_bytes(slot * 2)
assert patch_digest(framework, source, clone)
assert framework.read_bytes() == (marker + b"\x01\x01" + digest("b")) * 2
assert not patch_digest(framework, source, clone)
for bad in (marker, marker + b"\x01\x02" + digest("a"),
            marker + b"\x01\x01" + bytes(32)):
    original = slot + bad
    framework.write_bytes(original)
    try:
        patch_digest(framework, source, clone)
    except error:
        pass
    else:
        raise AssertionError("invalid integrity slot was accepted")
    assert framework.read_bytes() == original
framework.write_bytes(marker + bytes(34))
assert not patch_digest(framework, source, clone)
PYDIGEST
then
    pass "framework integrity stays enabled and invalid slots fail before mutation"
else
    fail "framework integrity stays enabled and invalid slots fail before mutation" "digest regression failed"
fi

if /usr/bin/python3 "$PATCHER" verify "$PRIMARY_ASAR" >/dev/null 2>&1; then
    fail "the unmodified primary is recognized as shared-scheme" \
        "verify incorrectly accepted the vendor codex:// behavior"
else
    pass "the unmodified primary is recognized as shared-scheme"
fi

if ! /bin/cp -c "$PRIMARY_ASAR" "$TEST_ASAR" 2>/dev/null; then
    /bin/cp "$PRIMARY_ASAR" "$TEST_ASAR" || exit 1
fi

PATCH_HASH="$(/usr/bin/python3 "$PATCHER" patch "$TEST_ASAR")" || {
    fail "the current vendor ASAR can be patched" "patch command failed"
    print -r -- "$PASSED passed, $FAILED failed"
    exit 1
}
pass "the current vendor ASAR can be patched"

VERIFY_HASH="$(/usr/bin/python3 "$PATCHER" verify "$TEST_ASAR")" || VERIFY_HASH=""
if [[ "$VERIFY_HASH" == "$PATCH_HASH" && ${#VERIFY_HASH} -eq 64 ]]; then
    pass "the patched archive and Electron header hash verify"
else
    fail "the patched archive and Electron header hash verify" \
        "patch '$PATCH_HASH', verify '$VERIFY_HASH'"
fi

SECOND_HASH="$(/usr/bin/python3 "$PATCHER" patch "$TEST_ASAR")" || SECOND_HASH=""
if [[ "$SECOND_HASH" == "$PATCH_HASH" ]]; then
    pass "patching is idempotent"
else
    fail "patching is idempotent" "second patch returned '$SECOND_HASH'"
fi

MARKERS="$(LC_ALL=C /usr/bin/grep -a -o 'DOPPEL_URL_SCHEME' "$TEST_ASAR" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [[ "$MARKERS" == "1" ]]; then
    pass "the runtime now reads the per-instance scheme"
else
    fail "the runtime now reads the per-instance scheme" "found $MARKERS patch markers"
fi

OAUTH_MARKERS="$(LC_ALL=C /usr/bin/grep -a -o 'Doppel could not claim codex:// OAuth callback' "$TEST_ASAR" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
CALLBACKS="$(LC_ALL=C /usr/bin/grep -a -o 'callbackUrl:`codex://connector/oauth_callback`' "$TEST_ASAR" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [[ "$OAUTH_MARKERS" == "1" && "$CALLBACKS" == "1" ]]; then
    pass "OAuth claims the shared registered callback only when requested"
else
    fail "OAuth claims the shared registered callback only when requested" \
        "found $OAUTH_MARKERS ownership markers and $CALLBACKS callback URLs"
fi

RESTORE_MARKERS="$(LC_ALL=C /usr/bin/grep -a -o 'DOPPEL_URL_HANDLER_HELPER' "$TEST_ASAR" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
RESTORE_SPAWNS="$(LC_ALL=C /usr/bin/grep -a -o 'require("node:child_process").spawn(process.env.DOPPEL_URL_HANDLER_HELPER' "$TEST_ASAR" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [[ "$RESTORE_MARKERS" == "2" && "$RESTORE_SPAWNS" == "1" ]]; then
    pass "a completed callback restores primary codex ownership"
else
    fail "a completed callback restores primary codex ownership" \
        "found $RESTORE_MARKERS restoration markers and $RESTORE_SPAWNS direct spawn calls"
fi

# Everything above runs against whichever vendor build happens to be installed,
# which is the real signal but only ever covers one build at a time. These
# shapes are the ones that actually shipped: 6321 and 6662 differ only in names
# the minifier chooses and in an argument the vendor added, and 6971 folded the
# whole open-url path into one shared handler plus a startup drain. Build 12246
# defers registration to a guarded startup function and adds universal links.
# A machine on one build still has to recognize the other supported shapes.
SHAPES_OUT="$(/usr/bin/python3 - "$PATCHER" "$SCRATCH" <<'PY'
import importlib.util, sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("patcher", sys.argv[1])
patcher = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
# Registered before execution: the module defines dataclasses, and resolving
# their annotations looks the module up by name in sys.modules.
sys.modules["patcher"] = patcher
spec.loader.exec_module(patcher)

oauth = {
    "6321": b'"app-connect-oauth-callback-url":async()=>({callbackUrl:`${r.u(l.app.isPackaged)}://connector/oauth_callback`})',
    "6662": b'"app-connect-oauth-callback-url":async()=>({callbackUrl:`${r.K(l.app.isPackaged)}://connector/oauth_callback`})',
}
queued = {
    "6321": b'if(i){let n=(e,t)=>{let n=XW(e);if(n){m(n),l?.(eG(n)?e:void 0),t?.preventDefault();return}let r=fG(e);r&&(h(r),t?.preventDefault())};e.on(`open-url`,(e,t)=>{n(t,e)});',
    "6662": b'if(i){let n=(e,t)=>{let n=TW(e);if(n){m(n),l?.(kW(n,e)?e:void 0),t?.preventDefault();return}let r=HW(e);r&&(h(r),t?.preventDefault())};e.on(`open-url`,(e,t)=>{n(t,e)});',
}
drained = {
    "6971": b'if(i){let n=(e,t)=>{let n=PW(e);if(n){h(n),u?.(BW(n,e)),t?.preventDefault();return}let r=$W(e);r&&(g(r),t?.preventDefault())};e.on(`open-url`,(e,t)=>{n(t,e)});for(let e of t.a())n(e)}',
}
started = {
    "12246": b'function T(){if(!t)return;let n=(e,t)=>{let n=n9(e);if(n){g(n),u?.(a9(n,e)),t?.preventDefault();return}let r=d9(e);r&&(_(r),t?.preventDefault())};e.on(`open-url`,(e,t)=>{n(t,e)}),d.l(e,(e,t)=>(g(t),u?.(void 0),!0));for(let e of d.s())n(e)}',
}
missed = []
for build, sample in oauth.items():
    if len(patcher.OAUTH_CALLBACK_HANDLER.findall(sample)) != 1:
        missed.append(f"oauth {build}")
for build, sample in queued.items():
    if len(patcher.QUEUED_OPEN_URL_HANDLER.findall(sample)) != 1:
        missed.append(f"open-url {build}")
for build, sample in drained.items():
    if len(patcher.DRAINED_OPEN_URL_HANDLER.findall(sample)) != 1:
        missed.append(f"open-url {build}")
for build, sample in started.items():
    if len(patcher.STARTED_OPEN_URL_HANDLER.findall(sample)) != 1:
        missed.append(f"open-url {build}")

# Exercise selection and replacement as well as recognition. A raw one-member
# Archive is sufficient here; the vendor ASAR checks above cover its packing.
sample = started["12246"]
fixture = Path(sys.argv[2]) / "started-handler.js"
def locate(data):
    fixture.write_bytes(data)
    archive = patcher.Archive(fixture, {"files": {
        "bootstrap.js": {"offset": "0", "size": len(data)}
    }}, b"", 0, len(data))
    return patcher.locate_restore_member(archive)

member, replacement, already = locate(sample)
assert not already and member.path == "bootstrap.js"
match = patcher.STARTED_OPEN_URL_HANDLER.fullmatch(sample)
assert match is not None
assert replacement.startswith(match.group("prefix") + b";if(")
assert replacement.endswith(match.group("suffix"))
assert replacement.count(patcher.RESTORE_PATCH_MARKER) == 2
assert replacement.count(patcher.RESTORE_SPAWN_MARKER) == 1
assert b'n.kind===`connectorOAuthCallback`' in replacement
assert locate(replacement)[1:] == (replacement, True)

for unsupported in (
    sample + sample,
    sample.replace(b".on(`open-url`", b".on(`unknown-event`"),
    sample.replace(b"d.l(e,(e,t)=>(g(t),u?.(void 0),!0))", b"d.l(e,unknown)"),
):
    try:
        locate(unsupported)
    except patcher.PatchError:
        pass
    else:
        raise AssertionError("ambiguous or unsupported startup handler accepted")
print(",".join(missed))
PY
)"
SHAPES_STATUS=$?
if [[ "$SHAPES_STATUS" -eq 0 && -z "$SHAPES_OUT" ]]; then
    pass "all supported shapes match and startup restoration remains fail-closed"
else
    fail "all supported shapes match and startup restoration remains fail-closed" \
        "shape regression exited $SHAPES_STATUS; unmatched: $SHAPES_OUT"
fi

print -r -- "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
