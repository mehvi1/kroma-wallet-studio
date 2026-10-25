# Kroma Wallet Studio

Kroma has an original Mac interface and one workflow: connect an iPhone, scan a Wallet card, choose a skin, preview it, and apply it to that card.

## Download

The source repository is public, but it has no customer release yet. A downloadable Mac build is not ready until membership hosting, private skin storage, Developer ID signing, notarization, and iPhone testing are complete. Kroma currently builds for macOS 14 or newer on Apple Silicon and Intel Macs; there is no Windows build.

Preview builds are ad-hoc signed and are not notarized by Apple. This means macOS may refuse to open a downloaded copy. A public release that installs normally needs a Developer ID signature and Apple notarization; this repository does not include those credentials.

The SwiftUI interface is implemented in [`SkinStudioApp.swift`](SkinStudioApp.swift). The device communication, iOS compatibility probe, Wallet scan rules, and artwork-writing backend are adapted from [Mak5er/AirCard](https://github.com/Mak5er/AirCard). The upstream MIT license and attribution are retained in [`LICENSE`](LICENSE) and [`NOTICE.md`](NOTICE.md). The separate upstream snapshot kept locally for maintainers is not included in this repository or compiled into Kroma.

## Build locally

```sh
./build.sh
```

This creates `build/Kroma.app` and `build/Kroma.dmg`. Premium skins are never bundled in the app. To connect a build to the deployed Kroma API, set `KROMA_API_BASE_URL` to its HTTPS origin before building. If it is unset, the app clearly reports that membership is not configured and the premium library stays locked. Builds are ad-hoc signed for local testing and are not notarized for public distribution.

## Use

1. Connect the iPhone to the Mac by USB, unlock it, and trust the Mac.
2. Open Kroma and select **Scan Wallet**.
3. On the iPhone, open Wallet and tap the card to identify it.
4. Redeem a one-time Kroma activation code to load the 211 private skins. You can also choose one of eight original presets, build a three-colour palette inside Kroma, or import your own image.
5. Choose **Apply to this card** and confirm.

Card identifiers are stored locally in `~/Library/Application Support/Kroma/cards.json` with owner-only file permissions. Activation tokens and the device identifier are stored in macOS Keychain. Skin selections and the custom palette are stored in local macOS preferences; generated images are stored under `~/Library/Application Support/Kroma/SkinPresets` with owner-only permissions. Premium WebP skins download to `~/Library/Application Support/Kroma/SkinLibrary` only after an active server entitlement is checked; the folder and files use owner-only permissions. Downloaded art is locally extractable by a determined user, so membership checks control service access rather than making delivered image files impossible to copy. Kroma does not send card identifiers or Wallet data to the membership API.

## Current limits

- The app builds for macOS 14 or newer on Apple Silicon and Intel. Its iPhone/Wallet workflow has not been tested against a physical iPhone. iOS 27.0–27.0.1 is listed in the upstream compatibility range, but support on a specific phone remains unverified.
- Applying uses an iOS-version-dependent AirTraffic/Airlift path over USB. Apple updates can close it.
- Kroma does not make a rollback backup. Keep a current iPhone backup before testing a write.
- Native activation, entitlement, rate-limit, and private R2 delivery endpoints are implemented in `kroma-saas`, but production hosting is not configured or verified. The app needs an HTTPS API origin; the service needs the D1 migration, `KROMA_TOKEN_PEPPER`, a private R2 `BUCKET` binding, and the 211 files uploaded with `tools/upload-skins-to-r2.sh`.
- Cash grants are manual one-time activation codes. There is no online payment processor or automatic renewal.
- Skin files are excluded from the app bundle and Git history before publishing. The local `assets/skins/` folder is ignored by Git and remains the source for private R2 uploads.
- The repository currently has no public release. Developer ID signing, Apple notarization, physical iPhone testing, and Windows support remain unavailable.
- No claim of absolute security or universal device compatibility is made.

## Verification

The previous local build produced universal arm64 and x86_64 binaries. After the membership change, a fresh build and test run is required. The existing Python test suite covers device discovery and selection, card-reference filtering and storage permissions, and artwork-write behavior; it does not prove that applying artwork works on a physical iPhone or that production membership hosting works.
