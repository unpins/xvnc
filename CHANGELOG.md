# Changelog

## [Unreleased]

### Fixed

- On macOS and Windows, TrueType and OpenType fonts in a directory added with
  `-fp` were ignored: only bitmap fonts were served. They now work as on Linux.
- Scalable fonts (TrueType, OpenType) on the font path no longer depend on a
  HarfBuzz shared library at run time. FreeType used one, when the system had
  it, to hint glyphs such as small caps and superscripts; that HarfBuzz is now
  built into the binary on every platform, so the result no longer depends on
  what the system has installed.

## [1.16.2-1] - 2026-09-26

Initial release — Xvnc from TigerVNC 1.16.2 (X server 21.1.22) as a single
self-contained binary, built natively for Linux, macOS, and Windows.

### Fixed

- On Windows, a single malformed message from a client crashed the whole
  server, and so did every `VncAuth` login. Errors now close only that
  connection, and password login works.
- On Windows, `Xvnc :1` exited with `Cannot establish any listening sockets`
  and only started with `-listen tcp`. It now listens on TCP by default.
- On Windows, the embedded bitmap fonts were not served: clients saw 11 fonts
  instead of 509.

### Added

- Builds for Linux (x86_64, aarch64, armv7l, i686, ppc64le, riscv64), macOS
  (x86_64, aarch64), and Windows.
- The keyboard layouts (`xkeyboard-config`) and the core `misc`/`cursor` bitmap
  fonts are embedded, and keymaps are compiled inside the server, so it needs no
  XKB directory, font path or `xkbcomp` on the machine.
- TLS and RSA-AES security types, linked in statically.
- The `Xvnc` man page, embedded — read it with `unpin man xvnc Xvnc`.
