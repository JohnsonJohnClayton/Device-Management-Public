#!/bin/bash

# Name of the package.
NAME="zenguarddock"

# Once installed the identifier is used as the filename for a receipt files in /var/db/receipts/.
IDENTIFIER="au.com.errorfreeit.dockmaster.${NAME}"

# Package version.
VERSION="1.0"

# The User Template directory is applied to new user accounts. The dock plist placed in this directory will be copied into new accounts.
INSTALL_LOCATION="/Library/User Template/English.lproj/Library/Preferences/"

# Change into the same directory as this script.
cd "$(/usr/bin/dirname "$0")"

# Store the path containing this script.
SCRIPT_PATH="$(pwd)"

# Build the package.
/usr/bin/pkgbuild \
    --root "${SCRIPT_PATH}/payload/" \
    --install-location "$INSTALL_LOCATION" \
    --scripts "$SCRIPT_PATH/scripts/" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    "${SCRIPT_PATH}/package/${NAME}-${VERSION}.pkg"