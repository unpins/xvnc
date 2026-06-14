#!/usr/bin/env bash
# unpins darwin link shim — sits in front of the nix-wrapped clang++ during the
# autotools xserver/hw/vnc build. Two surgical fixes ld64 (Apple's linker) needs
# that GNU ld on Linux didn't:
#
#  (1) Strip GNU-ld "-z <keyword>" pairs (e.g. "-z defs", from xorg-server's
#      LD_NO_UNDEFINED_FLAG=-Wl,-z,defs). clang forwards them to ld64, which
#      errors "unknown option: -z".
#
#  (2) When the output is Xvnc, prepend -Wl,-force_load on librfb.a. ld64 walks
#      a static archive in a single pass with no implicit --start-group, so
#      SSecurityPlain/SSecurityRSAAES (which reference
#      UnixPasswordValidator::displayName) fail to resolve it if the defining
#      object was already passed over. force_load pulls the whole archive in.
#
#  (3) When the output is Xvnc AND UNPIN_XFONT2_VFS_A is set, -force_load the
#      VFS-localized libXfont2_vfs.a (its file-I/O calls were redefined to
#      _unpinvfs_*). ld64 is first-wins per symbol, so force-loading it makes the
#      redefined Xfont2 objects define the symbols BEFORE the store -lXfont2 is
#      scanned → the on-demand store members are skipped and font reads route
#      through the /zip VFS. Order-independent, so no link-command capture needed.
#
#  (4) When UNPIN_LIBZ_A is set, replace every "-lz" token with the ABSOLUTE path
#      to the static libz.a. A transitive -L points at the DYNAMIC zlib output, and
#      ld64's -search_paths_first picks the first -L dir holding a match for -lz —
#      so a front -L with libz.a loses to whatever dir is scanned earlier. An
#      explicit archive path on the link line is unambiguous (ld64 links exactly
#      that file), so the dynamic libz.dylib never enters the load commands.
#
#  (5) When the output is Xvnc AND UNPIN_LIBICONV_A is set, append the static GNU
#      libiconv.a as the VERY LAST input. libunistring.a (pulled via gnutls's .la
#      dependency_libs) references the GNU _libiconv* symbols, and ld64 only
#      resolves an archive's symbols still undefined when it is reached. libtool
#      reorders the link so -lunistring lands AFTER the cc-wrapper's NIX_LDFLAGS,
#      so a -liconv there is too early. Appending the archive dead-last (after all
#      libtool/cc-wrapper args) guarantees _libiconv resolves — statically, so no
#      libiconv.2.dylib load command (the darwin allow-list rejects that).
#
# UNPIN_REAL_CXX = the real wrapped clang++; UNPIN_RFB_A = abs path to librfb.a;
# UNPIN_XFONT2_VFS_A = abs path to the redefined libXfont2_vfs.a (optional);
# UNPIN_LIBZ_A = abs path to the static libz.a (optional);
# UNPIN_LIBICONV_A = abs path to the static GNU libiconv.a (optional).
set -u
real="${UNPIN_REAL_CXX:?UNPIN_REAL_CXX unset}"

args=()
skip=0
expect_out=0
is_xvnc=0
for a in "$@"; do
  if (( skip )); then skip=0; continue; fi
  if (( expect_out )); then
    expect_out=0
    args+=("$a")
    [[ "$a" == *Xvnc ]] && is_xvnc=1
    continue
  fi
  case "$a" in
    -z) skip=1; continue ;;            # drop bare "-z <kw>" pair
    -Wl,-z,*) continue ;;             # drop single-token "-Wl,-z,defs" etc.
    -Wl,--no-undefined|--no-undefined) continue ;;  # GNU-only; ld64 rejects
    -lz)                               # fix (4): force the static libz.a
      if [[ -n "${UNPIN_LIBZ_A:-}" && -e "${UNPIN_LIBZ_A:-/nonexistent}" ]]; then
        args+=("$UNPIN_LIBZ_A"); continue
      fi ;;
    -o) expect_out=1 ;;
  esac
  args+=("$a")
done

extra=()
if (( is_xvnc )) && [[ -n "${UNPIN_RFB_A:-}" && -e "${UNPIN_RFB_A:-/nonexistent}" ]]; then
  extra=(-Wl,-force_load,"$UNPIN_RFB_A")
fi
if (( is_xvnc )) && [[ -n "${UNPIN_XFONT2_VFS_A:-}" && -e "${UNPIN_XFONT2_VFS_A:-/nonexistent}" ]]; then
  extra+=(-Wl,-force_load,"$UNPIN_XFONT2_VFS_A")
fi
# (5) static GNU libiconv.a dead-last, so libunistring's _libiconv* refs resolve.
# Explicit archive path (not -liconv): the only static libiconv with these GNU
# symbols is libiconvReal (Apple's libiconv-113 ships no .a, and the system dylib
# exports only POSIX _iconv) — name the file outright to avoid any search race.
# Plain (not -force_load): contributes only the iconv objects actually referenced.
if (( is_xvnc )) && [[ -n "${UNPIN_LIBICONV_A:-}" && -e "${UNPIN_LIBICONV_A:-/nonexistent}" ]]; then
  extra+=("$UNPIN_LIBICONV_A")
fi

exec "$real" "${args[@]}" "${extra[@]}"
