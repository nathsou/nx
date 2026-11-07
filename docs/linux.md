# nx on Linux (Vulkan)

nx builds and runs on Linux, x86-64 or AArch64, with the Vulkan renderer (`runtime/nvn/vulkan/`). The game code is
recompiled from your own game files exactly as on macOS. Only the host side differs:

- **CPU:** on x86-64 the guest's FP / SIMD instructions are lowered to portable C (`tools/simd_c.py`, `runtime/simd.h`),
  compiled for x86-64-v3 (AVX2 + FMA: a Haswell or newer Intel, a Zen or newer AMD; checked at startup). An AArch64
  host runs them as inline assembly, as on a Mac.
- **GPU:** Vulkan 1.3 with dynamic rendering. The Maxwell shader translator emits GLSL, compiled to SPIR-V with shaderc
  at run time (cached in `cache/`).
- **Window, input, audio:** SDL3, on Wayland or X11.

Checked on: CachyOS (Arch), Intel Core i5-12600K, NVIDIA GeForce RTX 4060 Ti (driver 615), KDE Plasma, through
XWayland (`SDL_VIDEO_DRIVER=x11`); SDL's native Wayland path hasn't been run yet.
- Metroid Dread 1.0.0: save checkpoints across the game (Artaria, Cataris, Ghavoran) load and play; at 4K internal
  resolution a frame takes about 5 ms of GPU and 4 ms of the render thread. All 832 shader stages compile.
- Animal Crossing: New Horizons 1.0.0: the intro (Timmy and Tommy, the name entry with the game's own keyboard, the
  character creator), the opening movie and the arrival on the island, at a steady 30 fps.
- Mario Tennis Aces 1.0.0 (games/mta: no patches, a Latin stand-in for the system font): its title screen at 60 fps
  with sound; it then runs out of memory in its own allocator as the menu loads.

## Building

Requirements: clang and lld, SDL3, FFmpeg, zstd, the Vulkan loader and headers, shaderc, libcurl (cloud saves),
Python 3 and [Bun](https://bun.sh) (only for extracting games).

```sh
# Arch / CachyOS / Manjaro
sudo pacman -S clang lld sdl3 ffmpeg zstd vulkan-icd-loader vulkan-headers shaderc curl python
# Debian / Ubuntu (24.10 or later for SDL3)
sudo apt install clang lld libsdl3-dev libavformat-dev libavcodec-dev libswscale-dev libzstd-dev \
    libvulkan-dev libshaderc-dev libcurl4-openssl-dev python3-venv
# Fedora
sudo dnf install clang lld SDL3-devel ffmpeg-devel libzstd-devel vulkan-loader-devel vulkan-headers \
    libshaderc-devel libcurl-devel python3

python3 -m venv .venv && .venv/bin/pip install unicorn capstone lz4
```

You also need your GPU's Vulkan driver (`vulkan-radeon` / `vulkan-intel` / NVIDIA's proprietary driver).
[Vulkan Memory Allocator](https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator)'s header is in
`third_party/vma/`. A system copy (`libvulkan-memory-allocator-dev`, `vulkan-memory-allocator`) is used instead if it is
installed.

Then, as on macOS (see the [README](../README.md)):

```sh
bun extract.mts "Metroid Dread.nsp" data/dread --keys prod.keys --title-keys title.keys
make gen GAME=dread
make -j$(nproc) GAME=dread
./build/nx data/dread
```

The game's library is `build/<name>/game.so`. The first build of a game takes a while (Metroid Dread's 460 MB of C:
about 40 minutes on a 12600K shared with other work); later builds only recompile what changed. The game code is
built with LLVM's LICM scalar promotion off (`GENOPT` in the Makefile): it promotes next to nothing in lifted code and
spent most of the build on a few very large functions (one of Mario Tennis Aces's: over 45 minutes, 218 s without it).

## Shaders

`make corpus GAME=<name>` translates every shader in the game's files to GLSL and compiles it to SPIR-V with shaderc
(`tools/shader_corpus_vk.c`, no GPU needed). Then it prepares the listed pipeline variants into the Vulkan pipeline
cache (`cache/<game>/`). Metroid Dread: all 832 stages compile. Animal Crossing: all but 8 of 8,571 (the same agl
debug shaders the Metal translation can't do, plus a bindless font shader). Pipelines that are neither prepared nor in
the driver's cache compile when a draw first needs them, on worker threads.

## Differences from macOS

- **Upscaler:** bilinear or AMD FSR 1 (the Video tab's *Upscaler*), where macOS has MetalFX.
- **Frame generation:** macOS only for now (`runtime/nvn/framegen.m`, `motion.m`). Animal Crossing runs at its own
  30 fps.
- **Menu:** the same in-game menu (F1 / Esc, Home or Minus + Plus on a controller), drawn by Dear ImGui's Vulkan
  backend. *Open the saves folder* opens your file manager.
- **Cloud saves:** the same buckets and objects as macOS and iOS (libcurl does the HTTPS). The application key's
  secret is kept in `cloud.secret`, readable only by you.

## Display and frame pacing

- On Wayland, SDL3 uses Wayland directly. `SDL_VIDEO_DRIVER=x11` uses XWayland or an X server instead.
- The swapchain uses MAILBOX where the driver offers it, otherwise FIFO (NVIDIA on X11 has no MAILBOX: the game is
  held to the display's refresh rate). `LARECOMP_VK_PRESENT=fifo|mailbox|immediate` chooses.
- With several GPUs (a laptop's integrated and discrete ones), the discrete one is used. `LARECOMP_GPU=<index>` chooses
  another (the log lists them as `[vk] gpu <index>: <name>`).

## Test hooks

Every `LARECOMP_*` hook in the README and PLAN.md works on Linux, among them `LARECOMP_SHOT_AT`, `LARECOMP_INPUT`,
`LARECOMP_LIVE`, `LARECOMP_WINDOW_SHOT`, `LARECOMP_MENU_AT` and `tools/checkpoints.sh`. Screenshots go to
`build/frames/` (or `LARECOMP_FRAMES_DIR`). On Linux, also:

- `LARECOMP_VK_VALIDATION=1`: the Khronos validation layer, with its messages in the log.
- `LARECOMP_VK_PROF=1`: where the render thread's and the present's time goes, added to the periodic `[vk]` lines.
