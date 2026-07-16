#!/usr/bin/env bash
#
# install.sh — build and batch-flash the PogCutoffResume firmware onto ATtiny412
# boards using a serial-UPDI programmer (e.g. a CH340/CP210x/FTDI USB-serial
# adapter wired for UPDI).
#
# For every board it: erases → writes fuses (1.8V brown-out) → flashes firmware
# → verifies, prints a clear SUCCESSFUL prompt, then auto-detects the next board
# so you can flash a whole batch hands-free.
#
#   Usage:  ./install.sh
#   Finish: press Ctrl-C at any time.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$ROOT/ATTiny412"     # PlatformIO project dir
DEVICE="attiny412"         # pymcuprog device name
FW_ENV="ATtiny412"         # [env:] that builds the firmware
FUSE_ENV="set_fuses"       # [env:] that writes the fuses
SIG="1E9223"               # ATtiny412 UPDI signature
BOD_FUSE="14"              # expected fuse1/BODCFG = 0x14 (BOD 1.8V, active)

if [ -t 1 ]; then G=$'\e[1;32m'; R=$'\e[1;31m'; Y=$'\e[1;33m'; C=$'\e[1;36m'; B=$'\e[1m'; X=$'\e[0m'
else G= ; R= ; Y= ; C= ; B= ; X= ; fi
say(){ printf '%b\n' "$*"; }

# ------------------------------------------------------------------ tools ---
ensure_tools(){
  export PATH="$HOME/.platformio/penv/bin:$HOME/.local/bin:$PATH"
  if ! command -v pio >/dev/null 2>&1 || ! command -v pymcuprog >/dev/null 2>&1; then
    say "${Y}Installing PlatformIO + pymcuprog (pip --user)…${X}"
    python3 -m pip install --user --upgrade --quiet platformio pymcuprog || {
      say "${R}Auto-install failed. Run:  python3 -m pip install --user platformio pymcuprog${X}"; exit 1; }
    export PATH="$HOME/.local/bin:$PATH"
  fi
  PIO="$(command -v pio)"; PYMCU="$(command -v pymcuprog)"
  say "${C}pio      ${X}$PIO"
  say "${C}pymcuprog${X} $PYMCU"
}

# ------------------------------------------------------------ port detect ---
# Serial-UPDI adapters can re-enumerate (ttyUSB0 -> ttyUSB1) between boards, so
# we re-detect the port before every operation. Prefer the stable by-id symlink.
detect_port(){
  local p
  for p in /dev/serial/by-id/*; do
    [ -e "$p" ] || continue
    case "$p" in
      *USB*Serial*|*CH340*|*CH341*|*usbserial*|*FT232*|*FTDI*|*UPDI*|*CP210*) echo "$p"; return 0;;
    esac
  done
  for p in /dev/ttyUSB* /dev/ttyACM*; do [ -e "$p" ] && { echo "$p"; return 0; }; done
  return 1
}
ping_sig(){ "$PYMCU" ping -t uart -u "$1" -d "$DEVICE" 2>/dev/null | sed -n 's/.*Ping response: *//p' | tr -d '[:space:]'; }
board_present(){ local port; port="$(detect_port)" || return 1; [ "$(ping_sig "$port")" = "$SIG" ]; }
retry(){ local n=$1; shift; local i; for i in $(seq 1 "$n"); do "$@" && return 0; sleep 1; done; return 1; }

# --------------------------------------------------------------- flashing ---
# Order matters: erase (halt any running firmware) → fuses → firmware LAST, so
# all UPDI work happens before the firmware boots and can disturb the adapter.
_erase(){  "$PYMCU" erase -t uart -u "$1" -d "$DEVICE" >/dev/null 2>&1; }
_fuses(){  ( cd "$PROJ" && "$PIO" run -e "$FUSE_ENV" -t fuses --upload-port "$1" >/dev/null 2>&1 ); }
_bod(){    [ "$("$PYMCU" read -t uart -u "$1" -d "$DEVICE" -m fuses 2>/dev/null | sed -n 's/^0x001280: *//p' | awk '{print $2}')" = "$BOD_FUSE" ]; }
_upload(){ ( cd "$PROJ" && "$PIO" run -e "$FW_ENV" -t upload --upload-port "$1" 2>&1 | grep -q "bytes of flash verified" ); }

flash_board(){  # $1 = port; returns 0 only when every step verifies
  retry 3 _erase  "$1" || { say "  ${R}erase failed${X}";           return 1; }
  retry 3 _fuses  "$1" || { say "  ${R}fuse write failed${X}";      return 1; }
  retry 2 _bod    "$1" || { say "  ${R}BOD fuse verify failed${X}"; return 1; }
  retry 3 _upload "$1" || { say "  ${R}firmware verify failed${X}"; return 1; }
  return 0
}

# ------------------------------------------------------------------- main ---
say "${B}PogCutoffResume — ATtiny412 batch flasher${X}"
ensure_tools

say "\n${C}Building firmware…${X}"
if ( cd "$PROJ" && "$PIO" run -e "$FW_ENV" ) >/dev/null 2>&1; then
  say "${G}✓ firmware built${X}"
else
  say "${R}✗ build failed — full output:${X}"; ( cd "$PROJ" && "$PIO" run -e "$FW_ENV" ); exit 1
fi

say "\n${Y}Connect your serial-UPDI programmer to USB, then press ${B}Enter${X}${Y} to begin…${X}"
read -r _

count=0
trap 'echo; say "${B}Finished — ${count} board(s) programmed.${X}"; exit 0' INT

while true; do
  say "\n${C}▶ Insert a board  (auto-detecting… Ctrl-C to finish)${X}"
  until board_present; do sleep 1; done
  port="$(detect_port)"
  say "  detected on ${port##*/} — programming (erase → fuses → firmware)…"
  if flash_board "$port"; then
    count=$((count+1))
    say "${G}┌──────────────────────────────────────┐${X}"
    say "${G}│  ✅  SUCCESSFUL — board #${count}${X}"
    say "${G}│  firmware verified · BOD 1.8V set${X}"
    say "${G}└──────────────────────────────────────┘${X}"
    say "${Y}Remove this board — the next one starts automatically.${X}"
    # require physical removal (2 absent reads) before accepting the next board
    f=0; while [ $f -lt 2 ]; do if board_present; then f=0; else f=$((f+1)); fi; sleep 1; done
  else
    say "${R}✗ FAILED — reseat the board to retry.${X}"
    f=0; while [ $f -lt 3 ]; do if board_present; then f=0; else f=$((f+1)); fi; sleep 1; done
  fi
done
