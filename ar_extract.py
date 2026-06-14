#!/usr/bin/env python3
# Extract named members from an ar archive by parsing the format and slicing the
# bytes ourselves. Worked around a darwin/nix bug where EVERY ar extractor
# (llvm-ar, cctools `ar x`/`ar p`, bsdtar) silently TRUNCATES some members
# (e.g. libX11.a's XKBMisc.o: 7328B written for a 12920B member, dropping
# XkbInitCanonicalKeyTypes) even though the archive file itself is intact.
# A plain file read does not truncate. Handles the BSD `#1/N` long-name variant.
#
# Usage: ar_extract.py <archive> <outdir> <member.o> [<member.o> ...]
import sys, os

archive, outdir = sys.argv[1], sys.argv[2]
want = set(sys.argv[3:])
data = open(archive, "rb").read()
assert data[:8] == b"!<arch>\n", "not an ar archive"

pos = 8
got = set()
while pos + 60 <= len(data):
    hdr = data[pos:pos + 60]
    pos += 60
    name = hdr[0:16].decode("ascii", "replace").rstrip()
    size = int(hdr[48:58].decode("ascii").strip())
    body = data[pos:pos + size]
    pos += size + (size & 1)  # members are padded to an even offset
    if name.startswith("#1/"):  # BSD extended name: real name is in the body
        n = int(name[3:].strip())
        real = body[:n].split(b"\x00", 1)[0].decode("ascii", "replace")
        obj = body[n:]
    else:
        real = name
        obj = body
    base = os.path.basename(real)
    if base in want:
        with open(os.path.join(outdir, base), "wb") as f:
            f.write(obj)
        got.add(base)

missing = want - got
if missing:
    sys.stderr.write("ar_extract: members not found: %s\n" % " ".join(sorted(missing)))
    sys.exit(1)
