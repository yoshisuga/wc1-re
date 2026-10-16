/* Nintendo 3DS host: system setup, both screens, and the touch key bar.
 *
 * SDL's 3DS video driver owns gfxInit() and the event pump, but its window
 * path converts, scales and rotates every frame through three surfaces.  The
 * frame here is written straight into the RGBA8 framebuffers instead, which
 * the 3DS stores rotated: column x of the screen is a run of 240 pixels with
 * the screen's bottom row first. */
/* libctru first: its applet headers name enum values that the Win32
 * compatibility layer in wc1.h defines as macros, such as ERROR_SUCCESS. */
#include <3ds.h>

#include "wc1.h"

#include "video_internal.h"
#include "n3ds.h"

#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#define N3DS_TOP_WIDTH 400
#define N3DS_BOTTOM_WIDTH 320
#define N3DS_SCREEN_HEIGHT 240
#define N3DS_TOP_LEFT ((N3DS_TOP_WIDTH - SDL_PORT_FRAME_WIDTH) / 2)

#define N3DS_KEY_COLUMNS 4
#define N3DS_KEY_ROWS 2
#define N3DS_KEY_WIDTH (N3DS_BOTTOM_WIDTH / N3DS_KEY_COLUMNS)
#define N3DS_KEY_HEIGHT 17
#define N3DS_KEY_GAP 2

typedef struct N3dsKey {
    const char *label;
    SDL_Keycode key;
} N3dsKey;

/* ESC leaves screens and opens the flight menu; N, A and C are the nav map,
 * autopilot and comms; F1-F4 are the front, left, right and rear views. */
static const N3dsKey g_aN3dsKeys[N3DS_KEY_ROWS * N3DS_KEY_COLUMNS] = {
    { "ESC", SDLK_ESCAPE }, { "NAV", SDLK_n },
    { "AUTO", SDLK_a }, { "COMM", SDLK_c },
    { "F1", SDLK_F1 }, { "F2", SDLK_F2 },
    { "F3", SDLK_F3 }, { "F4", SDLK_F4 },
};

/* 5x5 glyphs for the key labels, one row per byte, high bit on the left. */
typedef struct N3dsGlyph {
    char character;
    unsigned char rows[5];
} N3dsGlyph;

static const N3dsGlyph g_aN3dsGlyphs[] = {
    { 'A', { 0x0e, 0x11, 0x1f, 0x11, 0x11 } },
    { 'C', { 0x0f, 0x10, 0x10, 0x10, 0x0f } },
    { 'E', { 0x1f, 0x10, 0x1e, 0x10, 0x1f } },
    { 'F', { 0x1f, 0x10, 0x1e, 0x10, 0x10 } },
    { 'M', { 0x11, 0x1b, 0x15, 0x11, 0x11 } },
    { 'N', { 0x11, 0x19, 0x15, 0x13, 0x11 } },
    { 'O', { 0x0e, 0x11, 0x11, 0x11, 0x0e } },
    { 'S', { 0x0f, 0x10, 0x0e, 0x01, 0x1e } },
    { 'T', { 0x1f, 0x04, 0x04, 0x04, 0x04 } },
    { 'U', { 0x11, 0x11, 0x11, 0x11, 0x0e } },
    { 'V', { 0x11, 0x11, 0x11, 0x0a, 0x04 } },
    { '1', { 0x04, 0x0c, 0x04, 0x04, 0x0e } },
    { '2', { 0x1e, 0x01, 0x0e, 0x10, 0x1f } },
    { '3', { 0x1e, 0x01, 0x06, 0x01, 0x1e } },
    { '4', { 0x12, 0x12, 0x1f, 0x02, 0x02 } },
};

/* libctru gives a 3DSX main thread 32 KB unless asked for more.  The game
 * and the SDL host keep 4 KB path buffers and large frames on the stack. */
u32 __stacksize__ = 1024 * 1024;

static u32 g_adwN3dsPalette[256];
static unsigned short g_awN3dsStretchRow[N3DS_SCREEN_HEIGHT];
static u32 g_adwN3dsKeyBar[N3DS_BOTTOM_WIDTH * N3DS_SCREEN_HEIGHT];
static int g_nN3dsPressedKey = -1;
static int g_bN3dsKeyBarDirty = 1;
static int g_bN3dsVideoReady;

void N3dsSetupSystem(void)
{
    /* The New 3DS runs at 804 MHz with its extra cache only on request;
     * the original model ignores this. */
    osSetSpeedupEnable(true);
}

static int N3dsHasGameData(const char *directory)
{
    char path[256];
    struct stat info;

    snprintf(path, sizeof(path), "%s/GAMEDAT", directory);
    if (stat(path, &info) == 0 && S_ISDIR(info.st_mode))
        return 1;
    snprintf(path, sizeof(path), "%s/gamedat", directory);
    return stat(path, &info) == 0 && S_ISDIR(info.st_mode);
}

int N3dsFindGameDirectory(void)
{
    static const char *const candidates[] = {
        "sdmc:/3ds/wc1", "sdmc:/3ds/WC1", "sdmc:/wc1", "sdmc:/WC1",
    };
    char current[256];
    unsigned int index;

    /* A copy launched from inside the data directory uses it directly. */
    if (getcwd(current, sizeof(current)) != 0 && N3dsHasGameData(current))
        return 1;
    for (index = 0; index < SDL_arraysize(candidates); index++) {
        if (N3dsHasGameData(candidates[index]) &&
            SdlChangeDirectory(candidates[index]) == 0)
            return 1;
    }
    return 0;
}

void N3dsShowFatalError(const char *message)
{
    gfxInitDefault();
    consoleInit(GFX_TOP, 0);
    printf("\x1b[2;1HWing Commander\n\n%s\n\n"
           "Copy the game's files so that this\n"
           "folder exists on the SD card:\n\n"
           "  sdmc:/3ds/wc1/GAMEDAT\n\n"
           "Press START to exit.", message);
    while (aptMainLoop()) {
        hidScanInput();
        if (hidKeysDown() & KEY_START)
            break;
        gfxFlushBuffers();
        gfxSwapBuffers();
        gspWaitForVBlank();
    }
    gfxExit();
}

static const unsigned char *N3dsFindGlyph(char character)
{
    unsigned int index;

    for (index = 0; index < SDL_arraysize(g_aN3dsGlyphs); index++) {
        if (g_aN3dsGlyphs[index].character == character)
            return g_aN3dsGlyphs[index].rows;
    }
    return 0;
}

static void N3dsFillKeyBarRect(int left, int top, int width, int height,
                               u32 colour)
{
    int x;
    int y;

    for (y = top; y < top + height; y++) {
        for (x = left; x < left + width; x++)
            g_adwN3dsKeyBar[y * N3DS_BOTTOM_WIDTH + x] = colour;
    }
}

static void N3dsDrawKeyLabel(const char *label, int centreX, int centreY,
                             u32 colour)
{
    const unsigned char *rows;
    int length;
    int left;
    int top;
    int row;
    int column;

    length = (int)strlen(label);
    left = centreX - (length * 12 - 2) / 2;
    top = centreY - 5;
    for (; *label != '\0'; label++, left += 12) {
        rows = N3dsFindGlyph(*label);
        if (rows == 0)
            continue;
        for (row = 0; row < 5; row++) {
            for (column = 0; column < 5; column++) {
                if (rows[row] & (0x10 >> column))
                    N3dsFillKeyBarRect(left + column * 2, top + row * 2,
                                       2, 2, colour);
            }
        }
    }
}

static void N3dsRenderKeyBar(void)
{
    int index;
    int left;
    int top;
    int pressed;

    N3dsFillKeyBarRect(0, 0, N3DS_BOTTOM_WIDTH, N3DS_SCREEN_HEIGHT,
                       0x000000ff);
    for (index = 0; index < N3DS_KEY_ROWS * N3DS_KEY_COLUMNS; index++) {
        pressed = index == g_nN3dsPressedKey;
        left = (index % N3DS_KEY_COLUMNS) * N3DS_KEY_WIDTH + 1;
        top = N3DS_KEY_BAR_TOP +
              (index / N3DS_KEY_COLUMNS) * (N3DS_KEY_HEIGHT + N3DS_KEY_GAP);
        N3dsFillKeyBarRect(left, top, N3DS_KEY_WIDTH - 2, N3DS_KEY_HEIGHT,
                           pressed ? 0xc08020ff : 0x303848ff);
        N3dsDrawKeyLabel(g_aN3dsKeys[index].label,
                         left + (N3DS_KEY_WIDTH - 2) / 2,
                         top + N3DS_KEY_HEIGHT / 2,
                         pressed ? 0x000000ff : 0xd0d8e8ff);
    }
    g_bN3dsKeyBarDirty = 0;
}

SDL_Keycode N3dsKeyBarKeyAt(int x, int y, int *index)
{
    int column;
    int row;

    *index = -1;
    if (x < 0 || x >= N3DS_BOTTOM_WIDTH || y < N3DS_KEY_BAR_TOP ||
        y >= N3DS_SCREEN_HEIGHT)
        return SDLK_UNKNOWN;
    column = x / N3DS_KEY_WIDTH;
    row = (y - N3DS_KEY_BAR_TOP) / (N3DS_KEY_HEIGHT + N3DS_KEY_GAP);
    if (row >= N3DS_KEY_ROWS)
        row = N3DS_KEY_ROWS - 1;
    *index = row * N3DS_KEY_COLUMNS + column;
    return g_aN3dsKeys[*index].key;
}

void N3dsSetPressedKey(int index)
{
    if (index != g_nN3dsPressedKey) {
        g_nN3dsPressedKey = index;
        g_bN3dsKeyBarDirty = 1;
    }
}

int N3dsSecondaryTouchHeld(void)
{
    /* Holding L while tapping is a right click. */
    return (hidKeysHeld() & KEY_L) != 0;
}

int N3dsReadTouch(int *x, int *y)
{
    touchPosition touch;

    if ((hidKeysHeld() & KEY_TOUCH) == 0)
        return 0;
    hidTouchRead(&touch);
    *x = touch.px;
    *y = touch.py;
    return 1;
}

int N3dsInitializeVideo(void)
{
    int row;

    /* Nearest-row stretch from 200 to 240 lines: every fifth row twice. */
    for (row = 0; row < N3DS_SCREEN_HEIGHT; row++)
        g_awN3dsStretchRow[row] =
            (unsigned short)(row * SDL_PORT_FRAME_HEIGHT /
                             N3DS_SCREEN_HEIGHT);
    gfxSet3D(false);
    g_bN3dsKeyBarDirty = 1;
    g_bN3dsVideoReady = 1;
    return 1;
}

static void N3dsPresentTop(const unsigned char *pixels)
{
    u32 *framebuffer;
    u32 *column;
    const unsigned char *source;
    int x;
    int y;

    framebuffer = (u32 *)gfxGetFramebuffer(GFX_TOP, GFX_LEFT, 0, 0);
    memset(framebuffer, 0, N3DS_TOP_LEFT * N3DS_SCREEN_HEIGHT * 4);
    memset(framebuffer + (N3DS_TOP_LEFT + SDL_PORT_FRAME_WIDTH) *
                             N3DS_SCREEN_HEIGHT,
           0, N3DS_TOP_LEFT * N3DS_SCREEN_HEIGHT * 4);
    for (x = 0; x < SDL_PORT_FRAME_WIDTH; x++) {
        column = framebuffer + (N3DS_TOP_LEFT + x) * N3DS_SCREEN_HEIGHT +
                 N3DS_SCREEN_HEIGHT - 1;
        source = pixels + x;
        for (y = 0; y < N3DS_SCREEN_HEIGHT; y++)
            column[-y] = g_adwN3dsPalette[
                source[g_awN3dsStretchRow[y] * SDL_PORT_FRAME_WIDTH]];
    }
    GSPGPU_FlushDataCache(framebuffer,
                          N3DS_TOP_WIDTH * N3DS_SCREEN_HEIGHT * 4);
    gfxScreenSwapBuffers(GFX_TOP, false);
}

static void N3dsPresentBottom(const unsigned char *pixels)
{
    u32 *framebuffer;
    u32 *column;
    const u32 *keyBar;
    int x;
    int y;

    if (g_bN3dsKeyBarDirty)
        N3dsRenderKeyBar();
    framebuffer = (u32 *)gfxGetFramebuffer(GFX_BOTTOM, GFX_LEFT, 0, 0);
    for (x = 0; x < N3DS_BOTTOM_WIDTH; x++) {
        column = framebuffer + x * N3DS_SCREEN_HEIGHT +
                 N3DS_SCREEN_HEIGHT - 1;
        for (y = 0; y < N3DS_TOUCH_FRAME_HEIGHT; y++)
            column[-y] = g_adwN3dsPalette[
                pixels[y * SDL_PORT_FRAME_WIDTH + x]];
        keyBar = g_adwN3dsKeyBar + x;
        for (; y < N3DS_SCREEN_HEIGHT; y++)
            column[-y] = keyBar[y * N3DS_BOTTOM_WIDTH];
    }
    GSPGPU_FlushDataCache(framebuffer,
                          N3DS_BOTTOM_WIDTH * N3DS_SCREEN_HEIGHT * 4);
    gfxScreenSwapBuffers(GFX_BOTTOM, false);
}

int N3dsPresentFrame(const unsigned char *pixels,
                     const unsigned char *palette)
{
    int index;

    if (!g_bN3dsVideoReady || pixels == 0 || palette == 0)
        return 0;
    /* The game's palette is [B,G,R,pad]; the framebuffer wants RGBA. */
    for (index = 0; index < 256; index++)
        g_adwN3dsPalette[index] =
            (u32)palette[index * 4 + 2] << 24 |
            (u32)palette[index * 4 + 1] << 16 |
            (u32)palette[index * 4] << 8 | 0xff;
    N3dsPresentTop(pixels);
    N3dsPresentBottom(pixels);
    gspWaitForVBlank();
    return 1;
}

void N3dsWaitForVerticalBlank(void)
{
    gspWaitForVBlank();
}

/* The enhanced OpenGL renderer has no 3DS counterpart; SdlUsingGlRenderer
 * stays false, so these only satisfy the shared video code. */
int SdlGlRendererInitialize(SDL_Window *window)
{
    (void)window;
    return 0;
}

void SdlGlRendererShutdown(void)
{
}

int SdlGlRendererPresent(const unsigned char *pixels,
                         const unsigned char *palette)
{
    (void)pixels;
    (void)palette;
    return 0;
}

void SdlGlRendererWaitForVerticalBlank(void)
{
}

void SdlGlRendererBeginSpaceFrame(
    const struct ScreenViewportGeometry *geometry, int viewportMode,
    int fullViewportCopy, unsigned char clearColour)
{
    (void)geometry;
    (void)viewportMode;
    (void)fullViewportCopy;
    (void)clearColour;
}

void SdlGlRendererCompleteSpaceFrame(void)
{
}

void SdlGlRendererCancelSpaceFrame(void)
{
}

int SdlGlRendererRecordSpaceSprite(const struct Viewport *viewport, float x,
                                   float y, unsigned char *shape,
                                   short frame, short angle, short scale,
                                   short flip)
{
    (void)viewport;
    (void)x;
    (void)y;
    (void)shape;
    (void)frame;
    (void)angle;
    (void)scale;
    (void)flip;
    return 0;
}
