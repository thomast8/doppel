#!/bin/zsh
# Regression check: the instance helpers must be compiled with a deployment
# target. The clone's main executable is doppel-launcher, and Launch Services
# reads its LC_BUILD_VERSION minos: a helper compiled without one inherits the
# build host's SDK minimum, and a minos newer than the user's macOS marks every
# clone launch-disabled — `open` fails with -10825 and Doppel reports "The
# Doppel engine could not be launched". A 2.3.1 helper built with the 27.2 SDK
# shipped exactly that bug.
#
# This only greps the two compile sites; `just qa` runs where a toolchain
# exists, so a build is not repeated here.

set -u
setopt PIPE_FAIL

readonly REPO_ROOT="${0:A:h:h}"

typeset -i PASSED=0 FAILED=0
pass() { print -r -- "  ✓ $1"; (( PASSED += 1 )); return 0 }
fail() { print -r -- "  ✗ $1"; (( FAILED += 1 )); return 0 }

print -r -- "Doppel helper deployment-target QA"

check() {
    local file="$1" anchor="$2" stop="$3"
    # Only the helper-compile region matters; other clang/swiftc calls in the
    # same scripts build host-only tools whose minos Launch Services never
    # consults. Fail unless every compile in that region carries an explicit
    # minimum.
    if /usr/bin/awk -v anchor="$anchor" -v stop="$stop" '
        $0 ~ anchor { inside = 1 }
        inside && $0 ~ stop { exit }
        inside && /^[[:space:]]*#/ { next }
        inside && (/\/usr\/bin\/clang/ || /\/usr\/bin\/swiftc/) && !/mmacosx-version-min/ && !/-target / {
            print FILENAME ":" FNR; bad = 1
        }
    ' "$file" | grep -q .; then
        fail "$file: every helper compile sets a deployment target" \
            "a compile without -mmacosx-version-min/-target was reintroduced"
    else
        pass "$file: every helper compile sets a deployment target"
    fi
}

check "$REPO_ROOT/bin/doppel" "compile_helpers" "^}$"
check "$REPO_ROOT/app/build-app.zsh" "Compiling instance helpers" "Drawing the app icon"

print -r -- "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
