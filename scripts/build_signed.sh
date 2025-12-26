#!/usr/bin/env bash
set -euo pipefail

# Builds a signed Reminders MenuBar app so Firebase/Google Sign-In can use the keychain.
# Requires: Xcode command-line tools, a valid Apple Development certificate, and that
# you're signed into Xcode with the specified team ID.

SCHEME="${SCHEME:-Reminders MenuBar}"
CONFIGURATION="${CONFIGURATION:-Release}"
DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"
DERIVED_DATA="${DERIVED_DATA:-./build_out}"
TEAM_ID="${TEAM_ID:-J877BRYKD6}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Apple Development}"

echo "Building ${SCHEME} (${CONFIGURATION}) with signing for team ${TEAM_ID}"

exec xcodebuild \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA}" \
  -destination "${DESTINATION}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY}" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES
