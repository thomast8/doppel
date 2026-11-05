#!/bin/zsh
# The in-app browser refuses a client unless the client, its parent and its
# grandparent are OpenAI-signed and it descends from the socket owner. This
# drives the vendor's own checker (browser-use-peer-authorization.node) with
# the vendor's signed node standing in for codex and node_repl, so it proves the
# layer Doppel installs is accepted and that the plain clone layout is not.
set -eu
setopt PIPE_FAIL

readonly REPO_ROOT="${0:A:h:h}"
readonly PRIMARY="${DOPPEL_PRIMARY_APP:-/Applications/ChatGPT.app}"
readonly VENDOR_BIN="$PRIMARY/Contents/Resources/cua_node/bin"
readonly ADDON="$PRIMARY/Contents/Resources/native/browser-use-peer-authorization.node"
[[ -x "$VENDOR_BIN/node" && -f "$ADDON" ]] || { print -r -- "node-repl-layer QA: skipped (no vendor runtime)"; exit 0; }

readonly SCRATCH="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-node-repl.XXXXXXXX")"
readonly SOCK="/tmp/doppel-nrl-$$.sock"
trap '/bin/rm -rf "$SCRATCH" "$SOCK"' EXIT INT TERM

DOPPEL_APP_KIND=chatgpt source "$REPO_ROOT/engine/vendor.zsh"

# A fake bundle whose node_repl is the vendor node running a socket client.
APP="$SCRATCH/Clone.app"
BIN="$APP/Contents/Resources/cua_node/bin"
/bin/mkdir -p "$BIN"
/bin/cp "$VENDOR_BIN/node" "$BIN/node"
/bin/cp "$VENDOR_BIN/node" "$BIN/node_repl"
print -r -- "require('net').connect(process.argv[2]).on('close',()=>process.exit(0)).on('error',()=>process.exit(1))" > "$SCRATCH/client.js"

/bin/cat > "$SCRATCH/owner.js" <<'JS'
const net = require('net'), { spawn } = require('child_process');
const [addon, sock, launcher, client] = process.argv.slice(2);
const check = require(addon);
net.createServer((s) => { console.log(check.authorizeSocketPeer(s._handle.fd, false).authorized); s.end(); })
  .listen(sock, () => {
    // codex starts MCP servers as /bin/sh -c 'exec "$@"', so do the same.
    spawn('/bin/sh', ['-c', 'exec "$@"', 'cua-repl', launcher, client, sock], { stdio: 'inherit' })
      .on('exit', () => process.exit(0));
  });
JS

run() { "$VENDOR_BIN/node" "$SCRATCH/owner.js" "$ADDON" "$SOCK" "$1" "$SCRATCH/client.js"; /bin/rm -f "$SOCK"; }

failures=0
expect() { [[ "$2" == "$3" ]] && print -r -- "  ✓ $1" || { print -r -- "  ✗ $1 (got '$2', want '$3')"; failures=$((failures + 1)); } }

expect "the plain clone layout is refused" "$(run "$BIN/node_repl")" "false"
install_node_repl_layer "$APP"
expect "the layer keeps the vendor binary" "$(/bin/test -x "$BIN/node_repl-vendor" && print yes)" "yes"
expect "the layered launch is authorized" "$(run "$BIN/node_repl")" "true"
expect "installing twice refuses" "$(install_node_repl_layer "$APP" && print ok || print refused)" "refused"

print -r -- ""
(( failures == 0 )) && print -r -- "node-repl-layer QA: passed" || { print -r -- "node-repl-layer QA: $failures failed"; exit 1; }
