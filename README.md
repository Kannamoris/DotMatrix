# DotMatrix

A Game Boy Advance emulator for iOS, written in Swift. You supply your own
cartridge image; the app ships no game data and no BIOS.

This build is locked to Pokémon Emerald — it checks the header game code
(`BPEE`) on import and rejects anything else. That restriction lives entirely in
`ROMLibrary.requireEmerald`; the emulator core itself is general-purpose GBA.

## Status

**Nothing here has been compiled.** It was written on a Linux machine with no
Swift toolchain, so expect a round of build errors on first open. Treat the
first successful build as the starting point, not the finish line.

An emulator also isn't trustworthy until it's been run against test ROMs. Before
believing any of this, run the standard ARM and timing suites (`armwrestler`,
`FuzzARM`, `gba-suite`) — they will find CPU bugs far faster than a game will.

## Building

Requires **Xcode 16 or later** — the project uses file-system-synchronized
groups (`objectVersion = 77`), so files added to `DotMatrix/` are picked up
without editing the project.

```
open DotMatrix.xcodeproj
```

Set your development team on the target, then build to a device. The Simulator
works but is slower than hardware for this workload.

Debug builds compile Swift at `-O` deliberately. An interpreted CPU core at
`-Onone` runs at single-digit frames per second, which makes debugging anything
above the CPU level impossible.

## Building without a Mac

`.github/workflows/build.yml` builds the app on a GitHub-hosted macOS runner on
every push, so a Mac isn't needed to compile.

The build is **unsigned** — CI has no certificate, and compiling is the point.
Each successful run uploads two artifacts:

- `build-log` — the full `xcodebuild` output
- `DotMatrix-unsigned-ipa` — the app bundle wrapped as an `.ipa`

The job summary lists every error and warning grouped by file, so you can work
through build failures from the run page without downloading the log.

To get an unsigned IPA onto a device, use a sideloader that signs on-device —
[SideStore](https://sidestore.io) or AltStore. A free Apple ID works; apps
signed that way expire after seven days and need refreshing. Signing in CI
instead would need a paid developer account and its certificate stored as a
repository secret.

## Loading a cartridge

Tap **+** and pick a `.gba` file, or drop one into the DotMatrix folder in the
Files app. Saves are written next to it as plain `.sav`, the same layout desktop
emulators use, so you can move a save between them.

Dump the cartridge you own. Downloading a ROM of a game you don't have a copy of
is illegal in most countries.

## Architecture

```
Core/
  EmulatorCore.swift        Protocol the UI talks to; the console is swappable
  GBA/
    ARM7TDMI.swift          Registers, mode banking, exceptions, barrel shifter
    ARMInstructions.swift   32-bit instruction set
    ThumbInstructions.swift 16-bit instruction set
    GBABus.swift            Memory map, wait states, I/O, DMA, BIOS calls
    GBAPPU.swift            Video modes 0-5, sprites, windows, blending
    GBAAPU.swift            Direct Sound FIFOs + four PSG channels
    GBAPeripherals.swift    Interrupts, timers, DMA controller
    GBACartridge.swift      Header parsing, save-type detection, flash chip
    GBASystem.swift         Wires it together, conforms to EmulatorCore
Services/
  EmulatorSession.swift     Emulation thread, paced by the audio queue
  Renderer.swift            Metal; uploads the framebuffer each display frame
  AudioEngine.swift         AVAudioSourceNode pulling from the APU ring buffer
  SaveManager.swift         Battery-backed save persistence
  ROMLibrary.swift          Import, validation, on-disk collection
App/
  GamepadView.swift         UIKit multitouch controls
  MetalDisplayView.swift    MTKView host
  ...                       SwiftUI screens
```

Two design decisions worth knowing:

**Timing comes from the memory bus.** Every CPU access calls into the bus, which
advances the PPU, APU, timers and DMA. There's no separate scheduler to keep in
sync, and instructions that burn internal cycles charge them explicitly.

**Emulation is paced by the audio queue, not a timer.** The emulation thread
runs ahead until roughly 30 ms of audio is buffered, then throttles. Audio is
the one clock that can't drift without being audible, so it drives everything;
video just samples the newest frame at display rate.

## No BIOS

Nintendo's BIOS image is copyrighted and isn't included. Two things stand in
for it:

- **SWI calls are implemented directly** (`GBABus.handleSWI`) — the arithmetic
  routines, `CpuSet`/`CpuFastSet`, and the LZ77, RLE and Huffman decompressors.
  Emerald stores most of its graphics compressed, so nothing renders without
  at least LZ77.
- **A small IRQ dispatcher is synthesized** at the hardware's interrupt vector
  (`installSyntheticBIOS`) — six ARM instructions that save scratch registers
  and jump through the handler pointer the game leaves at `0x03007FFC`. Written
  here from the documented behaviour, not extracted.

## Known gaps

- **Save states.** Not implemented. The highest-value next addition.
- **EEPROM.** Detected but stubbed. Emerald uses 128 KB flash, which is
  implemented; other cartridges that use EEPROM won't save.
- **Link cable.** No serial emulation, so trading and battling are out.
- **Prefetch buffer.** ROM wait states are modelled per region but the
  prefetch unit isn't, so timing runs slightly fast in ROM-heavy code.
- **Cycle granularity.** Instruction-level, not sub-instruction. Scanline
  rendering happens at HBlank, so mid-scanline register changes are missed.
- **Solar sensor / RTC.** Emerald's cartridge has a real-time clock used for
  berry growth and tides. Not implemented; time-based events will not advance.

## Licence

The emulator source here is yours to do as you like with. It contains no
Nintendo code or assets, and none should be added to it.
