# Third-party licenses

## LAME (optional, MP3 export)
- Built by `scripts/build_lame.sh` when MP3 export is enabled.
- License: LGPL-2.0. Source: https://lame.sourceforge.io (version 3.100,
  unmodified). The app links it statically for personal/TestFlight use; if you
  distribute publicly on the App Store, review LGPL §6 obligations (offer to
  relink / provide object files) or ship MP3 disabled.

## Planned: demucs.cpp + htdemucs weights (AI stem separation)
- MIT (code) / MIT (Meta's Demucs weights). Not yet bundled; gated behind
  `DEMUCS_ENABLED`.

Everything else is first-party code (no SPM/CocoaPods dependencies).
