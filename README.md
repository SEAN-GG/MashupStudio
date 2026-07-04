# Mashup Studio (סטודיו מיקס)

iOS multitrack music editor for building song medleys and creative transitions:
a timeline editor with parallel lanes, per-clip volume/fades, stem-style
instrument control, BPM & key detection (Camelot + traditional), gradual tempo
and key changes, a rule-based transition assistant, and MP3/M4A/WAV export.

**UI language: Hebrew.** Native Swift/SwiftUI + AVAudioEngine, iOS 17+.

## Architecture

```
App/Sources
├── Models/       Value types: MixProject, Clip, AutomationCurve (rate/pitch ramps
│                 with exact ∫/inverse time mapping), MusicalKey (Camelot math)
├── Analysis/     vDSP FFT, waveform peaks, BPM (spectral flux + autocorrelation
│                 + DP beat tracking), key (chroma + Krumhansl profiles)
├── Engine/       PlaybackEngine: per-clip node chains (players → stem mixer →
│                 [EQ] → timePitch → mixers), host-time anchored scheduling,
│                 60 Hz automation pump; OfflineRenderer: two-pass export
├── Services/     Project store, asset library, stem job manager, transition
│                 planner, MP3 encoder (LAME, optional)
└── UI/           SwiftUI: home, timeline editor (pan/zoom/drag/trim/split),
                  stem mixer, pitch/tempo sheet, transition assistant, export
```

- **Stems**: real AI separation is behind `DEMUCS_ENABLED` (off by default; the
  integration point is `StemSeparating` in `Services/StemSeparation.swift`).
  Until then, stem faders drive a clearly-labeled approximate EQ mode.
- **MP3**: `scripts/build_lame.sh` builds LAME for iOS in CI and enables
  `import LAME` via `Configs/ThirdParty.xcconfig`. Without it the app exports
  M4A/WAV. See `LICENSES.md`.

## Building

Requires macOS + Xcode 16. The project file is generated:

```sh
brew install xcodegen
xcodegen generate
open MashupStudio.xcodeproj
```

CI (GitHub Actions):
- `CI` — unsigned device build + simulator unit tests, on every push.
- `TestFlight` — manual dispatch; archives with cloud signing (App Store
  Connect API key) and uploads. Requires secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`,
  `ASC_KEY_P8`, `APPLE_TEAM_ID`. See `docs/SETUP_TESTFLIGHT_HE.md`.
