# Linux (static-musl) Xvnc server derivation: TigerVNC trimmed to the Xvnc DDX
# only (no fltk viewer, PAM, wayland, h264, nls), built static, with the
# in-process xkbcomp blob + the VFS reader (vfs.c/miniz via `ld --wrap`) linked
# in. It does NOT embed the xkb/font data or strip itself — the flake delegates
# that to nix-lib's withUnpinEmbed (one self-EOF ZIP appended after the
# framework's strip), exactly like the zsh/vim/xvfb ports.
#
# TigerVNC is a two-stage build: CMake builds common/ (rfb/rdr/core/network/
# unixcommon C++ libs), then nixpkgs' postBuild overlays the xorg-server source,
# patches it (unix/xserver21.patch), autoreconf + ./configure + make → the
# hw/vnc/Xvnc DDX. We fully replace that postBuild to repoint paths at /zip, patch
# RunXkbComp to compile in-process, and link the VFS objects + --wrap.
#
# `static` is a target static-musl pkg set (native or cross) with staticFixes;
# `pkgs` is the build-host-aware nixpkgs (build-host tools via pkgs.buildPackages);
# `xkbcompObj` is the matching linux-xkbcomp.nix blob.
{ static, pkgs, xkbcompObj }:
let
  bpkgs = pkgs.buildPackages;

  drop = names: inputs: builtins.filter
    (x: !(builtins.elem (x.pname or x.name or "") names)) inputs;
  # Xvnc is headless: drop the GL stack (also kills the pkgsStatic SDL3-broken
  # eval pulled via ffmpeg/mesa), dbus/systemd/udev, PAM, the fltk viewer, h264.
  junk = [ "fltk" "libGLU" "glu" "libepoxy" "libglvnd" "mesa" "mesa-gl-headers"
           "mesa-libgbm" "SDL2" "SDL3" "ffmpeg" "ffmpeg-full"
           "pam" "linux-pam" "pipewire" "wayland" "libpciaccess" "libxshmfence"
           "dbus" "systemd" "systemd-minimal-libs" "libunwind"
           # Runtime tooling for the dropped vncserver/vncviewer wrappers — Xvnc
           # itself never uses them. They build on native/i686 but fail cross on
           # some arches (perl/openssh ld errors), so drop them everywhere.
           "perl" "openssh" "xterm" "xauth" "tab-window-manager" "xsetroot" ];
in
(static.tigervnc.override {
  # Cut the wayland/pipewire/SDL3 chain at the arg level.
  waylandSupport = false;
  # openssh is interpolated into vncviewer.cxx by the nixpkgs postPatch
  # (${openssh}/bin/ssh), forcing a cross build even though we drop the viewer.
  # Use the build-host one (cached, never ends up in Xvnc).
  openssh = bpkgs.openssh;
}).overrideAttrs (o: {
  pname = "xvnc";
  # autoreconf needs xtrans's aclocal macros (XTRANS_CONNECTION_FLAGS); xtrans is
  # header+m4 only (arch-independent) so the build-host pkg serves cross too.
  nativeBuildInputs = (o.nativeBuildInputs or []) ++ [ bpkgs.xtrans ];
  cmakeFlags = (o.cmakeFlags or []) ++ [
    "-DBUILD_VIEWER=0" "-DENABLE_NLS=0" "-DENABLE_H264=0"
  ];
  # PAM dropped: find_package non-required + PAM-free UnixPasswordValidator stub
  # (the rfb lib still links via the kept API). Also trim the unshipped unix/*
  # tools (vncserver→vncsession→PAM; x0vncserver/tx→GUI) and the tests.
  postPatch = (o.postPatch or "") + ''
    substituteInPlace CMakeLists.txt \
      --replace-fail "find_package(PAM REQUIRED)" "find_package(PAM)" \
      --replace-fail "add_subdirectory(tests)" "# unpins: dropped (tests not shipped)"
    cp ${./UnixPasswordValidator-stub.cxx} common/rfb/UnixPasswordValidator.cxx
    substituteInPlace unix/CMakeLists.txt \
      --replace-fail "add_subdirectory(tx)" "# unpins: dropped" \
      --replace-fail "add_subdirectory(vncconfig)" "# unpins: dropped" \
      --replace-fail "add_subdirectory(vncpasswd)" "# unpins: dropped" \
      --replace-fail "add_subdirectory(vncserver)" "# unpins: dropped" \
      --replace-fail "add_subdirectory(x0vncserver)" "# unpins: dropped"
  '';
  # Full replacement of the nixpkgs postBuild (autotools xserver hw/vnc → Xvnc):
  #   - paths repointed to the embedded /zip VFS
  #   - RunXkbComp patched to compile in-process
  #   - --disable-glx (GL stack dropped)
  #   - VFS objects + --wrap added to NIX_LDFLAGS AFTER ./configure (its cc-link
  #     probes would otherwise link vfs.o / hit undefined __wrap_*).
  postBuild = ''
    vfsdir=$NIX_BUILD_TOP/vfsobj; mkdir -p $vfsdir
    $CC -O2 -DMINIZ_USE_ZSTD -DUNPIN_VFS_SELF -DUNPIN_VFS_DIRS \
      -I${./src} -c ${./src/vfs.c} -o $vfsdir/vfs.o
    $CC -O2 -DMINIZ_USE_ZSTD -I${./src} -c ${./src/miniz.c} -o $vfsdir/miniz.o
    $CC -O2 -DMINIZ_USE_ZSTD -DUNPIN_ZSTD_VENDORED -I${./src} \
      -c ${./src/unpin_zstd.c} -o $vfsdir/unpin_zstd.o

    export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -Wno-error=int-to-pointer-cast -Wno-error=pointer-to-int-cast"
    export CXXFLAGS="$CXXFLAGS -fpermissive"
    tar xf ${bpkgs.xorg-server.src}
    cp -R xorg*/* unix/xserver
    pushd unix/xserver
    patch -p1 < "$source_top/unix/xserver21.patch"

    # RunXkbComp → in-process fork + unpin_xkbcomp_main (build-host python3).
    ${bpkgs.python3.interpreter} ${./patch-ddxload.py}

    autoreconf -vfi
    ./configure $configureFlags --disable-devel-docs --disable-docs \
        --disable-xorg --disable-xnest --disable-xvfb --disable-dmx \
        --disable-xwin --disable-xephyr --disable-kdrive --with-pic \
        --disable-xorgcfg --disable-xprint --disable-static \
        --enable-composite --disable-xtrap --enable-xcsecurity \
        --disable-afb --disable-cfb --disable-mfb \
        --disable-xwayland \
        --disable-config-dbus --disable-config-udev --disable-config-hal \
        --disable-xevie \
        --disable-dri --disable-dri2 --disable-dri3 --disable-glx \
        --enable-install-libxf86config \
        --prefix="$out" --disable-unit-tests \
        --with-xkb-path=/zip/xkb \
        --with-xkb-bin-directory=/usr/bin \
        --with-xkb-output=/tmp \
        --with-default-font-path=/zip/fonts/misc

    export NIX_LDFLAGS="$NIX_LDFLAGS \
      --wrap=open --wrap=stat --wrap=lstat --wrap=access \
      --wrap=fopen --wrap=opendir --wrap=readdir --wrap=closedir \
      $vfsdir/vfs.o $vfsdir/miniz.o $vfsdir/unpin_zstd.o \
      ${xkbcompObj}/xkbcomp_localized.o"

    make TIGERVNC_SRC=$src TIGERVNC_BUILDDIR=`pwd`/../.. -j$NIX_BUILD_CORES
    popd
  '';

  buildInputs = drop junk (o.buildInputs or [])
    ++ [ static.libtasn1 static.libidn2 static.libunistring static.gmp ];
  propagatedBuildInputs = drop junk (o.propagatedBuildInputs or []);
  # Static gnutls's full transitive tail after -lgnutls (appended, not
  # force-linked, so the bare CMake compiler probe ignores them).
  env = (o.env or {}) // {
    NIX_LDFLAGS = (o.env.NIX_LDFLAGS or "")
      + " -ltasn1 -lidn2 -lunistring -lhogweed -lnettle -lgmp";
  };

  # Keep the upstream binary name `Xvnc` (catalog policy: binaries keep their
  # upstream name). withUnpinEmbed (primary = "Xvnc") embeds into it after strip.
  # The catalog gate locates result/bin/<package-name> == result/bin/xvnc, so add
  # a lowercase compat symlink → the upstream binary; `readlink -f` resolves it
  # for verify/smoke/stage and no rename touches the real binary.
  installPhase = ''
    runHook preInstall
    install -Dm755 unix/xserver/hw/vnc/Xvnc $out/bin/Xvnc
    # Man page (best-effort: the autotools build emits hw/vnc/Xvnc.1 from .man).
    if [ -f unix/xserver/hw/vnc/Xvnc.1 ]; then
      install -Dm644 unix/xserver/hw/vnc/Xvnc.1 $out/share/man/man1/Xvnc.1
    fi
    ln -s Xvnc $out/bin/xvnc
    runHook postInstall
  '';
  postInstall = "";

  meta = (o.meta or {}) // { platforms = pkgs.lib.platforms.all; };

  # Scrub the unused gnutls store ref + assert a single ELF binary. Runs after the
  # framework strip and BEFORE withUnpinEmbed appends the data/man ZIP.
  postFixup = (o.postFixup or "") + ''
    bin=$out/bin/Xvnc
    rm -rf $out/nix-support
    # gnutls bakes ${"\${gnutls.out}"}/etc/gnutls/config + share/locale — unused
    # here (VNC TLS uses user x509 certs, no NLS), so scrub the foreign ref.
    ${bpkgs.removeReferencesTo}/bin/remove-references-to -t ${static.gnutls.out} "$bin"

    # The VFS objects + --wrap flags ride on the GLOBAL NIX_LDFLAGS, so they apply
    # to every link. That is only sound while Xvnc is the SOLE linked executable.
    # Assert it (the xvnc symlink is -type l, not counted).
    elfbins=""
    for f in $(find "$out" -type f); do
      file -b "$f" | grep -q "ELF.*executable" && elfbins="$elfbins $f"
    done
    if [ "$(echo $elfbins | wc -w)" != 1 ]; then
      echo "FATAL: expected exactly 1 ELF executable in \$out, got:$elfbins" >&2
      exit 1
    fi
  '';
})
