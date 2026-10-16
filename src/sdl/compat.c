#include "wc1sdl.h"

#include <string.h>

#ifndef _WIN32

#include <ctype.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <strings.h>
#include <sys/stat.h>

static int SdlAppendPathComponent(char *path, size_t pathSize,
                                     const char *component)
{
    size_t componentLength;
    size_t pathLength;
    int needsSeparator;

    pathLength = strlen(path);
    componentLength = strlen(component);
    needsSeparator = pathLength != 0 && path[pathLength - 1] != '/';
    if (pathLength + (size_t)needsSeparator + componentLength + 1 > pathSize)
        return 0;
    if (needsSeparator)
        path[pathLength++] = '/';
    memcpy(path + pathLength, component, componentLength + 1);
    return 1;
}

#ifdef __3DS__
/* libctru keeps no current directory that newlib's getcwd() can read back:
 * that walks ".." with readdir, and the SD card device accepts neither.  The
 * port records the directory itself, and resolves every path to an absolute
 * "sdmc:/..." path with "." and ".." folded away. */
static char g_szN3dsCurrentDirectory[PATH_MAX] = "sdmc:/";

const char *SdlGetN3dsCurrentDirectory(void)
{
    return g_szN3dsCurrentDirectory;
}

static int SdlFoldDotComponent(char *path, const char *component)
{
    char *last;
    char *root;

    if (strcmp(component, ".") == 0)
        return 1;
    if (strcmp(component, "..") != 0)
        return 0;
    root = strstr(path, ":/");
    root = root != 0 ? root + 2 : path;
    last = strrchr(root, '/');
    if (last != 0)
        *last = '\0';
    else
        *root = '\0';
    return 1;
}
#endif

static int SdlAppendResolvedComponent(char *path, size_t pathSize,
                                         const char *component)
{
    DIR *directory;
    struct dirent *entry;
    int result;

#ifdef __3DS__
    if (SdlFoldDotComponent(path, component))
        return 1;
#endif
    if (strcmp(component, ".") == 0 || strcmp(component, "..") == 0)
        return SdlAppendPathComponent(path, pathSize, component);
    directory = opendir(path);
    if (directory == 0)
        return SdlAppendPathComponent(path, pathSize, component);
    while ((entry = readdir(directory)) != 0) {
        if (strcasecmp(entry->d_name, component) == 0) {
            result = SdlAppendPathComponent(path, pathSize,
                                               entry->d_name);
            closedir(directory);
            return result;
        }
    }
    closedir(directory);
    return SdlAppendPathComponent(path, pathSize, component);
}

int SdlResolvePath(const char *path, char *resolved,
                      unsigned long resolvedSize)
{
    char component[PATH_MAX];
    char normalized[PATH_MAX];
    char prefix[PATH_MAX];
    const char *cursor;
    char *separator;
    size_t pathLength;

    if (path == 0 || resolved == 0 || resolvedSize == 0)
        return 0;
    pathLength = strlen(path);
    if (pathLength >= sizeof(normalized))
        return 0;
    memcpy(normalized, path, pathLength + 1);
    separator = normalized;
    while (*separator != '\0') {
        if (*separator == '\\')
            *separator = '/';
        separator++;
    }
    cursor = normalized;
#ifdef __3DS__
    /* libctru paths name their device, as in "sdmc:/3ds/wc1".  Keep the
     * device and its root as the prefix rather than resolving "sdmc:" as a
     * directory under ".". */
    separator = strchr(normalized, ':');
    if (separator != 0 && separator[1] == '/' &&
        strchr(normalized, '/') == separator + 1) {
        if ((size_t)(separator - normalized) + 3 > sizeof(prefix))
            return 0;
        memcpy(prefix, normalized, (size_t)(separator - normalized) + 2);
        prefix[separator - normalized + 2] = '\0';
        cursor = separator + 1;
    } else if (normalized[0] == '/') {
        strcpy(prefix, "sdmc:/");
    } else if (strlen(g_szN3dsCurrentDirectory) < sizeof(prefix)) {
        strcpy(prefix, g_szN3dsCurrentDirectory);
    } else
        return 0;
#else
    if (normalized[0] == '/')
        strcpy(prefix, "/");
    else
        strcpy(prefix, ".");
#endif
    while (*cursor == '/')
        cursor++;
    while (*cursor != '\0') {
        const char *end;
        size_t componentLength;

        end = cursor;
        while (*end != '\0' && *end != '/')
            end++;
        componentLength = (size_t)(end - cursor);
        if (componentLength >= sizeof(component))
            return 0;
        memcpy(component, cursor, componentLength);
        component[componentLength] = '\0';
        if (!SdlAppendResolvedComponent(prefix, sizeof(prefix), component))
            return 0;
        cursor = end;
        while (*cursor == '/')
            cursor++;
    }
    pathLength = strlen(prefix);
    if (pathLength + 1 > resolvedSize)
        return 0;
    memcpy(resolved, prefix, pathLength + 1);
    return 1;
}

int SdlChangeDirectory(const char *path)
{
    char resolved[PATH_MAX];

    if (!SdlResolvePath(path, resolved, sizeof(resolved)))
        return -1;
#ifdef __3DS__
    if (chdir(resolved) != 0)
        return -1;
    strcpy(g_szN3dsCurrentDirectory, resolved);
    return 0;
#else
    return chdir(resolved);
#endif
}

int SdlOpen(const char *path, int flags, ...)
{
    int hostFlags;
    int hostMode;
    int file;
    char hostPath[PATH_MAX];

    hostFlags = flags & 3;
    if ((flags & 0x0008) != 0)
        hostFlags |= O_APPEND;
    if ((flags & 0x0100) != 0)
        hostFlags |= O_CREAT;
    if ((flags & 0x0200) != 0)
        hostFlags |= O_TRUNC;
    if ((flags & 0x0400) != 0)
        hostFlags |= O_EXCL;

    hostMode = S_IRUSR | S_IWUSR;
    if ((flags & 0x0100) != 0) {
        va_list arguments;
        int dosMode;

        va_start(arguments, flags);
        dosMode = va_arg(arguments, int);
        va_end(arguments);
        hostMode = 0;
        if ((dosMode & 0x0100) != 0)
            hostMode |= S_IRUSR;
        if ((dosMode & 0x0080) != 0)
            hostMode |= S_IWUSR;
    }

    if (!SdlResolvePath(path, hostPath, sizeof(hostPath)))
        return -1;
    file = open(hostPath, hostFlags, hostMode);
    if (file == -1 && (hostFlags & O_ACCMODE) == O_RDWR &&
        (hostFlags & O_CREAT) == 0) {
        hostFlags = (hostFlags & ~O_ACCMODE) | O_RDONLY;
        file = open(hostPath, hostFlags, hostMode);
    }
    return file;
}

long SdlFileLength(int file)
{
    struct stat status;

    if (fstat(file, &status) != 0)
        return -1;
    return (long)status.st_size;
}

static char *SdlLowercaseDigits(char *text)
{
    char *cursor;

    cursor = text;
    while (*cursor != '\0') {
        *cursor = (char)tolower((unsigned char)*cursor);
        cursor++;
    }
    return text;
}

char *SdlItoa(int value, char *text, int radix)
{
    return SdlLtoa((long)value, text, radix);
}

char *SdlLtoa(long value, char *text, int radix)
{
    if (radix == 10)
        return SDL_ltoa(value, text, radix);
    else if (radix == 16)
        return SdlLowercaseDigits(
            SDL_ultoa((unsigned long)value, text, radix));
    text[0] = '\0';
    return text;
}

char *SdlUltoa(unsigned long value, char *text, int radix)
{
    if (radix == 10)
        return SDL_ultoa(value, text, radix);
    else if (radix == 16)
        return SdlLowercaseDigits(SDL_ultoa(value, text, radix));
    text[0] = '\0';
    return text;
}

char *SdlStrupr(char *text)
{
    char *cursor;

    cursor = text;
    while (*cursor != '\0') {
        *cursor = (char)toupper((unsigned char)*cursor);
        cursor++;
    }
    return text;
}

#else

int SdlChangeDirectory(const char *path)
{
    return _chdir(path);
}

int SdlResolvePath(const char *path, char *resolved,
                      unsigned long resolvedSize)
{
    size_t pathLength;

    if (path == 0 || resolved == 0 || resolvedSize == 0)
        return 0;
    pathLength = strlen(path);
    if (pathLength + 1 > resolvedSize)
        return 0;
    memcpy(resolved, path, pathLength + 1);
    return 1;
}

#endif
