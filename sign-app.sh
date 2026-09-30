#!/bin/bash
set -euo pipefail
SHIYI_SIGN_ROOT="$(cd "$(dirname "$0")" && pwd)"
SHIYI_SIGN_APP="${1:?Usage: sign-app.sh path-to-app}"
SHIYI_IDENTITY_FILE="$SHIYI_SIGN_ROOT/SigningIdentity.sha1"
if [ -n "${SHIYI_SIGNING_IDENTITY:-}" ]; then
  SHIYI_CERTIFICATE_HASH="$SHIYI_SIGNING_IDENTITY"
elif [ -f "$SHIYI_IDENTITY_FILE" ]; then
  SHIYI_CERTIFICATE_HASH="$(tr -d '[:space:]' < "$SHIYI_IDENTITY_FILE")"
else
  echo 'No stable signing identity configured. Configure SigningIdentity.sha1 before packaging; ad-hoc signing is intentionally disabled.' >&2
  exit 1
fi
if ! [[ "$SHIYI_CERTIFICATE_HASH" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo 'Signing identity must be a certificate SHA-1 fingerprint, not a private key or an ad-hoc identity.' >&2
  exit 1
fi
SHIYI_REQUIREMENT="identifier \"com.gonghui.shiyi\" and certificate leaf = H\"$SHIYI_CERTIFICATE_HASH\""
# Pin both the app identifier and the certificate. A new binary hash alone
# must never become a new permission identity on every build.
/usr/bin/codesign --force --sign "$SHIYI_CERTIFICATE_HASH" --timestamp=none \
  --identifier com.gonghui.shiyi --requirements "=designated => $SHIYI_REQUIREMENT" "$SHIYI_SIGN_APP"
/usr/bin/codesign --verify --deep --strict --test-requirement "=$SHIYI_REQUIREMENT" "$SHIYI_SIGN_APP"
/usr/bin/codesign --display --requirements - "$SHIYI_SIGN_APP"
