#!/usr/bin/env bash
#
# flash.sh — interactive batch flasher for the PogCutoffResume ATtiny412
# cutoff/resume boards, over a serial-UPDI programmer (CH340/CP210x/FTDI).
#
# What it does:
#   1. Checks a UPDI (USB-serial) adapter is actually plugged in.
#   2. Builds the firmware once from ./ATTiny412 (matches the repo source,
#      so "Days Between Reset" default = 0 / OFF).
#   3. Asks how many boards you're flashing.
#   4. For each board: waits for you to seat it, then erases -> writes the
#      1.8 V brown-out fuse -> verifies the fuse -> flashes -> verifies the
#      firmware, prints a clear SUCCESSFUL box, and tells you to seat the next.
#
#   Usage:  ./flash.sh
#   Quit early: Ctrl-C.
#
set -uo pipefail

# ----------------------------------------------------------------- config ---
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$ROOT/ATTiny412"     # PlatformIO project dir
DEVICE="attiny412"         # pymcuprog device name
FW_ENV="ATtiny412"         # [env:] that builds/uploads the firmware
FUSE_ENV="set_fuses"       # [env:] that writes the fuses
SIG="1E9223"               # ATtiny412 UPDI signature
BOD_FUSE="14"              # expected fuse1/BODCFG = 0x14 (BOD 1.8V, enabled)

# colours (only if stdout is a terminal)
if [ -t 1 ]; then G=$'\e[1;32m'; R=$'\e[1;31m'; Y=$'\e[1;33m'; C=$'\e[1;36m'; B=$'\e[1m'; X=$'\e[0m'
else G= ; R= ; Y= ; C= ; B= ; X= ; fi
say(){ printf '%b\n' "$*"; }

# ------------------------------------------------------------------ tools ---
export PATH="$HOME/.platformio/penv/bin:$HOME/.local/bin:$PATH"
if ! command -v pio >/dev/null 2>&1 || ! command -v pymcuprog >/dev/null 2>&1; then
  say "${Y}Installing PlatformIO + pymcuprog (pip --user)…${X}"
  python3 -m pip install --user --upgrade --quiet platformio pymcuprog || {
    say "${R}Auto-install failed. Run:  python3 -m pip install --user platformio pymcuprog${X}"; exit 1; }
fi

# ------------------------------------------------------------ port detect ---
# Serial-UPDI adapters can re-enumerate (ttyUSB0 -> ttyUSB1) between boards,
# so we re-detect before every operation. Prefer the stable by-id symlink.
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

# ping the target; echoes the signature (empty on failure). Serial-UPDI often
# needs a couple of tries to establish comms on a freshly seated board.
ping_sig(){
  local port="$1" i out sig
  for i in 1 2 3 4 5; do
    out="$(pymcuprog ping -t uart -u "$port" -d "$DEVICE" 2>&1)"
    sig="$(printf '%s' "$out" | sed -n 's/.*Ping response: *//p' | tr -d '[:space:]')"
    [ "$sig" = "$SIG" ] && { echo "$sig"; return 0; }
    sleep 1
  done
  echo ""
  return 1
}

retry(){ local n=$1; shift; local i; for i in $(seq 1 "$n"); do "$@" && return 0; sleep 1; done; return 1; }

# --------------------------------------------------------------- flashing ---
# Order matters: erase (halt any running firmware) -> fuses -> firmware LAST,
# so all UPDI work happens before the flashed firmware boots.
_erase(){  pymcuprog erase -t uart -u "$1" -d "$DEVICE" >/dev/null 2>&1; }
_fuses(){  ( cd "$PROJ" && pio run -e "$FUSE_ENV" -t fuses --upload-port "$1" >/dev/null 2>&1 ); }
_bod(){    [ "$(pymcuprog read -t uart -u "$1" -d "$DEVICE" -m fuses 2>/dev/null | sed -n 's/^0x001280: *//p' | awk '{print $2}')" = "$BOD_FUSE" ]; }
_upload(){ ( cd "$PROJ" && pio run -e "$FW_ENV" -t upload --upload-port "$1" 2>&1 | grep -q "bytes of flash verified" ); }

flash_board(){  # $1 = port; returns 0 only when every step verifies
  retry 3 _erase  "$1" || { say "  ${R}✗ erase failed${X}";           return 1; }
  retry 3 _fuses  "$1" || { say "  ${R}✗ fuse write failed${X}";      return 1; }
  retry 2 _bod    "$1" || { say "  ${R}✗ BOD fuse verify failed${X}"; return 1; }
  retry 3 _upload "$1" || { say "  ${R}✗ firmware verify failed${X}"; return 1; }
  return 0
}

# ------------------------------------------------------------------- main ---
say "${B}PogCutoffResume — ATtiny412 flasher${X}"
say "${C}project:${X} $PROJ"

# 1) UPDI adapter present?
say "\n${C}Checking for a UPDI (USB-serial) adapter…${X}"
if PORT="$(detect_port)"; then
  say "${G}✓ adapter found:${X} $PORT"
else
  say "${R}✗ No USB-serial (UPDI) adapter detected.${X}"
  say "  Plug your CH340/CP210x/FTDI UPDI programmer into USB and re-run."
  exit 1
fi

# 2) build firmware once
say "\n${C}Building firmware…${X}"
if ( cd "$PROJ" && pio run -e "$FW_ENV" ) >/dev/null 2>&1; then
  say "${G}✓ firmware built${X}  (Days Between Reset default = 0 / OFF)"
else
  say "${R}✗ build failed — full output:${X}"; ( cd "$PROJ" && pio run -e "$FW_ENV" ); exit 1
fi

# 3) how many boards?
echo
total=""
while ! [[ "${total:-}" =~ ^[1-9][0-9]*$ ]]; do
  printf '%b' "${B}How many boards do you need to flash?${X} "
  read -r total || exit 1
done
say "Great — flashing ${B}${total}${X} board(s).\n"

# wiring reminder
say "${Y}Wiring:${X} UPDI → J2 middle pin (PA0) · GND → any GND pad · VCC/+ → VIN"
say "${Y}       (do NOT wire a 3-pin harness straight across J2)${X}"

# 4) flash loop
n=0
while [ "$n" -lt "$total" ]; do
  next=$((n+1))
  echo
  if [ "$next" -eq 1 ]; then
    printf '%b' "${B}Seat board #${next} of ${total}${X}, then press ${B}Enter${X} (Ctrl-C to quit)… "
  else
    printf '%b' "${B}Seat board #${next} of ${total}${X}, then press ${B}Enter${X}… "
  fi
  read -r _ || { echo; break; }

  port="$(detect_port)" || { say "${R}✗ adapter disappeared — reconnect and press Enter.${X}"; continue; }
  say "  detecting target on ${port##*/}…"
  if [ -z "$(ping_sig "$port")" ]; then
    say "${R}✗ No ATtiny412 responded.${X} Check the board is seated, powered (VIN), and UPDI is on J2's middle pin. Then press Enter to retry."
    continue
  fi
  say "  ${G}✓ ATtiny412 detected${X} (sig $SIG) — programming (erase → fuse → firmware)…"

  if flash_board "$port"; then
    n=$next
    say "${G}┌────────────────────────────────────────────┐${X}"
    say "${G}│  ✅  SUCCESSFUL — board #${n} of ${total}${X}"
    say "${G}│  firmware verified · BOD 1.8V · reset=OFF${X}"
    say "${G}└────────────────────────────────────────────┘${X}"
    if [ "$n" -lt "$total" ]; then
      say "${Y}Remove board #${n} — you'll seat the next one next.${X}"
    fi
  else
    say "${R}✗ FAILED on board #${next}. Reseat it and press Enter to retry (nothing skipped).${X}"
  fi
done

echo
say "${B}${G}Done — ${n} of ${total} board(s) flashed successfully.${X}"
