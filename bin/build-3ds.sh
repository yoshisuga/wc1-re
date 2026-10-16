#!/bin/sh
# Builds out-3ds/wc1.3dsx.  Inside a devkitARM environment (for example the
# devkitpro/devkitarm Docker image) it builds directly; elsewhere it runs
# itself in that image:
#
#   bin/build-3ds.sh
#
# N3DS_DOCKER_IMAGE picks another image with devkitARM and libctru.  The
# build runs in a fresh, throwaway container that sees only this checkout.
# The first run builds SDL2 and LZO for the 3DS into out-3ds/deps; nothing
# is installed into the image or its devkitPro tree.
set -eu

SDL2_TAG=release-2.32.10
LZO_URL=https://github.com/nemequ/lzo.git

cd "$(dirname "$0")/.."
root=$(pwd)

if [ -z "${DEVKITARM:-}" ] && [ ! -d /opt/devkitpro/devkitARM ]; then
    exec docker run --rm -v "$root:/src" -w /src \
        -u "$(id -u):$(id -g)" -e HOME=/tmp \
        "${N3DS_DOCKER_IMAGE:-devkitpro/devkitarm:latest}" \
        sh bin/build-3ds.sh "$@"
fi

export DEVKITPRO=${DEVKITPRO:-/opt/devkitpro}
export DEVKITARM=${DEVKITARM:-$DEVKITPRO/devkitARM}
export PATH="$DEVKITARM/bin:$DEVKITPRO/tools/bin:$PATH"
toolchain=$DEVKITPRO/cmake/3DS.cmake
deps=$root/out-3ds/deps
src=$root/out-3ds/src
jobs=$(nproc 2>/dev/null || echo 4)

if [ ! -f "$deps/lib/libSDL2.a" ]; then
    mkdir -p "$src"
    [ -d "$src/SDL" ] || git clone --depth 1 -b "$SDL2_TAG" \
        https://github.com/libsdl-org/SDL.git "$src/SDL"
    rm -rf "$src/build-sdl2"
    # The game needs 4-byte enums; see Makefile.3ds.
    CFLAGS=-fno-short-enums cmake -S "$src/SDL" -B "$src/build-sdl2" \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$deps" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF
    cmake --build "$src/build-sdl2" -j "$jobs"
    cmake --install "$src/build-sdl2"
    # The software keyboard shares SwkbdState, which holds enums, with
    # libctru, so that one file keeps libctru's small enums.
    swkbd=$(arm-none-eabi-ar t "$deps/lib/libSDL2.a" | grep n3dsswkb)
    arm-none-eabi-gcc -march=armv6k -mtune=mpcore -mfloat-abi=hard \
        -mtp=soft -O2 -D__3DS__ -DSDL_VIDEO_DRIVER_N3DS \
        -I"$src/build-sdl2/include" \
        -I"$src/build-sdl2/include-config-release" \
        -I"$src/SDL/include" -I"$src/SDL/src" \
        -I"$DEVKITPRO/libctru/include" \
        -c "$src/SDL/src/video/n3ds/SDL_n3dsswkb.c" -o "$src/$swkbd"
    (cd "$src" && arm-none-eabi-ar r "$deps/lib/libSDL2.a" "$swkbd")
fi

if [ ! -f "$deps/lib/liblzo2.a" ]; then
    mkdir -p "$src"
    [ -d "$src/lzo" ] || git clone --depth 1 "$LZO_URL" "$src/lzo"
    rm -rf "$src/build-lzo"
    cmake -S "$src/lzo" -B "$src/build-lzo" \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$deps" \
        -DENABLE_STATIC=ON -DENABLE_SHARED=OFF
    cmake --build "$src/build-lzo" -j "$jobs" --target lzo_static_lib
    mkdir -p "$deps/lib" "$deps/include/lzo"
    cp "$src/build-lzo/liblzo2.a" "$deps/lib/"
    cp "$src/lzo/include/lzo/"*.h "$deps/include/lzo/"
fi

make -f Makefile.3ds -j "$jobs" N3DS_DEPS="$deps" "$@"
