# Darwin variant of the in-process xkbcomp blob → one relocatable .o exporting
# only _unpin_xkbcomp_main, built with the dynamic darwin stdenv cc (the blob is
# linked into the dynamic-base Xvnc), with libX11.a/libxkbfile.a members sliced
# out by ar_extract.py. Mach-O has no GNU objcopy --keep-global-symbol, so we
# localize via ld -r + llvm-objcopy --redefine-syms into a private _ublob*
# namespace (only _unpin_xkbcomp_main stays global). Reused verbatim from the
# shipped xvfb darwin port (the client-side xkbcomp stack is identical).
#
# `pkgs` is the native OR cross darwin pkg set the framework passes. arm64 darwin
# uses PLAIN libc symbols (no $INODE64/$DARWIN_EXTSN), so the VFS redefine map in
# darwin.nix already covers it. Build-host tools via pkgs.buildPackages so the
# cross blob's makekeys/python are executable on the builder.
{ pkgs }:
let
  static = pkgs.pkgsStatic;
  llvm = pkgs.buildPackages.llvm;
  bintools = pkgs.stdenv.cc.bintools.bintools;
  tp = pkgs.stdenv.cc.targetPrefix;            # cross cctools are target-prefixed
  ldArch = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x86_64";

  libX11A = "${static.xorg.libX11}/lib/libX11.a";
  libxkbfileA = "${static.xorg.libxkbfile}/lib/libxkbfile.a";
  xkbcInc = "-I. -I${static.xorg.xorgproto}/include "
    + "-I${static.xorg.libxkbfile.dev}/include -I${static.xorg.libX11.dev}/include";
in
pkgs.stdenv.mkDerivation {
  name = "xkbcomp-inproc-darwin-o";
  src = static.xorg.xkbcomp.src;
  nativeBuildInputs = [ pkgs.bison llvm pkgs.python3 ];
  # makekeys + ar_extract.py run ON THE BUILD HOST: pull the build-platform cc so
  # the cc-wrapper exports CC_FOR_BUILD (native = $CC, cross = the x86_64 cc).
  depsBuildBuild = [ pkgs.buildPackages.stdenv.cc ];
  buildPhase = ''
    runHook preBuild
    bison --defines=xkbparse.h -o xkbparse.c xkbparse.y

    "''${CC_FOR_BUILD:-$CC}" -O2 ${./tools/makekeys.c} -o makekeys
    xkbproto=${static.xorg.xorgproto}/include/X11
    ./makekeys $xkbproto/keysymdef.h $xkbproto/XF86keysym.h \
               $xkbproto/Sunkeysym.h $xkbproto/DECkeysym.h \
               $xkbproto/HPkeysym.h > ks_tables.h

    # Two darwin hazards: (1) POINTER TRUNCATION — reallocarray is NOT declared by
    # the macOS SDK, so -DHAVE_REALLOCARRAY makes uRecalloc() truncate a 64-bit
    # pointer to int → SIGSEGV. DROP HAVE_REALLOCARRAY (utils.h falls back to
    # realloc) and GUARD with -Werror=int-conversion (fires only on int→pointer).
    # (2) Do NOT define _DARWIN_C_SOURCE (would emit fopen$DARWIN_EXTSN, missed by
    # the redefine map → VFS bypassed).
    DEF=(-O2 -fno-strict-aliasing \
         -Wno-implicit-function-declaration -Werror=int-conversion \
         -Dmain=unpin_xkbcomp_main \
         '-DDFLT_XKB_CONFIG_ROOT="/zip/xkb"' \
         '-DPACKAGE_VERSION="unpin-inproc"' \
         -DHAVE_ASPRINTF=1)
    OBJS=""
    for c in action alias compat expr geometry indicators keycodes \
             keymap keytypes listing misc parseutils symbols utils vmod \
             xkbcomp xkbparse xkbpath xkbscan; do
      echo "  CC $c.c"; "$CC" "''${DEF[@]}" ${xkbcInc} -c "$c.c" -o "$c.o"
      OBJS="$OBJS $c.o"
    done
    "$CC" "''${DEF[@]}" ${xkbcInc} -c ${./src/unpin_keysym.c} -o unpin_keysym.o
    "$CC" "''${DEF[@]}" ${xkbcInc} -c ${./src/unpin_xkbcompute.c} -o unpin_xkbcompute.o
    "$CC" -O2 -Wno-implicit-function-declaration -Werror=int-conversion \
      -c ${./src/xkbcomp_stubs.c} -o xkbcomp_stubs.o
    OBJS="$OBJS unpin_keysym.o unpin_xkbcompute.o xkbcomp_stubs.o"

    # Extract into SEPARATE dirs: macOS's default FS is CASE-INSENSITIVE, so
    # libX11's XKBMisc.o and libxkbfile's xkbmisc.o collide in one dir (the 7328B
    # one overwrites the 12920B one → libX11 leak). ar_extract.py slices member
    # bytes directly (the cc-wrapper's llvm-ar truncates these Apple archives).
    mkdir libx11 libkf
    python3 ${./ar_extract.py} ${libX11A} libx11 \
      XKBAlloc.o XKBMAlloc.o XKBGAlloc.o XKBMisc.o
    python3 ${./ar_extract.py} ${libxkbfileA} libkf \
      xkmout.o xkbout.o xkbtext.o cout.o xkmread.o xkbmisc.o xkberrs.o xkbatom.o

    ${bintools}/bin/${tp}ld -r -arch ${ldArch} -o xkbcomp_all.o $OBJS libx11/*.o libkf/*.o

    # Rename every blob-defined global except the entry point into a private
    # _ublob* namespace (avoids clashing with the server's identically-named
    # client/server-shared XKB globals). --redefine-syms rewrites defs AND refs.
    nm -gU xkbcomp_all.o | awk '{print $NF}' | grep -v '^_unpin_xkbcomp_main$' \
      | awk '{print $1 " _ublob" substr($1,2)}' > redef.syms
    llvm-objcopy --redefine-syms=redef.syms xkbcomp_all.o xkbcomp_localized.o

    echo "=== exported globals (want: _unpin_xkbcomp_main + _ublob*, no bare X) ==="
    nm -gU xkbcomp_localized.o | awk '{print $NF}'
    if ! nm -gU xkbcomp_localized.o | awk '{print $NF}' | grep -qx '_unpin_xkbcomp_main'; then
      echo "FATAL: entry point _unpin_xkbcomp_main not exported" >&2; exit 1
    fi
    xleak=$(nm -gU xkbcomp_localized.o | awk '{print $NF}' | grep -E '^_X([A-Z]|kb|rm|t)' || true)
    if [ -n "$xleak" ]; then
      echo "FATAL: un-renamed X-client global(s) would clash with the server:" >&2
      echo "$xleak" >&2; exit 1
    fi

    echo "=== undefined (want libc/libSystem only; no X/Xkb leak) ==="
    undef=$(nm -u xkbcomp_localized.o | awk '{print $NF}' | sort -u)
    echo "$undef"
    leak=$(echo "$undef" | grep -E '^_X([A-Z]|kb|rm|t)' || true)
    if [ -n "$leak" ]; then
      echo "FATAL: blob has unresolved X-client symbols:" >&2; echo "$leak" >&2; exit 1
    fi
    runHook postBuild
  '';
  installPhase = ''mkdir -p $out; cp xkbcomp_localized.o $out/'';
  dontStrip = true;
  dontFixup = true;
}
