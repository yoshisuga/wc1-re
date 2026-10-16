# Nintendo 3DS port

`bin/build-3ds.sh` builds `out-3ds/wc1.3dsx`, a homebrew build of the SDL2
port for the Nintendo 3DS. It runs the same reconstructed game, `ix` audio
library and SDL2 host as the desktop port. The 3DS-specific code is
`src/sdl/n3ds.c`, plus `__3DS__` blocks in `video.c`, `events.c` and
`launcher.c`.

## Installing

1. Copy `wc1.3dsx` to `sdmc:/3ds/wc1/` on the SD card.
2. Copy the game's files into the same folder, so that
   `sdmc:/3ds/wc1/GAMEDAT` exists. Use the same Kilrathi Saga or DOS
   installation the desktop port accepts. Kilrathi Saga also needs its
   `STREAMS` folder next to `GAMEDAT`.
3. Start **Wing Commander** from the Homebrew Launcher.

Sound needs the 3DS DSP firmware at `sdmc:/3ds/dspfirm.cdc`, which the DSP1
homebrew creates. Most homebrew setups already have it. Without it, the game
says so once at startup and runs silently.

The game also looks for its data in `sdmc:/3ds/WC1`, `sdmc:/wc1` and
`sdmc:/WC1`, and in the folder the `.3dsx` was started from. If it finds no
`GAMEDAT` folder, it says so on the top screen and waits for START.

Settings and saved games go to the same places as on the desktop: saves in
the game folder, and `wc1-modern.cfg` in SDL's preference folder on the SD
card.

Errors the game reports with a message box appear on the touch screen.
Press A to continue.

The SD card driver has no working `getcwd()` and does not accept `..` in
paths, so on the 3DS `SdlChangeDirectory` records the current directory
itself and resolves every path to an absolute `sdmc:/` path.
`GetCurrentDirectoryA` returns that record. The game uses it to find
`STREAMS` next to `GAMEDAT`.

## Screens

The top screen shows the 320x200 game frame stretched to 320x240: the 4:3
shape it had on a VGA monitor. Every fifth line is doubled to get there. The
frame is centered with black bars at the sides. The 3D slider has no
effect.

The touch screen repeats the frame at 1:1 above a row of eight keys. Tapping
the frame clicks at that point, and holding **L** while tapping makes it a
right click. The keys hold down their keyboard key for as long as the stylus
is on them:

| Key | Keyboard | Use |
| --- | --- | --- |
| ESC | `Esc` | Leave a screen; pause in flight |
| NAV | `N` | Navigation map |
| AUTO | `A` | Autopilot |
| COMM | `C` | Communications |
| F1-F4 | `F1`-`F4` | Front, left, right and rear views |

## Buttons

The port uses the desktop's `4button-4axis` gamepad mode with the
`twin-stick-roll` axis layout. SDL's built-in Nintendo 3DS mapping supplies
the button names.

| 3DS | Flight | Menus and screens |
| --- | --- | --- |
| Circle Pad | Pitch and yaw | Move the pointer |
| C-stick (New 3DS) | Roll (left/right), throttle (up/down) | |
| A | Fire guns | Select (joystick button 1) |
| B | Fire missile | Joystick button 2 |
| X (hold) | Afterburner | |
| Y | Cycle target | Yes at `Y/N` prompts |
| L / R | Cycle guns / missiles | |
| ZL / ZR (New 3DS) | Navigation map / autopilot | |
| D-pad Up / Down | Full speed / stop | |
| D-pad Left / Right | Communications / lock target | |
| START | Pause | |
| SELECT | `Esc` | `Esc` |

On an original 3DS, which has no C-stick, ZL or ZR, use the touch keys for the
nav map and autopilot. The throttle stays on the D-pad (full speed and stop).

## Performance

`N3dsSetupSystem` asks for the New 3DS's 804 MHz clock and its extra cache.
The original model runs at 268 MHz. Space combat draws its 3D scene in
software, so expect a lower frame rate there on an original 3DS.

## Building

`bin/build-3ds.sh` runs inside the `devkitpro/devkitarm` Docker image when
devkitARM is not installed. With devkitARM installed, it builds directly.
On first run it builds SDL2 2.32 and LZO 2.10 for the 3DS into
`out-3ds/deps`. Then it runs `make -f Makefile.3ds`, which reuses the main
Makefile's source lists. The enhanced OpenGL renderer has no 3DS
counterpart, so `gl_renderer.c` is left out and `n3ds.c` provides stubs for
its entry points.

Two details of the toolchain need care:

- **Enum size.** Bare-metal ARM GCC makes an enum only as wide as its values
  need, and libctru is built that way. The recovered on-disk structures hold
  enums that must be 4 bytes wide (`MissionNavPoint` must be 0x51 bytes, for
  example). So the game and SDL2 are built with `-fno-short-enums`. One SDL
  file, `SDL_n3dsswkb.c`, shares a struct with enum members (`SwkbdState`)
  with libctru, so it is rebuilt with libctru's enum size. SDL's other 3DS
  files share only plain-integer structs with libctru.
- **Unaligned pointers.** Several recovered tables are byte-packed and hold
  pointers at odd offsets (`aObjectTypeData`, `aBriefingCharacters`,
  `aMissionShips`, `aScrambleAnimationActors`). The 3DSX relocation format
  covers only whole words, so `3dsxtool` rejects them. A 3DSX always loads at
  the host title's text base, 0x00100000, with its segments laid out as
  linked. So `bin/n3dsUnalignedRelocs.py` turns those relocations into
  `R_ARM_NONE` before `3dsxtool` runs, and the pointers keep their linked
  addresses.

The `Nintendo 3DS` GitHub workflow builds the same way and uploads the
`.3dsx` as an artifact.

## Testing

The port has been run in the Azahar emulator's libretro core, driven headless
with scripted input. It loads, shows the missing-data screen, starts SDL
video, input and audio, and resolves game paths case-insensitively under
`sdmc:/`. It also shows the no-sound notice and continues without DSP
firmware. It has not yet been played with real game data or on hardware.

## Not done yet

- Stereoscopic 3D. The space view is a single software-rendered image. Depth
  would mean rendering it twice from offset eye positions.
- A CIA build for the HOME Menu.
- The Super Wing Commander Mac demo. Its code is linked but has not been
  tried on the 3DS.
