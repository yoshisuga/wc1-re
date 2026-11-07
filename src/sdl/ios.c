#include "wc1.h"

#include "ios.h"

#include <dirent.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

/* Returns nonzero when the folder holds a GAMEDAT folder, in any case. */
static int IosFolderHoldsGameData(const char *path)
{
    DIR *directory;
    struct dirent *entry;
    int found;

    directory = opendir(path);
    if (directory == 0)
        return 0;
    found = 0;
    while ((entry = readdir(directory)) != 0) {
        if (strcasecmp(entry->d_name, "GAMEDAT") == 0) {
            found = 1;
            break;
        }
    }
    closedir(directory);
    return found;
}

int IosFindGameDirectory(void)
{
    char documents[PATH_MAX];
    char candidate[PATH_MAX];
    const char *home;
    DIR *directory;
    struct dirent *entry;
    struct stat status;
    int empty;

    home = getenv("HOME");
    if (home == 0 ||
        snprintf(documents, sizeof(documents), "%s/Documents", home) >=
            (int)sizeof(documents))
        return 0;
    if (IosFolderHoldsGameData(documents))
        return SdlChangeDirectory(documents) == 0;
    directory = opendir(documents);
    if (directory == 0)
        return 0;
    empty = 1;
    while ((entry = readdir(directory)) != 0) {
        if (entry->d_name[0] == '.')
            continue;
        empty = 0;
        if (snprintf(candidate, sizeof(candidate), "%s/%s", documents,
                     entry->d_name) >= (int)sizeof(candidate) ||
            stat(candidate, &status) != 0 || !S_ISDIR(status.st_mode))
            continue;
        if (IosFolderHoldsGameData(candidate)) {
            closedir(directory);
            return SdlChangeDirectory(candidate) == 0;
        }
    }
    closedir(directory);
    /* The Files app lists the app only once Documents holds something, so
     * a new install gets a folder to copy the game into. */
    if (empty &&
        snprintf(candidate, sizeof(candidate), "%s/WC1", documents) <
            (int)sizeof(candidate))
        mkdir(candidate, 0755);
    return 0;
}

int IosFlightActive(void)
{
    return pEventManagerPump == get_player_input && nArcadeState == 0;
}

/* The enhanced OpenGL renderer needs desktop OpenGL 3.2, which iOS does
 * not have; SdlUsingGlRenderer stays false, so these only satisfy the
 * shared video code. */
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
