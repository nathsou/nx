# iPhone and iPad

The same engine runs on iOS and iPadOS: the Metal renderer and the games' code built for the device, in one app
(`nx.app`) that can hold several games (`Frameworks/<game>/game.dylib`). The game files, saves and settings live in
the app's Documents folder, which the Files app shows ("On My iPhone / iPad > nx"). Tested: Metroid Dread on an iPhone 17 Pro
(iOS 27) and in the iOS Simulator (iPhone 18 Pro, iPad Pro 13-inch); Animal Crossing: New Horizons is in the same app
but hasn't been played on a device yet (the Simulator can't run it: see the end).

## Building (on a Mac, Xcode installed)

```sh
tools/build_deps_ios.sh                         # SDL3, zstd, FFmpeg as static libraries (once; SDK=iphoneos for devices)
make gen GAME=dread && make gen GAME=acnh       # (as for macOS: each game's code as C, from data/<game>)
make ios IOS_GAMES="dread acnh" -j10            # build/iphonesimulator/nx.app with both games' code
make ios-run IOS_GAMES="dread acnh"             # install in the booted Simulator, data/<game> linked into Documents
```

`IOS_GAMES` defaults to `GAME`. Each game's code is compiled once per SDK (the Simulator's and the devices'), a few
minutes for Dread, longer for Animal Crossing.

## On your own iPhone / iPad (USB)

1. In Xcode > Settings > Accounts, sign in with your Apple ID (a free account works: see below). Turn on Developer
   Mode on the device (Settings > Privacy & Security) and trust the Mac when asked.
2. Have Xcode make a provisioning profile for `dev.dreadrecomp.nx` with the Increased Memory Limit capability - any
   small Xcode project with that bundle ID, your team and `com.apple.developer.kernel.increased-memory-limit` in its
   entitlements, built once for the device with automatic signing (`xcodebuild -allowProvisioningUpdates ...`). The
   profile lands in `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.
3. Build, sign and install (the device's identifier: `xcrun devicectl list devices`):

   ```sh
   SDK=iphoneos tools/build_deps_ios.sh
   make ios-device IOS_GAMES="dread acnh" IOS_DEVICE=<identifier> IOS_PROFILE=<path to the .mobileprovision> -j10
   ```

4. Copy each game's folder (`exefs/` and `romfs/`) into the app's Documents: the Files app, Finder's file sharing, or
   `xcrun devicectl device copy to --device <id> --domain-type appDataContainer --domain-identifier dev.dreadrecomp.nx
   --source data/dread/romfs --destination Documents/dread/romfs` (and the same for `exefs`). A copy over USB tends to fail
   after some 17,000 files: copy a big romfs (Animal Crossing's has 67,000) one folder at a time.

**A free Apple account is enough on recent iPhones.** The guest's address window at `0x7000000000` (runtime/rt.h)
fits in the address space an app gets on an iPhone 17 Pro with iOS 27 (up to `0x7fc0000000`, measured), so the
Extended Virtual Addressing entitlement - which free accounts can't have - isn't needed there; Increased Memory
Limit, which they can have, gives the app about 6 GB. Older devices or iOS versions may give less address space. A
free account's profiles last 7 days (install again after), and a device takes at most 3 apps signed with one.

## Playing

- **Choosing a game**: with more than one game in Documents, a selection screen comes first; Game > "Switch game" in
  the menu goes back to it (the game restarts in place, no need to quit the app). A game whose code isn't in the
  app is listed but can't be picked.
- **The menu**: touch the screen and the ≡ button appears at the top for a few seconds - tap it. Or press Home on a
  controller (a Switch Pro controller's, the Xbox / PlayStation button), or Minus + Plus together, or F1 / Esc on a
  keyboard. It is sized for fingers: tap to press, drag up / down to scroll, drag sideways to move a slider.
- **Controllers**: any controller iOS knows (Xbox, PlayStation, Switch Pro, MFi), paired in Settings > Bluetooth.
  The last one used drives the game.
- **Touch**: Apple's on-screen controller (stick, A / B / X / Y in the Switch's places, L / R / ZL / ZR) appears
  while no controller is connected - Controls > On-screen controller: or always, or never. It has no Plus / Minus:
  they are the − and + buttons at the top of the screen, either side of the menu button.

## How it differs from macOS

- `runtime/platform/macos.c` serves both (`TARGET_OS_IPHONE` parts: no child processes or re-exec, alerts through
  SDL, the log always in the data folder). SDL runs `main` inside UIKit's app (`SDL_main.h`).
- The Simulator's GPU has no BC (DXT) textures: they are decoded on the CPU when loaded (`runtime/nvn/bc_soft.c`,
  with bcdec). Real devices from the A14 / M1 on sample them directly. It has no MetalFX either (bilinear
  upscaling and optical-flow frame generation there).
- Touches never reach the games (neither uses the touch screen): they are the menu's.
- The Simulator's GPU allows 32 bytes of colour targets per pixel; Animal Crossing draws with 48 and stops there with a
  Metal assertion. Devices from the A11 on allow 64 or more: play it on a device.
