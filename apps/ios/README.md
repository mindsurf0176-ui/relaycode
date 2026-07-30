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

Open the **Models** tab and choose one of four pinned artifacts:

- **Gemma 4 E4B** (about 3.66 GB) is the recommended quality model on iPhones
  with at least 7 GB of physical memory. It uses Google's mobile QAT weights,
  Metal, thinking mode, and multi-token prediction;
- **Gemma 4 E2B** (about 2.59 GB) is the fast, stable default on iPhones with
  at least 5 GB of physical memory. It keeps the same thinking and MTP path
  while using substantially less working memory;
- **Qwen2.5 Coder 3B** (about 2.10 GB) remains a smaller compatibility option;
- **Qwen2.5 Coder 1.5B** (about 1.12 GB) is the stable speed fallback on
  devices with less than 5 GB of physical memory.

All models execute entirely inside the iPhone app. RelayCode downloads the
selected artifact from a pinned official revision, verifies its exact byte count
and SHA-256, excludes the re-downloadable file from backups, and protects it
with iOS file protection.

Gemma 4 runs through Google's pinned `LiteRT-LM` Swift runtime. Its official
binary and Swift wrapper sources are checksum-verified during the build; a
small pinned patch exposes LiteRT-LM's native maximum-output-token option.
Qwen runs through the pinned `llama.cpp` XCFramework with Metal Flash
Attention, a Q8 KV cache, and unchanged-prefix reuse. The prompt and output do
not leave the device. Both paths keep the verified model resident for five idle
minutes and coalesce streamed UI updates. Automatic mode adapts context and
resource settings to physical memory, Low Power Mode, and thermal pressure.
Manual low-power, balanced, and turbo profiles plus an in-app benchmark remain
available. The maximum context is 8,192 tokens; the Gemma response budget is
1,024 tokens and the Qwen budget is 768 tokens.

The internal instruction policy is localized to the user's language and tuned
per model size. It prioritizes the latest request and explicit constraints,
requires grounded claims, neutralizes model control tokens inside pasted data,
and asks a question only when a critical input blocks progress. Gemma 4 uses
its native system role and private thinking channel; Qwen uses ChatML.
The 0.5 model-catalog migration replaces a legacy automatic 1.5B selection
once with the best Gemma tier the device can safely run. Later manual choices
are preserved.

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

- 64 MB RAM on constrained devices, or 128 MB on iPhones with at least 6 GB
  while power and thermal state allow;
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

The first run downloads the 1.5B smoke-test artifact into the ignored
`artifacts/` directory. The test validates the exact byte count and SHA-256,
requires a real generated marker from llama.cpp, and reports first-token,
prompt, and generation throughput.

Run the same full smoke test against the 3B quality artifact with:

```bash
RELAYCODE_ON_DEVICE_MODEL=quality npm run ios:test:on-device-model-live
```

To download the pinned Gemma 4 E4B artifact and exercise the same LiteRT-LM
engine, Korean prompt policy, Metal backend, and output limit used by the app:

```bash
npm run ios:test:gemma-live
```

The first run downloads about 3.66 GB into the ignored `artifacts/` directory.
It validates the exact byte count and SHA-256 and requires a real generated
marker before reporting LiteRT-LM throughput.

Use the E2B stable tier instead with:

```bash
RELAYCODE_GEMMA_MODEL=e2 npm run ios:test:gemma-live
```

## Security boundary

- Pairing is stored as a generic Keychain password with
  `WhenUnlockedThisDeviceOnly` accessibility and no iCloud synchronization.
- Model endpoint credentials use separate `WhenUnlockedThisDeviceOnly`
  Keychain items. Profiles contain only a credential reference.
- An internal model is downloaded only after an explicit tap and is
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

`ios:verify` does not require a bootable Simulator: it builds a real arm64 iOS
app, runs the provider and pairing tests, boots Linux and executes a shell
probe, and validates metadata and assets. `ios:build` runs the same complete
unsigned Xcode build locally or on the GitHub macOS runner.

Push notifications, multi-device revocation, Android Keystore support, and
background execution are not part of this slice.
