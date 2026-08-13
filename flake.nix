{
  description = "Xvnc (the TigerVNC X server) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";
  inputs.nixpkgs.follows = "unpins-lib/nixpkgs";

  # Xvnc (the TigerVNC X server) as a single self-contained binary — TigerVNC
  # trimmed to the Xvnc DDX, the whole client-side xkbcomp compiled in-process
  # (every RMLVO keymap), the xkeyboard-config tree + core bitmap fonts embedded
  # in the binary's EOF ZIP and served by the unpin-vfs, no /nix/store closure.
  #
  # Three structurally different platform paths feed one mkStandaloneFlake:
  #   - Linux (static-musl, every arch): VFS via `ld --wrap`; see linux.nix.
  #   - macOS (Mach-O, libSystem-only): no --wrap → llvm-objcopy --redefine-sym +
  #     an autotools relink against a dynamic-base build with pkgsStatic libs and
  #     a libSystem-only gate; see darwin.nix.
  #   - Windows (Cosmopolitan APE → PE): cosmo's native zipos VFS; see cosmo/.
  # The xkb tree + core fonts are embedded by nix-lib's withUnpinEmbed
  # (runtimeStage) on Linux/macOS, and by cosmo's own zipos zip on Windows.
  #
  # Catalog naming policy: the shipped binary KEEPS its upstream name `Xvnc`
  # (binName = "Xvnc"); each module adds a lowercase `xvnc` compat symlink so the
  # action-build gate (result/bin/<package-name>) resolves it. No binary rename.
  outputs = { self, unpins-lib, nixpkgs }:
    let
      ulib = unpins-lib.lib;
      lib = nixpkgs.lib;

      # Arch-independent runtime data (XKB rules/symbols text + .pcf.gz bitmap
      # fonts). Pull the x86_64-linux copies so cross/darwin builders don't rebuild
      # pure data; identical bytes either way.
      dataPkgs = nixpkgs.legacyPackages."x86_64-linux";

      # Curated man tree: ONLY Xvnc.1 (decompressed). The autotools xserver build
      # doesn't leave a harvestable Xvnc.1 in share/man, and nixpkgs' tigervnc man
      # output carries pages for every tool we dropped (vncviewer/vncpasswd/…). Pin
      # the one page we ship; used as manRoot for Linux/macOS (withUnpinEmbed) and
      # winManRoot for Windows, so all three embed exactly Xvnc.1.
      #
      # The page content is arch-independent (read from the x86_64-linux tigervnc as
      # a substitutable download), but the *runCommand itself* must run on the build
      # host: pinning it to x86_64-linux made it unbuildable on the aarch64 CI runner
      # (which builds the aarch64-linux native + armv7l-linux cross targets) →
      # "platform mismatch". Parameterize over the per-target pkgs and emit it via
      # buildPackages.runCommand so its `system` always tracks the build platform.
      manSrc = "${dataPkgs.tigervnc.man or dataPkgs.tigervnc}/share/man/man1/Xvnc.1.gz";
      mkCuratedMan = pkgs: pkgs.buildPackages.runCommand "xvnc-man" { } ''
        mkdir -p $out/share/man/man1
        gzip -dc ${manSrc} > $out/share/man/man1/Xvnc.1
      '';
      # Windows always cross-builds on x86_64-linux, so its winManRoot can use the
      # x86_64-linux executor directly.
      curatedMan = mkCuratedMan dataPkgs;

      # pkgsStatic leaf fixes: libxcvt defaults meson to a shared object that can't
      # link the static-only crt; libfontenc bakes its encodingsdir as an embedded
      # /nix/store string → pin to /zip. riscv64 has no libjpeg-turbo SIMD impl but
      # simdcoverage.c still references the jsimd_can_* funcs → disable SIMD there.
      staticFixes = selfP: superP: {
        libxcvt = superP.libxcvt.overrideAttrs (o: {
          postPatch = (o.postPatch or "") + ''
            substituteInPlace lib/meson.build \
              --replace-fail "shared_library('xcvt'," "library('xcvt',"
          '';
          mesonFlags = (o.mesonFlags or [ ]) ++ [ "-Ddefault_library=static" ];
        });
        libfontenc = superP.libfontenc.overrideAttrs (o: {
          configureFlags = (o.configureFlags or [ ]) ++ [
            "--with-fontrootdir=/zip/fonts"
            "--with-encodingsdir=/zip/fonts/encodings"
          ];
        });
      } // lib.optionalAttrs (superP.stdenv.hostPlatform.parsed.cpu.name == "riscv64") {
        libjpeg_turbo = superP.libjpeg_turbo.overrideAttrs (o: {
          cmakeFlags = (o.cmakeFlags or [ ]) ++ [ "-DWITH_SIMD=0" ];
        });
      };

      # The X stack libs are marked `badPlatforms = static` (and pkgsStatic.python3
      # `broken`) in nixpkgs even though they build + link fine static (the spike
      # proved the whole Xvnc closure does). mkStandaloneFlake's pkgs doesn't set
      # the escape hatches, so re-derive the set from the SAME nixpkgs with them.
      allowUnsup = pkgs:
        let hp = pkgs.stdenv.hostPlatform; bp = pkgs.stdenv.buildPlatform; in
        import nixpkgs ({
          system = bp.system;
          # `allowBroken` used to sit here too. nixpkgs replaced it with
          # `problems.handlers`, so it went inert without a word and took the
          # whole darwin matrix with it (tigervnc is `broken = isDarwin`); the
          # fix is a per-derivation `meta.broken = false` in darwin.nix, where
          # it is a claim about this recipe rather than a blanket amnesty.
          config = {
            allowUnsupportedSystem = true;
            problems.handlers.python3.broken = "ignore";
          };
        } // lib.optionalAttrs (hp != bp) { crossSystem = { config = hp.config; }; });

      # Cosmo (Windows) leaf fixes — the X-stack chains that don't cross-build under
      # cosmocc, plus the gnutls slim. libxfont2 needs no FreeType backend (PCF
      # fonts only); libxcvt static; pixman drops the libpng/zlib-probing demos.
      xvncCosmoFixes = final: prev: {
        libxfont_2 = prev.libxfont_2.overrideAttrs (o: {
          configureFlags = (o.configureFlags or []) ++ [ "--disable-freetype" ];
          buildInputs = builtins.filter
            (x: (x.pname or x.name or "") != "freetype") (o.buildInputs or []);
        });
        libxcvt = prev.libxcvt.overrideAttrs (o: {
          postPatch = (o.postPatch or "") + ''
            substituteInPlace lib/meson.build \
              --replace 'shared_library(' 'library('
          '';
        });
        pixman = prev.pixman.overrideAttrs (o: {
          mesonFlags = (o.mesonFlags or []) ++ [ "-Dtests=disabled" "-Ddemos=disabled" ];
          buildInputs = builtins.filter
            (x: builtins.match ".*libpng.*" (x.name or "") == null) (o.buildInputs or []);
        });
        # libjpeg-turbo declares a `man` output but its CMake man install is skipped
        # under the cosmo cross → "failed to produce output path for output 'man'".
        libjpeg_turbo = prev.libjpeg_turbo.overrideAttrs (o: {
          postInstall = (o.postInstall or "") + "\nmkdir -p $man\n";
        });
        # gnutls slimmed for cosmo: drop the optional features whose deps don't (yet)
        # build under cosmocc — TigerVNC's x509 TLS needs none of them.
        #   gettext (--disable-nls), unbound (--disable-libdane), libidn2
        #   (--without-idn), libunistring (--with-included-unistring), p11-kit
        #   (withP11-kit=false). Core x509 keeps nettle+gmp+libtasn1+zlib.
        gnutls =
          let
            dropNames = [ "gettext" "unbound" "libidn2" "libunistring" "p11-kit" ];
            dropDep = builtins.filter (x:
              !(builtins.elem (x.pname or x.name or "") dropNames));
          in
          (prev.gnutls.override { withP11-kit = false; }).overrideAttrs (o: {
            configureFlags = (o.configureFlags or []) ++ [
              "--disable-nls" "--disable-libdane" "--without-idn"
              "--with-included-unistring"
            ];
            # gnulib's getlocalename_l-unsafe.c #errors on unrecognized targets
            # (cosmo isn't in its ladder). Only gnutls's CLI-tools gnulib pulls it;
            # cosmo defaults to the C locale, so the generic POSIX "C" fallback is
            # correct (TigerVNC links only libgnutls.a, but nix builds the tools too).
            postPatch = (o.postPatch or "") + ''
              if [ -f src/gl/tests/getlocalename_l-unsafe.c ]; then
                substituteInPlace src/gl/tests/getlocalename_l-unsafe.c \
                  --replace-fail \
                    '#error "Please port gnulib getlocalename_l-unsafe.c to your platform! Report this to bug-gnulib."' \
                    'return (struct string_with_storage) { "C", STORAGE_INDEFINITE };'
              fi
            '';
            buildInputs = dropDep (o.buildInputs or []);
            propagatedBuildInputs = dropDep (o.propagatedBuildInputs or []);
          });
      };

      # The xkb tree + core fonts, staged at the embedded ZIP root for the
      # unpin-vfs self-EOF reader. Shared by the Linux + macOS withUnpinEmbed calls
      # (Windows embeds the same trees via cosmo's zipos in cosmo/).
      runtimeStage = ''
        mkdir -p "$__unpin_stage/xkb" "$__unpin_stage/fonts/misc"
        # -aL: deref the rules/{xorg,xorg.lst,xorg.xml} -> base* symlinks so the ZIP
        # is symlink-free; the dupes are byte-identical → the shared zstd dict
        # erases them.
        cp -aL ${dataPkgs.xkeyboard_config}/share/X11/xkb/. "$__unpin_stage/xkb/"

        cp ${dataPkgs.xorg.fontmiscmisc}/share/fonts/X11/misc/*.pcf.gz "$__unpin_stage/fonts/misc/"
        cp ${dataPkgs.xorg.fontcursormisc}/share/fonts/X11/misc/*.pcf.gz "$__unpin_stage/fonts/misc/"
        { n1=$(sed -n 1p ${dataPkgs.xorg.fontmiscmisc}/share/fonts/X11/misc/fonts.dir)
          n2=$(sed -n 1p ${dataPkgs.xorg.fontcursormisc}/share/fonts/X11/misc/fonts.dir)
          echo $((n1 + n2))
          tail -n +2 ${dataPkgs.xorg.fontmiscmisc}/share/fonts/X11/misc/fonts.dir
          tail -n +2 ${dataPkgs.xorg.fontcursormisc}/share/fonts/X11/misc/fonts.dir
        } > "$__unpin_stage/fonts/misc/fonts.dir"
        cp ${dataPkgs.xorg.fontalias}/share/fonts/X11/misc/fonts.alias \
           "$__unpin_stage/fonts/misc/fonts.alias"
        chmod -R u+w "$__unpin_stage"
      '';

      # The bare server derivation for a target pkg set: Linux static-musl or the
      # macOS dynamic-base build (branch on the platform). Does NOT embed data or
      # strip — withUnpinEmbed (below) does that uniformly.
      buildServer = pkgs0:
        let pkgs = allowUnsup pkgs0; in
        if pkgs.stdenv.hostPlatform.isDarwin then
          let xk = import ./darwin-xkbcomp.nix { inherit pkgs; };
          in import ./darwin.nix { inherit ulib pkgs; xkbcompObj = xk; }
        else
          let
            static = pkgs.pkgsStatic.extend staticFixes;
            xk = import ./linux-xkbcomp.nix { inherit static pkgs; };
          in import ./linux.nix { inherit ulib static pkgs; xkbcompObj = xk; };

      # mkStandaloneFlake `build`: the PRISTINE server (no embed). The xkb/font
      # runtime tree + the curated Xvnc man page are embedded once, post-build, via
      # runtimeEmbed.native → unpinEmbedWrap (one self-EOF ZIP, the single embed
      # path), into the upstream-named `Xvnc` binary (binName; the module already
      # added the lowercase `xvnc` gate symlink). Windows is cosmo which embeds
      # xkb/fonts via its own zipos in-build, so only man is added there (the
      # framework default, sourced from winManRoot = curatedMan).
      build = pkgs: buildServer pkgs;
      runtimeEmbed.native = pkgs: base: {
        man = true;
        manRoot = "${mkCuratedMan pkgs}";
        inherit runtimeStage;
      };

      # Windows: the cosmo cross set with the xvnc leaf fixes layered on, feeding
      # the cosmo Xvnc module (its own zipos embed for xkb/fonts + the gate symlink;
      # the framework then carries that tail-ZIP and adds man via withMan --carry).
      windowsBuild = wpkgs:
        let
          c = wpkgs.pkgsCross.cosmo.extend xvncCosmoFixes;
          xk = import ./cosmo/xkbcomp.nix { cosmoPkgs = c; };
        in import ./cosmo/default.nix { cosmoPkgs = c; inherit nixpkgs; xkbcompObj = xk; };
    in
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "xvnc";
      # The binary keeps its upstream name `Xvnc`; binName feeds the man-embed
      # primary + apps.default.program. The gate finds result/bin/xvnc via the
      # lowercase compat symlink each module installs.
      binName = "Xvnc";
      # nixpkgs attr for the man graft (windows winManGraft) / optimize overlay.
      # The build is bespoke, so GC is off; man is harvested from the build's own
      # share/man on Linux/macOS and grafted from nixpkgs tigervnc on Windows.
      pkgsAttr = "tigervnc";
      license = "GPL-2.0-or-later";
      optimize = { gc = false; };
      # The xserver bakes `$out/lib/xorg/protocol.txt` into the binary, but this
      # build installs only bin/ — the path never exists. Harmless as a
      # self-reference in the pristine base; once unpinEmbedWrap copies the binary
      # into its own output it becomes a real dependency on the base. Scrub it.
      removeReferences = [ "xvnc" ];
      # Windows embeds the same curated single page (else the nixpkgs tigervnc man
      # graft would carry every dropped tool's page).
      winManRoot = curatedMan;

      inherit build windowsBuild runtimeEmbed;

      # Xvnc is a server; `-version` prints its TigerVNC banner and exits 0.
      smoke = [ "-version" ];
      smokePattern = "TigerVNC";
    };
}
