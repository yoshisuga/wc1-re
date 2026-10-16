#ifndef SDL_PORT_N3DS_H
#define SDL_PORT_N3DS_H

/* Nintendo 3DS host.  The top screen shows the 320x200 frame stretched to
 * 320x240, the 4:3 shape it had on a VGA monitor.  The touch screen repeats
 * the frame 1:1 so a tap lands where it is drawn, with a row of keys below it
 * for the commands an original 3DS has no spare button for. */

#include <SDL.h>

#define N3DS_TOUCH_FRAME_HEIGHT 200
#define N3DS_KEY_BAR_TOP 204

void N3dsSetupSystem(void);
int N3dsFindGameDirectory(void);
void N3dsShowFatalError(const char *message);

int N3dsInitializeVideo(void);
int N3dsPresentFrame(const unsigned char *pixels,
                     const unsigned char *palette);
void N3dsWaitForVerticalBlank(void);

/* Returns the key under a touch-screen point on the key bar, or
 * SDLK_UNKNOWN.  *index receives the key's slot for highlighting. */
SDL_Keycode N3dsKeyBarKeyAt(int x, int y, int *index);
void N3dsSetPressedKey(int index);
int N3dsSecondaryTouchHeld(void);
/* Returns nonzero while the touch screen is held, with the point in
 * touch-screen pixels. */
int N3dsReadTouch(int *x, int *y);

#endif
