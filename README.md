# xvnc

[Xvnc](https://tigervnc.org/doc/Xvnc.html) — the [TigerVNC](https://tigervnc.org)
X server: a full X11 server that renders to memory and exports the display over
the [VNC/RFB](https://en.wikipedia.org/wiki/RFB_protocol) protocol, so remote VNC
viewers can attach to a headless desktop. A single self-contained binary, built
natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/xvnc/actions/workflows/xvnc.yml/badge.svg)](https://github.com/unpins/xvnc/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install xvnc`.

The binary keeps its upstream name `Xvnc`; a lowercase `xvnc` is installed as a convenience symlink.

## Usage

Run `Xvnc` with [unpin](https://github.com/unpins/unpin):

```bash
unpin Xvnc :1 -geometry 1280x1024 -depth 24 -SecurityTypes None &  # display :1 → VNC port 5901
DISPLAY=:1 your-gui-program                                         # point clients at it
# then attach any VNC viewer to localhost:5901
```

To install it onto your PATH:

```bash
unpin install xvnc
```

Everything an X server normally reads from disk is **embedded in the binary** —
no `XKB`/keymap directory, no font path, no companion files to ship:

- **Keyboard layouts (XKB).** The full
  [`xkeyboard-config`](https://www.freedesktop.org/wiki/Software/XKeyboardConfig/)
  tree is embedded and the keymap compiler (`xkbcomp`) runs **in-process** — any
  RMLVO layout compiles from the in-binary tree with no external `xkbcomp` and
  nothing written to `/tmp`.
- **Core fonts.** `fixed`, `cursor`, and the `misc` bitmap fonts are embedded at
  the default font path, so clients that ask for the built-in fonts work with no
  font server or font directory.
- **TLS built in.** The VNC TLS security types (`X509`, `TLSVnc`, `RA2`) are
  linked statically against GnuTLS, so encrypted sessions work with no shared
  library to ship — bring your own x509 cert/key.

## Build locally

```bash
nix build github:unpins/xvnc
./result/bin/Xvnc -version
```

Or run directly:

```bash
nix run github:unpins/xvnc -- :1 -geometry 1024x768 -SecurityTypes None
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/xvnc/releases) page has standalone binaries for manual download.

## Build notes

- **In-process xkbcomp (every keymap).** A normal X server forks an external
  `xkbcomp` to turn the selected layout into a compiled keymap. There is no
  external binary in a single-file build, so the entire client-side XKB stack
  (xkbcomp's sources plus the display-free struct/IO members lifted straight from
  `libX11`/`libxkbfile`) is bundled into one self-contained object that exports a
  single entry point and depends on nothing but libc. `RunXkbComp` is patched to
  call it in-process (fork + an in-memory spec/`.xkm` handoff), so the full RMLVO
  → keymap pipeline runs from the embedded `xkeyboard-config` tree.

- **Embedded data via the VFS (unpin-vfs).** The server opens its XKB rules,
  symbols, and font files with `open`/`fopen`/`opendir`. The `xkeyboard-config`
  tree and core bitmap fonts are packed into a ZIP appended at the binary's EOF
  and served by the shared [unpin-vfs](https://github.com/unpins/unpin) core. On
  Linux the libc file calls are routed through the VFS with `ld --wrap`; on macOS
  (no `--wrap` for Mach-O) the server's own objects are rewritten with
  `llvm-objcopy --redefine-sym` and relinked; on Windows the data lives in the
  Cosmopolitan's native `/zip` store. A live X server reads from the in-binary
  mount only — no `/nix/store`, no system XKB/font directory.

- **Three platform paths, one binary each.**
  - **Linux** (static-musl, every arch): TigerVNC trimmed to the Xvnc DDX, linked
    statically, XKB + fonts embedded, `file` reports `statically linked`, no
    `/nix/store` closure.
  - **macOS** (Mach-O, libSystem-only): not pure `pkgsStatic` (the X stack's
    meson/python toolchain can't link statically on macOS) — built with the
    dynamic darwin stdenv but with every linked library (including GnuTLS and its
    nettle/tasn1/gmp tail and `libc++`) swapped to its `pkgsStatic` `.a`, yielding
    a libSystem-only Mach-O.
  - **Windows** via [Cosmopolitan](https://github.com/jart/cosmopolitan): the
    same X server compiled to an APE and apelinked to an `Xvnc.exe` PE32+, with
    the data served from cosmo's native `/zip` and TLS against a cosmo-slimmed
    GnuTLS.

- **Headless, viewer/PAM-free.** This ships only the `Xvnc` server — the FLTK
  viewer, the `vncserver`/`vncpasswd`/`x0vncserver` wrapper tools, PAM, Wayland,
  and H.264 are all dropped. GL/GLX/DRI3 are disabled; it renders to memory and
  needs no root, KMS, or DRM.
```
