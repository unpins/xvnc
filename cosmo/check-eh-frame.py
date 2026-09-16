#!/usr/bin/env python3
# Fail if a cosmo ELF's unwind table ends early.
#
# Cosmo's ape.lds folds every input .eh_frame into .data between
# __eh_frame_start and __eh_frame_end, byte for byte. Alignment padding between
# two inputs is zeros, and a zero length field is how the unwinder recognises
# the end of the table: every entry after the gap is invisible to it. When the
# C++ runtime lies past the gap, no exception can be caught and the first
# `throw` aborts the process.
#
# usage: check-eh-frame.py <elf> <nm>
import struct
import subprocess
import sys

elf, nm = sys.argv[1], sys.argv[2]
data = open(elf, "rb").read()

syms = {}
for line in subprocess.check_output([nm, elf], text=True).splitlines():
    parts = line.split()
    if len(parts) == 3 and parts[2] in ("__eh_frame_start", "__eh_frame_end"):
        syms[parts[2]] = int(parts[0], 16)
if len(syms) != 2:
    sys.exit(f"FATAL: {elf}: __eh_frame_start/__eh_frame_end not found")
start, end = syms["__eh_frame_start"], syms["__eh_frame_end"]

# Map the virtual address to a file offset through the PT_LOAD segments.
phoff = struct.unpack_from("<Q", data, 0x20)[0]
phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
offset = None
for i in range(phnum):
    p_type, _, p_offset, p_vaddr, _, p_filesz = struct.unpack_from(
        "<IIQQQQ", data, phoff + i * phentsize)
    if p_type == 1 and p_vaddr <= start and end <= p_vaddr + p_filesz:
        offset = p_offset + (start - p_vaddr)
if offset is None:
    sys.exit(f"FATAL: {elf}: eh_frame range not inside a loaded segment")

pos, stop, entries = offset, offset + (end - start), 0
while pos < stop:
    length = struct.unpack_from("<I", data, pos)[0]
    if length == 0:
        if any(data[pos:stop]):
            sys.exit(f"FATAL: {elf}: .eh_frame ends at byte {pos - offset} of "
                     f"{stop - offset} after {entries} entries; everything "
                     "past it cannot be unwound, so C++ exceptions abort")
        break
    if length == 0xFFFFFFFF:
        sys.exit(f"FATAL: {elf}: 64-bit .eh_frame entry not handled")
    entries += 1
    pos += 4 + length
print(f"eh_frame OK: {entries} entries, {end - start} bytes, no gap")
