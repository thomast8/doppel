# Fixed vendor identities shared by the CLI and the signed instance engine.
case "${DOPPEL_APP_KIND:-chatgpt}" in
    chatgpt)
        readonly PRIMARY_EXECUTABLE="ChatGPT"
        readonly PRIMARY_FRAMEWORK="Codex Framework"
        readonly AGENT_HOME_KEY="DOPPEL_CODEX_HOME" AGENT_HOME_PREFIX=".codex"
        readonly DEFAULT_DOPPEL_HOME="$HOME/Library/Application Support/Doppel"
        readonly OTHER_INSTANCES_ROOT="$HOME/Library/Application Support/Doppel/claude/instances"
        readonly PRIMARY_APP="${DOPPEL_PRIMARY_APP:-/Applications/ChatGPT.app}"
        readonly PRIMARY_BUNDLE_ID="${DOPPEL_PRIMARY_BUNDLE_ID:-com.openai.codex}"
        readonly PRIMARY_SCHEME="${DOPPEL_PRIMARY_SCHEME:-codex}"
        readonly PRIMARY_TEAM_ID="${DOPPEL_PRIMARY_TEAM_ID:-2DC432GLL2}"
        ;;
    claude)
        readonly PRIMARY_EXECUTABLE="Claude"
        readonly PRIMARY_FRAMEWORK="Electron Framework"
        readonly AGENT_HOME_KEY="DOPPEL_CLAUDE_CONFIG_DIR" AGENT_HOME_PREFIX=".claude"
        readonly DEFAULT_DOPPEL_HOME="$HOME/Library/Application Support/Doppel/claude"
        readonly OTHER_INSTANCES_ROOT="$HOME/Library/Application Support/Doppel/instances"
        readonly PRIMARY_APP="${DOPPEL_PRIMARY_APP:-/Applications/Claude.app}"
        readonly PRIMARY_BUNDLE_ID="${DOPPEL_PRIMARY_BUNDLE_ID:-com.anthropic.claudefordesktop}"
        readonly PRIMARY_SCHEME="${DOPPEL_PRIMARY_SCHEME:-claude}"
        readonly PRIMARY_TEAM_ID="${DOPPEL_PRIMARY_TEAM_ID:-Q6L2SF6YDW}"
        ;;
    *) print -u2 -r -- "Doppel: unsupported app kind"; exit 1 ;;
esac

# ChatGPT 26.1029 lets a process drive the in-app browser only when that
# process, its parent and its grandparent are all signed by OpenAI, and it
# descends from the app that owns the socket. The computer-use tool chain is
# node_repl <- codex <- ChatGPT.real, so a clone's locally signed main
# executable lands on the grandparent and every request is refused. Run the
# vendor's node_repl through the vendor's own signed node instead, giving
# node_repl <- node <- codex. The check itself is untouched; this only restores
# the extra signed layer older builds happened to have. Call it on the staged
# copy before signing so the clone's seal covers the result.
install_node_repl_layer() {
    local bin="$1/Contents/Resources/cua_node/bin"
    [[ -f "$bin/node_repl" && -x "$bin/node" ]] || return 0
    [[ ! -e "$bin/node_repl-vendor" ]] || return 1
    [[ "$(/usr/bin/xxd -p -l 4 "$bin/node_repl")" == (cffaedfe|cafebabe) ]] || return 1
    /bin/mv "$bin/node_repl" "$bin/node_repl-vendor" || return 1
    /bin/cat > "$bin/doppel-node-repl.cjs" <<'SHIM' || return 1
'use strict';
// Installed by Doppel: keeps node_repl one process below this signed node.
const { spawn } = require('child_process');
const [, , target, ...args] = process.argv;
const child = spawn(target, args, { stdio: 'inherit' });
const forward = (signal) => { if (child.exitCode === null) child.kill(signal); };
for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(signal, forward);
child.on('error', (error) => { process.stderr.write(`doppel: ${error.message}\n`); process.exit(127); });
child.on('exit', (code, signal) => {
  if (signal) { process.removeAllListeners(signal); process.kill(process.pid, signal); return; }
  process.exit(code ?? 1);
});
SHIM
    /bin/cat > "$bin/node_repl" <<'LAUNCH' || return 1
#!/bin/sh
dir="${0%/*}"
exec "$dir/node" "$dir/doppel-node-repl.cjs" "$dir/node_repl-vendor" "$@"
LAUNCH
    /bin/chmod 755 "$bin/node_repl"
}
