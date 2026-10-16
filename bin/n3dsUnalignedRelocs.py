#!/usr/bin/env python3
"""Neutralize unaligned absolute relocations in a 3DS ELF before 3dsxtool.

Several recovered tables are byte-packed and statically hold pointers at odd
offsets (aObjectTypeData, aBriefingCharacters, aMissionShips, ...).  The 3DSX
relocation format addresses whole words, so 3dsxtool stops at them with
"Unaligned relocation!".

A 3DSX is always loaded at the host title's text base, 0x00100000, with its
segments laid out exactly as linked.  A pointer that 3dsxtool leaves alone
therefore keeps its correct linked address.  This rewrites each unaligned
R_ARM_ABS32 entry as R_ARM_NONE at the containing word, which 3dsxtool skips.

    n3dsUnalignedRelocs.py wc1.elf
"""

import struct
import sys

SHT_REL = 9
SHF_ALLOC = 0x2
R_ARM_NONE = 0
R_ARM_ABS32 = 2


def main(path):
    with open(path, "rb") as handle:
        image = bytearray(handle.read())
    if image[:4] != b"\x7fELF" or image[4] != 1 or image[5] != 1:
        sys.exit(f"{path}: not a little-endian ELF32 file")
    shoff, = struct.unpack_from("<I", image, 0x20)
    shentsize, shnum = struct.unpack_from("<HH", image, 0x2E)
    sections = [struct.unpack_from("<IIIIIIIIII", image, shoff + i * shentsize)
                for i in range(shnum)]
    patched = 0
    for _, kind, _, _, offset, size, _, info, _, entsize in sections:
        if kind != SHT_REL or entsize != 8:
            continue
        # Debug sections are not loaded, so their relocations never matter.
        if not sections[info][2] & SHF_ALLOC:
            continue
        for entry in range(offset, offset + size, 8):
            r_offset, r_info = struct.unpack_from("<II", image, entry)
            if r_info & 0xFF != R_ARM_ABS32 or r_offset & 3 == 0:
                continue
            struct.pack_into("<II", image, entry, r_offset & ~3,
                             (r_info & ~0xFF) | R_ARM_NONE)
            patched += 1
    with open(path, "wb") as handle:
        handle.write(image)
    print(f"{path}: {patched} unaligned absolute relocations left as linked")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
