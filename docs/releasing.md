# Releasing Chalkwork

A release is `Chalkwork-<version>.zip` holding `Chalkwork.app`, plus `gettext-0.24.tar.gz` (the source of GNU libintl, which Chalkwork links statically inside libghostty; the LGPL requires it) and `THIRD_PARTY_NOTICES.md`. Signed with a Developer ID Application certificate and notarized, it opens with a double-click; without the certificate it's ad-hoc signed and users clear the quarantine flag (README, Install).

- `scripts/bundle.sh release` builds and assembles the app. `CHALKWORK_SIGN_IDENTITY` switches its ad-hoc signature to a distribution one: nested code first, then the app, with the hardened runtime (`--options runtime`), `scripts/Chalkwork.entitlements` and a secure timestamp.
- `scripts/notarize.sh <app> <zip>` checks the signature, zips the app, submits it with `notarytool submit --wait`, prints the notary log, staples the ticket to the app, checks it with `stapler validate` and `spctl`, and zips the stapled app.
- `.github/workflows/release.yml` does both on a `v*` tag when the signing secrets exist, and makes the ad-hoc zip otherwise. It fetches `gettext-0.24.tar.gz` from GNU (or Ghostty's identical copy) and fails unless its SHA-256 matches. It fails when the tag isn't `v` + `VERSION`. When the tag's release already exists (one made from a Mac), it publishes nothing but the libintl source and the notices.

The version lives in `VERSION`, and its notes in `CHANGELOG.md`: a release's notes are its version's section (`scripts/release-notes.sh`) above GitHub's list of merged changes, so drop `(unreleased)` from the heading when you tag it. `scripts/bundle.sh` stamps it into Info.plist (`CHALKWORK_VERSION` overrides it), and `bun scripts/gen-clients.ts` writes it into the Python and TypeScript clients' manifests and the Claude Code plugin. To bump: edit `VERSION`, run `bun scripts/gen-clients.ts`, commit.

`bundle.sh` copies `LICENSE` and `THIRD_PARTY_NOTICES.md` into `Contents/Resources`. When a package, `resources/` asset or the libghostty-spm xcframework changes, update the notices: the libghostty table follows the Ghostty commit the xcframework was built from (`ar -t` on its `libghostty.a` lists the C libraries; the fonts are the ones `src/font/embedded.zig` embeds), and the GNU libintl section's source links, checksum and relinking steps follow its gettext version, as do the tarball name and `GETTEXT_SHA256` in `release.yml`. The libintl section includes a written offer of its source, valid three years from each release.

## One-time setup

1. Enroll in the Apple Developer Program. Note the Team ID (developer.apple.com › Account › Membership details).
2. Create the **Developer ID Application** certificate (only the Account Holder can). Either:
   - Xcode › Settings › Accounts › your team › Manage Certificates… › + › Developer ID Application; or
   - Keychain Access › Certificate Assistant › Request a Certificate From a Certificate Authority… (saved to disk), then developer.apple.com › Certificates › + › Developer ID Application (G2 Sub-CA), upload the request, download the `.cer` and double-click it.

   Check: `security find-identity -v -p codesigning` lists `"Developer ID Application: <Name> (<TEAMID>)"`.
3. Store notary credentials in the keychain as the profile `chalkwork-notary`. Either an app-specific password (account.apple.com › Sign-In and Security › App-Specific Passwords):
   ```sh
   xcrun notarytool store-credentials chalkwork-notary --apple-id <apple id email> --team-id <TEAMID>
   ```
   or an App Store Connect API key (App Store Connect › Users and Access › Integrations › Team Keys › +, access Developer; the `.p8` downloads once, keep it — CI needs it too):
   ```sh
   xcrun notarytool store-credentials chalkwork-notary --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <issuer id>
   ```

## Release from this Mac

Bump `VERSION` first (above). Build into `.build/dist`, never `.build/Chalkwork.app` (the running instance); `gh release create` makes the tag, and the Release workflow it starts leaves the release alone except for re-uploading the same libintl source and notices:

```sh
export CHALKWORK_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
CHALKWORK_BUNDLE_APP="$PWD/.build/dist/Chalkwork.app" scripts/bundle.sh release
CHALKWORK_NOTARY_PROFILE=chalkwork-notary scripts/notarize.sh .build/dist/Chalkwork.app Chalkwork-0.2.1.zip
curl -fLO https://ftp.gnu.org/gnu/gettext/gettext-0.24.tar.gz
echo "c918503d593d70daf4844d175a13d816afacb667c06fba1ec9dcd5002c1518b7  gettext-0.24.tar.gz" | shasum -a 256 -c -
gh release create v0.2.1 Chalkwork-0.2.1.zip gettext-0.24.tar.gz THIRD_PARTY_NOTICES.md --title "Chalkwork 0.2.1" --notes-file <(scripts/release-notes.sh 0.2.1) --generate-notes
```

The first `codesign` asks for the key: choose Always Allow. Notarization usually takes a few minutes. `notarize.sh` fails on an Invalid submission and prints the log that says why. It ends with `spctl` saying `accepted, source=Notarized Developer ID`.

## Release from CI

Add these repository secrets (Settings › Secrets and variables › Actions, or `gh secret set`), bump `VERSION`, then push a `v*` tag:

| Secret | Value |
| --- | --- |
| `CHALKWORK_CERT_P12` | Keychain Access › My Certificates › the Developer ID Application certificate (with its key) › Export… as `.p12`, then `base64 -i cert.p12 \| gh secret set CHALKWORK_CERT_P12` |
| `CHALKWORK_CERT_PASSWORD` | the `.p12` export password |
| `CHALKWORK_NOTARY_KEY` | `base64 -i AuthKey_<KEYID>.p8 \| gh secret set CHALKWORK_NOTARY_KEY` |
| `CHALKWORK_NOTARY_KEY_ID` | `<KEYID>` |
| `CHALKWORK_NOTARY_ISSUER` | the issuer id shown above the keys in App Store Connect |

CI notarizes with the API key, not the app-specific password. Without `CHALKWORK_CERT_P12` and `CHALKWORK_NOTARY_KEY` the workflow publishes an ad-hoc zip as before. Delete the exported `.p12` after uploading it.

### Renamed from Canvas

The secrets, the keychain profile and the repository were set up under Canvas's name. Before the first Chalkwork release (one-time):

- Add the five secrets above under their `CHALKWORK_` names (same values as the `CANVAS_` ones, which the workflow no longer reads), then delete the `CANVAS_` ones. Until they exist, a tag publishes an ad-hoc zip.
- Store the notary credentials again as `chalkwork-notary` (One-time setup, step 3), or keep the old profile with `CHALKWORK_NOTARY_PROFILE=canvas-notary`.
- The repository is still `github.com/twaldin/canvas`. When it moves, change its links in `README.md` (three), `SECURITY.md` and `THIRD_PARTY_NOTICES.md` (two); GitHub redirects the old URLs meanwhile.

After the first notarized release, drop step 2 of the README's Install section (clearing the quarantine flag).

## Entitlements

Chalkwork needs no hardened-runtime exception (JIT, unsigned memory, library validation): libghostty and tree-sitter are linked in, WebKit's JIT runs in its own process, and the JavaScriptCore context behind `browser.eval` only parses. Subprocesses (zmx, shells, git, language servers, python3, bun) inherit no entitlements.

They do inherit TCC responsibility: macOS attributes a privacy request from anything in a terminal tile, or from a browser tile's page, to Chalkwork, and under the hardened runtime `tccd` won't ask the user unless Chalkwork has the matching entitlement. So `scripts/Chalkwork.entitlements` carries Apple Events (osascript), audio input and camera (dictation, getUserMedia), and `bundle.sh` writes the matching `NS…UsageDescription` strings into Info.plist. Contacts, calendars, photos and location are left out: a terminal program asking for them is refused without a prompt. Adding one is a key in the entitlements and a usage string in `bundle.sh`.

Try the hardened runtime without a certificate: `CHALKWORK_SIGN_IDENTITY=-` signs the same way ad hoc (no timestamp). Run it as a separate instance (docs/testing.md):

```sh
CHALKWORK_SIGN_IDENTITY=- CHALKWORK_BUNDLE_APP=/tmp/hr/Chalkwork.app scripts/bundle.sh release
CHALKWORK_DEV_HOME=/tmp/hr/home CHALKWORK_DEV_APP=/tmp/hr/Chalkwork.app scripts/dev.sh start <root>
```

`log show --last 5m --predicate 'process == "tccd" AND eventMessage CONTAINS "hardened runtime"'` shows any privacy request refused for a missing entitlement.
