#!/bin/sh
# Notarize a Developer ID-signed Chalkwork.app (scripts/bundle.sh with CHALKWORK_SIGN_IDENTITY), staple
# the ticket to it, and zip it for distribution. Usage: scripts/notarize.sh <Chalkwork.app> <out.zip>
# Credentials (docs/releasing.md), one of:
#   CHALKWORK_NOTARY_PROFILE   a keychain profile from `xcrun notarytool store-credentials`
#   CHALKWORK_NOTARY_KEY, CHALKWORK_NOTARY_KEY_ID, CHALKWORK_NOTARY_ISSUER
#                           an App Store Connect API key: the .p8 file's path, its key id, issuer id
set -eu
app="${1:?usage: scripts/notarize.sh <Chalkwork.app> <out.zip>}"
out="${2:?usage: scripts/notarize.sh <Chalkwork.app> <out.zip>}"
if [ -n "${CHALKWORK_NOTARY_PROFILE:-}" ]; then
  set -- --keychain-profile "$CHALKWORK_NOTARY_PROFILE"
elif [ -n "${CHALKWORK_NOTARY_KEY:-}" ]; then
  set -- --key "$CHALKWORK_NOTARY_KEY" --key-id "${CHALKWORK_NOTARY_KEY_ID:?CHALKWORK_NOTARY_KEY_ID}" --issuer "${CHALKWORK_NOTARY_ISSUER:?CHALKWORK_NOTARY_ISSUER}"
else
  echo "notarize.sh: set CHALKWORK_NOTARY_PROFILE, or CHALKWORK_NOTARY_KEY with _KEY_ID and _ISSUER" >&2
  exit 2
fi
# The notary service rejects ad-hoc signatures, a missing hardened runtime or timestamp; say so
# before uploading.
codesign --verify --deep --strict "$app"
details="$(codesign -dvv "$app" 2>&1)"
case "$details" in *"Authority=Developer ID Application"*) ;; *)
  echo "notarize.sh: $app is not signed with a Developer ID Application identity (CHALKWORK_SIGN_IDENTITY)" >&2
  exit 1 ;;
esac
case "$details" in *"runtime)"*) ;; *)
  echo "notarize.sh: $app is not signed with the hardened runtime" >&2
  exit 1 ;;
esac
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The service takes a zip of the app, not the app; the ticket is stapled to the app afterwards.
# No resource forks, extended attributes or ACLs: a signed bundle carries none that matter, and
# ditto would store them as AppleDouble `._*` entries beside every file.
ditto -c -k --norsrc --noextattr --noacl --keepParent "$app" "$work/upload.zip"
# An Invalid submission may exit non-zero; its log says why, so read the verdict from the JSON.
xcrun notarytool submit "$work/upload.zip" "$@" --wait --output-format json > "$work/submit.json" || true
id="$(plutil -extract id raw "$work/submit.json")" || { cat "$work/submit.json" >&2; exit 1; }
status="$(plutil -extract status raw "$work/submit.json")"
# The log lists every issue, including warnings on an accepted submission.
xcrun notarytool log "$id" "$@" "$work/log.json" >/dev/null && cat "$work/log.json" >&2
[ "$status" = Accepted ] || { echo "notarize.sh: submission $id is $status" >&2; exit 1; }
xcrun stapler staple "$app"
xcrun stapler validate "$app"
# Gatekeeper's verdict on the stapled app: "accepted, source=Notarized Developer ID".
spctl --assess --type execute -vv "$app"
rm -f "$out"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$app" "$out"
echo "$out"
