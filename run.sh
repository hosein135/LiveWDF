#!/usr/bin/env bash
# LiveWDF — Nix launcher for x86_64 Linux (bare metal, VM, or WSL2).
set -euo pipefail

info()  { printf '%s\n' "[run] $*"; }
warn()  { printf '%s\n' "[run] $*" >&2; }
error() { printf '%s\n' "[run] ERROR: $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
LIVEWDF_ORIG_ARGS=("$@")

# shellcheck source=nix/host-linux.sh
. "${SCRIPT_DIR}/nix/host-linux.sh"

# sudo looks like "Nix is not installed" because root does not see the
# desktop user's profile. Switch back before checks or installs.
if [ "${1:-}" != "--help" ] && [ "${1:-}" != "-h" ]; then
  livewdf_rerun_as_desktop_user "$@" || exit 1
fi

COMMAND="shell"
EXTRA=()
PREP_ONLY=false
CLEAN=false
SEEN_COMMAND=false

show_help() {
  cat <<'EOF'
LiveWDF — run via Nix flake (pure eval, NixOS 25.05).

  ./run.sh              development shell (cmake, ninja, ngspice, JUCE libs)
  ./run.sh shell        same as ./run.sh
  ./run.sh test         build and run livewdf_tests
  ./run.sh editor       build and open the circuit editor
  ./run.sh plugin       build and open the standalone plugin
  ./run.sh --prep-only  build LiveWDF into the Nix store (out-link: ./result)
  ./run.sh --clean      remove local CMake build directories and ./result

Arguments after the command are passed through:
  ./run.sh test [approx]
  ./run.sh shell -- cmake -S . -B build -DCMAKE_BUILD_TYPE=Release

Needs x86_64 Linux: bare metal, a VM, or WSL2 (not WSL1, not
Windows-native). Run as your desktop user. sudo is accepted and
continues as that user. Missing git and curl are installed with that
distro's package manager. If curl still cannot be installed, a static
binary is downloaded. Nix 2.28.5 (the NixOS 25.05 package manager) is
required. Any other Nix is replaced. On NixOS, /nix is kept and 2.28.5
is installed into your user profile.
nixpkgs is locked to NixOS 25.05 in flake.lock
(rev ac62194c3917d5f474c1a844b6fd6da2db95077d).
JUCE is locked to the modules/JUCE gitlink
(454fe891acc8204f99f4ef1e3a28c84b1a4da145).
First install keeps the toolchain in the Nix store and needs ~6 GiB free.

The editor and the plugin open on your desktop display. Core tests do
not need a GUI. Inside the dev shell, init the JUCE submodule once if
you configure with CMake yourself; nix build uses the flake pin.
EOF
}

for arg in "$@"; do
  if [ "${SEEN_COMMAND}" = true ]; then
    EXTRA+=("$arg")
    continue
  fi
  case "$arg" in
    --help|-h)
      show_help
      exit 0
      ;;
    --prep-only) PREP_ONLY=true ;;
    --clean) CLEAN=true ;;
    shell|test|editor|plugin)
      COMMAND="$arg"
      SEEN_COMMAND=true
      ;;
    *)
      COMMAND="shell"
      EXTRA+=("$arg")
      SEEN_COMMAND=true
      ;;
  esac
done

# Preflight before Nix or any store writes.
livewdf_check_linux_host || exit 1
livewdf_check_free_space || exit 1
livewdf_ensure_bootstrap_tools || exit 1

if [ "${CLEAN}" = true ]; then
  info "Removing local CMake build directories and the result link ..."
  rm -rf "${SCRIPT_DIR}/build"
  rm -rf "${SCRIPT_DIR}/build_"* "${SCRIPT_DIR}/build-"* 2>/dev/null || true
  rm -f "${SCRIPT_DIR}/result" "${SCRIPT_DIR}/result-"*
fi

livewdf_ensure_nix || exit 1

if [ ! -f "${SCRIPT_DIR}/flake.lock" ]; then
  error "flake.lock is missing. This repository must ship a lock file for reproducibility."
  exit 1
fi

rev="$(livewdf_nixpkgs_25_05_rev || true)"
if [ -z "${rev}" ]; then
  error "flake.lock has no nixos-25.05 revision."
  exit 1
fi
info "nixpkgs: NixOS 25.05 ${rev}"
info "Nix package manager: ${LIVEWDF_NIX_PIN_VERSION}"

livewdf_ensure_flake_git_files || exit 1
livewdf_warn_if_git_dirty

# Local CMake in the dev shell reads modules/JUCE. The Nix build uses the
# flake input of the same commit and does not need this checkout.
livewdf_ensure_juce_checkout() {
  if [ -f "${SCRIPT_DIR}/modules/JUCE/CMakeLists.txt" ]; then
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    warn "modules/JUCE is not checked out and git is not installed."
    return 0
  fi
  if ! git -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  info "Checking out modules/JUCE (git submodule) ..."
  git -C "${SCRIPT_DIR}" submodule update --init modules/JUCE
}

if [ "${PREP_ONLY}" = true ]; then
  info "Building LiveWDF (pure flake eval, nixpkgs 25.05) ..."
  "${NIX_BIN}" build --accept-flake-config "${SCRIPT_DIR}#livewdf" --out-link "${SCRIPT_DIR}/result"
  info "Done. Binaries are in the Nix store, linked at ${SCRIPT_DIR}/result."
  exit 0
fi

case "${COMMAND}" in
  shell)
    livewdf_ensure_juce_checkout || exit 1
    info "Opening the LiveWDF development shell ..."
    if [ ${#EXTRA[@]} -eq 0 ]; then
      exec "${NIX_BIN}" develop --accept-flake-config "${SCRIPT_DIR}"
    fi
    exec "${NIX_BIN}" develop --accept-flake-config "${SCRIPT_DIR}" -c "${EXTRA[@]}"
    ;;
  test)
    info "Building and running livewdf_tests ..."
    exec "${NIX_BIN}" run --accept-flake-config "${SCRIPT_DIR}#livewdf-tests" -- "${EXTRA[@]}"
    ;;
  editor)
    info "Building and starting the editor ..."
    exec "${NIX_BIN}" run --accept-flake-config "${SCRIPT_DIR}#livewdf-editor" -- "${EXTRA[@]}"
    ;;
  plugin)
    info "Building and starting the standalone plugin ..."
    exec "${NIX_BIN}" run --accept-flake-config "${SCRIPT_DIR}#livewdf-plugin" -- "${EXTRA[@]}"
    ;;
  *)
    error "Unknown command: ${COMMAND}"
    exit 1
    ;;
esac
