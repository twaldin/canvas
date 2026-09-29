# Releasing Canvas

A release is `Canvas-<version>.zip` holding `Canvas.app`. Signed with a Developer ID Application certificate and notarized, it opens with a double-click; without the certificate it's ad-hoc signed and users clear the quarantine flag (README, Install).

- `scripts/bundle.sh release` builds and assembles the app. `CANVAS_SIGN_IDENTITY` switches its ad-hoc signature to a distribution one: nested code first, then the app, with the hardened runtime (`--options runtime`), `scripts/Canvas.entitlements` and a secure timestamp.
- `scripts/notarize.sh <app> <zip>` checks the signature, zips the app, submits it with `notarytool submit --wait`, prints the notary log, staples the ticket to the app, checks it with `stapler validate` and `spctl`, and zips the stapled app.
- `.github/workflows/release.yml` does both on a `v*` tag when the signing secrets exist, and makes the ad-hoc zip otherwise. It fails when the tag isn't `v` + `VERSION`, and publishes nothing when the tag's release already exists (one made from a Mac).

The version lives in `VERSION`. `scripts/bundle.sh` stamps it into Info.plist (`CANVAS_VERSION` overrides it), and `bun scripts/gen-clients.ts` writes it into the Python and TypeScript clients' manifests and the Claude Code plugin. To bump: edit `VERSION`, run `bun scripts/gen-clients.ts`, commit.

`bundle.sh` copies `LICENSE` and `THIRD_PARTY_NOTICES.md` into `Contents/Resources`. When a package, `resources/` asset or the libghostty-spm xcframework changes, update the notices: the libghostty table follows the Ghostty commit the xcframework was built from (`ar -t` on its `libghostty.a` lists the C libraries; the fonts are the ones `src/font/embedded.zig` embeds), and the GNU libintl section's source links, checksum and relinking steps follow its gettext version. The libintl section includes a written offer of its source, valid three years from each release.

## One-time setup

1. Enroll in the Apple Developer Program. Note the Team ID (developer.apple.com › Account › Membership details).
2. Create the **Developer ID Application** certificate (only the Account Holder can). Either:
   - Xcode › Settings › Accounts › your team › Manage Certificates… › + › Developer ID Application; or
   - Keychain Access › Certificate Assistant › Request a Certificate From a Certificate Authority… (saved to disk), then developer.apple.com › Certificates › + › Developer ID Application (G2 Sub-CA), upload the request, download the `.cer` and double-click it.

   Check: `security find-identity -v -p codesigning` lists `"Developer ID Application: <Name> (<TEAMID>)"`.
3. Store notary credentials in the keychain as the profile `canvas-notary`. Either an app-specific password (account.apple.com › Sign-In and Security › App-Specific Passwords):
   ```sh
   xcrun notarytool store-credentials canvas-notary --apple-id <apple id email> --team-id <TEAMID>
   ```
   or an App Store Connect API key (App Store Connect › Users and Access › Integrations › Team Keys › +, access Developer; the `.p8` downloads once, keep it — CI needs it too):
   ```sh
   xcrun notarytool store-credentials canvas-notary --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <issuer id>
   ```

## Release from this Mac

Bump `VERSION` first (above). Build into `.build/dist`, never `.build/Canvas.app` (the running instance); `gh release create` makes the tag, and the Release workflow it starts leaves the release alone:

```sh
export CANVAS_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
CANVAS_BUNDLE_APP="$PWD/.build/dist/Canvas.app" scripts/bundle.sh release
CANVAS_NOTARY_PROFILE=canvas-notary scripts/notarize.sh .build/dist/Canvas.app Canvas-0.2.1.zip
gh release create v0.2.1 Canvas-0.2.1.zip --title "Canvas 0.2.1" --generate-notes
```

The first `codesign` asks for the key: choose Always Allow. Notarization usually takes a few minutes. `notarize.sh` fails on an Invalid submission and prints the log that says why. It ends with `spctl` saying `accepted, source=Notarized Developer ID`.

## Release from CI

Add these repository secrets (Settings › Secrets and variables › Actions, or `gh secret set`), bump `VERSION`, then push a `v*` tag:

| Secret | Value |
| --- | --- |
| `CANVAS_CERT_P12` | Keychain Access › My Certificates › the Developer ID Application certificate (with its key) › Export… as `.p12`, then `base64 -i cert.p12 \| gh secret set CANVAS_CERT_P12` |
| `CANVAS_CERT_PASSWORD` | the `.p12` export password |
| `CANVAS_NOTARY_KEY` | `base64 -i AuthKey_<KEYID>.p8 \| gh secret set CANVAS_NOTARY_KEY` |
| `CANVAS_NOTARY_KEY_ID` | `<KEYID>` |
| `CANVAS_NOTARY_ISSUER` | the issuer id shown above the keys in App Store Connect |

CI notarizes with the API key, not the app-specific password. Without `CANVAS_CERT_P12` and `CANVAS_NOTARY_KEY` the workflow publishes an ad-hoc zip as before. Delete the exported `.p12` after uploading it.

After the first notarized release, drop step 2 of the README's Install section (clearing the quarantine flag).

## Entitlements

Canvas needs no hardened-runtime exception (JIT, unsigned memory, library validation): libghostty and tree-sitter are linked in, WebKit's JIT runs in its own process, and the JavaScriptCore context behind `browser.eval` only parses. Subprocesses (zmx, shells, git, language servers, python3, bun) inherit no entitlements.

They do inherit TCC responsibility: macOS attributes a privacy request from anything in a terminal tile, or from a browser tile's page, to Canvas, and under the hardened runtime `tccd` won't ask the user unless Canvas has the matching entitlement. So `scripts/Canvas.entitlements` carries Apple Events (osascript), audio input and camera (dictation, getUserMedia), and `bundle.sh` writes the matching `NS…UsageDescription` strings into Info.plist. Contacts, calendars, photos and location are left out: a terminal program asking for them is refused without a prompt. Adding one is a key in the entitlements and a usage string in `bundle.sh`.

Try the hardened runtime without a certificate: `CANVAS_SIGN_IDENTITY=-` signs the same way ad hoc (no timestamp). Run it as a separate instance (docs/testing.md):

```sh
CANVAS_SIGN_IDENTITY=- CANVAS_BUNDLE_APP=/tmp/hr/Canvas.app scripts/bundle.sh release
CANVAS_DEV_HOME=/tmp/hr/home CANVAS_DEV_APP=/tmp/hr/Canvas.app scripts/dev.sh start <root>
```

`log show --last 5m --predicate 'process == "tccd" AND eventMessage CONTAINS "hardened runtime"'` shows any privacy request refused for a missing entitlement.
