# musicunderstanding-probe

A throwaway CI probe for Apple's Music Understanding framework (iOS 27 / Xcode 27).

Three questions:

1. **Simulator support** — does the framework run inside the iOS 27 Simulator, or is it device-only?
2. **Speed** — wall-clock analysis time per 3–5 minute track on CI hardware (a proxy, not a device promise).
3. **Structure quality** — do detected section boundaries line up with cross-signal shifts (loudness, pace, instrument entries)? And does the structure result carry semantic labels, or bare time ranges?

## Layout

- `.github/workflows/api-surface.yml` — dumps the framework's public API surface out of the SDK.
- `.github/workflows/probe.yml` — builds and runs the analysis harness on host + simulator.
- `Sources/` — a small Swift harness.

## Audio

No audio is stored in this repository. The test tracks are Creative Commons licensed and are
downloaded by URL at CI time (see `tracks.txt`), analysed, and discarded with the runner.
Nothing is redistributed and nothing is modified for redistribution.

Attribution:

- Distromacy, "Theory Of Lies And Confusion" — CC BY-NC-ND 3.0, via Jamendo
- ZWITS, "Future Dreams" — CC BY-NC-ND 3.0, via Jamendo
- Soundway, "This feelin again" — CC BY-NC-ND 3.0, via Jamendo
- Josh Woodward, "Shot Down" — CC BY 3.0, via Jamendo
- Broke For Free, "Something Elated" — CC BY 3.0 US, via Free Music Archive
