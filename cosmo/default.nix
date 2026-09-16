# Xvnc cosmo (APE / Windows) server derivation — TigerVNC's CMake common/ libs +
# the autotools xserver hw/vnc DDX, built under cosmocc into a single PE32+.
# Structure mirrors the Linux module (CMake common/ + autotools hw/vnc) with the
# cosmo adaptations proven by the shipped xvfb cosmo build:
#   * VFS = cosmo NATIVE zipos (/zip/...): NO vfs.o/miniz/--wrap; plain zip append.
#   * RunXkbComp → in-process fork via the cosmo mkstemp+fmemopen patcher.
#   * -DUSE_POLL (sysconf(_SC_OPEN_MAX)==-1 on Windows closes listen sockets).
#   * XTRANS_SEND_FDS=0 (recvmsg/SCM_RIGHTS fails on Windows) — patched in the
#     autotools-generated config header.
#   * TLS ON: link the slimmed cosmo gnutls (.a) + its tail (tasn1/hogweed/nettle/
#     gmp; NO idn2/unistring — dropped from the cosmo gnutls in the flake overlay).
#
# Self-contained embed (zipos /zip + the gate symlink), like the xvfb cosmo port;
# the framework adds man via withMan --carry on top.
#
# `cosmoPkgs` is the framework's pkgsCross.cosmo with the xvnc cosmo leaf fixes
# layered on; `xkbcompObj` is the matching cosmo/xkbcomp.nix blob.
{ cosmoPkgs, nixpkgs, xkbcompObj }:
let
  c = cosmoPkgs;
  np = nixpkgs.legacyPackages."x86_64-linux";

  # build-host data (arch-independent text/bitmap, builds native).
  xkbTree    = np.xkeyboard_config;
  fontMisc   = np.xorg.fontmiscmisc;
  fontCursor = np.xorg.fontcursormisc;
  fontAlias  = np.xorg.fontalias;
  ddxCosmoPatch = ./patch-ddxload-cosmo.py;

  # On cosmo (non-Linux) tigervnc's X-stack buildInputs are gated out — so the
  # autotools xserver's configure has no xorgproto/Xfont2/Xau/Xdmcp/xkbfile to
  # find. Add them explicitly (protocol headers all come from xorgproto; the
  # server implements extensions itself, so no client libXext/libXi/... needed).
  xLibs = with c.xorg; [ xorgproto libX11 libXfont2 libXau libXdmcp libxkbfile ]
    ++ [ c.xtrans ];
  # The unwrapped pkg-config honors PKG_CONFIG_PATH but doesn't get the cosmo
  # buildInputs' .pc dirs auto-populated. Feed the dirs explicitly: every
  # pkg-config module the xserver configure probes + the TLS chain.
  pcPkgs = xLibs ++ [ c.pixman c.gnutls c.zlib c.libtasn1 c.gmp c.libjpeg_turbo c.nettle ];
  pcPath = builtins.concatStringsSep ":"
    (builtins.concatMap (x: [
      "${np.lib.getDev x}/lib/pkgconfig"
      "${np.lib.getDev x}/share/pkgconfig"
    ]) pcPkgs);
  # pkg.m4 (PKG_PROG_PKG_CONFIG) for aclocal, fed via ACLOCAL_PATH.
  pkgM4Dir = "${np.pkg-config-unwrapped}/share/aclocal";
  # cosmo ships libpthread.a in the cosmocc sysroot, but CMake's find_library
  # doesn't search there. TigerVNC's top CMakeLists does `if(UNIX) link_libraries
  # (pthread)`, and the libtool .la generator find_library(pthread)s it.
  cosmoCcLib = "${c.stdenv.cc.cc}/x86_64-linux-cosmo/lib";

  drop = names: inputs: builtins.filter
    (x: !(builtins.elem (x.pname or x.name or "") names)) inputs;
  baseJunk = [ "fltk" "ffmpeg" "ffmpeg-full" "pam" "linux-pam"
               "pipewire" "wayland" "libpciaccess" "libxshmfence"
               "perl" "openssh" "xterm" "xauth" "tab-window-manager" "xsetroot"
               # libidn2/libunistring are NOT used by the slimmed cosmo gnutls
               # (--without-idn / --with-included-unistring), so they never apply.
               "libidn2" "libunistring"
               # gawk is a build-time tool (postPatch `gawk -i inplace`), wrongly
               # in the target buildInputs; supply the build-host gawk instead.
               "gawk" ];
in
(c.tigervnc.override {
  waylandSupport = false;
  openssh = np.openssh;   # build-host (interpolated into vncviewer.cxx postPatch)
}).overrideAttrs (o: {
  pname = "xvnc";
  nativeBuildInputs = (o.nativeBuildInputs or []) ++ [
    np.gawk np.python3 np.zip
    # aclocal m4 providers for the autotools xserver's configure.ac (gated out on
    # cosmo where the X-stack is absent): util-macros (XORG_MACROS_VERSION),
    # xtrans (XTRANS_CONNECTION_FLAGS), font-util (XORG_FONT*).
    np.xtrans np.xorg.utilmacros np.xorg.fontutil
    np.libtool                 # autoreconf runs libtoolize
    np.pkg-config-unwrapped    # PKG_PROG_PKG_CONFIG + pkg.m4 for aclocal
  ];
  cmakeFlags = (o.cmakeFlags or []) ++ [
    "-DBUILD_VIEWER=0" "-DENABLE_NLS=0" "-DENABLE_H264=0"
    "-DENABLE_GNUTLS=ON" "-DENABLE_NETTLE=ON"
    # Pinned rather than left to FindZLIB, which would rather have a `.so`.
    "-DZLIB_LIBRARY=${c.zlib}/lib/libz.a"
    "-DZLIB_INCLUDE_DIR=${c.zlib.dev}/include"
    "-DGNUTLS_LIBRARY=${c.gnutls.out}/lib/libgnutls.a"
    "-DGNUTLS_INCLUDE_DIR=${c.gnutls.dev}/include"
    # So find_library(pthread) (the libtool .la generator) finds the cosmo
    # sysroot's libpthread.a.
    "-DCMAKE_LIBRARY_PATH=${cosmoCcLib}"
  ];
  postPatch = (o.postPatch or "") + ''
    substituteInPlace CMakeLists.txt \
      --replace-fail "find_package(PAM REQUIRED)" "find_package(PAM)" \
      --replace-fail "add_subdirectory(tests)" "# unpins: dropped"
    cp ${../UnixPasswordValidator-stub.cxx} common/rfb/UnixPasswordValidator.cxx
    substituteInPlace unix/CMakeLists.txt \
      --replace-fail "add_subdirectory(tx)" "# unpins: dropped" \
      --replace-fail "add_subdirectory(vncconfig)" "# unpins: dropped" \
      --replace-fail "add_subdirectory(vncpasswd)" "# unpins: dropped" \
      --replace-fail "add_subdirectory(vncserver)" "# unpins: dropped" \
      --replace-fail "add_subdirectory(x0vncserver)" "# unpins: dropped"
    # CMake doesn't set UNIX for the cosmo system, but cosmo IS POSIX-like — the
    # source's if(UNIX) branches are exactly the ones we want. Without UNIX set,
    # cosmo wrongly skips Unix-gated sources: the libtool .la control files, the
    # syslog logger, and (via `if(UNIX AND NOT APPLE)`) UnixPasswordValidator.cxx.
    # Force UNIX TRUE right after project(). WIN32 stays false on cosmo.
    sed -i '/^project(tigervnc)/a set(UNIX TRUE)' CMakeLists.txt
  '';

  # Full replacement of the nixpkgs postBuild: autotools xserver hw/vnc → Xvnc,
  # cosmo-adapted (no --wrap; zipos paths; cosmo RunXkbComp; socket fixes).
  postBuild = ''
    # nixpkgs sets source_top only under isLinux (false on cosmo). With
    # dontUseCmakeBuildDir=true the CMake build runs in the source tree, so cwd
    # here IS the source root — capture it for the xserver21.patch path below.
    source_top="$(pwd)"
    export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -Wno-implicit-function-declaration -Wno-error=int-to-pointer-cast -Wno-error=pointer-to-int-cast -DUSE_POLL"
    export CXXFLAGS="$CXXFLAGS -fpermissive"
    export ACLOCAL_PATH="${pkgM4Dir}''${ACLOCAL_PATH:+:$ACLOCAL_PATH}"
    export PKG_CONFIG_PATH="${pcPath}''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    tar xf ${np.xorg-server.src}
    cp -R xorg*/* unix/xserver
    pushd unix/xserver
    patch -p1 < "$source_top/unix/xserver21.patch"

    # RunXkbComp → in-process fork + unpin_xkbcomp_main (cosmo mkstemp+fmemopen).
    ${np.python3.interpreter} ${ddxCosmoPatch}

    autoreconf -vfi

    # autoreconf regenerated config.sub from the build-host automake, which
    # predates the cosmo triple. nix-lib's cosmo-config-sub-hook already patched
    # config.sub at preConfigure, but unix/xserver didn't exist yet — re-run it
    # now (the hook exports patchCosmoConfigSub; inline the seds if out of scope).
    if declare -f patchCosmoConfigSub >/dev/null 2>&1; then
      patchCosmoConfigSub
    else
      for cs in $(find . -name config.sub -type f); do
        chmod u+w "$cs" || true
        grep -q 'cosmo\*' "$cs" || sed -i 's/| ironclad\* )/| ironclad* | cosmo* )/' "$cs"
        grep -q 'cosmo-gnu\*-' "$cs" || sed -i '/uclinux-uclibc\*- )/i\	cosmo-gnu*- )\n\t\t;;' "$cs"
      done
    fi

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
        --with-default-font-path=/zip/fonts/misc \
        --enable-listen-tcp --disable-listen-unix --disable-listen-local

    # Listen on TCP, not on a Unix socket, unless told otherwise (the three
    # --*-listen-* flags above). The stock default is Unix + local only, and on
    # Windows neither comes up: xtrans refuses to create /tmp/.X11-unix behind a
    # `!defined(WIN32)` check a cosmo build does not satisfy, so the server
    # exited `Cannot establish any listening sockets` and `Xvnc :1` failed
    # outright; only `-listen tcp` worked. Clients reach display :N at port
    # 6000+N. Same defect and fix as the xvfb cosmo build.

    # Cosmo presents SCM_RIGHTS at build time, so configure turns XTRANS_SEND_FDS
    # on and the transport uses recvmsg/sendmsg w/ an SCM_RIGHTS control buffer —
    # which returns -1/WSAEINVAL on Windows, dropping every client's setup read.
    # Xvnc needs no fd-passing; force it off in the generated config header.
    hdr=$(grep -rl 'XTRANS_SEND_FDS' include/*.h 2>/dev/null | head -1)
    if [ -z "$hdr" ]; then echo "FATAL: XTRANS_SEND_FDS define not found post-configure" >&2; exit 1; fi
    sed -i 's/#define XTRANS_SEND_FDS 1/#define XTRANS_SEND_FDS 0/' "$hdr"
    echo "XTRANS_SEND_FDS forced 0 in $hdr"

    # -include strings.h applies to the make ONLY (not configure, where it breaks
    # autoconf's undeclared-builtin probe): vncExtInit.cc calls ffs() but relies on
    # a transitive glibc header pulling <strings.h>, which cosmo's chain lacks.
    export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -include strings.h"

    # Link the cosmo gnutls (.a) tail + the in-process xkbcomp blob. NO --wrap /
    # vfs.o here (cosmo serves /zip natively). The slimmed cosmo gnutls dropped
    # idn2/unistring, so the tail is tasn1/hogweed/nettle/gmp (+ zlib).
    export NIX_LDFLAGS="$NIX_LDFLAGS \
      -L${c.gnutls.out}/lib -lgnutls \
      -L${c.libtasn1}/lib -ltasn1 \
      -L${c.nettle}/lib -lhogweed -lnettle \
      -L${c.gmp}/lib -lgmp \
      -L${c.zlib}/lib -lz \
      ${xkbcompObj}/xkbcomp_localized.o"

    make TIGERVNC_SRC=$src TIGERVNC_BUILDDIR=`pwd`/../.. -j$NIX_BUILD_CORES

    # TigerVNC reports protocol and auth errors with C++ exceptions. A gap in
    # the unwind table left every one of them uncatchable on Windows, so a
    # single bad message from an unauthenticated client aborted the server.
    # Checked on the ELF, before apelink turns it into a PE.
    ${np.python3.interpreter} ${./check-eh-frame.py} hw/vnc/Xvnc "$NM"
    popd
  '';

  buildInputs = drop baseJunk (o.buildInputs or []) ++ [
    c.zlib c.libtasn1 c.gmp
  ] ++ xLibs;
  propagatedBuildInputs = drop baseJunk (o.propagatedBuildInputs or []);

  # Keep the upstream binary name `Xvnc` (catalog policy). apelinkHook (preFixup)
  # turns bin/Xvnc → bin/Xvnc.exe; embed /zip AFTER, in postFixup.
  installPhase = ''
    runHook preInstall
    install -Dm755 unix/xserver/hw/vnc/Xvnc $out/bin/Xvnc
    runHook postInstall
  '';
  postInstall = "";

  dontStrip = true;
  postFixup = (o.postFixup or "") + ''
    bin=$out/bin/Xvnc.exe
    [ -f "$bin" ] || bin=$out/bin/Xvnc
    [ -f "$bin" ] || { echo "FATAL: Xvnc(.exe) not found (apelink failed?)" >&2; exit 1; }
    rm -rf $out/nix-support

    # gnutls bakes ${"\${gnutls.out}"}/etc/gnutls/config into libgnutls (system
    # priority file) — unused here (VNC TLS uses user x509 certs), so scrub the
    # foreign store ref. Length-preserving, format-agnostic on the PE; do it BEFORE
    # appending the zip (mirrors the Linux ordering). The remaining
    # $out/lib/xorg/protocol.txt string is a self-ref (cosmetic) — allowed.
    ${np.removeReferencesTo}/bin/remove-references-to -t ${c.gnutls.out} "$bin"

    stage=$(mktemp -d); mkdir -p $stage/xkb $stage/fonts/misc
    cp -aL ${xkbTree}/share/X11/xkb/. $stage/xkb/
    cp ${fontMisc}/share/fonts/X11/misc/*.pcf.gz $stage/fonts/misc/
    cp ${fontCursor}/share/fonts/X11/misc/*.pcf.gz $stage/fonts/misc/
    { n1=$(sed -n 1p ${fontMisc}/share/fonts/X11/misc/fonts.dir)
      n2=$(sed -n 1p ${fontCursor}/share/fonts/X11/misc/fonts.dir)
      echo $((n1 + n2))
      tail -n +2 ${fontMisc}/share/fonts/X11/misc/fonts.dir
      tail -n +2 ${fontCursor}/share/fonts/X11/misc/fonts.dir
    } > $stage/fonts/misc/fonts.dir
    cp ${fontAlias}/share/fonts/X11/misc/fonts.alias $stage/fonts/misc/fonts.alias
    chmod -R u+w $stage
    ( cd $stage && zip -q -r -9 "$bin" xkb fonts )
    echo "embedded /zip xkb + fonts; $(basename "$bin") now $(stat -c %s "$bin") bytes"

    # The real binary keeps its UPSTREAM name `Xvnc(.exe)`. The catalog gate
    # locates result/bin/<package-name> == result/bin/xvnc, so add a lowercase
    # compat symlink → the upstream-named binary. ${"\${target#Xvnc}"} carries the
    # .exe (or empty) suffix.
    target=$(basename "$bin")
    ln -s "$target" "$out/bin/xvnc''${target#Xvnc}"
    echo "added gate compat symlink xvnc''${target#Xvnc} -> $target"
  '';

  meta = (o.meta or {}) // { platforms = np.lib.platforms.all; };
})
