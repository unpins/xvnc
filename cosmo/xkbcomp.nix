# Cosmo port of the spike's in-process xkbcomp blob: the entire client-side XKB
# stack bundled into one relocatable .o exporting only unpin_xkbcomp_main,
# depending on nothing but libc. Same recipe as the Linux mkXvfb xkbcompObj,
# retargeted to the cosmocc pkg set + cosmo binutils + cosmo libX11.a/libxkbfile.a.
{ cosmoPkgs }:
let
  c = cosmoPkgs;
  spikeRoot = ../.;
  # Cosmo ELF binutils (objects are ELF until apelink), derived from the cosmo
  # cross stdenv — same as the Linux mkXvfb uses static.stdenv.cc.bintools. The
  # unwrapped cosmo bintools ship ar/ld/nm/objcopy that shim to the matching
  # x86_64-linux-cosmo-* tools (mkBintoolsUnwrapped in nix-lib/cosmocc.nix).
  bintools = c.stdenv.cc.bintools.bintools;
  ar = "${bintools}/bin/ar";
  ld = "${bintools}/bin/ld";        # cosmo's ld is GNU ld.bfd; -r relocatable
  nm = "${bintools}/bin/nm";
  objcopy = "${bintools}/bin/objcopy";

  xkbcompSrc = c.xorg.xkbcomp.src;
  libX11A = "${c.xorg.libX11}/lib/libX11.a";
  libxkbfileA = "${c.xorg.libxkbfile}/lib/libxkbfile.a";
  xkbcInc = "-I. -I${c.xorg.xorgproto}/include "
    + "-I${c.xorg.libxkbfile.dev}/include -I${c.xorg.libX11.dev}/include";
in
c.stdenv.mkDerivation {
  name = "xkbcomp-inproc-cosmo-o";
  src = xkbcompSrc;
  nativeBuildInputs = [ c.buildPackages.bison ];
  # makekeys runs on the BUILD host (x86_64-linux), not the cosmo target.
  depsBuildBuild = [ c.buildPackages.stdenv.cc ];
  buildPhase = ''
    runHook preBuild
    bison --defines=xkbparse.h -o xkbparse.c xkbparse.y

    "''${CC_FOR_BUILD:-$CC_FOR_BUILD}" -O2 ${spikeRoot}/tools/makekeys.c -o makekeys || \
      "$CC_FOR_BUILD" -O2 ${spikeRoot}/tools/makekeys.c -o makekeys
    xkbproto=${c.xorg.xorgproto}/include/X11
    ./makekeys $xkbproto/keysymdef.h $xkbproto/XF86keysym.h \
               $xkbproto/Sunkeysym.h $xkbproto/DECkeysym.h \
               $xkbproto/HPkeysym.h > ks_tables.h

    # -Werror=int-conversion guards the pointer-truncation class the darwin port
    # hit: an implicitly-declared (int-returning) function whose result is
    # assigned to a pointer gets truncated 64->32 bits -> wild-address crash.
    # Cosmo keeps -DHAVE_REALLOCARRAY=1 (cosmo libc declares reallocarray, so
    # uRecalloc is safe -- proven by the real-Windows-VM keymap compile, which
    # exercises that path), so this guard is a no-op today; it's a tripwire that
    # fails the build loudly if a future cosmocc bump stops declaring it (instead
    # of silently regressing to the darwin crash). -Wno-implicit-function-
    # declaration stays: implicit int-returning calls (asprintf) are harmless.
    DEF=(-O2 -fno-strict-aliasing \
         -Wno-implicit-function-declaration -Werror=int-conversion \
         -Dmain=unpin_xkbcomp_main \
         '-DDFLT_XKB_CONFIG_ROOT="/zip/xkb"' \
         '-DPACKAGE_VERSION="unpin-inproc"' \
         -DHAVE_ASPRINTF=1 -DHAVE_REALLOCARRAY=1)
    OBJS=""
    for cc in action alias compat expr geometry indicators keycodes \
             keymap keytypes listing misc parseutils symbols utils vmod \
             xkbcomp xkbparse xkbpath xkbscan; do
      echo "  CC $cc.c"
      $CC "''${DEF[@]}" ${xkbcInc} -c "$cc.c" -o "$cc.o"
      OBJS="$OBJS $cc.o"
    done
    $CC "''${DEF[@]}" ${xkbcInc} -c ${spikeRoot}/src/unpin_keysym.c -o unpin_keysym.o
    $CC "''${DEF[@]}" ${xkbcInc} -c ${spikeRoot}/src/unpin_xkbcompute.c -o unpin_xkbcompute.o
    $CC -O2 -Wno-implicit-function-declaration -Werror=int-conversion \
      -c ${spikeRoot}/src/xkbcomp_stubs.c -o xkbcomp_stubs.o
    OBJS="$OBJS unpin_keysym.o unpin_xkbcompute.o xkbcomp_stubs.o"

    mkdir libx; ( cd libx
      ${ar} x ${libX11A} XKBAlloc.o XKBMAlloc.o XKBGAlloc.o XKBMisc.o
      ${ar} x ${libxkbfileA} \
        xkmout.o xkbout.o xkbtext.o cout.o xkmread.o xkbmisc.o \
        xkberrs.o xkbatom.o )

    ${ld} -r -o xkbcomp_all.o $OBJS libx/*.o
    ${objcopy} --keep-global-symbol=unpin_xkbcomp_main \
      xkbcomp_all.o xkbcomp_localized.o

    echo "=== exported globals (want: only unpin_xkbcomp_main) ==="
    defined=$(${nm} -g --defined-only xkbcomp_localized.o | awk '{print $NF}')
    echo "$defined"
    if [ "$defined" != "unpin_xkbcomp_main" ]; then
      echo "FATAL: blob exports unexpected globals" >&2; exit 1
    fi

    echo "=== undefined (want: only libc; no X/Xkb leak) ==="
    undef=$(${nm} -u xkbcomp_localized.o | awk '{print $NF}' | sort -u)
    echo "$undef"
    leak=$(echo "$undef" | grep -E '^_?X([A-Z]|kb|rm|t)' || true)
    if [ -n "$leak" ]; then
      echo "FATAL: blob has unresolved X-client symbols:" >&2
      echo "$leak" >&2; exit 1
    fi
    runHook postBuild
  '';
  installPhase = ''mkdir -p $out; cp xkbcomp_localized.o $out/'';
  dontStrip = true;
  dontFixup = true;
}
