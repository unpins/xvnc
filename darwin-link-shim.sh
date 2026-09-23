#!/usr/bin/env bash
# unpins darwin link shim — sits in front of the nix-wrapped clang++ during the
# autotools xserver/hw/vnc build. Surgical fixes that ld64 (Apple's linker), and
# ld64.lld under the engine, need where GNU ld on Linux did not:
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
#      _unpinvfs_*) and REMOVE the store libXfont2 from the line. Apple's ld64 is
#      first-wins per symbol, so force-loading our copy was enough: the store
#      archive was then scanned on demand, found nothing still undefined and
#      contributed nothing. ld64.lld, which links this under the engine, loads
#      the store members anyway and reports every one of them as a duplicate
#      symbol (__libxfont_internal__MakeAtom and its ~200 neighbours). Our copy
#      is the same archive with the file-I/O calls renamed, so it defines exactly
#      what the store one does and dropping the original loses nothing.
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
#  (6) Drop a static archive that is already on the line under another name.
#      TigerVNC's CMake writes libtool control files and, because they say
#      installed=no, also creates `.libs/librfb.a` as a SYMLINK to `../librfb.a`
#      so libtool finds it there. The xserver's Makefile reaches librfb through
#      the .la (-> the .libs spelling) while another .la's dependency_libs names
#      the plain one, so both land on the same link. A classic linker scans the
#      second archive on demand, finds every symbol already defined and pulls
#      nothing; ld64.lld does not canonicalise paths and reports every member as
#      a duplicate symbol. Compare realpaths and keep the first. A force_load of
#      a path also displaces its plain occurrences — it pulls a superset.
#
# UNPIN_REAL_CXX = the real wrapped clang++; UNPIN_RFB_A = abs path to librfb.a;
# UNPIN_XFONT2_VFS_A = abs path to the redefined libXfont2_vfs.a (optional);
# UNPIN_LIBZ_A = abs path to the static libz.a (optional);
# UNPIN_LIBICONV_A = abs path to the static GNU libiconv.a (optional).
set -u
real="${UNPIN_REAL_CXX:?UNPIN_REAL_CXX unset}"

# fix (6): realpath of every archive already placed, so the same file cannot be
# named twice. `readlink -f` is coreutils'; macOS's own readlink has no -f, and
# the build runs with nix coreutils on PATH, but fall back to the path itself
# rather than dropping an input we could not canonicalise.
declare -A seen_a=()
canon() { readlink -f -- "$1" 2>/dev/null || printf '%s' "$1"; }
place_archive() {   # $1 = archive path; echoes nothing, returns 1 if a dupe
  local c; c=$(canon "$1")
  [[ -n "${seen_a[$c]:-}" ]] && return 1
  seen_a[$c]=1; return 0
}

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
        place_archive "$UNPIN_LIBZ_A" && args+=("$UNPIN_LIBZ_A"); continue
      fi ;;
    -o) expect_out=1 ;;
    *.a)                               # fix (6): same file, second spelling
      if [[ -e "$a" ]]; then
        place_archive "$a" || continue
      fi ;;
  esac
  args+=("$a")
done

# Drop every plain occurrence of an archive we are about to -force_load: the
# forced load pulls a superset of what the on-demand scan would, so leaving the
# plain one in only gives ld64.lld a second definition of every member.
drop_plain() {   # $1 = archive being force_loaded
  local c x
  local -a kept=()
  c=$(canon "$1")
  for x in "${args[@]}"; do
    [[ "$x" == *.a && -e "$x" && "$(canon "$x")" == "$c" ]] && continue
    kept+=("$x")
  done
  args=("${kept[@]}")
}

drop_lib() {     # $1 = library base name, e.g. Xfont2 -> -lXfont2 and libXfont2.a
  local n=$1 x
  local -a kept=()
  for x in "${args[@]}"; do
    [[ "$x" == "-l$n" || "$x" == */lib"$n".a || "$x" == lib"$n".a ]] && continue
    kept+=("$x")
  done
  args=("${kept[@]}")
}

extra=()
if (( is_xvnc )) && [[ -n "${UNPIN_RFB_A:-}" && -e "${UNPIN_RFB_A:-/nonexistent}" ]]; then
  drop_plain "$UNPIN_RFB_A"
  extra=(-Wl,-force_load,"$UNPIN_RFB_A")
fi
if (( is_xvnc )) && [[ -n "${UNPIN_XFONT2_VFS_A:-}" && -e "${UNPIN_XFONT2_VFS_A:-/nonexistent}" ]]; then
  drop_plain "$UNPIN_XFONT2_VFS_A"
  drop_lib Xfont2
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
