# Linux (static-musl) in-process xkbcomp blob: the entire client-side XKB stack
# merged into one module exporting only unpin_xkbcomp_main, depending on nothing
# but libc. xkbcomp (client XKB API) and the X server (server XKB API) share many
# function NAMES with divergent signatures, so they can't be linked together
# naively — we bundle the client stack and localize all of it.
# The merge happens in LLVM IR: every caller is on the unpin-llvm engine, so the
# objects are bitcode. The output keeps the .o name because the server link feeds
# it as an object, and lld reads bitcode there.
#
# `static` is a target static-musl package set (native or cross) with the
# staticFixes overlay. `pkgs` is the build-host nixpkgs (arch-independent headers
# + bison/makekeys run on the builder).
{ ulib, static, pkgs }:
let
  bintools = static.stdenv.cc.bintools.bintools;
  tp = static.stdenv.cc.targetPrefix;
  # The LLVM multitool, for the IR merge. Build-host binary (it runs here), so it
  # is keyed on buildPlatform even though everything it reads is target IR.
  mt = "${ulib.unpinToolchain pkgs.stdenv.buildPlatform.system}/bin/llvm";

  # The objects MUST be bitcode. `llvm link` would reject ELF loudly on its own,
  # but it would reject it deep in a build log; check the magic up front and say
  # why. This is also the tripwire for a caller quietly leaving the engine — the
  # predecessor of this code merged with `ld -r`, which does NOT fail on bitcode:
  # it runs LTO codegen and hands back a native .o, losing cross-blob
  # optimization in silence.
  merge = ''
    fmt=$(od -An -tx1 -N4 action.o | tr -d ' \n')
    if [ "$fmt" != "4243c0de" ]; then
      echo "FATAL: action.o is $fmt, not bitcode (4243c0de)." >&2
      echo "       Is the calling package set still on the unpin-llvm engine?" >&2
      exit 1
    fi
    # internalize is a linkage change rather than a symtab edit, so the comdat
    # groups the archive objects carry (__x86.get_pc_thunk.* on i686) survive it.
    ${mt} link $OBJS libx/*.o -o xkbcomp_all.bc
    ${mt} opt --passes=internalize \
      --internalize-public-api-list=unpin_xkbcomp_main \
      xkbcomp_all.bc -o xkbcomp_localized.o
  '';

  xkbcInc = "-I. -I${pkgs.xorg.xorgproto}/include "
    + "-I${pkgs.xorg.libxkbfile.dev}/include -I${pkgs.xorg.libX11.dev}/include";
  libX11A = "${static.xorg.libX11}/lib/libX11.a";
  libxkbfileA = "${static.xorg.libxkbfile}/lib/libxkbfile.a";
in
static.stdenv.mkDerivation {
  name = "xkbcomp-inproc-o";
  src = pkgs.xorg.xkbcomp.src;
  nativeBuildInputs = [ pkgs.bison ];
  # makekeys is a BUILD-TIME tool: it must be compiled with the build-platform
  # compiler ($CC_FOR_BUILD), not the static-musl TARGET $CC — otherwise a cross
  # build (i686/aarch64) produces a makekeys that can't execute on the builder.
  depsBuildBuild = [ static.buildPackages.stdenv.cc ];
  buildPhase = ''
    runHook preBuild
    bison --defines=xkbparse.h -o xkbparse.c xkbparse.y

    "''${CC_FOR_BUILD:-$CC}" -O2 ${./tools/makekeys.c} -o makekeys
    xkbproto=${pkgs.xorg.xorgproto}/include/X11
    ./makekeys $xkbproto/keysymdef.h $xkbproto/XF86keysym.h \
               $xkbproto/Sunkeysym.h $xkbproto/DECkeysym.h \
               $xkbproto/HPkeysym.h > ks_tables.h

    DEF=(-O2 -fno-strict-aliasing -Dmain=unpin_xkbcomp_main \
         '-DDFLT_XKB_CONFIG_ROOT="/zip/xkb"' \
         '-DPACKAGE_VERSION="unpin-inproc"' \
         -DHAVE_ASPRINTF=1 -DHAVE_REALLOCARRAY=1)
    OBJS=""
    for c in action alias compat expr geometry indicators keycodes \
             keymap keytypes listing misc parseutils symbols utils vmod \
             xkbcomp xkbparse xkbpath xkbscan; do
      echo "  CC $c.c"
      $CC "''${DEF[@]}" ${xkbcInc} -c "$c.c" -o "$c.o"
      OBJS="$OBJS $c.o"
    done
    $CC "''${DEF[@]}" ${xkbcInc} -c ${./src/unpin_keysym.c} -o unpin_keysym.o
    $CC "''${DEF[@]}" ${xkbcInc} -c ${./src/unpin_xkbcompute.c} -o unpin_xkbcompute.o
    $CC -O2 -c ${./src/xkbcomp_stubs.c} -o xkbcomp_stubs.o
    OBJS="$OBJS unpin_keysym.o unpin_xkbcompute.o xkbcomp_stubs.o"

    mkdir libx; ( cd libx
      ${bintools}/bin/${tp}ar x ${libX11A} \
        XKBAlloc.o XKBMAlloc.o XKBGAlloc.o XKBMisc.o
      ${bintools}/bin/${tp}ar x ${libxkbfileA} \
        xkmout.o xkbout.o xkbtext.o cout.o xkmread.o xkbmisc.o \
        xkberrs.o xkbatom.o )

    ${merge}

    echo "=== exported globals (want: only unpin_xkbcomp_main) ==="
    # No exception list: internalize leaves the i686 __x86.get_pc_thunk.* comdat
    # symbols local, where the old objcopy localization had to keep them global
    # or the discarded duplicate group dangled the reference.
    defined=$(${bintools}/bin/${tp}nm -g --defined-only xkbcomp_localized.o \
              | awk '{print $NF}')
    echo "$defined"
    if [ "$defined" != "unpin_xkbcomp_main" ]; then
      echo "FATAL: blob exports unexpected globals (want only unpin_xkbcomp_main)" >&2
      exit 1
    fi

    echo "=== undefined (want: only libc; no X/Xkb leak) ==="
    undef=$(${bintools}/bin/${tp}nm -u xkbcomp_localized.o | awk '{print $NF}' | sort -u)
    echo "$undef"
    leak=$(echo "$undef" | grep -E '^_?X([A-Z]|kb|rm|t)' || true)
    if [ -n "$leak" ]; then
      echo "FATAL: blob has unresolved X-client symbols (would drag libX11/xcb):" >&2
      echo "$leak" >&2
      exit 1
    fi
    runHook postBuild
  '';
  installPhase = ''mkdir -p $out; cp xkbcomp_localized.o $out/'';
  dontStrip = true;
  dontFixup = true;
}
