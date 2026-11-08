# Brahma Connect for iOS

Native SwiftUI port of [`brahma-connect-android`](../brahma-connect-android). It talks to the
same Brahma Gateway over the same WebSocket protocol (`ws://<pc>:8765/ws`), so the PC side
needs no changes. The device registers with `platform: "ios"`.

An Android APK can't be turned into an iOS app directly: the APK holds Android bytecode built
on Android-only APIs. This project rebuilds the app in Swift against Apple's frameworks.

## Getting the .ipa

### Option A: GitHub Actions (no Mac needed)
The workflow `.github/workflows/build-ios.yml` runs on a macOS runner. It runs on every push
that touches `brahma-connect-ios/**`, on `v*` tags, and on demand (Actions tab, then
**Build iOS App (.ipa)**, then **Run workflow**). Download the `BrahmaConnect-iOS-unsigned-ipa`
artifact from the run.

The .ipa is **unsigned**. iOS will only install it after it has been signed. Sign it with your
Apple ID using a sideloading tool such as AltStore, Sideloadly or SideStore, which re-sign it at
install time. A free Apple ID gives a 7-day certificate; a paid developer account gives one year.

### Option B: build locally on a Mac
```bash
brew install xcodegen
cd brahma-connect-ios
xcodegen generate
open BrahmaConnect.xcodeproj
```
In Xcode, select the **BrahmaConnect** target, then **Signing & Capabilities**, and choose your
Team. Then either run it on a connected iPhone, or use **Product, Archive** and
**Distribute App** to export a signed .ipa (Ad Hoc, Development, or App Store / TestFlight).

Requires Xcode 15 or later. The minimum deployment target is iOS 16.

## Feature parity with Android

| Gateway action | Android | iOS |
| --- | --- | --- |
| QR pairing, manual IP, Bonjour auto-discover | ✅ | ✅ (AVFoundation, `NWBrowser`) |
| Secure credential storage | EncryptedSharedPreferences | Keychain |
| Chat with Brahma | ✅ | ✅ |
| `get_device_info`, `get_battery` | ✅ | ✅ |
| `flashlight_on` / `flashlight_off` | ✅ | ✅ |
| `open_url` | ✅ | ✅ |
| `volume_get` / `volume_set` | ✅ | ✅ (system volume slider) |
| `launch_app` | any installed package | only apps with a known URL scheme (Spotify, YouTube, WhatsApp, …) or a scheme passed directly, e.g. `spotify://` |
| `file_list` / `file_read` / `file_write` / `file_delete` | shared storage | the app's own Documents folder only (visible in the Files app) |
| `unlock_phone`, `ui_dump`, `ui_tap`, `ui_swipe`, `ui_type` | Accessibility Service | ❌ iOS doesn't let third-party apps do this. Returns `UNSUPPORTED_ON_IOS`. |
| Always-on background connection | Foreground service | ❌ iOS suspends apps in the background. The app reconnects each time it is opened. |

The holographic three.js background is loaded straight from
`../brahma-connect-android/app/src/main/assets/web_background`, so both apps share one copy.
