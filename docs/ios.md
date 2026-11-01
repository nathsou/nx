# iPhone and iPad

The same engine runs on iOS and iPadOS: the Metal renderer and the game code built for the device, in an app
(`nx.app`) that holds the recompiled code of one game. The game files, saves and settings live in the app's
Documents folder, which the Files app shows ("On My iPhone / iPad > nx"). Only the iOS **Simulator** has been
tested so far (Metroid Dread on an iPhone 18 Pro and an iPad Pro 13-inch simulator): signing for a real device is
still to do (see the end).

## Building (on a Mac, Xcode installed)

```sh
tools/build_deps_ios.sh                # SDL3, zstd, FFmpeg as static libraries: build/deps-iphonesimulator (once)
make gen GAME=dread                    # (as for macOS: the game's code as C, from data/dread)
make ios GAME=dread -j10               # build/iphonesimulator/nx.app, the game's code in Frameworks/game.dylib
```

`make ios-run GAME=dread` installs the app in the booted Simulator, links `data/<game>` into its Documents folder (no
4 GB copy) and starts it with its log in the terminal (set `SIMCTL_CHILD_LARECOMP_LOG_STDERR=1` for the full log;
without it the log goes to `lasrecomp.log` in Documents). The app plays the first folder in Documents that has
`exefs/main` in it. Saves go to `Documents/save/<game>/` - copy a Mac save folder there to carry on from it.

## Playing

- **The menu**: the ≡ button at the top of the screen (or Minus + Plus on a controller, F1 / Esc on a keyboard).
  It is sized for fingers: tap to press, drag up / down to scroll, drag sideways to move a slider. Settings are the
  Mac's, minus the window ones; Saves > "Show in the Files app" opens the save folder there.
- **Controllers**: any controller iOS knows (Xbox, PlayStation, Switch Pro, MFi), paired in Settings > Bluetooth.
  The last one used drives the game.
- **Touch**: Apple's on-screen controller (stick, A / B / X / Y in the Switch's places, L / R / ZL / ZR) appears
  while no controller is connected - Controls > On-screen controller: or always, or never. iOS's on-screen controller
  has no Plus / Minus: they are the − and + buttons on either side of the menu button.

## How it differs from macOS

- `runtime/platform/macos.c` serves both (`TARGET_OS_IPHONE` parts: no child processes or re-exec, alerts through
  SDL, the log always in the data folder). SDL runs `main` inside UIKit's app (`SDL_main.h`).
- The Simulator's GPU has no BC (DXT) textures: they are decoded on the CPU when loaded (`runtime/nvn/bc_soft.c`,
  with bcdec). Real devices from the A14 / M1 on sample them directly. It has no MetalFX either (bilinear
  upscaling and optical-flow frame generation there).
- Touches never reach the game (Dread doesn't use the touch screen): they are the menu's.

## Not done yet: a real iPhone / iPad

`make ios IOS_SDK=iphoneos` builds for devices (after `SDK=iphoneos tools/build_deps_ios.sh`) but the app isn't
signed for one. The guest's 13.5 GB address window at `0x7000000000` (runtime/rt.h) needs the
`com.apple.developer.kernel.extended-virtual-addressing` and `increased-memory-limit` entitlements, which need a
paid developer account and a provisioning profile; `game.dylib` must be signed with the app. Expect a device with
8 GB of memory or more (the game's heap is 3.25 GB).
