#!/bin/zsh
# Runs the menu-bar app's unit tests.
#
# `swift test` needs XCTest, which ships inside Xcode and not with the Command
# Line Tools. A machine can have Xcode installed while `xcode-select` still
# points at the Command Line Tools, and then a bare `swift test` fails to build
# with "unable to resolve module dependency: 'XCTest'" even though a usable
# toolchain is sitting right there. This finds one instead of requiring the
# global setting to be changed.
#
#   app/test.zsh [extra swift test args]

set -eu
setopt PIPE_FAIL

readonly APP_SRC="${0:A:h}"

# True when this developer directory carries XCTest for macOS.
has_xctest() {
    [[ -d "$1/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]]
}

typeset chosen=""
# An explicit DEVELOPER_DIR wins; the caller has said what they want.
if [[ -n "${DEVELOPER_DIR:-}" ]] && has_xctest "$DEVELOPER_DIR"; then
    chosen="$DEVELOPER_DIR"
fi
# Then whatever xcode-select points at, so a normal Xcode setup is untouched.
if [[ -z "$chosen" ]]; then
    typeset active=""
    active="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
    [[ -n "$active" ]] && has_xctest "$active" && chosen="$active"
fi
# Otherwise any installed Xcode, newest last so a release beats a beta only if
# it sorts later; either is fine for running unit tests.
if [[ -z "$chosen" ]]; then
    typeset candidate=""
    for candidate in /Applications/Xcode*.app(N/); do
        has_xctest "$candidate/Contents/Developer" && chosen="$candidate/Contents/Developer"
    done
fi

if [[ -z "$chosen" ]]; then
    print -u2 -r -- "app/test.zsh: no toolchain with XCTest was found."
    print -u2 -r -- "  The Command Line Tools do not include it. Install Xcode, or point"
    print -u2 -r -- "  DEVELOPER_DIR at one that has it."
    exit 1
fi

print -r -- "Toolchain: $chosen"
cd "$APP_SRC"
DEVELOPER_DIR="$chosen" swift test "$@"
