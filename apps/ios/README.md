# RelayCode for iOS

RelayCode for iOS is a native SwiftUI development console. It controls paired
Mac coding agents, runs a downloaded coding model directly on the Apple device,
can connect to private OpenAI-compatible models, and boots an isolated
Linux/BusyBox terminal on-device. Full repository toolchains remain on the
paired Mac; the current Linux guest is a separate ephemeral workspace.

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

Local Xcode is optional for contributors. Every pull request runs
`npm run ios:verify` and the complete unsigned `xcodebuild` on GitHub's macOS
runner. Installing the app on a physical iPhone or publishing through
TestFlight still requires Apple signing.

For maintainers with an Apple Developer Program membership, the manual
**TestFlight** GitHub Actions workflow performs automatic Apple signing and
uploads an internal build without a locally configured Xcode account. Complete
the one-time setup in [`docs/testflight.md`](../../docs/testflight.md).

## Run the internal model on-device

Open the **Models** tab and download the pinned Qwen2.5-Coder 0.5B Q4_0 model
(about 429 MB). RelayCode downloads the artifact from Qwen's official pinned
revision, verifies both its exact byte count and SHA-256, excludes the
re-downloadable file from backups, and protects it with iOS file protection.

Inference runs in-process through the official pinned `llama.cpp` XCFramework.
The prompt and output do not leave the device. The first response after opening
the app takes longer because the GGUF weights must be mapped and the Metal
backend initialized. The current internal model uses a 4,096-token context and
generates at most 384 tokens per response.

## Connect an optional on-premises model

Open the **Models** tab, add the private HTTPS base URL ending in `/v1`, and use
**Check connection and models**. Ollama and LM Studio normally do not need an
API key on a trusted private network; authenticated OpenAI-compatible endpoints
can store a bearer token in device-only Keychain storage.

The app calls `GET <base-url>/models`, lets the user select or enter a model ID,
and never places the credential in the endpoint URL, web storage, or profile
JSON. The **Inference** tab defaults to the internal model and can optionally
send real `POST <base-url>/chat/completions` requests to the selected private
server.

## Run Linux on-device

The **Linux** tab boots an actual Linux 6.1.14 RISC-V kernel and Buildroot
BusyBox userland inside a small interpreter. It does not use JIT, a jailbreak,
or private APIs. The current guest has:

- 64 MB RAM;
- an ephemeral in-memory filesystem;
- an interactive UART-backed shell;
- no guest network or host-folder mount yet.

`npm run ios:prepare` downloads the pinned MIT-licensed interpreter headers and
GPL guest image, validates every SHA-256 digest, and makes the image an app
resource. `npm run ios:verify` boots that same image and requires `uname` plus a
BusyBox shell command to succeed. See
[`THIRD_PARTY_NOTICES.md`](RelayCode/Resources/THIRD_PARTY_NOTICES.md) for
source and license details.

To exercise the production inference client against a running Ollama server:

```bash
ollama pull qwen2.5-coder:0.5b
npm run ios:test:model-live
```

Override `RELAYCODE_MODEL_BASE_URL`, `RELAYCODE_MODEL_ID`, and optionally
`RELAYCODE_MODEL_TOKEN` for another OpenAI-compatible server.

To download the pinned GGUF and exercise the same in-process
`OnDeviceInferenceEngine` used by the iOS app:

```bash
npm run ios:test:on-device-model-live
```

The first run downloads about 429 MB into the ignored `artifacts/` directory.
The test validates the exact byte count and SHA-256 before requiring a real
generated marker from llama.cpp.

## Security boundary

- Pairing is stored as a generic Keychain password with
  `WhenUnlockedThisDeviceOnly` accessibility and no iCloud synchronization.
- Model endpoint credentials use separate `WhenUnlockedThisDeviceOnly`
  Keychain items. Profiles contain only a credential reference.
- The internal GGUF model is downloaded only after an explicit tap and is
  verified against a pinned SHA-256 before it can be loaded.
- Internal inference runs inside the app process; its prompts are not sent over
  the network.
- Model prompts are sent only when the user taps **Send**, directly to the
  selected endpoint.
- The Linux guest cannot access iOS files or the network in this slice.
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
the provider and pairing tests, boots Linux and executes a shell probe, links a
real arm64 iOS executable, and validates metadata and assets. `ios:build` is
the full Xcode build and requires an iOS platform runtime locally or on the
GitHub macOS runner.

Push notifications, multi-device revocation, Android Keystore support, and
background execution are not part of this slice.
