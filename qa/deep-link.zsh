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

# BSD grep -o rescans very long ASAR lines; match the same bytes without line buffering.
count_marker() {
    /usr/bin/python3 - "$TEST_ASAR" "$1" "${2:-literal}" <<'PYCOUNT'
import mmap, re, sys
with open(sys.argv[1], "rb") as source, mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as data:
    pattern = sys.argv[2].encode()
    if sys.argv[3] == "regex":
        count = sum(1 for _ in re.finditer(pattern, data))
    else:
        count, offset = 0, 0
        while (offset := data.find(pattern, offset)) != -1:
            count += 1
            offset += len(pattern)
    print(count)
PYCOUNT
}

MARKERS="$(count_marker 'DOPPEL_URL_SCHEME')"
if [[ "$MARKERS" == "1" ]]; then
    pass "the runtime now reads the per-instance scheme"
else
    fail "the runtime now reads the per-instance scheme" "found $MARKERS patch markers"
fi

OAUTH_MARKERS="$(count_marker 'Doppel could not claim codex:// OAuth callback')"
CALLBACKS="$(count_marker 'callbackUrl:`codex://connector/oauth_callback`|return`codex://connector/oauth_callback`' regex)"
if [[ "$OAUTH_MARKERS" == "1" && "$CALLBACKS" == "1" ]]; then
    pass "OAuth claims the shared registered callback only when requested"
else
    fail "OAuth claims the shared registered callback only when requested" \
        "found $OAUTH_MARKERS ownership markers and $CALLBACKS callback URLs"
fi

RESTORE_MARKERS="$(count_marker 'DOPPEL_URL_HANDLER_HELPER')"
RESTORE_SPAWNS="$(count_marker 'require("node:child_process").spawn(process.env.DOPPEL_URL_HANDLER_HELPER')"
if [[ "$RESTORE_MARKERS" == "2" && "$RESTORE_SPAWNS" == "1" ]]; then
    pass "a completed callback restores primary codex ownership"
else
    fail "a completed callback restores primary codex ownership" \
        "found $RESTORE_MARKERS restoration markers and $RESTORE_SPAWNS direct spawn calls"
fi

MICRO_MARKERS="$(count_marker 'process.env.DOPPEL_CODEX_MICRO')"
if [[ "$MICRO_MARKERS" == "1" ]]; then
    pass "the clone leaves the Codex Micro pad to the primary"
else
    fail "the clone leaves the Codex Micro pad to the primary" "found $MICRO_MARKERS Micro gates"
fi

CHANNEL_GATES="$(count_marker 'process.env.DOPPEL_MICRO_CHANNEL')"
if [[ "$CHANNEL_GATES" == "1" ]]; then
    pass "the pad owner can be limited to one Bluetooth channel"
else
    fail "the pad owner can be limited to one Bluetooth channel" "found $CHANNEL_GATES channel gates"
fi

# The runtime root moves, the plugin marketplace copy beneath it does not: the
# Codex CLI only trusts that copy at the real ~/.cache path.
RUNTIME_ROOTS="$(count_marker '\(process\.env\.DOPPEL_CODEX_RUNTIMES_ROOT\|\|[A-Za-z_$][A-Za-z0-9_$]*\.default\.join\([A-Za-z_$][A-Za-z0-9_$]*\.default\.homedir\(\),`\.cache`,`codex-runtimes`\)\)' regex)"
RUNTIME_MARKERS="$(count_marker 'DOPPEL_CODEX_RUNTIMES_ROOT')"
PLUGIN_COPIES="$(count_marker 'homedir\(\),`\.cache`,`codex-runtimes`,[A-Za-z_$][A-Za-z0-9_$.]*,`plugins`' regex)"
if [[ "$RUNTIME_ROOTS" == "4" && "$RUNTIME_MARKERS" == "4" && "$PLUGIN_COPIES" == "1" ]]; then
    pass "the clone keeps its own Codex runtime but the shared plugin copy"
else
    fail "the clone keeps its own Codex runtime but the shared plugin copy" \
        "found $RUNTIME_ROOTS patched roots, $RUNTIME_MARKERS markers, $PLUGIN_COPIES plugin copies"
fi

# Everything above runs against whichever vendor build happens to be installed,
# which is the real signal but only ever covers one build at a time. These
# shapes are the ones that actually shipped: 6321 and 6662 differ only in names
# the minifier chooses and in an argument the vendor added, and 6971 folded the
# whole open-url path into one shared handler plus a startup drain. Pinning any
# one of them is what broke clone builds three times running. A machine on one
# build still has to notice a patcher that has been re-pinned to another.
SHAPES_OUT="$(/usr/bin/python3 -B - "$PATCHER" <<'PY'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("patcher", sys.argv[1])
patcher = importlib.util.module_from_spec(spec)
# Registered before execution: the module defines dataclasses, and resolving
# their annotations looks the module up by name in sys.modules.
sys.modules["patcher"] = patcher
spec.loader.exec_module(patcher)

oauth = {
    "6321": b'"app-connect-oauth-callback-url":async()=>({callbackUrl:`${r.u(l.app.isPackaged)}://connector/oauth_callback`})',
    "6662": b'"app-connect-oauth-callback-url":async()=>({callbackUrl:`${r.K(l.app.isPackaged)}://connector/oauth_callback`})',
    "51333": b'y_e=class extends u.Nt{async getCallbackUrl(){return`${_.M(O.app.isPackaged)}://connector/oauth_callback`}}',
    # 61615 moved to a different bundler: double-quoted strings and the helper
    # reached as ``(0,ns.name)(...)``.
    "61615": b'class FS extends eo.TF{async getCallbackUrl(){return`${(0,Fb.xz)(ea.app.isPackaged)}://connector/oauth_callback`}}',
}
protocol = {
    "51333": b"function se(e,t=process.platform){return e||t===`win32`||t===`linux`?le:ue}",
    "61615": b'function D(e,t=process.platform){return e||"win32"===t||"linux"===t?"codex":"codex-dev"}',
}
inline = {
    "61615": b'if(r){I(r),"wakeQueuedThread"!==r.kind&&g?.(G(r,t)),n?.preventDefault();return}let i=W(t);i&&(C(i),n?.preventDefault())};for(let e of(t.on("open-url",(e,t)=>{r(t,e)}),(0,m._t)(t,e=>(r(e),!0)),(0,h.Z1)()))r(e)}',
}
micro_starts = {
    "51333": b"start(){if(this.lifecycleState!==`started`){this.lifecycleState=`started`",
    "61615": b'start(){if("started"!==this.lifecycleState){this.lifecycleState="started",this.resolvePendingDeviceRpcs?.()',
}
queued = {
    "6321": b'if(i){let n=(e,t)=>{let n=XW(e);if(n){m(n),l?.(eG(n)?e:void 0),t?.preventDefault();return}let r=fG(e);r&&(h(r),t?.preventDefault())};e.on(`open-url`,(e,t)=>{n(t,e)});',
    "6662": b'if(i){let n=(e,t)=>{let n=TW(e);if(n){m(n),l?.(kW(n,e)?e:void 0),t?.preventDefault();return}let r=HW(e);r&&(h(r),t?.preventDefault())};e.on(`open-url`,(e,t)=>{n(t,e)});',
}
drained = {
    "6971": b'if(i){let n=(e,t)=>{let n=PW(e);if(n){h(n),u?.(BW(n,e)),t?.preventDefault();return}let r=$W(e);r&&(g(r),t?.preventDefault())};e.on(`open-url`,(e,t)=>{n(t,e)});for(let e of t.a())n(e)}',
    "12404": b'function T(){if(!t)return;let n=(e,t)=>{let n=n9(e);if(n){g(n),u?.(a9(n,e)),t?.preventDefault();return}let r=d9(e);r&&(_(r),t?.preventDefault())};e.on(`open-url`,(e,t)=>{n(t,e)}),d.l(e,(e,t)=>(g(t),u?.(void 0),!0));for(let e of d.s())n(e)}',
    "31256": b'function re(){if(!t)return;let n=(e,t)=>{let n=oD(e);if(n){S(n),n.kind!==`wakeQueuedThread`&&d?.(fD(n,e)),t?.preventDefault();return}let r=ED(e);r&&(C(r),t?.preventDefault())};e.on(`open-url`,(e,t)=>{n(t,e)}),u.u(e,(e,t)=>(S(t),d?.(void 0),!0));for(let e of u.c())n(e)}',
}
runtime_roots = {
    "21421": b"installRoot:n=l.default.join(u.default.homedir(),`.cache`,`codex-runtimes`),osRelease:r",
    "21421 worker": b"function xZ(e){return e==null&&yZ!=null?yZ:g.default.join(e??g.default.join(h.default.homedir(),`.cache`,`codex-runtimes`),Jwe)}",
    # Not shipped yet: longer minified names must not be wrapped a second time
    # from their second letter.
    "long names": b"installRoot:n=ab.default.join(uv.default.homedir(),`.cache`,`codex-runtimes`),osRelease:r",
    "61615": b'installRoot:r=d().join(u().homedir(),".cache","codex-runtimes"),osRelease:n',
    "61615 worker": b'function h2(e){return c1().join(e??c1().join(cJ().homedir(),".cache","codex-runtimes"),"codex-primary-runtime")}',
}
not_runtime_roots = {
    "21421 plugins": b"let n=C.default.join(T.default.homedir(),`.cache`,`codex-runtimes`,l.I,`plugins`,C.default.basename(e))",
    "21421 language servers": b"this.cacheRoot=e.cacheRoot??C.default.join(T.default.homedir(),`.cache`,`codex-runtimes`,`language-servers`)",
    "61615 plugins": b'let n=ei().join(ef().homedir(),".cache","codex-runtimes","codex-texlive"),o=1',
    "61615 language servers": b'this.cacheRoot=e.cacheRoot??ei().join(ef().homedir(),".cache","codex-runtimes","language-servers")',
}
missed = []
for build, sample in runtime_roots.items():
    if len(patcher.UNPATCHED_RUNTIME_ROOT.findall(sample)) != 1:
        missed.append(f"runtime root {build}")
    if len(patcher.UNPATCHED_RUNTIME_ROOT.findall(patcher.patched_runtime_roots(sample))) != 0:
        missed.append(f"runtime root idempotence {build}")
for build, sample in not_runtime_roots.items():
    if patcher.UNPATCHED_RUNTIME_ROOT.findall(sample):
        missed.append(f"runtime root overmatch {build}")
for build, sample in oauth.items():
    if len(patcher.OAUTH_CALLBACK_HANDLER.findall(sample)) + len(patcher.OAUTH_CALLBACK_GETTER.findall(sample)) != 1:
        missed.append(f"oauth {build}")
# The vendor's last bundler change swapped backtick strings for double quotes
# without changing behaviour. Every shipped shape must therefore also match
# with its quotes swapped, so the next such change cannot fail a clone build.
def requoted(sample):
    return sample.replace(b"`", b'"')
for build, sample in protocol.items():
    if len(patcher.PROTOCOL_HELPER.findall(requoted(sample))) != 1:
        missed.append(f"requoted protocol helper {build}")
for build, sample in queued.items():
    if len(patcher.QUEUED_OPEN_URL_HANDLER.findall(requoted(sample))) != 1:
        missed.append(f"requoted open-url {build}")
for build, sample in drained.items():
    if len(patcher.DRAINED_OPEN_URL_HANDLER.findall(requoted(sample))) != 1:
        missed.append(f"requoted open-url {build}")
for build, sample in inline.items():
    if len(patcher.INLINE_OPEN_URL_HANDLER.findall(requoted(sample))) != 1:
        missed.append(f"requoted open-url {build}")
for build, sample in micro_starts.items():
    if len(patcher.MICRO_START.findall(requoted(sample))) != 1:
        missed.append(f"requoted micro start {build}")
for build, sample in runtime_roots.items():
    if len(patcher.UNPATCHED_RUNTIME_ROOT.findall(requoted(sample))) != 1:
        missed.append(f"requoted runtime root {build}")
for build, sample in not_runtime_roots.items():
    if patcher.UNPATCHED_RUNTIME_ROOT.findall(requoted(sample)):
        missed.append(f"requoted runtime root overmatch {build}")
for build, sample in protocol.items():
    if len(patcher.PROTOCOL_HELPER.findall(sample)) != 1:
        missed.append(f"protocol helper {build}")
for build, sample in inline.items():
    if len(patcher.INLINE_OPEN_URL_HANDLER.findall(sample)) != 1:
        missed.append(f"open-url {build}")
for build, sample in micro_starts.items():
    if len(patcher.MICRO_START.findall(sample)) != 1:
        missed.append(f"micro start {build}")
    if len(patcher.MICRO_PATCHED_START.findall(patcher.patched_micro_start(sample))) != 1 or patcher.MICRO_START.search(patcher.patched_micro_start(sample)):
        missed.append(f"micro start patch {build}")
for build, sample in queued.items():
    if len(patcher.QUEUED_OPEN_URL_HANDLER.findall(sample)) != 1:
        missed.append(f"open-url {build}")
for build, sample in drained.items():
    if len(patcher.DRAINED_OPEN_URL_HANDLER.findall(sample)) != 1:
        missed.append(f"open-url {build}")
print(",".join(missed))
PY
)" || SHAPES_OUT="the shape check itself failed"
if [[ -z "$SHAPES_OUT" ]]; then
    pass "all shipped minified shapes still match"
else
    fail "all shipped minified shapes still match" "no match for: $SHAPES_OUT"
fi

print -r -- "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
