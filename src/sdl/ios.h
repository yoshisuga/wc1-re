#ifndef SDL_PORT_IOS_H
#define SDL_PORT_IOS_H

/* iOS and iPadOS host.  The game data lives in the app's Documents folder,
 * which the Files app and Finder can copy into.  The touch controls are a
 * UIKit overlay over SDL's view (ios_touch.m): buttons in the bars beside
 * the 4:3 frame and a flight stick that drives a virtual game controller.
 *
 * This header is shared with Objective-C, so it does not include wc1.h. */

#include <SDL.h>

/* Changes to the folder that holds GAMEDAT: Documents itself or a folder
 * directly inside it.  Returns 0 when there is none; an empty Documents
 * gets a WC1 folder to copy the game into. */
int IosFindGameDirectory(void);

/* Nonzero while the player is flying: the event pump is player_input and
 * the flight loop has not been told to stop. */
int IosFlightActive(void);

/* Makes the open controller with this instance the game's joystick, while
 * the game is using one (joystick.c).  The touch controls' virtual
 * controller and a hardware controller take turns this way. */
void SdlSelectJoystickInstance(SDL_JoystickID instanceId);

/* After the window exists and before the game reads the joystick: attaches
 * the virtual controller and adds the overlay. */
void IosInitializeTouchControls(SDL_Window *window);
/* Once per event pump. */
void IosUpdateTouchControls(void);
void IosShutdownTouchControls(void);

#endif
