set shell := ["zsh", "-cu"]

test:
    ./app/test.zsh

qa:
    ./qa/e2e.zsh
    ./qa/edge.zsh

build:
    ./app/build-app.zsh

# Signing and notarisation credentials are inherited from the environment.
package-release version build:
    DOPPEL_VERSION="{{version}}" DOPPEL_BUILD="{{build}}" ./script/package-release.zsh
