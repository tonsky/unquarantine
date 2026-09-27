#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./script/build.sh

# INSTALL_DIR supports testing in a disposable directory; normal installs go
# into /Applications. Build as the current user, elevate only the copy if needed.
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
if [[ "$INSTALL_DIR" != /* || ! -d "$INSTALL_DIR" ]]; then
    echo "INSTALL_DIR must be an existing absolute directory: $INSTALL_DIR" >&2
    exit 1
fi
DESTINATION="$INSTALL_DIR/Unquarantine.app"
if [[ -L "$DESTINATION" ]]; then
    echo "Refusing to replace a symbolic link: $DESTINATION" >&2
    exit 1
fi

run_install() {
    if [[ -w "$INSTALL_DIR" ]]; then
        "$@"
    else
        sudo "$@"
    fi
}
STAGING="$(run_install /usr/bin/mktemp -d "$INSTALL_DIR/.unquarantine-install.XXXXXX")"
MOVED_PREVIOUS=0
INSTALLED=0
cleanup() {
    # Restore the previous installation if replacing it failed partway through.
    if [[ "$MOVED_PREVIOUS" == 1 && "$INSTALLED" == 0 ]]; then
        run_install /bin/mv "$STAGING/previous.app" "$DESTINATION"
    fi
    run_install /bin/rm -rf "$STAGING"
}
trap cleanup EXIT

run_install /usr/bin/ditto "$PWD/build/Unquarantine.app" "$STAGING/Unquarantine.app"
run_install /usr/bin/codesign --verify --strict "$STAGING/Unquarantine.app"
if [[ -e "$DESTINATION" ]]; then
    run_install /bin/mv "$DESTINATION" "$STAGING/previous.app"
    MOVED_PREVIOUS=1
fi
run_install /bin/mv "$STAGING/Unquarantine.app" "$DESTINATION"
INSTALLED=1
echo "Installed $DESTINATION"
echo "Quit any running copy, then open the installed app."
