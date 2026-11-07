# iOS and iPadOS port

`bin/build-ios.sh` builds `WingCommander.app` for an iPhone or iPad, or for
the iOS Simulator. It runs the same reconstructed game, `ix` audio library
and SDL2 host as the desktop port, drawn through SDL's renderer. The
iOS-specific code is `src/sdl/ios.c` (game data and glue),
`src/sdl/ios_touch.m` (touch controls), plus `__IPHONEOS__` blocks in
`launcher.c`, `events.c` and `joystick.c`.

## Game files

Copy the game folder, the one that holds `GAMEDAT`, into the app's
Documents folder: in the Files app it is **On My iPhone › Wing Commander**,
and Finder shows it under the device's **Files** tab. Kilrathi Saga also
needs its `STREAMS` folder next to `GAMEDAT`, as on the desktop. DOS data
works too.

At launch the game looks for `GAMEDAT` in Documents itself and then in each
folder directly inside it, ignoring case. A new install creates an empty
`WC1` folder to copy into, since the Files app lists the app only once its
Documents folder holds something. Without game data the app says so and
closes.

Saved games go in the game folder, as on the desktop; `wc1-modern.cfg` goes
in SDL's preference folder inside the app's Library.

## Touch controls

The controls are a UIKit overlay over SDL's view, following OpenTIE's iOS
port. The buttons sit in the black bars beside the 4:3 picture, inside the
safe area. On a screen without wide bars, such as an iPad's, they overlap
the picture's edges. Each press gives a light haptic tap.

**Menus, briefings and conversations:** the screen is a trackpad. Drag
anywhere to move the pointer from where it is; tap anywhere to click where
the pointer is, and tap with two fingers to right-click. The game moves its
pointer through `SDL_WarpMouseInWindow`, so SDL's mouse position is always
the game's pointer; a drag warps it by the finger's travel, kept on the
picture. **ESC** and **ENTER** are in the left bar and **KEYS** in the
right; KEYS opens the system keyboard for the pilot's name and other text,
and closes it again.

**Flight:** put a thumb down anywhere outside the buttons and drag; that is
the flight stick. The stick and most buttons drive a virtual SDL game
controller, so flight uses the desktop's `4button-4axis` mode with the
`twin-stick-roll` layout, exactly as a real controller would:

| Button | Controller | Does |
| --- | --- | --- |
| Stick | Left stick | Pitch and yaw |
| FIRE | A | Fire guns |
| MISSILE | B | Fire missile |
| BURN (hold) | X | Afterburner |
| TGT | Y | Cycle target |
| GUNS / MSLS | L / R shoulder | Cycle guns / missiles |
| ROLL ◀ / ▶ (hold) | Right stick X | Roll |
| THR + / − (hold) | Right stick Y | Throttle up / down |
| NAV / AUTO | Left / right stick click | Navigation map / autopilot |
| COMM / LOCK | D-pad left / right | Communications / lock target |
| FULL / STOP | D-pad up / down | Full speed / stop |
| PAUSE | Start | Pause |
| ESC | `Esc` key | Leave a screen |
| FRONT / LEFT / RIGHT / REAR | `F1`–`F4` keys | Cockpit views |

In the communications menu the D-pad picks a message, so FULL and STOP move
the choice, LOCK sends it and COMM cancels.

The overlay shows flight controls while the event pump is `player_input`
and the flight loop's `nArcadeState` is 0; everywhere else it shows the menu
keys and turns the rest of the screen into the trackpad.

## Game controllers

MFi, Xbox, PlayStation and Switch controllers work through SDL as on the
desktop. SDL's accelerometer joystick is turned off: SDL would list it
first, and the game, which takes the first joystick, would move the pointer
by the phone's tilt. The virtual touch controller and a hardware one take turns as the
game's joystick: pressing a button or pushing a stick on the hardware
controller selects it and hides the overlay, and the next touch brings the
overlay and the touch controller back. A hardware keyboard works as on the
desktop.

## Leaving the app

When the app goes to the background the event pump waits, with the game
stopped where it was, until it returns: iOS ends an app that draws in the
background. Home-indicator swipes need a second swipe, so a stray swipe in
flight does not leave the game.

## Building

You need macOS with Xcode, CMake and Git.

**Simulator:**

```sh
bin/build-ios.sh simulator
xcrun simctl install booted out-ios/simulator/WingCommander.app
```

**iPhone or iPad:** you need a development signing identity and a
provisioning profile that covers the bundle ID. A wildcard team profile
works.

```sh
export IOS_CODESIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"
export IOS_PROVISIONING_PROFILE=/path/to/profile.mobileprovision
export IOS_BUNDLE_ID=com.example.wingcommander
bin/build-ios.sh device
xcrun devicectl device install app --device <device-id> out-ios/device/WingCommander.app
```

The first run builds SDL2 2.32 and LZO 2.10 for that slice into
`out-ios/<slice>/deps`. Then it runs `make -f Makefile.ios`, which reuses
the main Makefile's source lists, and signs the app. `IOS_DEPLOYMENT_TARGET`
sets the minimum iOS (15.0 by default).

Details of the build:

- **main().** UIKit owns the process's `main`. `ios_touch.m` defines it and
  calls `SDL_UIKitRunApp`, which starts SDL's application delegate and then
  calls the port's own `main` from `launcher.c`, compiled as
  `SdlIosGameMain`.
- **Unaligned pointers.** Several recovered tables are byte-packed and hold
  pointers at odd offsets (`aObjectTypeData`, `aScrambleAnimationActors` and
  others). Chained fixups cannot rebase those, so the app links with
  `-no_fixup_chains`, as the desktop Mac build does.
- **No enhanced renderer.** The enhanced renderer needs desktop OpenGL 3.2,
  so `gl_renderer.c` is left out and `ios.c` provides stubs for its entry
  points.
- **Icon.** The app icon is the 3DS build's 48x48 icon, scaled up.

## Testing

The app has run in the iOS Simulator on an iPhone 15 Pro with the GOG DOS
release's data. There the intro, the title menu, the trackpad pointer, the
training simulator's flight screen and its high-score entry all work, and
the overlay switches between its menu and flight buttons. The app also
starts on an iPhone 17 Pro Max and an iPhone DX with the same data, with
AdLib audio enabled. A full mission, Kilrathi Saga data, an iPad, and the
two-finger right click have not been tried.

## Not done yet

- Gyro aiming, which OpenTIE's port has.
- Dragging with the button held (press, move, release) from the trackpad.
- The system keyboard covers the lower half of the picture while open.
- The Super Wing Commander Mac demo. Its code is linked but has not been
  tried on iOS.
