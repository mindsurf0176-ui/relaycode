# RelayCode for iOS

RelayCode for iOS is a small SwiftUI security and lifecycle shell around the
mobile control plane. Coding agents, repositories, credentials, and command
execution remain on the paired Mac.

## Run on a device

Requirements:

- Xcode 26 or another Xcode version with the iOS 17+ SDK and an installed iOS
  platform runtime;
- XcodeGen 2.44+;
- a reachable RelayCode bridge, preferably through private Tailscale HTTPS.

```bash
npm run ios:generate
open apps/ios/RelayCode.xcodeproj
```

Select the `RelayCode` target, choose your Apple development team, replace
`com.minseo.relaycode` with a unique bundle identifier if needed, and run on an
iPhone or iPad. On the Mac, create the paste-ready pairing link:

```bash
RELAYCODE_PUBLIC_URL=https://your-mac.your-tailnet.ts.net npm run pair
```

Paste the complete link into the app. `relaycode://pair?pair=…&bridge=…` is also
accepted when opened by iOS.

## Security boundary

- Pairing is stored as a generic Keychain password with
  `WhenUnlockedThisDeviceOnly` accessibility and no iCloud synchronization.
- The token is injected into the page's runtime at document start; the native
  client does not persist it in `localStorage`.
- Remote bridge URLs require `wss://`. Plain `ws://` is accepted only for
  loopback development.
- `WKWebView` stays on the configured origin. User-tapped external links may open
  through iOS; redirects and scripted cross-origin navigation are blocked.
- Returning to the foreground triggers a reconnect request, while `/healthz`
  supplies the native offline banner.

## Verification

```bash
npm run ios:verify
npm run ios:build
```

`ios:verify` does not require a bootable Simulator: it typechecks the app, runs
the pairing parser tests, links a real arm64 iOS executable, and validates
metadata and assets. `ios:build` is the full Xcode build and requires an iOS
platform runtime installed through Xcode.

Push notifications, multi-device revocation, Android Keystore support, and
background execution are not part of this slice.
