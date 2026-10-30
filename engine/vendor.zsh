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
