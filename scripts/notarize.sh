#!/bin/sh
# Build easl.app, sign it for distribution, notarize and staple it, and zip it (docs/releasing.md).
#
#   scripts/notarize.sh [--dry-run] <out.zip>
#
# Builds the release bundle (scripts/bundle.sh release) at EASL_BUNDLE_APP, default
# .build/dist/easl.app (never .build/easl.app, which a dev instance may be running from).
# Signs it inside out with EASL_SIGN_IDENTITY ("Developer ID Application: <Name> (<TEAMID>)",
# default: the keychain's only Developer ID Application identity), the hardened runtime,
# scripts/easl.entitlements and a secure timestamp, and checks the signature. Submits it to
# the notary service and waits, staples the ticket, zips the stapled app, and checks the zip's
# copy as a user unzips it. EASL_VERSION and EASL_BUILD set the bundle version (bundle.sh).
#
# Notary credentials, one of:
#   EASL_NOTARY_PROFILE      a keychain profile from `xcrun notarytool store-credentials`
#                                 (default: easl-notary)
#   EASL_NOTARY_KEY, EASL_NOTARY_KEY_ID, EASL_NOTARY_ISSUER
#                                 an App Store Connect API key: the .p8 file's path, key id, issuer id
#   EASL_NOTARY_APPLE_ID, EASL_NOTARY_PASSWORD, EASL_NOTARY_TEAM_ID
#                                 an Apple ID, an app-specific password and the team id
#
# --dry-run does everything that needs neither the certificate nor the notary service. Without
# EASL_SIGN_IDENTITY it signs ad hoc ("-") the same way, minus the timestamp. It checks the
# credentials when some are set (`notarytool history` uploads nothing), zips the signed app to
# <out.zip> unnotarized, and stops there. Run its bundle as a dev instance to try the hardened
# runtime (docs/releasing.md, "Hardened runtime").
set -eu
dry=
[ "${1:-}" != --dry-run ] || { dry=1; shift; }
[ $# -eq 1 ] || { echo "usage: scripts/notarize.sh [--dry-run] <out.zip>" >&2; exit 2; }
repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$1"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
app="${EASL_BUNDLE_APP:-$repo/.build/dist/easl.app}"
case "$app" in /*) ;; *) app="$PWD/$app" ;; esac
fail() { echo "notarize.sh: $*" >&2; exit 1; }
pack() { rm -f "$2"; ditto -c -k --norsrc --noextattr --noacl --keepParent "$1" "$2"; }

# Everything that can be wrong before a build is checked before it.
identity="${EASL_SIGN_IDENTITY:-}"
identities="$(security find-identity -v -p codesigning)"
if [ -z "$identity" ] && [ -n "$dry" ]; then
  identity=-
elif [ -z "$identity" ]; then
  found="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | sort -u)"
  [ -n "$found" ] || fail "no Developer ID Application identity in the keychain (docs/releasing.md, One-time setup); --dry-run signs ad hoc"
  [ "$(printf '%s\n' "$found" | wc -l)" -eq 1 ] || fail "several Developer ID Application identities; pick one with EASL_SIGN_IDENTITY: $found"
  identity="$found"
elif [ "$identity" != - ]; then
  case "$identities" in *"\"$identity\""* | *" $identity "*) ;; *)
    fail "no valid signing identity \"$identity\" in the keychain (security find-identity -v -p codesigning)" ;;
  esac
fi
[ "$identity" = - ] || [ -n "$dry" ] || case "$identity" in "Developer ID Application:"*) ;; *[!0-9A-F]*)
  fail "notarization needs a Developer ID Application identity, not \"$identity\"" ;;
esac
if [ -n "${EASL_NOTARY_KEY:-}" ]; then
  set -- --key "$EASL_NOTARY_KEY" --key-id "${EASL_NOTARY_KEY_ID:?set with EASL_NOTARY_KEY}" --issuer "${EASL_NOTARY_ISSUER:?set with EASL_NOTARY_KEY}"
elif [ -n "${EASL_NOTARY_APPLE_ID:-}" ]; then
  set -- --apple-id "$EASL_NOTARY_APPLE_ID" --password "${EASL_NOTARY_PASSWORD:?set with EASL_NOTARY_APPLE_ID}" --team-id "${EASL_NOTARY_TEAM_ID:?set with EASL_NOTARY_APPLE_ID}"
elif [ -n "${EASL_NOTARY_PROFILE:-}" ] || [ -z "$dry" ]; then
  set -- --keychain-profile "${EASL_NOTARY_PROFILE:-easl-notary}"
else
  set --
fi
if [ $# -gt 0 ]; then
  xcrun notarytool history "$@" >/dev/null || fail "notarytool can't use these credentials (no keychain profile? docs/releasing.md, One-time setup)"
else
  echo "notarize.sh: dry run without notary credentials: not checking them" >&2
fi

EASL_BUNDLE_APP="$app" "$repo/scripts/bundle.sh" release >&2

sign() {
  if [ "$identity" = - ]; then
    codesign --force --options runtime --sign - "$@"
  else
    codesign --force --options runtime --timestamp --sign "$identity" "$@"
  fi
}
# Inside out: nested code before the bundle that seals it. The executable is the only Mach-O
# today (libghostty, tree-sitter and the Swift packages are linked in; zmx, bun, git and language
# servers are the user's). A nested framework, XPC service or helper app would need signing as a
# bundle, before the app.
nested="$(find "$app/Contents" \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.appex' \) -print)"
[ -z "$nested" ] || fail "sign these nested bundles before the app: $nested"
find "$app/Contents" -depth -type f ! -path "$app/Contents/MacOS/Easl" -print | while IFS= read -r file; do
  case "$(file -b "$file")" in Mach-O*) sign "$file" ;; esac
done
sign --entitlements "$repo/scripts/easl.entitlements" "$app"

# A terminal tile imports the SDK from the bundle; that must leave the signature intact (bundle.sh).
PYTHONPATH="$app/Contents/Resources/clients/python" python3 -c 'import easl_sdk'
codesign --verify --deep --strict --verbose=2 "$app"
# What the notary service rejects, said before uploading.
details="$(codesign -dvv "$app" 2>&1)"
printf '%s\n' "$details" | grep -q '^CodeDirectory .*flags=0x[0-9a-f]*([^)]*runtime' || fail "$app is not signed with the hardened runtime"
case "$(codesign -d --entitlements - --xml "$app" 2>/dev/null)" in
  *get-task-allow*) fail "$app carries com.apple.security.get-task-allow, which notarization refuses" ;;
esac
if [ "$identity" != - ]; then
  case "$details" in *"Authority=Developer ID Application:"*) ;; *) fail "$app is not signed with a Developer ID Application identity" ;; esac
  case "$details" in *"Timestamp="*) ;; *) fail "$app has no secure timestamp" ;; esac
fi
# Gatekeeper refuses it until it's notarized ("source=Unnotarized Developer ID"; ad hoc, "no
# usable signature"): shown, not fatal.
spctl --assess --type execute -vvv "$app" 2>&1 || true

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The zip's copy as a user unzips it: the archive must keep the signature (and, notarized, the ticket).
check_zip() {
  rm -rf "$work/unzipped"
  ditto -x -k "$out" "$work/unzipped"
  codesign --verify --deep --strict "$work/unzipped/easl.app"
}
if [ -n "$dry" ]; then
  pack "$app" "$out"
  check_zip
  echo "notarize.sh: dry run: $app signed (${identity}) with the hardened runtime, zipped unnotarized to $out; nothing submitted" >&2
  echo "$out"
  exit 0
fi

# The service takes a zip of the app, not the app; the ticket is stapled to the app afterwards.
# No resource forks, extended attributes or ACLs: a signed bundle carries none that matter, and
# ditto would store them as AppleDouble `._*` entries beside every file.
pack "$app" "$work/upload.zip"
# An Invalid submission may exit non-zero; its log says why, so read the verdict from the JSON.
xcrun notarytool submit "$work/upload.zip" "$@" --wait --output-format json > "$work/submit.json" || true
id="$(plutil -extract id raw "$work/submit.json")" || { cat "$work/submit.json" >&2; exit 1; }
status="$(plutil -extract status raw "$work/submit.json")"
# The log lists every issue, including warnings on an accepted submission.
xcrun notarytool log "$id" "$@" "$work/log.json" >/dev/null && cat "$work/log.json" >&2
[ "$status" = Accepted ] || fail "submission $id is $status"
xcrun stapler staple "$app"
pack "$app" "$out"
check_zip
xcrun stapler validate "$work/unzipped/easl.app"
# Gatekeeper's verdict on what users get: "accepted", "source=Notarized Developer ID".
verdict="$(spctl --assess --type execute -vvv "$work/unzipped/easl.app" 2>&1)" || { echo "$verdict" >&2; fail "Gatekeeper rejects the notarized app"; }
echo "$verdict" >&2
case "$verdict" in *"source=Notarized Developer ID"*) ;; *) fail "Gatekeeper doesn't see the app as notarized" ;; esac
echo "$out"
