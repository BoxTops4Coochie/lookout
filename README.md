# Lookout

Native iOS client for [Frigate NVR](https://frigate.video) — live cameras,
24/7 review timeline, and server-side clip exports. Built for LAN/VPN use
with self-signed HTTPS (first-run certificate pinning).

**Requires iOS 17+. Targets Frigate 0.16 / 0.17 (verified against 0.17.2).**

## Features

- **Live** — camera grid, full-screen detail, PTZ control pad (via Frigate
  ONVIF command socket), sub-second WebRTC with automatic fallback to RTSP,
  HLS, and JPEG stills
- **History** — web-UI-style full-day review timeline: recording-density
  bars, motion waveform ticks, detection bars, zoom, drag-to-scrub with
  gap-aware seeking, tap-to-mark export ranges
- **Exports** — 1×–100× speed (native 25× timelapse + lossless on-device
  time-warp), custom timeframes, play / Share / Save to Photos
- **Detections** — event grid with camera & type filters, clip playback,
  snapshot viewer
- **Self-signed friendly** — explicit certificate trust with SHA-256 pinning;
  works over LAN or WireGuard/VPN
- **Private by design** — connects only to your Frigate server, collects no
  data, passwords live in the Keychain

## Build it

This repo uses [XcodeGen](https://github.com/yonaskolb/XcodeGen): the Xcode
project is generated from `project.yml`.

```sh
brew install xcodegen
xcodegen generate
open Lookout.xcodeproj
```

Then set your development team in Xcode and run on a device.

### Unsigned CI build (sideload with Sideloadly, no paid account)

The included GitHub Actions workflow (*Sideload Build*) produces an unsigned
arm64 `.ipa` on a `macos-26` runner — re-sign locally with Sideloadly using a
free Apple ID (7-day cert).

### App Store

Set `DEVELOPMENT_TEAM` in your project and archive from Xcode, or script
signing with `fastlane` + an App Store Connect API key on CI.

## Architecture notes

| Concern | Route |
|---|---|
| Auth | `POST /api/login` (JSON), cookie session |
| Live video | WebRTC `wss:///live/webrtc/api/ws?src=` → RTSP `:8554` → HLS → `latest.jpg` |
| Review video | nginx-vod `/vod/clip/{cam}/start/{ts}/end/{ts}/master.m3u8` (≤1–3 h windows) |
| Timeline data | `GET /api/{cam}/recordings` (per-segment `motion` 0–100) |
| Events | `GET /api/events` |
| Exports | `POST /api/export/{cam}/start/../end/../` (needs JSON body + content-type) |
| PTZ | WS `/ws`, topic `<cam>/ptz` |

## Privacy

No analytics, no accounts, no third-party servers. Everything you see stays
between your phone and your Frigate box. See
`Lookout/Resources/PrivacyInfo.xcprivacy`.

## License

MIT — see [LICENSE](LICENSE).
