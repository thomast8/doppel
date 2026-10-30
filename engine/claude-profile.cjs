const path = require('node:path');
const {execFileSync} = require('node:child_process');

exports.install = function ({app, dialog}, config) {
    const assets = path.join(process.resourcesPath, 'Doppel');
    const command = (binary, args) => execFileSync(path.join(assets, 'bin', binary), args, {
        encoding: 'utf8', timeout: 30000, stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
    let ownsLogin = false;
    let timer;
    app.setPath('userData', config.profile);
    app.setPath('logs', path.join(config.profile, 'Logs'));
    process.env.CLAUDE_CONFIG_DIR = config.code;

    const setProtocol = app.setAsDefaultProtocolClient.bind(app);
    const removeProtocol = app.removeAsDefaultProtocolClient.bind(app);
    app.setAsDefaultProtocolClient = (scheme, ...args) =>
        setProtocol(scheme === 'claude' ? config.scheme : scheme, ...args);
    app.removeAsDefaultProtocolClient = (scheme, ...args) =>
        removeProtocol(scheme === 'claude' ? config.scheme : scheme, ...args);

    function finishLogin() {
        if (!ownsLogin) return;
        command('doppel', ['--app', 'claude', '__auth-release', config.slug, String(process.pid)]);
        ownsLogin = false;
        clearTimeout(timer);
    }

    function reportRestoreFailure() {
        dialog.showErrorBox(config.name, 'Doppel could not restore the main Claude sign-in handler. Quit this instance before starting another sign-in.');
    }

    function prepareLogin(options) {
        try {
            command('doppel', ['--app', 'claude', '__auth-claim', config.slug, String(process.pid)]);
        } catch {
            throw new Error('Doppel could not route this sign-in. Finish any sign-in in another Claude instance, then try again.');
        }
        ownsLogin = true;
        clearTimeout(timer);
        timer = setTimeout(() => {
            try { finishLogin(); } catch { reportRestoreFailure(); }
        }, 18 * 60 * 1000);
        timer.unref();
        const wrap = callback => (...args) => {
            try { return callback?.(...args); }
            finally { finishLogin(); }
        };
        return {...options, onCallback: wrap(options.onCallback),
            onGenuineCancel: wrap(options.onGenuineCancel)};
    }

    app.on('open-url', (_event, value) => {
        let url;
        try { url = new URL(value); } catch { return; }
        if (url.protocol === 'claude:' &&
            (url.hostname === 'login' || url.hostname === 'claude.ai')) {
            setImmediate(() => {
                try { finishLogin(); } catch { reportRestoreFailure(); }
            });
        }
    });
    app.on('before-quit', () => {
        if (!ownsLogin) return;
        // Edit/remove may hold the CLI lock while waiting for this app to quit.
        // Restore directly; the coordinator reclaims the dead owner's receipt.
        try {
            if (command('doppel-url-handler', ['get', 'claude']) === config.bundleID) {
                command('doppel-url-handler', ['set', 'claude', config.primaryApp, config.primaryBundleID]);
            }
            ownsLogin = false;
            clearTimeout(timer);
        } catch { reportRestoreFailure(); }
    });
    return {prepareLogin};
};
