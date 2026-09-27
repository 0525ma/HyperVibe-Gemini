# HyperVibe-Gemini project guide for Claude

Read `AGENTS.md` before changing or deploying this macOS app. Keep this repository's fork as `origin` and `HOLODATA-COM/SiriRemoteForge` as `upstream`.

- Build the core with `cd SiriRemoteCore && swift test`; build the app with `cd app && ./build.sh`.
- The only live test installation is `/Applications/HyperVibe.app`. Verify its signature before replacement, preserve a rollback copy, and finish with exactly one running UI process from that path.
- The source Mac's one-time consent to ad-hoc signing does not authorize it on another Mac. Check the target's signing identity and ask the user about a changed permission/signing boundary before deployment.
- Keep API keys, authentication databases, certificates, private keys, and voice captures out of Git, logs, migration archives, and Claude project notes. Users enter API keys through HyperVibe Settings on each Mac.
- Treat build success, API-key model lookup, Bluetooth packet capture, decoded PCM, and text insertion as separate verification gates. A Gemini key can query a model while inference still fails with HTTP 402 when Prepay credit is zero.
- For Siri Remote audio, verify the PacketLogger capture service, router frame decode, HAL ring, selected `VoiceAudioCapture` source, and destination editor independently. The Mac built-in microphone is the current fallback.

Start with `README.md`, `docs/product-direction.md`, and the relevant code. Do not copy user-machine permissions or absolute paths into product defaults.
