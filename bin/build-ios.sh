#!/bin/sh
# Builds "WingCommander.app" for an iPhone or iPad, or for the iOS
# Simulator:
#
#   bin/build-ios.sh simulator   # out-ios/simulator/WingCommander.app
#   bin/build-ios.sh device      # out-ios/device/WingCommander.app
#
# The first run builds SDL2 and LZO for that slice into
# out-ios/<slice>/deps.  A simulator build is signed ad hoc.  A device build
# is signed with IOS_CODESIGN_IDENTITY and embeds IOS_PROVISIONING_PROFILE;
# see docs/IOS.md.  Further arguments go to make.
set -eu

SDL2_TAG=release-2.32.10
LZO_URL=https://github.com/nemequ/lzo.git

cd "$(dirname "$0")/.."
root=$(pwd)

slice=${1:-simulator}
[ $# -gt 0 ] && shift
case "$slice" in
device)
    sdk=iphoneos
    target_suffix=
    ;;
simulator | sim)
    slice=simulator
    sdk=iphonesimulator
    target_suffix=-simulator
    ;;
*)
    echo "usage: $0 device|simulator [make arguments]" >&2
    exit 2
    ;;
esac

deployment_target=${IOS_DEPLOYMENT_TARGET:-15.0}
bundle_id=${IOS_BUNDLE_ID:-org.wc1re.wingcommander}
sign_identity=${IOS_CODESIGN_IDENTITY:--}
profile=${IOS_PROVISIONING_PROFILE:-}
out=$root/out-ios/$slice
deps=$out/deps
src=$root/out-ios/src
jobs=$(sysctl -n hw.logicalcpu)
sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
target=arm64-apple-ios$deployment_target$target_suffix

for command in cmake codesign git make xcrun; do
    command -v "$command" >/dev/null ||
        { echo "$command is required" >&2; exit 1; }
done

cmake_ios() {
    cmake -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk_path" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$deps" \
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO "$@"
}

if [ ! -f "$deps/lib/libSDL2.a" ]; then
    mkdir -p "$src"
    [ -d "$src/SDL" ] || git clone --depth 1 -b "$SDL2_TAG" \
        https://github.com/libsdl-org/SDL.git "$src/SDL"
    rm -rf "$out/build-sdl2"
    cmake_ios -S "$src/SDL" -B "$out/build-sdl2" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF
    cmake --build "$out/build-sdl2" -j "$jobs"
    cmake --install "$out/build-sdl2"
fi

if [ ! -f "$deps/lib/liblzo2.a" ]; then
    mkdir -p "$src"
    [ -d "$src/lzo" ] || git clone --depth 1 "$LZO_URL" "$src/lzo"
    rm -rf "$out/build-lzo"
    cmake_ios -S "$src/lzo" -B "$out/build-lzo" \
        -DENABLE_STATIC=ON -DENABLE_SHARED=OFF
    cmake --build "$out/build-lzo" -j "$jobs" --target lzo_static_lib
    mkdir -p "$deps/lib" "$deps/include/lzo"
    cp "$out/build-lzo/liblzo2.a" "$deps/lib/"
    cp "$src/lzo/include/lzo/"*.h "$deps/include/lzo/"
fi

make -f Makefile.ios -j "$jobs" IOS_SLICE="$slice" IOS_SDK="$sdk" \
    IOS_TARGET="$target" IOS_DEPLOYMENT_TARGET="$deployment_target" \
    IOS_BUNDLE_ID="$bundle_id" "$@"

app="$out/WingCommander.app"
entitlements=
if [ -n "$profile" ]; then
    cp "$profile" "$app/embedded.mobileprovision"
    security cms -D -i "$profile" >"$out/profile.plist"
    # A wildcard profile names "PREFIX.*"; the app needs its own identifier.
    prefix=$(plutil -extract ApplicationIdentifierPrefix.0 raw \
        "$out/profile.plist")
    team=$(plutil -extract TeamIdentifier.0 raw "$out/profile.plist")
    entitlements=$out/entitlements.plist
    cat >"$entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>application-identifier</key><string>$prefix.$bundle_id</string>
    <key>com.apple.developer.team-identifier</key><string>$team</string>
    <key>get-task-allow</key><true/>
</dict></plist>
PLIST
fi
if [ -n "$entitlements" ]; then
    codesign --force --sign "$sign_identity" --timestamp=none \
        --entitlements "$entitlements" "$app"
else
    codesign --force --sign "$sign_identity" --timestamp=none "$app"
fi
echo "Built $app"
