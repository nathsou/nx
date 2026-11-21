# nx: plan

nx started as a static recompilation of Metroid Dread (sections 0 to 6 below, written for it) and became an engine
for several games. Section 7 covers the multi-game layout, Animal Crossing: New Horizons, game updates and shader
prebuilding.

Goal: run *Metroid Dread* (Switch, 2021) natively on macOS (Apple Silicon, Metal) and Linux (Vulkan), then
Windows (Vulkan), by statically recompiling the game's AArch64 code to C and replacing the Switch OS, GPU API,
audio and input with host implementations. No Nintendo code or assets are ever committed or distributed: like
LASRecomp, the game code is generated and compiled on the player's machine from their own dump.

## 0. Status (2026-10-25)

**Dread 1.0.0 boots, plays its movies, reaches the title screen and the save files, plays the opening, and is
controllable in the first area on macOS (Apple Silicon, Metal).** Rendering is not right yet (see below).

Build and run (game files in `exefs/` and `romfs/` here, from `bun extract-xci.mts "Metroid Dread.xci"`):

```
python3 -m venv .venv && .venv/bin/pip install unicorn capstone lz4
make gen          # lift main, sdk, subsdk0 to C (about 25 s)
make -j10         # runtime + game library (about 2-3 min the first time)
./build/dreadrecomp .
```

Controls: any SDL gamepad (Nintendo layout by position: right face button = A, bottom = B, top = X, left = Y; L/R
shoulders, ZL/ZR triggers; in Dread B jumps and Y shoots) or the keyboard:
WASD left stick, arrow keys d-pad, K/J/L/I = A/B/X/Y, Q/E = L/R, 1/3 = ZL/ZR, Enter / Backspace = Plus / Minus,
F / keypad 0 = stick clicks, keypad 8/5/4/6 right stick. Remappable in `dreadrecomp.ini` (`bind_key_*` / `bind_pad_*`
lines); F11 toggles fullscreen. Unrecognised controllers: add an SDL mapping line to `gamecontrollerdb.txt`.

Whole-game check: `tools/checkpoints.sh <dir> [jobs] [first] [last]` boots each folder of a save-file ladder (folders
holding `profile0/*.bmssv`, e.g. the 54 1.0.0 checkpoints of github.com/ZacharyACoon/MetroidDreadSaveFiles, cloned
into the ignored build/ - player data, never committed) from a scratch copy, continues it, walks left and right and
captures frames into build/cp/<NNN>/; `tools/checkpoint_sheet.sh <dir>` puts each next to its hardware screenshot.
`LARECOMP_VPAD` drives a virtual SDL gamepad (the real controller path) in tests.

Test hooks inherited from LASRecomp: `LARECOMP_INPUT="frame:A:frames,..."` (scripted pad),
`LARECOMP_SHOT_AT=frame,...` (build/frames/), `LARECOMP_DEBUG_FRAME=n` (per-draw log and per-pass images),
`LARECOMP_SAVE_MSL=1` (translated shaders to build/msl/), `LARECOMP_NO_AUDIO=1`.

Done (phases 0 to 2, part of phase 3):
- LASRecomp's core vendored, and the Link's Awakening layer removed or stubbed (`runtime/nvn/la_leftovers.c` and the
  no-op `texpatch.h` / `recolour.h` / `screen_filter.h` still hold its dead hooks).
- Generator: `.eh_frame` FDE ranges stop ADR/ADRP-derived jump-table bases from splitting functions. Jump tables went
  from 41 to 519 resolved in `sdk` (27 to 361 in `main`) and fixed musl's `vfprintf`. All three modules lift with
  **zero unsupported instructions**, and the 400 MB of C compiles without errors.
- Three modules (`main`, `sdk`, `subsdk0` at 0x7076000000). The memory layout moved `sdk` past `main`'s 1.8 GB
  bss. SDK 11's `nn::init::Start` takes three callbacks.
- Kernel/services: "used memory" counts module images; the program id is Dread's; `audren`'s work-buffer size comes
  from its parameters (a flat 16 MB had overflowed Dread's 6 MB sound heap); the romfs marker is `system/`.
- Movies: `movie::Decoder` replaced on FFmpeg (VP9 into the game's NVN texture as NV12, sync signalled); `subsdk0`'s
  own extractor (libwebm), Buffer and MediaData run recompiled.
- NVN/Metal: the float `ClearColor` kind was garbage (an upstream bug); RGBX textures get alpha 1 through sampling
  views (Metal refuses swizzle plus render target); `BindProgram` per stage (null unbinds); partial `WriteTexels` in
  place; vertex shaders without fast math or FP contraction; depth `EQUAL` without writes is tested as biased `LEQUAL`
  (the prepass and G-buffer vertex shaders disagree in the last bits).

Graphics fixes since (commits after the first snapshot):
- **LDC's offset is signed** with an index register. Read as unsigned, every static mesh's x row came from past its
  buffer, which caused the horizontal streaks, the black near geometry and the prepass/G-buffer depth mismatch. Exact
  depth `EQUAL` and fast-math vertex shaders work again (the biased-`LEQUAL` workaround is now opt-in:
  `LARECOMP_EQUAL_LE=1`).
- TXD (sampling with explicit derivatives), AL2P and indexed vertex attribute loads, and the −16 self-branch at the
  end of code.
- Depth-only Metal pipelines for `BindProgram(null, fragment)`.
- **Shader corpus:** `make corpus` translates and compiles with Metal all 832 unique shader stages in
  `system/shd`. All pass; the GLSL translation passes with `CORPUS_ARGS=--glsl`.

Rendering now matches reference screenshots of the opening area (the Chozo statue room) and looks right in the
first caves, at the display's refresh rate (see "Frame rate" below).

**Frame rate.** The game runs at whatever rate the display refreshes: 120 fps on a 120 Hz (ProMotion) Mac, 60 on a
60 Hz display. Nothing caps it at 60: the game thread blocks only on untimed waits, and the only limit is Metal's
`nextDrawable` (the display's refresh, even with `displaySyncEnabled` off, in a window). Measured on an M4 Pro, 120 Hz:
- every present is a full world update: over 600 presented frames, 648 game functions ran exactly 600 times and none
  ran 300 times (`LARECOMP_FNPROF=5000:5600`);
- the world steps by elapsed time: Samus ran about 845 px/s at 120 fps and 833 px/s at ~68 fps
  (`LARECOMP_SIM_SLOW_FRAME_MS=11`), holding left for the same 0.55-0.58 s from the same save. The same 60 frames of
  input took her ~2.2x farther at ~68 fps (fixed steps would have given the same distance);
- the 54-checkpoint exploration runs (3 minutes each) all ran at 120 fps;
- cutscenes stay at 30 fps (paced by the movie's audio clock).
The emulated 60 Hz vsync (`runtime/hle/vi.c`) doesn't pace the game: running it at 120 Hz changed nothing.
`LARECOMP_INPUT`, `LARECOMP_SHOT_AT` and the checkpoint scripts count presented frames, so their timings assume
~120 frames a second (on a 60 Hz display they take twice as long).

Known problems, in priority order:
1. **Audio:** the I3DL2 reverb effect (audio renderer effect type 5), which NintendoWare Atk uses, isn't implemented
   (only type 4 reverb is), and nothing has been checked by ear.
2. **Whole game, not a playthrough:** all 54 checkpoints of a 1.0.0 save ladder (every area, opening to Raven Beak)
   load and run three minutes of scripted play without crashing and look right (the black rectangles outside the
   current room are the game's own). That was after fixing `setjmp`/`longjmp` (Lua's error handling) and a
   movie-player race (the dispatcher returned with an unlink pending). Boss fights, EMMI chases and cutscenes beyond
   the opening are only covered where the scripted play happened to run into them, and nobody has finished the
   game on it yet.
3. Unhandled `am` commands (logged as ok), `ectx:aw` is a logging stub, and `nfp` (amiibo) is a stub.
4. No menu or start screen yet (`runtime/ui/menu.mm` is a stub; F11 toggles fullscreen); the on-device game-code
   build (`runtime/gamebuild.c`) still knows only two modules.
5. Vulkan (Linux/Windows) hasn't been built. It shares the translator fixes but not the depth-only pipelines, and
   neither its NV12 movie upload nor its RGBX handling has been checked against the Metal changes.

## 1. What LASRecomp does (the model to follow)

[peiikai/LASRecomp](https://github.com/peiikai/LASRecomp) (MIT, created 2026-10-08, about 76k lines of runtime and
tools, beta) ships *Link's Awakening* on macOS, Windows and Linux this way. It was read at commit `9e8efeb`
(2026-10-25). Its architecture, layer by layer:

| Layer | How LASRecomp does it | Where |
|---|---|---|
| Function discovery | `.eh_frame_hdr` FDEs + defined dynsym functions + `R_AARCH64_RELATIVE` targets + every `bl` target + code addresses built by `ADR` / `ADRP+ADD`; split functions at any outside branch target until a fixpoint | `tools/gen.py`, `tools/analyze.py` |
| CPU lifting | Python lifter, one C function per guest function (`void f_<addr>(Cpu *c)`); registers and NZCV live in a `Cpu` struct; direct calls are C calls, tail branches use `musttail` | `tools/lifter.py`, `runtime/cpu.h` |
| Indirect control flow | `blr`/`br` go through `rt_dispatch` (address → function table, binary search plus a per-thread cache, always tail-called). Jump tables are resolved at generation time by single-stepping the bounds-checked lookup in Unicorn; unresolved `br` falls back to a `switch` over every instruction in the function | `tools/gen.py`, `runtime/dispatch.c` |
| FP/SIMD | On arm64 hosts: batches of the original instructions re-emitted as inline asm (bit-exact). Elsewhere: portable C lowering of all ARMv8.0 FP/AdvSIMD/crypto/CRC32 (x86 builds need AVX2+FMA) | `tools/simd_c.py`, `runtime/simd.h` |
| Atomics | `LDXR/STXR` emulated with compare-and-swap; `DMB/DSB` become `__atomic_thread_fence` | `runtime/cpu.h` |
| Memory | Guest address == host address: a 12.5 GB window reserved at `0x70_0000_0000` (fits the 39-bit guest space; avoids macOS's reserved range), so loads and stores are plain pointer accesses | `runtime/rt.h`, `runtime/main.c` |
| Modules | Loads `main` and `sdk` NSOs itself (LZ4, relocations, symbol binding); **both** are recompiled. `rtld` is not used. libc `mem*`/`str*` are swapped for host versions | `runtime/loader.c`, `runtime/hle/libc.c` |
| OS | A small Horizon kernel at the SVC level: handles, guest threads on host pthreads (256 MB host stacks), mutex/condvar/address arbitration, memory mapping, events. HIPC/CMIF IPC to host services: `sm:`, `fsp-srv` (romfs from a host folder, saves), `hid`, `audren:u`/`audout:u`, `time`, `set`, `acc`, `appletOE`, `nfp`, `pctl`, `aoc`, `apm`, `lm` | `runtime/kernel.c`, `runtime/ipc.c`, `runtime/services/` |
| Graphics | **NVN replaced at the API level**: `nvnBootstrapLoader` / `nvnDeviceGetProcAddress` hand out host stubs (~517 NVN functions). Command buffers are recorded into guest memory as compact records and replayed by Metal or Vulkan backends. An in-house Maxwell (SM5) shader translator emits MSL or GLSL→SPIR-V; shaders are translated ahead of time; ASTC decode, Tegra block-linear swizzling | `runtime/nvn/` |
| Video | `movie::` (nnMedia) API reimplemented on FFmpeg | `runtime/hle/movie.c` |
| Game changes | Per-instruction patches and runtime hooks, each checked against the original instruction word; per-version address tables keyed by the NSO build ID; host overrides of guest functions | `tools/patches.py`, `runtime/hle/`, `runtime/game_addresses/` |
| Distribution | Release builds contain no game code: the start screen runs the bundled generator and a bundled `zig cc` on the player's files to build `lasgame.*`, a shared library compiled at `-O1`, with a resumable build cache | `runtime/gamebuild.c`, `runtime/build_cache.cpp` |

Takeaways for Dread: the CPU, kernel, IPC, NVN and build-pipeline layers are game-agnostic. The game-specific parts
are `runtime/hle/*` (randomizer and features), `tools/patches.py`, the address tables, the UI and the randomizer.

## 2. What Dread looks like (measured from our dump)

Dump: base game **1.0.0** cartridge, `main` build ID `49161d9ccbc15df944d0b6278a3c446c006b0be8`, SDK 11.4.3.
Internal name *cazadora* (`…\apps\gameapp\Retail\cazadora.nss`).

| Module | Code | Functions (eh_frame) | Symbols | Notes |
|---|---|---|---|---|
| `main` | 17.96 MiB (4.71 M instructions) | 102,288 | stripped: 30 exported functions, 547 imports | **bss is 1.80 GB** (a static engine arena). 43,786 `blr`, 5,246 `br`, 11,353 exclusive loads, about 4% FP/SIMD. 2,751 static initialisers. Links NintendoWare **Atk** (audio) statically, plus an embedded Lua 5.1 VM and Box2D strings |
| `sdk` | 5.55 MiB | 29,434 | 23,099 named functions | nnSdk + NVN + libz 11.4.3 |
| `subsdk0` | 3.29 MiB | 9,844 | 8,794 named functions | NintendoSDK **movie** library 11.4.3 (video playback) |
| `rtld` | tiny | 26 | | not needed |

What `main` imports: `nn::audio` 144, `nn::os` 55, `nn::hid` 31, `nn::nfp` 26 (amiibo), `nn::fs` 22,
`movie::` 36, `nn::oe` 13, `nn::prepo` 6, `nn::account` 4, `nn::time` 4, `nn::vi` 4, plus libc and the NVN entry
points.

Comparison with what LASRecomp already handles:

- **NVN**: Dread looks up 524 NVN function names. All but 7 already appear in LASRecomp's implementation; the 7 are
  debug "checkpoint" calls that can be no-ops. Having a function by name is not the same as covering Dread's use of it,
  though (see the risks section).
- **movie::**: Dread calls a *different* set of movie functions (direct `Extractor`/`Decoder` methods) from the ones
  LASRecomp implements (virtual-method based), so none of Dread's 36 imports match. The FFmpeg approach carries over,
  but the binding layer needs writing. The videos are 101 **WebM** files (`romfs/system/video`, 130 MB).
- **Other imports**: 39 of Dread's non-NVN imports are already implemented as host functions in LASRecomp. The rest
  resolve into the recompiled `sdk`, so they work once the services under them do.

Romfs (4.1 GiB, 9,654 files):

- **Shaders**: 478 `.bshdat` files in `system/shd` (MSHD containers, 130 MB) holding precompiled Maxwell binaries,
  plus 442 `.bsmat` materials. They can be translated ahead of time by parsing MSHD instead of discovering shaders at
  draw time.
- **Scripts**: compiled Lua 5.1 (`.lc`, `LuaQ` header) using 32-bit floats as the number type. They run inside the
  recompiled game unchanged, and the VM is a good place to hook mods.
- **Assets**: 5,700 `.bctex` textures, 1,276 `.bfstm` streams plus `bfsar`/`bfgrp` (NintendoWare sound), and
  2.2 GiB of `.pkg` packs.

## 2b. Prior art found (checked 2026-10-25)

- **[Metroid-Dread-Recomp](https://github.com/yozander2009-stack/Metroid-Dread-Recomp)** (Apache-2.0; its EXE is
  GPL-3.0 because it vendors ScarletNX's renderer). Created 2026-09-15, v0.4.0 on 2026-10-24.
  - Targets 2.1.0 on **Windows and Linux only**; no macOS.
  - Design: lifts `main`, `sdk` and `subsdk0`, then emulates the GPU at the command level (OpenGL, Vulkan opt-in).
  - Open issues: no sound, crashes, QTE timing.
  - Our project is still worth doing: a macOS-first build, NVN replaced at the API level (faster), and 1.0.0
    support.
- **[nxnative](https://github.com/seedds/nxnative)** (MIT): runs Dread natively on iPhone and iPad by rewriting the
  NSO, not by recompiling it; a Mac path is documented. Its
  [Dread notes](https://github.com/seedds/nxnative/tree/main/dm/games/010093801237C000) (for 2.1.0) are a list of
  issues we will meet:
  - Heap sizing: "used memory" must count `main`'s 1.8 GB bss, or `SetHeapSize` fails.
  - Movies:
    - `movie::Decoder` runs in NVN-texture output mode.
    - The game calls the `D1` destructor directly.
    - Its `RegisterClientEvents` pointers get overwritten.
    - The movie threads crash unless posted requests are handled first, as same-core preemption would do on the
      Switch.
  - Graphics:
    - `BindProgram` binds **per stage**: a null bind unbinds only those stages. Without this the depth prepass draws
      nothing and the scene renders black.
    - 1×1 `WriteTexels` calls must write in place.
    - Inline `UpdateUniformBuffer` calls must not end the render pass.
  - Timing: cutscenes are paced by a 30 Hz sound thread, so macOS sleep slack needs a precise sleep.
  - Files: Atk stream paths contain `..`, which must resolve lexically.
  - Services: SDK 11 names (`fs::CommitSaveData`); `oe::FinishStartupLogo` and `hid::SendVibrationValues` need
    host versions.
  - Shaders: 478 files hold 1,342 stages (1,010 unique). The control sections carry NV assembly text and the SASS
    follows each code area.
- **Other Switch recomps:** ssbu-recomp/smo-recomp (GPL), nxrecomp (GPL), nxrt (Unlicense, verified on macOS
  arm64), ScarletNX (GPL), and LASRecomp's own derivatives (PokeZ-ARecomp, Android ports).
- **Modding:** [open-dread-rando](https://github.com/randovania/open-dread-rando) and its exlaunch module,
  [mercury-engine-data-structures](https://github.com/randovania/mercury-engine-data-structures) (formats), and
  DreadGhidraPlugin (reflection and Lua-binding analyzers). The community supports only 1.0.0 and 2.1.0. The 2.1.0
  `main` build ID is `646761F643AFEBB379EDD5E6A5151AF2CEF93DC1`; its `sdk` and `subsdk0` are the same builds as
  1.0.0's.

## 3. Strategy

**Build on LASRecomp's core rather than starting over.** Fork it (MIT), split it into a game-agnostic core (lifter,
generator, loader, kernel, IPC, services, NVN and backends, shader translator, platform, build pipeline) and a Dread
game layer (address tables, patches, hooks, movie bindings, UI). Since LASRecomp is two and a half weeks old and
changes daily, keep the core as a tracked vendor branch, and propose the core/game split upstream so both projects can
share fixes.

Alternatives considered and rejected:

- **Our own lifter (for example via LLVM IR or remill).** It would cost months to reach what `gen.py`, `lifter.py`
  and `simd_c.py` already do, including bit-exact SIMD on arm64 and portable SIMD on x86.
- **Emulating the GPU at the Maxwell command level** (yuzu/Ryujinx style) instead of replacing NVN. It would be more
  general but slower, and a much bigger job. LASRecomp shows that replacing NVN works for a shipped game. The
  emulators stay useful as references for shader semantics and as a source of known-good renders.
- **Reimplementing the SDK function by function** instead of recompiling `sdk` and replacing the OS underneath it. The
  SVC/IPC surface is much smaller and better documented than nnSdk's tens of thousands of functions.

Tooling stays as in LASRecomp: Python generator (Unicorn, Capstone), C/Objective-C runtime, clang or `zig cc`, SDL3,
FFmpeg. Small host-side utilities can be Bun `.mts` scripts like `extract-xci.mts`.

## 4. Phases

Each phase has an exit test. The phases are rough, not dated; graphics will take the longest.

### Phase 0: Groundwork
- `git init`; ignore `exefs/`, `romfs/`, `generated/`, `*.xci`, `*.keys`.
- Bring in LASRecomp's core and remove the Link's Awakening layer (`hle/` features, `rando`, `ui` tabs, patches,
  address tables) so it builds and links with no game code.
- Add a version table keyed by `main` build ID, starting with 1.0.0 (`49161d9c…`).
- Extend `extract-xci.mts` to apply update NSPs (BKTR patch romfs and exefs), for 2.1.0 later.
- **Exit:** the runtime builds on macOS with an empty game library.

### Phase 1: Lift the whole game
- Run the generator on `main` and `sdk`. Record the counts it reports: functions, unsupported instructions, resolved
  and unresolved jump tables, `br` fallbacks. Fix lifter gaps until there are no unsupported instructions on hot
  paths.
- Memory layout: LASRecomp puts `sdk` 64 MB after `main`. Dread's `main` needs about 1.83 GB with bss, so move the
  module bases and check the heap, alias and stack regions still fit the 39-bit window. Load three modules if
  `subsdk0` is recompiled.
- Compile at `-O1`. Measure compile time and library size: on-device builds need to stay reasonable for 4.7 M
  instructions.
- **Exit:** generated code compiles and links, and the dispatch table covers every discovered function.

### Phase 2: Boot to the first presented frame
- Run the static initialisers and `nnMain` with full logging of unknown SVCs, IPC commands and unimplemented host
  functions. Fill gaps in services; expect `fsp-srv` save creation, `hid` NPad styles, an `audren` revision for SDK
  11, `set` language and region, `appletOE` focus and performance mode, `account`, `prepo` (stub) and `nfp`
  (stub, or amiibo emulation later).
- `movie::` for Dread's API on FFmpeg, decoding the WebM videos. Alternatively recompile `subsdk0` and replace the
  lower-level multimedia service, which is harder.
- Reuse LASRecomp's debugging tools: function-entry profiler, crash explainer, page watchpoints, `LARECOMP_*`-style
  environment hooks.
- **Exit:** the game reaches its title logic and presents frames, even if they render wrongly.

### Phase 3: Graphics correctness (the critical path)
- **Shader corpus:** parse MSHD (see the mercury-engine-data-structures format notes), extract every Maxwell
  program, and run the translator over all of them offline. Required: zero translation failures, Metal compiles
  everything, and `spirv-val` passes. This finds translator gaps without having to play the game.
- **Features Link's Awakening never used:** Dread is a heavier 3D renderer (deferred-style lighting, shadow maps,
  post-processing, particles, cutscene effects, EMMI-zone effects). Audit Dread's real use of compute dispatch,
  indirect draws, image load/store and atomics, queries, conditional rendering, MSAA and resolves, texture views and
  aliasing, and formats (BCn, ASTC, R11G11B10F, depth/stencil).
- **CPU/GPU coherency:** NVN memory pools are shared between CPU and GPU. Check how Dread streams uniforms and
  vertices (persistently mapped pools), and size LASRecomp's pool-write tracking and page watches for it.
- **Reference images:** scripted positions captured on an emulator running the same version, compared against
  ours.
- **Exit:** title, menus, and the first area (Artaria) render correctly at 60 fps on an M1.

### Phase 4: Audio, input, saves, video (alongside phase 3)
- `audren`: NintendoWare Atk depends heavily on renderer effects (reverb, delay, biquad, limiters) and voice
  features. Extend LASRecomp's `audio.c` to cover them.
- Input through SDL3 (keyboard and controllers, remapping); collapse HD rumble to simple rumble.
- Saves through `fsp-srv` to a host folder, using the Switch save layout so real saves can be imported.
- **Exit:** the first two areas play through with correct sound, video and saving.

### Phase 5: Complete and stable
- A test harness of saves at checkpoints, plus scripted input, covering every area, boss, EMMI zone and cutscene.
- Performance: profile dispatch overhead (43 k `blr` sites, mostly virtual calls), hot-function optimisation, and
  thread and job-system scheduling (Dread runs work across three cores).
- **Exit:** the game can be finished on macOS without crashes or visual bugs.

### Phase 6: Platforms, versions, enhancements
- Linux and Windows on Vulkan, and x86 FP/SIMD correctness: rounding, flush-to-zero, NaN propagation. Physics and
  scripts may be sensitive to these.
- Version 2.1.0 (the latest update) through LASRecomp's version mapping (addresses mapped through identical
  functions).
- Enhancements: resolution scaling, MetalFX/FSR, widescreen and ultrawide (a 2.5D camera, so check the culling
  bounds), and shaders prepared ahead of time. (Higher frame rates: already there, see "Frame rate"; an optional cap,
  for example 60 on battery, isn't.)
- Mods: romfs overlay (LayeredFS-style), code mods through hooks, and compatibility with community randomizer
  output.

## 5. Risks

1. **Graphics depth and performance (highest).** Dread uses NVN far more heavily than Link's Awakening. Translator
   coverage, memory-pool coherency and Vulkan synchronisation are where most of the effort will go.
   *Mitigation:* the offline shader-corpus tests, the reference-image comparisons, and running Vulkan validation from
   early on.
2. **Code size.** 4.7 M instructions mean long on-device compiles and a large library. *Mitigation:* chunking, the
   build cache and `-O1` (all in LASRecomp already); measure in phase 1.
3. **Indirect control flow in a stripped binary.** `.eh_frame` gives 102 k functions, but leaf functions with no FDE,
   and vtable targets only reachable through data, can be missed. *Mitigation:* scan `.rodata`/`.data` for pointers
   into code (vtables), fail loudly on an unknown dispatch target, and treat each miss as a generator bug.
4. **Concurrency.** 11 k exclusive-access sites, and a job system across cores. Compare-and-swap emulation of the
   exclusive monitor has ABA edge cases. *Mitigation:* stress tests, and a review of the lock-free paths that keep
   showing up.
5. **Floating-point behaviour on x86.** Portable SIMD has to match the guest's FPCR behaviour. *Mitigation:* test
   on arm64 (bit-exact asm) first; differential testing of `simd.h` against the asm path.
6. **Upstream churn.** LASRecomp changes daily. *Mitigation:* the vendor branch, small local changes to the core,
   and upstreaming fixes.
7. **Legal.** Never commit or ship game code, generated C, assets or keys. Generate on the user's machine. Do not use
   leaked SDK or NVN material.

## 6. First steps

1. `git init` this folder with the ignore list above.
2. Set up a Python environment with `unicorn` and `capstone` and run LASRecomp's `analyze.py` and `gen.py` on Dread's
   `main` and `sdk` *as they are*, for real lifting statistics (unsupported instructions, jump tables). This is the
   cheapest way to find out how far the existing lifter gets.
3. Write an MSHD parser and dump shader-corpus statistics, then run LASRecomp's `translate.c` over every shader.
4. Decide fork versus vendored core with upstream in mind, then start phase 0.

## 7. Several games (nx)

### Layout
- `build/nx` is the app, shared by every game; each game's recompiled code is its own library
  (`build/<name>/game.dylib`, from `data/<name>/exefs` through `generated/<name>/`). The app scans `build/*/` for the
  library whose id matches the game files' main build ID, so several games and versions sit side by side.
- `games/<id>/` profiles (runtime/game.h): versions by main build ID, per-version address tables
  (`patches_<v>.h` for the generator, `runtime_<v>.h` for the runtime only), hooks, boot fixes and `flags`, the engine
  behaviours a game opts into (`GAME_CLEAR_SCREEN_TARGETS`: Dread's per-frame clear of screen-sized targets, which
  breaks ACNH's lazy clears). Saves, settings keys and shader caches are keyed by the profile id (`save/<id>/`,
  `cache/<id>/`).
- A game without a profile still boots: title ID from `main.npdm`, no patches.

### Animal Crossing: New Horizons (1.0.0, 2.0.7)
Engine fixes it needed, all shared:
- **Conditional rendering** (`nvnCommandBufferSetRenderEnableConditional`): agl's lazy clears depend on it. The
  counter pair at the address decides (mode 0 renders if equal, 1 if not). A cell starts armed and the counter report
  after the first clear disarms it for good: re-arming it each frame (an early guess) cleared targets the game keeps
  between frames, and the opening movie flickered black on frames without a new video frame.
- `nvnCommandBufferClearBuffer` and `nvnCommandBufferReportValue` were recorded but never executed; both write
  guest memory in command order now.
- **3D render targets**: the colour-grading LUT is drawn slice by slice (`depthPlane`), and such draws compile their
  program synchronously (an async-skipped LUT draw left the tonemap black).
- **FMZ** (`FMUL.FMZ`/`FFMA.FMZ`: 0 * anything = 0) and NaN texture coordinates sampling as 0 (Metal samples the far
  edge: a white sky).
- **Vertex streams with a stride that isn't a multiple of 4** (bone indices, 1 byte) are repacked: Metal can't read
  them, which had given spiky black geometry everywhere.
- HID touch screen, keyboard, mouse, debug pad and six-axis state reads (their shared-memory LIFOs overflowed: heap
  corruption at the name entry).
- The movie decoder decodes audio (Vorbis, Opus), writes into the game's own output buffers, and calls the guest
  outside its lock (4 s stalls).
- Time: `IStaticService` 400/401 (clock snapshots), `LARECOMP_TIME_OFFSET`.

### ACNH fixes after the first play (PR acnh-fixes)
- **Speed**: ACNH runs at 30 fps (window present interval 2) and steps per frame; presents now wait their 60 Hz
  vsync slots unless the game opts out (`GAME_UNCAPPED_FPS`: Dread). Measured: a steady 30 fps, 34-35 ms frames.
- **Black bands** over the blurred distance (depth of field) and blocky airport-wall shadows: a pass mixed a scaled
  colour target with an unflagged R8 one, and Metal draws only over the smallest attachment; such textures are
  promoted to scaled (metal.m `renderer_texture_promote_scalable`).
- **Island flag / designs scrambled**: `LINEAR_RENDER_TARGET` (0x40) textures are pitch-linear, rows packed.
- **Dark sea**: the sky panorama the water reflects samples `agl::env::CubeMap`, a cube array, as a cube: views now.
- **Compute shared memory** (`LDS` / `STS`): a lighting kernel never translated.
- Draws into targets not drawn the frame before (one-shot renders) wait for their shaders instead of being skipped.
- Audio renderer effects ported from Ryujinx: I3DL2 reverb (5: rooms, ACNH and Dread), delay (3), biquad filter (6).
  Its Cos / Sin take degrees and its Pow10 clamps (radians made the reverb's feedback network diverge: NaN after
  ~50 s of Dread); a non-finite state resets the effect. Aux (2, Ryujinx's AuxiliaryBufferCommand): the mix goes to
  the game through the send buffer's ring and comes back from the return buffer's (ACNH taps its 6-channel final mix
  this way and returns it unchanged; before, the output buffers weren't written).
- Known, not done:
  an 8x8x8 3D texture left bound to a 2D slot of a UI shader reads the dummy (undefined on the Switch too).
- Testing aids: `LARECOMP_HIDDEN=1 LARECOMP_DISPLAY_SYNC=0 LARECOMP_UNCAPPED=1` runs the intro at 120 fps off screen;
  `LARECOMP_LIVE=<dir>` steers a running game (lines appended to `<dir>/cmd`: `A 6`, `STICK_UP 300`, `wait 60`,
  `shot name`; holds run one after another, `+NAME n` together with the previous one). A new game's island is random
  (its randomness is time-based too), so scripts can't navigate one: tests start from saves instead.
- Saves made elsewhere: each resident is tied to the account that made it (main.dat keeps 8 slots of 0x48 bytes:
  account ID, island and player identity; `tools/acnh_save.py` decrypts a save, the NHSE scheme, and prints them).
  `LARECOMP_USER_ID` makes our one account that one; without it the game moves a new resident in. Loading a save from
  an older version, the game asks to upgrade it and commits every mount together through fsp-srv's
  OpenMultiCommitManager (1200, now implemented); then a loaded resident asks for the controller's colours
  (`nn::hid::GetNpadControllerColor`, HLE: the SDK aborted on the unset attribute). Checked with a public April 2020
  save (ericlewis/acnh-save-backups, 1.1-era) on 2.0.7: upgrade, island, house, Nook's Cranny, Resident Services,
  the Nook Stop terminal, the airport and a Nook Miles Ticket flight to a mystery island, night time, Save and end,
  and the saved game loading again. `tools/acnh_saves.sh` repeats the boot, a walk, the phone and the pockets, day and
  night, for a folder of saves.
- Frame generation (`frame_generation = 60 | 120` in nx.ini, `LARECOMP_FRAMEGEN`): ACNH steps its world once per
  frame at 30 fps, so a real 60 fps needs every per-frame amount rescaled (a community mod does it for 3.0.x with
  ~6,400 code patches and 1,437 parameter values). Instead, runtime/nvn/framegen.m makes images between the game's
  frames: a quarter-size luminance pyramid of each frame, coarse-to-fine block-matching flow both ways (5x5 patches,
  a bias to no motion so the HUD stays put, a 3x3 median), then each in-between image samples both frames along the
  flows (Super SloMo's approximation) and blends them by time and forward-backward consistency; a large average match
  error (a cut) shows the nearer frame instead. metal.m's present is now a layout step plus one present per image,
  scheduled a display frame apart (the real frame keeps its old deadline). Capped at the display's refresh rate
  (NSScreen.maximumFramesPerSecond); off when the game runs uncapped (Dread). Checked: 30 game / 60 shown fps, even
  quarter steps of a pan at 4 images per frame (LARECOMP_FG_SHOTS saves them). Not checked on a visible display yet
  (LARECOMP_LOG_SHOWN=1 logs the real on-screen intervals).
- Output resolution and window textures: the scaler picks screen-sized render targets by NVN's compressible flag
  (0x8); ACNH's window textures have none, so its scene rendered at 4K was composited with the HUD into 1080p window
  images (and scaled up again to the window). Textures given to an NVN window now carry a host-only flag
  (NVN_TEX_HOST_WINDOW) and are scaled too: `resolution = 2x` gives a real 3840x2160 image (30 fps on an M4 Pro,
  frame generation and camera photos included).
- Render thread: every draw copied its bound uniform buffers into the ring (indexed ones whole, up to 64 KB). ACNH
  records each draw as its own small command list and binds the same 40 KB buffer to all of them: 55 MB copied a
  frame, a new 64 MB ring every ~15 ms, a quarter of the render thread. renderer.m's snap_reuse shares a snapshot
  until a command writes its range (uniform updates, counter reports, buffer clears and copies) or may write anywhere
  (dispatches, fences, a new list). ACNH uncapped on an M4 Pro: 77 -> 115 fps at 1440p, 98 fps at 4K
  (LARECOMP_SNAP_VERIFY=1 compares each shared snapshot with memory: 0 of 204 M differ). A first version missed
  writes that grew a range already logged (a write next to the last one extends it): the intro's depth of field read
  the previous pass's constants, its blur sampled one texel and the wall behind Timmy and Tommy came out flat dark
  grey, posters gone - each range now carries the write count when it last grew. ACNH draws no motion vectors (one color
  target and depth for its scene), which MetalFX's frame interpolator and temporal scaler would need.
- Motion vectors and MetalFX frame interpolation (runtime/nvn/motion.m, framegen.m; `frame_generation_method =
  metalfx`, the default at 60): each program gets a variant whose vertex shader is the translated one as a function,
  called with this frame's constant buffers and with the previous frame's copy of the same draw's (from one history
  buffer, two free vertex buffer slots), and whose fragment shader writes the uv offset between the two positions to
  colour attachment 7 (RG16Float) of the passes drawing with the scene's depth buffer - the frame before's with the
  most depth-writing draws x pixels (ACNH's minimap, 386x386, has more draws than its view). Depth-writing draws
  write it (ACNH: a depth prepass, then shading with EQUAL). Matching draws across frames: ACNH double-buffers its
  uniform buffers (a draw alternates between two addresses) and draws the terrain's chunks with one mesh, so the
  previous frame's draw is the one of the same shaders, mesh and range with the most uniform buffers of equal
  contents (512-byte hashes: the world matrix of anything standing still), unmatched first. ~1,000 such draws a
  frame, 99.9% matched. Checked by reprojection: frame N-1 warped by N's vectors on a camera pan, mean error 13.6 ->
  2.3 (of 255); the character's limbs, the trees' wind sway and the camera all move right. Not covered: the sky
  (no depth writes: no motion), shadows (they move with the ground under them), transparent effects.
  The HUD: MetalFX moved it with the scene under it. A UI layer (RGBA16Float, coverage in alpha) is attached to the
  passes into screen-sized images without depth; a full-screen opaque draw into a screen-sized image (ACNH's scene
  composite into DTA[0] - in a pass that still has the scene's depth) takes it, empty, and a copy of its owner (into
  the window image) keeps it; blended draws into the owner write their alpha to it too. The owner is also copied
  before its first HUD pass: where the finished image differs from that copy is HUD as well (the clock's soft shadow
  leaves alpha alone). MetalFX gets the shown image's colours, premultiplied, with that coverage feathered over two
  pixels (no seam between the HUD's surroundings and the in-between image) - not the layer's colours: DTA[0] is
  RGB10A2 (two bits of alpha) and the copy to the window changes the colours. uiTextureComposited off (on, MetalFX
  on macOS 27.0 gave black images). One in-between image only: 120 stays
  on the optical flow. Cost: uncapped 115 -> ~109 fps for the vectors; the in-between image's command buffer ~5.5 ms
  of GPU span against ~9 ms for the flow (2560x1440, M4 Pro).
- Typing in ACNH's text entry (runtime/hle/input.c): nn::hid::GetKeyboardState answered "no keyboard". ACNH reads
  a USB keyboard for its on-screen keyboard, polling it from a call site of its own (besides one polling every
  frame): while that one polls, the keys that type are reported as a connected keyboard's (the SDK's 0x30-byte
  KeyboardState: modifiers, attributes - connected -, keys by USB usage = SDL scancode) and stop pressing their bound
  buttons; a key pressed and released between two polls still types.
- Audio (runtime/services/audio.c): crackling - ACNH's whole mix goes through an Aux effect, the game's own
  processing by its audio thread each 5 ms frame. That thread came every 10 to 34 ms: it waited for a mutex its sound
  thread (priority 45, core 1) held, which waited for its core, held by the presenting thread (priority 30) asleep in
  present_wait for frame pacing. The 5-frame Aux rings ran over; blocks came back part rewritten (a click every few
  ms: 1,898 in 30 s). present_wait gives the core up while it sleeps (a kernel wait on the Switch): every 5.0 ms,
  7 clicks. Splitters (ACNH: 6, 19 destinations) are routed (Ryujinx's SplitterContext; 2.0.7's layout: splitters
  0x1C + 4n bytes, destinations 0x70 with the mix at 0x68, used at 0x6C). Not done: priority inheritance for
  mutexes (Horizon has it; not needed for this once the core was free).

- Camera photos: the camera app renders the photo into a linear render target (NVN_TEX_LINEAR, 1280x720) and passes
  that memory to caps:su's SaveScreenShotEx1 (205). The Metal backend now copies linear targets drawn or copied into
  back to guest memory after each list (or at a fence inside one), and waits for the GPU when the target isn't one
  drawn every frame (the game reads the photo without a fence that holds the copy). caps:su writes the image as a PNG
  to `save/<game>/album/` (before: a stub, and the memory held whatever was there before).

### Generator
- Jump tables whose bounds check sits far above the `br` (compilers schedule the per-case register setup in between:
  29 instructions in ACNH 2.0.7) are found within `JT_WINDOW` (48) straight-line instructions instead of 16. Before,
  such a `br` fell back to the function dispatch and stopped the game at boot ("no function at ...").

### Updates
`extract.mts --update <update.nsp>` takes the update's exefs and applies its romfs patch: the BKTR section, an
indirect storage mapping the patched romfs onto the base romfs and the update's own data, that data AES-CTR-Ex
encrypted with a per-subsection generation in the counter. A new version needs a `GA_VERSION` line and its address
tables; addresses were ported by matching masked instruction windows around each 1.0.0 site (Dread 2.1.0's moved
by 0x490).

### Shader prebuilding
- Pipeline variants (`ShaderRec`: the shader pair's hashes, a 0x100-byte prefix hash and two constants to locate
  them, and the render state Metal compiles in) are recorded with `LARECOMP_RECORD_KEYS` into
  `games/<id>/shader_variants.txt`, which ships (hashes only, no game code).
- At startup the runtime indexes the shader containers in the player's romfs (`.bfsha`, `.bnsh`, `.ptcl`, `.arc`,
  `.sarc`/`.pack`/`.szs`/`.zs` contents; cached per version in `cache/<id>/shader_index-<build ID>.txt`), finds each
  listed variant's code by prefix hash then full hash, and builds the pipelines on background threads. Measured:
  Dread 376 variants in 0.5 s; ACNH 408 in 0.4 s cached (the first index of its 100,000 files: ~60 s from an external
  disk). 28 of ACNH's recorded stages aren't found in the files as stored (nested archives or code patched in
  memory): they compile on first use.
- `make corpus` found a translator bug: texel offsets on 3D lookups were 2-component (now x, y, z). ACNH's corpus
  (9,558 stages) leaves 7 agl debug shaders untranslated: TLDS type 6 (multisample fetch) and TLD4 with per-texel
  offsets.
- `make corpus` also builds them into a read-only Metal binary archive, one per version
  (`cache/<id>/shaders-<build ID>.metalarchive`, tagged with the translator, GPU and macOS build), which later
  launches load. It is built whole each time: Metal (macOS 27) can't save an archive it loaded and added to
  ("expecting 'fragment' stage in pipeline no. N").

### Dumps that could not be supported
Incomplete downloads, whose game code isn't there (`extract.mts` now says so for NSPs, from their file table, and
XCIs, from the card header's last valid page, listing how much of each NCA is present):
- Pikmin 2: a RAR holding 940 MB of a 1.1 GB NSP.
- Metroid Prime Remastered: an NSP missing its last 14.5 MB, which hold most of its exefs.
- Donkey Kong Country: Tropical Freeze (419 of 7,192 MiB), Game Builder Garage (788 of 1,356 MiB) and Tomodachi
  Life: Living the Dream (152 of 6,737 MiB): XCIs cut short inside their Program NCA. Like most program NCAs, theirs
  keep the exefs section last, after the romfs, so even the code is missing.

## 8. Linux (Vulkan)

The Vulkan backend vendored from LASRecomp builds on Linux (x86-64: the lifter's portable SIMD) and runs Dread and
ACNH (docs/linux.md). What it needed beyond building:
- The Metal backend's fixes since the vendoring, ported: conditional rendering, depth-only pipelines (Dread's prepass),
  3D render targets, one-shot targets waiting for their shaders, scaled-target promotion, linear render target
  write-back, virtual pools inside the GPU's span, and the GLSL side of the translator (FMZ, NaN coordinates, TLD4 /
  TLD4S, VOTE, RED). `tools/shader_corpus_vk.c` compiles a game's every shader through shaderc (`make corpus`).
- The in-game menu (menu.mm, ImGui's Vulkan backend through device.c's overlay) and cloud saves (libcurl).
- Kernel: an IPC request frees its thread's emulated core while it is handled, as a blocked SendSyncRequest does on
  the Switch. Holding it starved ACNH's main thread behind a file-reading thread on core 0, while a worker on core 1
  used a manager not yet initialised: a boot crash in 3 of 5 boots on a loaded machine.
- Boot: nn::init::Start's callbacks are classed from its own code (before nninitStartup, between it and nnMain, after
  nnMain). ACNH's and Mario Tennis Aces's SDK (two callbacks) calls the second before nnMain: main's constructors.
  It had been run as the fini arrays (after nnMain on SDK 9), so these games had their main constructors run before
  their heap existed (Mario Tennis: a crash in operator new) and their static destructors before nnMain.
- Audio renderer: render info (the elapsed frame count) only from REV5 (Mario Tennis Aces is REV4 and aborted on it).
- Mario Tennis Aces: a profile with GAME_LATIN_SYSTEM_FONT (its font engine finds no glyph in BIZ UDPGothic, the
  bundled Japanese stand-in); it reaches its title screen, then its own allocator runs out of memory loading the menu.
