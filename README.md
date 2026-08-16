# neiro

*[日本語版はこちら](README.ja.md)*

A macOS menu bar app that plays Apple Music at each track's own sample rate,
with a parametric EQ in the path.

Music.app resamples everything to whatever rate your output device happens to
be set to, so a 96 kHz master reaches a 48 kHz DAC as 48 kHz. neiro captures
Music's audio with a Core Audio process tap, reads the track's real rate,
rebuilds its engine and the DAC at that rate, and plays it back through the
output device you choose.

The rate change happens at the start of a track — a short silence, then the
track plays from its beginning at the right rate. Mid-track it never
interrupts: a change needed by the next song waits for the track boundary.

> Development happens in a private Azure DevOps repository; this GitHub
> repository is a published mirror, updated when there is something worth
> publishing. Issues and discussion here are read — pull requests are applied
> by hand upstream, so please open an issue first for anything substantial.

## Features

- Follows the source rate per track (44.1 / 48 / 96 kHz and beyond)
- 10-band parametric EQ (RBJ biquads) with a draggable response curve and a
  live spectrum behind it
- Presets, including one bound to an output device and applied automatically
  whenever that device becomes the output
- Bypass for an instant A/B, undo/redo, and a pin that keeps the panel open
- The menu bar shows the current track, its codec, and the rate actually
  being played

Requires macOS 15 or later and Music.app. Apple Silicon and Intel.

## Install

Download the zip from [Releases](../../releases), unpack it, and move
`neiro.app` to `/Applications`.

The build is ad-hoc signed and not notarized, so macOS blocks the first
launch. To allow it, open **System Settings → Privacy & Security**, scroll
down to Security, and press **Open Anyway** next to the message about neiro.

On first run, grant two permissions when asked:

| Permission | Why |
| --- | --- |
| Screen & System Audio Recording | How a process tap reads Music's audio. neiro captures nothing but Music, and records nothing to disk. |
| Automation → Music | neiro pauses and resumes Music around a rate switch so the change is not audible mid-note. |

Because the app is ad-hoc signed its signature changes with every build, so
macOS asks for the audio permission again after an update.

## Build

```bash
brew install xcodegen
scripts/ci.sh          # generate the project, run the tests, build Release
open build/Build/Products/Release/neiro.app
```

`neiro.xcodeproj` is generated from `project.yml` and is not committed — run
`scripts/bootstrap.sh` after adding a source file. Signing uses whichever
Apple Development identity is in your keychain (override with
`DEVELOPMENT_TEAM=…`); with no identity at all the build is unsigned.

Use the Release build for listening. Debug leaves the DSP unoptimised on the
realtime thread and costs about 37% CPU.

## How it works

| | |
| --- | --- |
| Capture | `CATapDescription(stereoMixdownOfProcesses:)` on Music's audio process, muted at the source so you never hear it twice |
| Playback | tap and output device combined in one private aggregate device, with drift compensation |
| DSP | cascaded RBJ biquads on the HAL's realtime thread, coefficients published lock-free |
| Rate detection | Music exposes the source rate through no API, so neiro reads the decoder lines from its unified log |

[SPEC.md](SPEC.md) covers the architecture and the rate-switch policy;
[KNOWLEDGE.md](KNOWLEDGE.md) collects what went wrong on the way — Core Audio
restart loops, AppleScript blocking forever, menu bar dead ends. Both are
written in Japanese.

## Why it exists

[MusEQ](https://museq-app.com) does this commercially and does it well. neiro
is a from-scratch take on the same idea, built to understand the problem. The
name is 音色 (*neiro*), "timbre".

## License

MIT — see [LICENSE](LICENSE). The app icon and the name are the author's own
work and are not part of that grant; please use your own if you fork this.

neiro is an independent project. It is not affiliated with, endorsed by, or
derived from MusEQ, and not affiliated with or endorsed by Apple. Apple Music,
Apple and macOS are trademarks of Apple Inc. Product names are used only to
say what this software works with and where the idea came from.
