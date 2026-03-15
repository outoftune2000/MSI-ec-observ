#!/usr/bin/env bash
set -euo pipefail

EC_IO_FILE="${EC_IO_FILE:-/sys/kernel/debug/ec/ec0/io}"
OUT_DIR="${OUT_DIR:-./ec_logs}"
EC_COUNT="${EC_COUNT:-256}"
WRITES_LOG="${OUT_DIR}/ec_writes.csv"

# Defaults aligned with OpenFreezeCenter config.py values.
CPU_TEMP_ADDR="${CPU_TEMP_ADDR:-104}"
GPU_TEMP_ADDR="${GPU_TEMP_ADDR:-128}"
CPU_RPM_ADDR="${CPU_RPM_ADDR:-200}"
GPU_RPM_ADDR="${GPU_RPM_ADDR:-202}"
PROFILE_ADDR="${PROFILE_ADDR:-212}"
COOLER_BOOST_ADDR="${COOLER_BOOST_ADDR:-152}"
WATCH_ADDRS_DEFAULT="${WATCH_ADDRS_DEFAULT:-104,128,152,200,202,212,114,115,116,117,118,119,120,138,139,140,141,142,143,144}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Standalone EC observability helper.

Usage:
  ./ec_observe.sh snapshot [label] [count]
  ./ec_observe.sh action [label] [-- command arg1 arg2 ...]
  ./ec_observe.sh diff <before.txt> <after.txt>
  ./ec_observe.sh watch [interval_seconds] [addr_csv]
  ./ec_observe.sh watch-unknown [interval_seconds] [start_addr] [count]
  ./ec_observe.sh write <byte_addr> <value_0_to_255> [profile_name]

Examples:
  ./ec_observe.sh snapshot baseline
  ./ec_observe.sh action auto_to_adv
  ./ec_observe.sh action auto_to_adv -- ./set_profile.sh advanced
  ./ec_observe.sh diff ec_logs/20260315_091000_before.txt ec_logs/20260315_091010_after.txt
  ./ec_observe.sh watch 0.5
  ./ec_observe.sh watch 0.5 "104,128,200,202,212"
  ./ec_observe.sh watch-unknown 0.5 0 256
  ./ec_observe.sh write 0xd4 141 Advanced

Notes:
  - Most systems require root permissions for /sys/kernel/debug/ec/ec0/io.
  - Run with sudo (recommended) or allow sudo prompts when needed.
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

with_sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_prereqs() {
  require_cmd dd
  require_cmd od
  require_cmd xxd
  require_cmd python3
  if [[ ! -e "$EC_IO_FILE" ]]; then
    echo "EC IO file not found: $EC_IO_FILE" >&2
    exit 1
  fi
}

ensure_out_dir() {
  mkdir -p "$OUT_DIR"
  if [[ ! -f "$WRITES_LOG" ]]; then
    echo "timestamp,byte_dec,byte_hex,value_dec,value_hex,profile" >"$WRITES_LOG"
  fi
}

ts_iso() {
  date -Is
}

sanitize_label() {
  local raw="$1"
  echo "$raw" | tr -cs 'a-zA-Z0-9._-' '_'
}

to_int() {
  local value="$1"
  # shellcheck disable=SC2004
  echo "$((value))"
}

read_byte() {
  local addr="$1"
  with_sudo dd if="$EC_IO_FILE" bs=1 skip="$addr" count=1 status=none \
    | od -An -tu1 \
    | tr -d '[:space:]'
}

read_word_be() {
  local addr="$1"
  local hex
  hex="$(
    with_sudo dd if="$EC_IO_FILE" bs=1 skip="$addr" count=2 status=none \
      | xxd -p \
      | tr -d '\n'
  )"
  if [[ -z "$hex" ]]; then
    echo 0
  else
    printf '%d\n' "0x${hex}"
  fi
}

rpm_from_tach() {
  local tach="$1"
  if [[ "$tach" -le 0 ]]; then
    echo 0
  else
    echo $((478000 / tach))
  fi
}

snapshot() {
  local label="${1:-snapshot}"
  local count="${2:-$EC_COUNT}"
  local ts name raw txt

  ensure_out_dir
  ts="$(date +%Y%m%d_%H%M%S)"
  name="$(sanitize_label "$label")"
  raw="${OUT_DIR}/${ts}_${name}.bin"
  txt="${OUT_DIR}/${ts}_${name}.txt"

  with_sudo dd if="$EC_IO_FILE" bs=1 count="$count" status=none >"$raw"
  xxd -g1 "$raw" >"$txt"

  echo "$txt"
}

diff_snapshots() {
  local before="$1"
  local after="$2"
  if [[ ! -f "$before" || ! -f "$after" ]]; then
    echo "Both files must exist for diff." >&2
    exit 1
  fi

  echo "=== Unified diff ==="
  diff -u "$before" "$after" || true
  echo
  echo "=== Byte-level changes ==="
  python3 "$SCRIPT_DIR/ec_diff.py" "$before" "$after"
}

log_write() {
  local addr="$1"
  local value="$2"
  local profile="$3"
  ensure_out_dir
  printf '%s,%d,0x%02x,%d,0x%02x,%s\n' \
    "$(ts_iso)" "$addr" "$addr" "$value" "$value" "$profile" >>"$WRITES_LOG"
}

write_byte() {
  local addr value profile hex_byte
  addr="$(to_int "$1")"
  value="$(to_int "$2")"
  profile="${3:-unknown}"

  if ((value < 0 || value > 255)); then
    echo "Value must be in 0..255, got: $value" >&2
    exit 1
  fi

  hex_byte="$(printf '%02x' "$value")"
  printf '%b' "\\x${hex_byte}" | with_sudo dd of="$EC_IO_FILE" bs=1 seek="$addr" conv=notrunc status=none
  log_write "$addr" "$value" "$profile"
  echo "Wrote addr=${addr} (0x$(printf '%02x' "$addr")) value=${value} (0x${hex_byte}) profile=${profile}"
}

watch_loop() {
  local interval="${1:-0.5}"
  local addr_csv="${2:-$WATCH_ADDRS_DEFAULT}"
  local -a addrs
  local ts cpu_temp gpu_temp cpu_tach gpu_tach cpu_rpm gpu_rpm profile cooler val addr

  IFS=',' read -r -a addrs <<<"$addr_csv"
  echo "Watching EC every ${interval}s. Press Ctrl-C to stop."
  echo "Temp/RPM addresses: CPU temp ${CPU_TEMP_ADDR}, GPU temp ${GPU_TEMP_ADDR}, CPU rpm ${CPU_RPM_ADDR}, GPU rpm ${GPU_RPM_ADDR}"

  while true; do
    ts="$(ts_iso)"
    cpu_temp="$(read_byte "$CPU_TEMP_ADDR" || echo "NA")"
    gpu_temp="$(read_byte "$GPU_TEMP_ADDR" || echo "NA")"
    cpu_tach="$(read_word_be "$CPU_RPM_ADDR" || echo 0)"
    gpu_tach="$(read_word_be "$GPU_RPM_ADDR" || echo 0)"
    cpu_rpm="$(rpm_from_tach "$cpu_tach")"
    gpu_rpm="$(rpm_from_tach "$gpu_tach")"
    profile="$(read_byte "$PROFILE_ADDR" || echo "NA")"
    cooler="$(read_byte "$COOLER_BOOST_ADDR" || echo "NA")"

    printf '%s cpu_temp=%sC gpu_temp=%sC cpu_rpm=%s gpu_rpm=%s profile_byte=%s cooler_boost_byte=%s' \
      "$ts" "$cpu_temp" "$gpu_temp" "$cpu_rpm" "$gpu_rpm" "$profile" "$cooler"

    for addr in "${addrs[@]}"; do
      addr="$(echo "$addr" | xargs)"
      if [[ -z "$addr" ]]; then
        continue
      fi
      val="$(read_byte "$(to_int "$addr")" || echo "NA")"
      printf ' [%d]=%s' "$(to_int "$addr")" "$val"
    done
    printf '\n'
    sleep "$interval"
  done
}

read_block_values() {
  local start="$1"
  local count="$2"
  with_sudo dd if="$EC_IO_FILE" bs=1 skip="$start" count="$count" status=none \
    | od -An -tu1 -v \
    | tr -s '[:space:]' ' '
}

watch_unknown_loop() {
  local interval="${1:-0.5}"
  local start count addr_csv
  local -A known=()
  local -a addrs current previous
  local addr val i ts line changed_count entry changes

  start="$(to_int "${2:-0}")"
  count="$(to_int "${3:-$EC_COUNT}")"
  addr_csv="${4:-$WATCH_ADDRS_DEFAULT}"

  if ((start < 0 || count <= 0)); then
    echo "watch-unknown requires start >= 0 and count > 0." >&2
    exit 1
  fi

  IFS=',' read -r -a addrs <<<"$addr_csv"
  for addr in "${addrs[@]}"; do
    addr="$(echo "$addr" | xargs)"
    [[ -z "$addr" ]] && continue
    known["$(to_int "$addr")"]=1
  done

  # Explicitly treat core bytes as mapped, including second bytes of tach words.
  known["$(to_int "$CPU_TEMP_ADDR")"]=1
  known["$(to_int "$GPU_TEMP_ADDR")"]=1
  known["$(to_int "$CPU_RPM_ADDR")"]=1
  known["$((CPU_RPM_ADDR + 1))"]=1
  known["$(to_int "$GPU_RPM_ADDR")"]=1
  known["$((GPU_RPM_ADDR + 1))"]=1
  known["$(to_int "$PROFILE_ADDR")"]=1
  known["$(to_int "$COOLER_BOOST_ADDR")"]=1

  echo "Watching UNKNOWN EC bytes every ${interval}s (start=${start}, count=${count}). Press Ctrl-C to stop."
  echo "Known/mapped addresses are excluded from output."

  line="$(read_block_values "$start" "$count" || true)"
  read -r -a previous <<<"$line"
  if ((${#previous[@]} != count)); then
    echo "Failed to capture initial EC block (${#previous[@]} bytes, expected ${count})." >&2
    exit 1
  fi
  echo "Baseline captured."

  while true; do
    line="$(read_block_values "$start" "$count" || true)"
    read -r -a current <<<"$line"
    if ((${#current[@]} != count)); then
      echo "$(ts_iso) read_error bytes=${#current[@]} expected=${count}"
      sleep "$interval"
      continue
    fi

    changed_count=0
    changes=""
    for ((i = 0; i < count; i++)); do
      addr=$((start + i))
      if [[ -n "${known[$addr]+x}" ]]; then
        continue
      fi
      if [[ "${previous[$i]}" != "${current[$i]}" ]]; then
        val="${current[$i]}"
        entry=" [${addr}]=${previous[$i]}->${val}"
        changes+="$entry"
        ((changed_count += 1))
      fi
    done

    if ((changed_count > 0)); then
      ts="$(ts_iso)"
      echo "${ts} unknown_changes=${changed_count}${changes}"
    fi

    previous=("${current[@]}")
    sleep "$interval"
  done
}

action_diff() {
  local label="${1:-action}"
  shift || true

  local before after
  before="$(snapshot "${label}_before")"
  echo "Captured before snapshot: $before"

  if [[ "$#" -gt 0 ]]; then
    if [[ "$1" == "--" ]]; then
      shift
    fi
    if [[ "$#" -eq 0 ]]; then
      echo "No command provided after --." >&2
      exit 1
    fi
    echo "Running action command: $*"
    "$@"
  else
    echo "Perform exactly one external action now, then press Enter."
    read -r _
  fi

  after="$(snapshot "${label}_after")"
  echo "Captured after snapshot: $after"
  diff_snapshots "$before" "$after"
}

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    snapshot)
      ensure_prereqs
      snapshot "${1:-snapshot}" "${2:-$EC_COUNT}"
      ;;
    action)
      ensure_prereqs
      local label="action"
      if [[ "$#" -gt 0 && "$1" != "--" ]]; then
        label="$1"
        shift
      fi
      action_diff "$label" "$@"
      ;;
    diff)
      require_cmd python3
      if [[ "$#" -lt 2 ]]; then
        echo "Usage: ./ec_observe.sh diff <before.txt> <after.txt>" >&2
        exit 1
      fi
      diff_snapshots "$1" "$2"
      ;;
    watch)
      ensure_prereqs
      watch_loop "${1:-0.5}" "${2:-$WATCH_ADDRS_DEFAULT}"
      ;;
    watch-unknown|watch_unknown|unknown)
      ensure_prereqs
      watch_unknown_loop "${1:-0.5}" "${2:-0}" "${3:-$EC_COUNT}" "${4:-$WATCH_ADDRS_DEFAULT}"
      ;;
    write)
      ensure_prereqs
      if [[ "$#" -lt 2 ]]; then
        echo "Usage: ./ec_observe.sh write <byte_addr> <value_0_to_255> [profile_name]" >&2
        exit 1
      fi
      write_byte "$1" "$2" "${3:-unknown}"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
