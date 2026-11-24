#!/bin/zsh
# Project Aether — Phase 1 Wine + D3DMetal bootstrapper.
#
# Usage:
#   launch_d3dmetal.sh <BOTTLE_PATH> <WINE_BIN> <D3DMETAL_LIB_DIR> <EXE_PATH> <HUD_ENABLED> [GAME_ARGS...]
#
# Exit codes (mapped by BottleExit.launcherFailureHint):
#   64  usage error         66  executable not found
#   69  Rosetta 2 missing   127 wine binary missing / not executable
#   otherwise               the game's own exit status (we `exec` into Wine)
#
# Changes from the blueprint draft:
#  1. DYLD_* survives SIP. /bin/zsh and /usr/bin/arch are SIP-protected, and dyld strips
#     DYLD_* variables from protected processes. An `export DYLD_FALLBACK_LIBRARY_PATH`
#     followed by `exec arch ...` never reached Wine. We pass it with `arch -e`, which
#     sets it after arch starts, so the (unprotected) Wine process gets it.
#  2. Argument handling. `shift 5 || true` with fewer than 5 args left the positional
#     parameters unshifted and leaked them into the game's argv. We validate first.
#  3. Caller environment wins. Profile env vars from BottleEngine are kept; the values
#     here are defaults only (${VAR:-default}).

set -euo pipefail

if (( $# < 5 )); then
  echo "[AETHER ERROR] usage: $0 <BOTTLE_PATH> <WINE_BIN> <D3DMETAL_LIB_DIR> <EXE_PATH> <HUD_ENABLED> [ARGS...]" >&2
  exit 64
fi

BOTTLE_PATH="$1"
WINE_BIN="$2"
D3DMETAL_LIB_DIR="$3"
EXE_PATH="$4"
HUD_ENABLED="$5"
shift 5

if [[ ! -f "$EXE_PATH" ]]; then
  echo "[AETHER ERROR] Executable not found: $EXE_PATH" >&2
  exit 66
fi

if [[ ! -x "$WINE_BIN" ]]; then
  echo "[AETHER ERROR] Wine binary missing or not executable: $WINE_BIN" >&2
  exit 127
fi

# GPTK's Wine is x86_64-only, so Rosetta 2 is mandatory.
if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  echo "[AETHER ERROR] Rosetta 2 is not installed. Run: softwareupdate --install-rosetta --agree-to-license" >&2
  exit 69
fi

mkdir -p "$BOTTLE_PATH"

# Core Wine + D3DMetal environment. Defaults only: values from the game profile take precedence.
export WINEPREFIX="$BOTTLE_PATH"
export WINEARCH="${WINEARCH:-win64}"
export WINEMSYNC="${WINEMSYNC:-1}"
export WINEESYNC="${WINEESYNC:-1}"
export D3DM_ENABLE_METALFX="${D3DM_ENABLE_METALFX:-1}"
export MTL_HUD_ENABLED="$HUD_ENABLED"
# Silence Wine debug channels for frame pacing, unless the caller asked for specific ones.
export WINEDEBUG="${WINEDEBUG:--all}"

# Setting DYLD_FALLBACK_LIBRARY_PATH replaces dyld's default fallback (~/lib:/usr/local/lib:/usr/lib),
# so we append those defaults again.
arch_args=(-x86_64)
if [[ -n "$D3DMETAL_LIB_DIR" ]]; then
  arch_args+=(-e "DYLD_FALLBACK_LIBRARY_PATH=${D3DMETAL_LIB_DIR}:${HOME}/lib:/usr/local/lib:/usr/lib")
fi

echo "[AETHER] Bottle: $WINEPREFIX"
echo "[AETHER] Launching: $EXE_PATH (Metal HUD: $HUD_ENABLED)"

# exec keeps the PID: BottleEngine's SIGTERM lands on Wine itself, not on this shell.
exec /usr/bin/arch "${arch_args[@]}" "$WINE_BIN" "$EXE_PATH" "$@"
