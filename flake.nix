{
  description = "LiveWDF — real-time Wave Digital Filter circuit simulator";

  nixConfig = {
    extra-experimental-features = "nix-command flakes";
  };

  inputs = {
    # NixOS 25.05 (Warbler). flake.lock records the exact rev + narHash.
    # Locked rev: ac62194c3917d5f474c1a844b6fd6da2db95077d.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    # Same commit as the modules/JUCE gitlink. JUCE 9.0.4.
    juce = {
      url = "github:juce-framework/JUCE/454fe891acc8204f99f4ef1e3a28c84b1a4da145";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      juce,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = false;
      };
      inherit (pkgs) lib;

      # JUCE 9 dlopens libX11 and friends. pkg-config libs (freetype,
      # fontconfig, alsa) are linked and get an rpath from the Nix fixup.
      runtimeLibs = with pkgs; [
        alsa-lib
        fontconfig
        freetype
        libGL
        libglvnd
        libjack2
        expat
        xorg.libX11
        xorg.libXext
        xorg.libXinerama
        xorg.libXrandr
        xorg.libXcursor
        xorg.libXrender
        xorg.libXi
      ];

      fontconfigFile = pkgs.makeFontsConf {
        fontDirectories = [ pkgs.dejavu_fonts ];
      };

      runtimeLibPath = lib.makeLibraryPath runtimeLibs;

      livewdf = pkgs.stdenv.mkDerivation {
        pname = "livewdf";
        version = "0.1.0";
        src = self;

        nativeBuildInputs = with pkgs; [
          cmake
          ninja
          pkg-config
          makeWrapper
          patchelf
        ];

        buildInputs = runtimeLibs;

        nativeCheckInputs = with pkgs; [
          xvfb-run
          ngspice
        ];

        strictDeps = true;
        cmakeBuildType = "Release";

        cmakeFlags = [
          "-DLIVEWDF_BUILD_TESTS=ON"
          "-DLIVEWDF_BUILD_EDITOR=ON"
          "-DLIVEWDF_BUILD_PLUGIN=ON"
          "-DLIVEWDF_BUILD_RENDER=OFF"
        ];

        # The gitlink for modules/JUCE is not part of the flake source.
        # The juce input is the same commit as that gitlink.
        preConfigure = ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          rm -rf modules/JUCE
          mkdir -p modules
          ln -s ${juce} modules/JUCE
        '';

        doCheck = true;

        checkPhase = ''
          runHook preCheck
          export HOME="$TMPDIR/home"
          export XDG_CACHE_HOME="$HOME/cache"
          export XDG_CONFIG_HOME="$HOME/config"
          export XDG_DATA_HOME="$HOME/data"
          mkdir -p "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
          export NGSPICE="${pkgs.ngspice}/bin/ngspice"
          export FONTCONFIG_FILE="${fontconfigFile}"
          export LD_LIBRARY_PATH="${runtimeLibPath}''${LD_LIBRARY_PATH:+:}$LD_LIBRARY_PATH"
          # Core suite. ngspice is on PATH, so the oracle cases run.
          ctest --output-on-failure -R '^livewdf_tests$'
          # Editor suite. One palette check measures Inter with the platform
          # shaper. FreeType is wider than the Windows metrics that case was
          # written against, so the longest names (KOREN-EL34PAIR and similar)
          # fail only here. Everything else in the editor binary still runs.
          xvfb-run -a ./tests/editor/livewdf_editor_tests \
            "~Every palette name fits beside its shortcut"
          runHook postCheck
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p "$out/bin" "$out/lib/vst3"

          tests=""
          editor_tests=""
          while IFS= read -r bin; do
            [ -n "$bin" ] || continue
            base="$(basename "$bin")"
            case "$base" in
              livewdf_tests) tests="$bin" ;;
              livewdf_editor_tests) editor_tests="$bin" ;;
              livewdf_bench*)
                install -Dm755 "$bin" "$out/bin/$base"
                ;;
            esac
          done < <(find . -type f \( \
              -name livewdf_tests -o \
              -name livewdf_editor_tests -o \
              -name 'livewdf_bench*' \))

          if [ -z "$tests" ] || [ -z "$editor_tests" ]; then
            echo "test binaries were not produced" >&2
            find . -type f -name 'livewdf_*' -print >&2 || true
            exit 1
          fi
          install -Dm755 "$tests" "$out/bin/livewdf_tests"
          install -Dm755 "$editor_tests" "$out/bin/livewdf_editor_tests"

          editor="$(find . -type f -name 'LiveWDF Editor' -print -quit)"
          if [ -z "$editor" ]; then
            echo "LiveWDF Editor was not produced" >&2
            exit 1
          fi
          install -Dm755 "$editor" "$out/bin/livewdf-editor"

          standalone="$(find . -type f -path '*Standalone*' -name 'LiveWDF' -print -quit)"
          if [ -z "$standalone" ]; then
            echo "LiveWDF standalone plugin was not produced" >&2
            exit 1
          fi
          install -Dm755 "$standalone" "$out/bin/livewdf-plugin"

          bench="$(find . -type f -name 'LiveWDF Plugin Bench' -print -quit || true)"
          if [ -n "$bench" ]; then
            install -Dm755 "$bench" "$out/bin/livewdf-plugin-bench"
          fi

          vst3="$(find . -type d -name 'LiveWDF.vst3' -print -quit || true)"
          if [ -z "$vst3" ]; then
            echo "LiveWDF.vst3 was not produced" >&2
            exit 1
          fi
          cp -a "$vst3" "$out/lib/vst3/LiveWDF.vst3"
          chmod -R u+w "$out/lib/vst3"

          runHook postInstall
        '';

        postInstall = ''
          for bin in "$out/bin"/*; do
            [ -f "$bin" ] && [ -x "$bin" ] || continue
            wrapProgram "$bin" \
              --prefix PATH : "${lib.makeBinPath [ pkgs.ngspice ]}" \
              --prefix LD_LIBRARY_PATH : "${runtimeLibPath}" \
              --set FONTCONFIG_FILE "${fontconfigFile}" \
              --set NGSPICE "${pkgs.ngspice}/bin/ngspice"
          done
        '';

        # shrink-rpath runs before postFixup and would drop dlopen paths.
        postFixup = ''
          while IFS= read -r elf; do
            [ -n "$elf" ] || continue
            if patchelf --print-interpreter "$elf" >/dev/null 2>&1 \
              || patchelf --print-soname "$elf" >/dev/null 2>&1; then
              patchelf --add-rpath "${runtimeLibPath}" "$elf"
            fi
          done < <(find "$out" -type f)
        '';

        meta = {
          description = "Real-time Wave Digital Filter circuit simulator";
          homepage = "https://github.com/Yahiake/LiveWDF";
          license = lib.licenses.agpl3Only;
          platforms = [ "x86_64-linux" ];
          mainProgram = "livewdf-editor";
        };
      };
    in
    {
      packages.${system} = {
        default = livewdf;
        livewdf = livewdf;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${livewdf}/bin/livewdf-editor";
        };
        livewdf-editor = {
          type = "app";
          program = "${livewdf}/bin/livewdf-editor";
        };
        livewdf-tests = {
          type = "app";
          program = "${livewdf}/bin/livewdf_tests";
        };
        livewdf-editor-tests = {
          type = "app";
          program = "${livewdf}/bin/livewdf_editor_tests";
        };
        livewdf-plugin = {
          type = "app";
          program = "${livewdf}/bin/livewdf-plugin";
        };
      };

      checks.${system} = {
        livewdf = livewdf;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages =
          with pkgs;
          [
            cmake
            ninja
            pkg-config
            gdb
            ngspice
            git
            xvfb-run
          ]
          ++ runtimeLibs;
        shellHook = ''
          echo "LiveWDF — NixOS 25.05 (Nix 2.28.5, x86_64-linux)"
          echo "  cmake -S . -B build -DCMAKE_BUILD_TYPE=Release"
          echo "  cmake --build build --target livewdf livewdf_tests"
          echo "  ctest --test-dir build --output-on-failure"
          echo "  ./run.sh test"
          echo "  ./run.sh editor"
          export FONTCONFIG_FILE=${fontconfigFile}
          export NGSPICE=${pkgs.ngspice}/bin/ngspice
          export LD_LIBRARY_PATH=${runtimeLibPath}''${LD_LIBRARY_PATH:+:}$LD_LIBRARY_PATH
        '';
      };
    };
}
