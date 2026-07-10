# Releasing LokalBot (Sparkle)

Practical runbook for cutting a notarized LokalBot release and publishing a
Sparkle update. The release tooling lives in `Scripts/`:

| File | Role |
| --- | --- |
| `Scripts/build_release_dmg.py` | styled installer DMG via `dmgbuild` |
| `Scripts/build_test_dmg.sh` | quick unsigned DMG for local layout checks |
| `Scripts/generate_appcast.py` | sign the DMG + render `appcast.xml` |
| `Scripts/appcast.template.xml` | Sparkle 2 feed skeleton |
| `Scripts/clean_local.sh` | wipe local build/derived/DMG artifacts |

---

## Mental model (keep this)

Two independent signing systems — never mix them:

1. **Apple signing** (`codesign` + `notarytool` + `stapler`) → lets macOS *run* the app.
2. **Sparkle signing** (Ed25519 `sign_update`) → lets installed copies *trust the update*.

Apple checks the app/DMG bytes; Sparkle checks the DMG bytes against `SUPublicEDKey`.
Because Sparkle hashes the *final* bytes, it is always the **last** step — after
notarization and stapling, with no further edits to the DMG.

---

## Current config

- Product: **LokalBot** · bundle id `me.dotenv.LokalBot` · team `3N8B4562P4`
- Xcode project `LokalBot.xcodeproj` · schemes `LokalBot` (prod), `LokalBot Dev` (dev)
- Sparkle feed (`SUFeedURL`):
  `https://github.com/stevyhacker/lokalbot/releases/latest/download/appcast.xml`
- Feed file name: **`appcast.xml`** (uploaded as a GitHub Release asset, not Pages)
- Public key (`SUPublicEDKey`):
  `R1A2lIfQ82UnkmUd12kwgpiS3tOlb6D0pVK8sKSrZdA=`

The private Sparkle key is a secret. **Never commit it.**

---

## One-time setup

### 1. Point the project at a GitHub repo

The canonical remote is `https://github.com/stevyhacker/lokalbot.git`. If you
are starting from a fresh clone or fork, set the real `owner/repo` slug anywhere
the examples below still use `OWNER/REPO`.

Create a new remote only for a fresh repository:

```sh
git remote add origin git@github.com:OWNER/REPO.git
git push -u origin main
```

### 2. Generate the Sparkle key pair (ONCE, ever)

Sparkle ships the key tools as binaries inside its SwiftPM artifact. After an
Xcode build that resolves the Sparkle package, symlink them onto your PATH:

```sh
mkdir -p ~/bin
ln -sf "$(find ~/Library/Developer/Xcode/DerivedData -name generate_keys    -type f | head -n 1)" ~/bin/sparkle-generate-keys
ln -sf "$(find ~/Library/Developer/Xcode/DerivedData -name sign_update       -type f | head -n 1)" ~/bin/sparkle-sign-update
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

> No Sparkle package resolved yet? Download a Sparkle release tarball from
> <https://github.com/sparkle-project/Sparkle/releases>; the tools are under
> its `bin/` directory (`bin/generate_keys`, `bin/sign_update`).

Generate the key and print the public half:

```sh
sparkle-generate-keys           # creates the private key in the login Keychain
sparkle-generate-keys -p        # prints the base64 SUPublicEDKey
```

Back the private key up somewhere safe (you can never regenerate a matching one):

```sh
sparkle-generate-keys -x ~/secure/LokalBot-sparkle-key.txt
```

### 3. Publish the public key in the app

Add the Sparkle Info.plist keys via `project.yml` (so xcodegen writes them into
`LokalBot.app/Contents/Info.plist`). Under `targets.LokalBot.info.properties`:

```yaml
        SUFeedURL: https://github.com/stevyhacker/lokalbot/releases/latest/download/appcast.xml
        SUPublicEDKey: R1A2lIfQ82UnkmUd12kwgpiS3tOlb6D0pVK8sKSrZdA=
        SUEnableAutomaticChecks: true        # optional: opt-in auto-update checks
```

`SUPublicEDKey` must match the private key used by `sign_update` at release time.
A mismatch makes every installed copy reject the update silently.

> Adding the Sparkle **framework** to the app (the `SPUStandardUpdaterController`
> wiring) is separate from this runbook; this document covers building, signing,
> and publishing the release artifacts.

### 4. Create the Developer ID Application certificate

For direct distribution outside the Mac App Store, create a **Developer ID
Application** certificate for team `3N8B4562P4`. The simplest route is Xcode:

1. Open Xcode → Settings → Accounts.
2. Select the Apple ID and the `Stevan Bogosavljevic` team.
3. Open **Manage Certificates…**, click `+`, and choose
   **Developer ID Application**.

Verify that the certificate and its private key are available locally:

```sh
security find-identity -p codesigning -v
```

The output must include `Developer ID Application` with team `3N8B4562P4`.
`Apple Development`, `Apple Distribution`, and `Developer ID Installer` are
different certificate types and do not replace it for this DMG flow.

For GitHub Actions, export the Developer ID Application certificate **with its
private key** from Keychain Access as a password-protected `.p12`. Never commit
the `.p12` or its password.

An App Store Connect app record and a Mac App Store provisioning profile are
not required for this direct-distribution path.

### 5. Store notarization credentials

Create an app-specific password at <https://appleid.apple.com>, then cache it as
a notarytool keychain profile so the release commands stay credential-free:

```sh
xcrun notarytool store-credentials "LokalBot-notary" \
  --apple-id "you@example.com" \
  --team-id "3N8B4562P4" \
  --password "<app-specific-password>"
```

---

## Release flow (every release)

Run from the repo root. Replace `1.0.0` / `100` with the version you are shipping.

### 1. Bump the version

Edit `LokalBot/Info.plist`:

- `CFBundleShortVersionString` → marketing version, e.g. `1.0.0`
- `CFBundleVersion` → build number, e.g. `100` (monotonic; Sparkle compares this)

Then regenerate the project:

```sh
xcodegen generate
```

### 2. Archive + export a Developer ID build

Hardened Runtime must be ON for notarization (the project default is OFF for
fast local builds), so pass it on the archive command:

```sh
xcodebuild archive \
  -project LokalBot.xcodeproj \
  -scheme LokalBot \
  -configuration Release \
  -archivePath build/LokalBot.xcarchive \
  -allowProvisioningUpdates \
  ENABLE_HARDENED_RUNTIME=YES
```

Create `build/exportOptions.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>3N8B4562P4</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
```

Export the signed app to `build/export/LokalBot.app` (the default the DMG
builder looks for):

```sh
xcodebuild -exportArchive \
  -archivePath build/LokalBot.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/exportOptions.plist
```

### 3. Notarize + staple the app

Stapling the app (not just the DMG) lets first launch succeed offline:

```sh
ditto -c -k --keepParent build/export/LokalBot.app build/LokalBot-app.zip
xcrun notarytool submit build/LokalBot-app.zip --keychain-profile "LokalBot-notary" --wait
xcrun stapler staple build/export/LokalBot.app
```

### 4. Build the styled DMG

```sh
pip3 install dmgbuild   # once per machine; pip3 install "dmgbuild[badge_icons]" for a badged volume icon
python3 Scripts/build_release_dmg.py \
  --app build/export/LokalBot.app \
  --output build/LokalBot.dmg
```

This stages `LokalBot.app` beside an `Applications` shortcut, locks the
drag-to-install icon layout, and reuses the bundle's `AppIcon.icns` as the
volume icon. Pass `--background path/to/dmg_background.png` (with an optional
sibling `@2x` for HiDPI) for custom art.

### 5. Notarize + staple the DMG

```sh
xcrun notarytool submit build/LokalBot.dmg --keychain-profile "LokalBot-notary" --wait
xcrun stapler staple build/LokalBot.dmg
```

### 6. Sparkle-sign + generate the appcast (LAST)

No edits to the DMG after this point — the signature covers these exact bytes:

```sh
python3 Scripts/generate_appcast.py \
  --archive build/LokalBot.dmg \
  --app build/export/LokalBot.app \
  --repo stevyhacker/lokalbot \
  --output build/appcast.xml
  # --ed-key-file ~/secure/LokalBot-sparkle-key.txt   # only if the key isn't in your Keychain
```

The script reads `CFBundleShortVersionString` / `CFBundleVersion` from the app,
locates `sign_update` (via `--sign-update-tool`, `$SPARKLE_BIN`, your PATH,
`xcrun`, or DerivedData), signs the DMG, and renders `appcast.xml` with the
enclosure URL `https://github.com/stevyhacker/lokalbot/releases/download/v1.0.0/LokalBot.dmg`.

The download URL's tag defaults to `v<short-version>`. If you're publishing
under a pre-release tag (step 7), pass it explicitly — e.g.
`--release-tag v1.0.0-beta` — so the enclosure points at the release the DMG
actually uploads to.

### 7. Publish the GitHub Release

Upload **both** the DMG and the appcast as release assets so the feed at
`releases/latest/download/appcast.xml` resolves:

```sh
git tag v1.0.0 && git push origin v1.0.0
gh release create v1.0.0 \
  build/LokalBot.dmg \
  build/appcast.xml \
  --title "LokalBot 1.0.0" \
  --notes "What's new in this release."
```

Pre-release tags (a hyphen suffix, e.g. `v1.0.0-beta`) are marked **Pre-release**
on GitHub and won't become "Latest"; tag without a suffix for a stable release.

- Agent runtime: no separate pi GitHub asset is published. The app downloads
  checksum-pinned Bun, then installs pi from the public npm registry using
  `LokalBot/Resources/pi/runtime/package.json` + `bun.lock`. When bumping pi,
  first verify the chosen release is at least seven days old, pin the matching
  `pi-agent-core`, `pi-ai`, and `pi-tui` overrides, regenerate the lockfile with
  the Bun version in `AgentRuntimeManifest`, and verify a clean
  `bun install --production --frozen-lockfile --ignore-scripts` before release.

---

## CI release

A tag-triggered GitHub Actions workflow (`.github/workflows/release.yml`)
automates the flow above: import the Developer ID cert into a temp keychain,
archive + export, build the DMG, notarize + staple, download the Sparkle tarball
for `sign_update`, run `generate_appcast.py`, and upload `LokalBot.dmg` +
`appcast.xml` to the Release. Required repo secrets:

- `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PWD`, `KEYCHAIN_PWD`
- `NOTARY_APPLE_ID`, `NOTARY_APPLE_TEAM_ID`, `NOTARY_APPLE_PWD`
- `SPARKLE_PRIVATE_KEY` (the base64 Ed25519 private key; written to a temp file
  and passed to `generate_appcast.py --ed-key-file`)

Set the certificate and credential secrets without pasting them into source or
shell history. `gh secret set NAME` prompts for the value securely:

```sh
base64 -i /path/to/Developer-ID-Application.p12 | \
  gh secret set MACOS_CERTIFICATE --repo stevyhacker/lokalbot
gh secret set MACOS_CERTIFICATE_PWD --repo stevyhacker/lokalbot
gh secret set KEYCHAIN_PWD --repo stevyhacker/lokalbot
gh secret set NOTARY_APPLE_ID --repo stevyhacker/lokalbot
gh secret set NOTARY_APPLE_TEAM_ID --repo stevyhacker/lokalbot --body 3N8B4562P4
gh secret set NOTARY_APPLE_PWD --repo stevyhacker/lokalbot
gh secret set SPARKLE_PRIVATE_KEY --repo stevyhacker/lokalbot
```

`NOTARY_APPLE_PWD` is an app-specific password for the Apple ID, not the
account's normal password.

CI passes `--repo "$GITHUB_REPOSITORY"`, so the `OWNER/REPO` placeholder is
resolved automatically there.

---

## Sanity checks

```sh
# Apple: app and DMG accepted by Gatekeeper
spctl -a -t exec -vv build/export/LokalBot.app
spctl -a -t open --context context:primary-signature -vv build/LokalBot.dmg

# Stapling present (offline launch)
xcrun stapler validate build/LokalBot.dmg

# Sparkle: signature verifies against the public key
sparkle-sign-update --verify "$(python3 - <<'PY'
import re,sys
print(re.search(r'edSignature="([^"]+)"', open('build/appcast.xml').read()).group(1))
PY
)" build/LokalBot.dmg

# Installer layout: mounts in icon view, app above the Applications drop target
hdiutil attach build/LokalBot.dmg
```

---

## Rules (important)

- Never lose the Sparkle private key → you can't ship a trusted update again.
- Never rotate the key casually → existing installs reject updates signed by a new key.
- Never commit the private key.
- Always Sparkle-sign **after** the final DMG exists (no edits after signing).
- Always publish `appcast.xml` **after** the Release asset exists.
- Always pass the real `owner/repo` slug when generating the appcast.

---

## Rollback

Sparkle follows the appcast, not the GitHub Releases page. To roll back, restore
the previous release's `appcast.xml` as the `latest` asset (or re-upload the prior
DMG + its appcast). Leave the bad Release in place unless there's a security
reason to delete it; pulling the asset only breaks anyone mid-download.

---

## Clean slate

```sh
bash Scripts/clean_local.sh   # removes .build, build/, *.dmg, the dmgbuild venv, and LokalBot-* DerivedData
```
