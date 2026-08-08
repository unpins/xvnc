# Darwin (macOS) Xvnc server derivation — self-contained, libSystem-only Mach-O
# with the in-process xkbcomp + the /zip VFS linked in. Merges the autotools link
# path (link shim, gnutls static tail, unix/ forcing, libSystem-only gate) with
# the VFS-localization technique from the shipped xvfb darwin port (vfs.c +
# llvm-objcopy --redefine-syms; macOS ld has no --wrap).
#
# Unlike xvfb (meson + `ninja -t commands` relink), TigerVNC's xserver is
# AUTOTOOLS. We avoid capturing/replaying the libtool link command: the file-I/O
# of the build-tree archives + the DDX objects is redefined in place, then Xvnc is
# relinked by `make`. The redefined libXfont2_vfs.a is injected via the link
# shim's -force_load (order-independent, ld64 first-wins) so its /zip-routed font
# reads beat the store -lXfont2.
#
# Like linux.nix this produces ONLY the server drv (no data embed / no manual
# strip) — the flake delegates the /zip embed to withUnpinEmbed (one self-EOF ZIP
# appended after the framework's strip; the bytes lie beyond codesign's codeLimit,
# matching the zsh/vim darwin ports).
#
# `pkgs` is the native OR cross darwin pkg set the framework passes; `xkbcompObj`
# is the matching darwin-xkbcomp.nix blob. nativeBuildInputs list entries
# auto-splice to the build host; script `${…}` interpolations use buildPackages.
{ pkgs, xkbcompObj }:
let
  # libfontenc bakes its font/encodings dirs into the library as absolute paths,
  # and libXfont2 links it — so on darwin the shipped Xvnc carried a live store
  # reference to libfontenc's own output and looked there at runtime, where a
  # user's Mac has no /nix/store. The linux side already pins both to /zip (see
  # the flake's staticFixes); this is that pin, and nothing more, so both
  # platforms resolve fonts through the VFS and neither drags a store path.
  static = pkgs.pkgsStatic.extend (_: super: {
    libfontenc = super.libfontenc.overrideAttrs (o: {
      configureFlags = (o.configureFlags or [ ]) ++ [
        "--with-fontrootdir=/zip/fonts"
        "--with-encodingsdir=/zip/fonts/encodings"
      ];
    });
  });
  bpkgs = pkgs.buildPackages;

  # gnutls, NLS off (its only gettext use is error-string translation, which would
  # drag the dynamic libintl.8.dylib — gettext is a darwin-bootstrap pkg, can't be
  # overlaid static). VNC error messages stay English.
  gnutlsStatic = static.gnutls.overrideAttrs (o: {
    configureFlags = (o.configureFlags or []) ++ [ "--disable-nls" ];
  });
  # libXfont2 without the FreeType backend (PCF bitmap fonts only).
  libxfont2NoFt = static.libxfont_2.overrideAttrs (o: {
    configureFlags = (o.configureFlags or []) ++ [ "--disable-freetype" ];
    buildInputs = builtins.filter
      (x: (x.pname or x.name or "") != "freetype") (o.buildInputs or []);
  });
  # The dynamic darwin set with the linked libs swapped to their pkgsStatic .a
  # variants (so tigervnc + the autotools xserver fold them static).
  opkgs = pkgs.extend (self: super: {
    inherit (static) pixman libjpeg_turbo nettle;
    gnutls = gnutlsStatic;
    libxfont_2 = libxfont2NoFt;
  });

  # The RunXkbComp → mkstemp+fork+fmemopen rewrite (darwin has all three; the
  # cosmo variant is correct for macOS too).
  ddxPatch = ./cosmo/patch-ddxload-cosmo.py;

  # VFS redefine map: route the server's file I/O to vfs.c's _unpinvfs_*. On
  # x86_64-darwin the stat/dir family carries the $INODE64 asm-label; map both the
  # suffixed and the bare forms (objcopy ignores absent ones). NEVER define
  # _DARWIN_C_SOURCE anywhere (it emits _fopen$DARWIN_EXTSN, which this map misses).
  redefMap = pkgs.writeText "vfs-redef.map" ''
    _open _unpinvfs_open
    _stat$INODE64 _unpinvfs_stat
    _stat _unpinvfs_stat
    _lstat$INODE64 _unpinvfs_lstat
    _lstat _unpinvfs_lstat
    _access _unpinvfs_access
    _fopen _unpinvfs_fopen
    _opendir$INODE64 _unpinvfs_opendir
    _opendir _unpinvfs_opendir
    _readdir$INODE64 _unpinvfs_readdir
    _readdir _unpinvfs_readdir
    _closedir _unpinvfs_closedir
  '';

  drop = names: inputs: builtins.filter
    (x: !(builtins.elem (x.pname or x.name or "") names)) inputs;
  junk = [ "fltk" "libGLU" "glu" "libepoxy" "libglvnd" "mesa" "mesa-gl-headers"
           "SDL2" "SDL3" "ffmpeg" "ffmpeg-full" "pam" "linux-pam"
           "pipewire" "wayland" "libpciaccess" "libxshmfence"
           "perl" "openssh" "xterm" "xauth" "tab-window-manager" "xsetroot" ];
in
(opkgs.tigervnc.override {
  waylandSupport = false;
  openssh = bpkgs.openssh;   # build-host (interpolated into vncviewer.cxx postPatch)
}).overrideAttrs (o: {
  pname = "xvnc";
  # List entries auto-splice to the build host (xtrans/util-macros/font-util carry
  # arch-independent aclocal m4; bison/libtool/auto*/pkg-config are build tools).
  nativeBuildInputs = (o.nativeBuildInputs or [])
    ++ [ pkgs.xtrans pkgs.bison pkgs.util-macros pkgs.font-util
         pkgs.libtool pkgs.automake pkgs.autoconf pkgs.pkg-config
         pkgs.buildPackages.llvm ];
  cmakeFlags = (o.cmakeFlags or []) ++ [
    "-DBUILD_VIEWER=0" "-DENABLE_NLS=0" "-DENABLE_H264=0"
  ];
  postPatch = (o.postPatch or "") + ''
    substituteInPlace CMakeLists.txt \
      --replace-fail "find_package(PAM REQUIRED)" "find_package(PAM)" \
      --replace-fail "add_subdirectory(tests)" "# dropped"
    # Compile UnixPasswordValidator on darwin (upstream gates it NOT APPLE).
    substituteInPlace common/rfb/CMakeLists.txt \
      --replace-fail "if(UNIX AND NOT APPLE)" "if(UNIX)"
    # libvnc.la hardcodes GNU "-Wl,-z,now"; ld64 rejects "-z now". Drop it.
    substituteInPlace unix/xserver/hw/vnc/Makefile.am \
      --replace-fail "-module -avoid-version -Wl,-z,now" "-module -avoid-version"
    # Force unix/ on darwin (gated NOT APPLE) so unix/common → libunixcommon.la.
    ${bpkgs.python3.interpreter} -c "f='CMakeLists.txt'; s=open(f).read(); s=s.replace('  if(NOT APPLE)\n    add_subdirectory(unix)\n  endif()','  add_subdirectory(unix)'); assert 'add_subdirectory(unix)' in s; open(f,'w').write(s)"
    cp ${./UnixPasswordValidator-stub.cxx} common/rfb/UnixPasswordValidator.cxx
    substituteInPlace unix/CMakeLists.txt \
      --replace-fail "add_subdirectory(tx)" "# dropped" \
      --replace-fail "add_subdirectory(vncconfig)" "# dropped" \
      --replace-fail "add_subdirectory(vncpasswd)" "# dropped" \
      --replace-fail "add_subdirectory(vncserver)" "# dropped" \
      --replace-fail "add_subdirectory(x0vncserver)" "# dropped"
  '';
  postBuild = ''
    source_top="$PWD"

    ###### unpin-vfs runtime objects (darwin $CC; NEVER redefined) ######
    # -DNDEBUG: miniz's MZ_ASSERT is plain assert() → keeps __FILE__ store-path
    # cstring in .rodata (a foreign runtime ref surviving strip). NDEBUG drops it.
    vfsdir=$NIX_BUILD_TOP/vfsobj; mkdir -p $vfsdir
    $CC -O2 -DNDEBUG -DMINIZ_USE_ZSTD -DUNPIN_VFS_SELF -DUNPIN_VFS_DIRS \
      -I${./src} -c ${./src/vfs.c} -o $vfsdir/vfs.o
    $CC -O2 -DNDEBUG -DMINIZ_USE_ZSTD -I${./src} -c ${./src/miniz.c} -o $vfsdir/miniz.o
    $CC -O2 -DNDEBUG -DMINIZ_USE_ZSTD -DUNPIN_ZSTD_VENDORED -I${./src} \
      -c ${./src/unpin_zstd.c} -o $vfsdir/unpin_zstd.o

    ###### VFS-localized copy of libXfont2 + the xkbcomp blob ######
    cp ${libxfont2NoFt}/lib/libXfont2.a $vfsdir/libXfont2_vfs.a
    chmod +w $vfsdir/libXfont2_vfs.a
    llvm-objcopy --redefine-syms=${redefMap} $vfsdir/libXfont2_vfs.a
    cp ${xkbcompObj}/xkbcomp_localized.o $vfsdir/blob_vfs.o
    llvm-objcopy --redefine-syms=${redefMap} $vfsdir/blob_vfs.o

    ###### link shim in front of clang++ ######
    export UNPIN_REAL_CXX="$CXX"
    export UNPIN_RFB_A="$(find "$source_top" -name librfb.a | head -1)"
    # Force the static libz.a in place of every -lz (a transitive -L points at the
    # DYNAMIC zlib; an explicit archive path is order-independent → no libz.dylib
    # load command). See fix (4) in darwin-link-shim.sh.
    export UNPIN_LIBZ_A="${static.zlib}/lib/libz.a"
    # Append the GNU static libiconv.a dead-last so libunistring's _libiconv* refs
    # resolve (libtool reorders -lunistring after the cc-wrapper NIX_LDFLAGS, so a
    # -liconv there is too early). libiconvReal is the GNU libiconv (the only static
    # one carrying _libiconv*; Apple's libiconv-113 ships no .a). See fix (5) in
    # darwin-link-shim.sh.
    export UNPIN_LIBICONV_A="${static.libiconvReal}/lib/libiconv.a"
    # NB: UNPIN_XFONT2_VFS_A is set only just before the RELINK below — the first
    # (throwaway) make link has no vfs.o yet, so force-loading the
    # _unpinvfs_*-referencing libXfont2_vfs.a there would fail to resolve them.
    mkdir -p "$TMPDIR/linkshim"
    cp ${./darwin-link-shim.sh} "$TMPDIR/linkshim/clang++"
    chmod +x "$TMPDIR/linkshim/clang++"
    export CXX="$TMPDIR/linkshim/clang++"
    export CXXFLAGS="$CXXFLAGS -fpermissive"
    export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -Wno-error=incompatible-function-pointer-types -Wno-error=incompatible-pointer-types"

    tar xf ${bpkgs.xorg-server.src}
    cp -R xorg*/* unix/xserver
    pushd unix/xserver
    patch -p1 < "$source_top/unix/xserver21.patch"

    # RunXkbComp → in-process fork + unpin_xkbcomp_main (build-host python3).
    ${bpkgs.python3.interpreter} ${ddxPatch}

    autoreconf -vfi
    ./configure $configureFlags --disable-devel-docs --disable-docs \
        --disable-xorg --disable-xnest --disable-xvfb --disable-dmx \
        --disable-xwin --disable-xephyr --disable-kdrive --with-pic \
        --disable-xquartz \
        --disable-xorgcfg --disable-xprint \
        --enable-composite --disable-xtrap --enable-xcsecurity \
        --disable-afb --disable-cfb --disable-mfb \
        --disable-xwayland \
        --disable-nls \
        --disable-config-dbus --disable-config-udev --disable-config-hal \
        --disable-xevie \
        --disable-dri --disable-dri2 --disable-dri3 --disable-glx \
        --prefix="$out" --disable-unit-tests \
        --with-xkb-path=/zip/xkb \
        --with-xkb-bin-directory=/usr/bin \
        --with-xkb-output=/tmp \
        --with-default-font-path=/zip/fonts/misc

    # Static-fold link flags — set AFTER ./configure so its cc-link probes aren't
    # perturbed. gnutls's transitive .a tail + static libc++ fold (jbig2 recipe):
    # the darwin allow-list rejects /usr/lib/libc++.1.dylib.
    mkdir -p "$TMPDIR/cxx-static"
    ln -sf ${static.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libc++.a"
    ln -sf ${static.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libstdc++.a"
    ln -sf ${static.libcxx}/lib/libc++abi.a "$TMPDIR/cxx-static/libc++abi.a"
    ln -sf ${static.zlib}/lib/libz.a        "$TMPDIR/cxx-static/libz.a"
    # The VFS runtime objects + the localized xkbcomp blob ride on NIX_LDFLAGS for
    # BOTH links: the patched RunXkbComp references _unpin_xkbcomp_main (blob) and
    # the blob references _unpinvfs_* (vfs.o), so even the first link needs them.
    # libiconv is resolved dead-last by the link shim (fix (5)) — libtool reorders
    # -lunistring past any -liconv we could place in NIX_LDFLAGS here.
    export NIX_LDFLAGS="-search_paths_first -dead_strip_dylibs \
      -L$TMPDIR/cxx-static $NIX_LDFLAGS \
      -ltasn1 -lidn2 -lunistring -lhogweed -lnettle -lgmp -lc++abi \
      -framework CoreFoundation -framework Security \
      $vfsdir/vfs.o $vfsdir/miniz.o $vfsdir/unpin_zstd.o $vfsdir/blob_vfs.o"

    # First link: Xvnc builds with the blob+vfs present (so RunXkbComp resolves),
    # but the server's OWN archives still call the REAL libc I/O (not yet
    # redefined). Throwaway — we overwrite it after redefining those archives.
    make TIGERVNC_SRC=$src TIGERVNC_BUILDDIR=`pwd`/../.. -j$NIX_BUILD_CORES

    ###### redefine file I/O in the build-tree archives + DDX objects, relink ######
    echo "=== redefining file I/O in build-tree archives + hw/vnc objects ==="
    find . -name '*.a' -print | while read -r a; do
      llvm-objcopy --redefine-syms=${redefMap} "$a" || true
    done
    for ob in $(find hw/vnc -name '*.o'); do
      llvm-objcopy --redefine-syms=${redefMap} "$ob" || true
    done

    # Route the redefined server archives' font reads through the VFS: let the
    # shim -force_load the redefined libXfont2_vfs.a (order-independent → it wins
    # over the store -lXfont2). Relink by removing the program target + re-making.
    export UNPIN_XFONT2_VFS_A="$vfsdir/libXfont2_vfs.a"
    rm -f hw/vnc/Xvnc hw/vnc/.libs/Xvnc
    echo "=== relinking Xvnc with VFS objects ==="
    # The Xvnc rule lives in hw/vnc/Makefile (the top dir only recurses), so relink
    # there. cwd is still unix/xserver → `pwd`/../.. = the CMake builddir.
    make TIGERVNC_SRC=$src TIGERVNC_BUILDDIR=`pwd`/../.. -C hw/vnc

    ###### gates ######
    echo "=== otool -L hw/vnc/Xvnc ==="
    otool -L hw/vnc/Xvnc || true
    bad=$(otool -L hw/vnc/Xvnc | tail -n +2 | awk '{print $1}' \
          | grep -vE '^/usr/lib/libSystem|^/System/Library/Frameworks' || true)
    if [ -n "$bad" ]; then
      echo "FATAL: Xvnc links non-system dylibs:" >&2; echo "$bad" >&2; exit 1
    fi
    echo "✅ Xvnc is libSystem-only on darwin"
    # Capture nm output to a var and match with a here-string: `llvm-nm | grep -q`
    # makes grep close the pipe on first match → llvm-nm hits SIGPIPE → under
    # pipefail the `if` condition reads as failure even when the symbol IS present.
    nmout="$(llvm-nm hw/vnc/Xvnc)"
    if grep -qw _unpinvfs_open <<<"$nmout"; then
      echo "✅ VFS shims linked in: $(grep -c _unpinvfs_ <<<"$nmout")"
    else
      echo "FATAL: _unpinvfs_open not in the final image (relink lost the VFS)" >&2
      grep -i unpinvfs <<<"$nmout" || true
      exit 1
    fi
    if grep -qw _unpin_xkbcomp_main <<<"$nmout"; then
      echo "✅ in-process xkbcomp linked in"
    else
      echo "FATAL: _unpin_xkbcomp_main not in the final image" >&2; exit 1
    fi
    popd
  '';

  # Keep the upstream binary name `Xvnc`; withUnpinEmbed (primary = "Xvnc") embeds
  # into it after strip. Add the lowercase `xvnc` gate symlink.
  installPhase = ''
    runHook preInstall
    install -Dm755 unix/xserver/hw/vnc/Xvnc $out/bin/Xvnc
    if [ -f unix/xserver/hw/vnc/Xvnc.1 ]; then
      install -Dm644 unix/xserver/hw/vnc/Xvnc.1 $out/share/man/man1/Xvnc.1
    fi
    # macOS's default FS is CASE-INSENSITIVE, so `xvnc` already resolves to `Xvnc`
    # (the gate's result/bin/xvnc lookup needs no symlink there) and `ln` would
    # error "File exists". Only create it where the two names are distinct.
    [ -e "$out/bin/xvnc" ] || ln -s Xvnc "$out/bin/xvnc"
    runHook postInstall
  '';
  postInstall = "";

  # Let the framework strip + withUnpinEmbed embed run (NO dontFixup). Scrub the
  # unused gnutls store ref. No ELF-count assert here — the binary is Mach-O.
  postFixup = (o.postFixup or "") + ''
    rm -rf $out/nix-support
    ${bpkgs.removeReferencesTo}/bin/remove-references-to -t ${gnutlsStatic.out} "$out/bin/Xvnc" || true
  '';

  buildInputs = drop junk (o.buildInputs or [])
    ++ [ static.zlib static.libjpeg_turbo static.pixman gnutlsStatic
         static.nettle libxfont2NoFt static.libxau static.libxdmcp
         static.libfontenc ]
    ++ [ static.libtasn1 static.libidn2 static.libunistring static.gmp
         static.libiconvReal ]
    ++ (with opkgs.xorg; [
      xorgproto libX11 libxkbfile libXext libXfixes
      libXdamage libXi libXrandr libXrender libXtst libXres libXinerama
    ]);
  propagatedBuildInputs = drop junk (o.propagatedBuildInputs or []);

  # nixpkgs sets `broken = isDarwin` on tigervnc because its darwin path only
  # produces the viewer .dmg; this recipe builds the Xvnc DDX instead and does
  # link (Mach-O, libSystem-only). Clear it here rather than through a config
  # escape hatch: nixpkgs dropped `allowBroken` for `problems.handlers`, so the
  # old hatch went silently dead and took the whole darwin matrix with it.
  meta = (o.meta or {}) // {
    platforms = pkgs.lib.platforms.all;
    broken = false;
  };
})
