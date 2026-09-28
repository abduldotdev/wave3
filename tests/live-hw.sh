#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAVE3_HW="${WAVE3_HW:-"$SCRIPT_DIR/../bin/wave3-hw"}"

if [[ ! -x "$WAVE3_HW" ]]; then
  echo "live-hw: executable not found: $WAVE3_HW" >&2
  exit 1
fi

status_out=$("$WAVE3_HW" status 2>/dev/null) || {
  echo "live-hw: failed to execute $WAVE3_HW status" >&2
  exit 1
}

declare -A status_map
while IFS='=' read -r k v; do
  [[ -z "$k" ]] && continue
  status_map["$k"]="$v"
done <<< "$status_out"

if [[ "${status_map[present]:-}" != "yes" ]]; then
  echo "live-hw: device not present" >&2
  exit 3
fi
if [[ "${status_map[access]:-}" != "ok" ]]; then
  echo "live-hw: device access not ok (${status_map[access]:-})" >&2
  exit 4
fi
if [[ "${status_map[supported]:-}" != "yes" ]]; then
  echo "live-hw: device api not supported (${status_map[api]:-})" >&2
  exit 5
fi

FIELDS=("clipguard" "lowcut" "gain_lock" "direct_monitor" "gain_db")

declare -A ORIG
declare -A CHANGED
declare -A RESTORED
declare -a CHANGED_STACK=()

rollback() {
  local failed_field="${1:-}"
  echo "live-hw: mismatch or error on '$failed_field', restoring modified fields..." >&2
  for (( i=${#CHANGED_STACK[@]}-1; i>=0; i-- )); do
    local f="${CHANGED_STACK[i]}"
    local orig_val="${ORIG[$f]}"
    "$WAVE3_HW" set "$f" "$orig_val" >/dev/null 2>&1 || true
  done
  exit 1
}

compute_gain_changed() {
  local orig="$1"
  python3 -c "
orig = float('$orig')
if orig + 0.5 <= 40.0:
    print('%.1f' % (orig + 0.5))
else:
    print('%.1f' % (orig - 0.5))
"
}

for field in "${FIELDS[@]}"; do
  orig="${status_map[$field]}"
  ORIG["$field"]="$orig"

  # Step 1: no-op write of current value
  if ! "$WAVE3_HW" set "$field" "$orig" >/dev/null 2>&1; then
    rollback "$field"
  fi

  # Step 2: change value
  case "$field" in
    clipguard|lowcut|gain_lock)
      if [[ "$orig" == "1" ]]; then
        changed="0"
      else
        changed="1"
      fi
      ;;
    direct_monitor)
      orig_int="$((orig))"
      if (( orig_int + 5 <= 100 )); then
        changed="$((orig_int + 5))"
      else
        changed="$((orig_int - 5))"
      fi
      ;;
    gain_db)
      changed=$(compute_gain_changed "$orig")
      ;;
  esac
  CHANGED["$field"]="$changed"

  # Apply change
  if ! "$WAVE3_HW" set "$field" "$changed" >/dev/null 2>&1; then
    rollback "$field"
  fi
  CHANGED_STACK+=("$field")

  # Read back changed value
  readback_status=$("$WAVE3_HW" status 2>/dev/null) || rollback "$field"
  readback_val=$(echo "$readback_status" | grep "^${field}=" | head -n1 | cut -d'=' -f2-)
  if [[ "$readback_val" != "$changed" ]]; then
    rollback "$field"
  fi

  # Step 3: restore original value
  if ! "$WAVE3_HW" set "$field" "$orig" >/dev/null 2>&1; then
    rollback "$field"
  fi
  unset 'CHANGED_STACK[${#CHANGED_STACK[@]}-1]'

  # Read back restored value
  readback_status=$("$WAVE3_HW" status 2>/dev/null) || rollback "$field"
  restored_val=$(echo "$readback_status" | grep "^${field}=" | head -n1 | cut -d'=' -f2-)
  if [[ "$restored_val" != "$orig" ]]; then
    rollback "$field"
  fi
  RESTORED["$field"]="$restored_val"
done

printf "%-15s | %-10s | %-10s | %-10s | %s\n" "field" "original" "changed" "restored" "result"
printf "%s\n" "----------------+------------+------------+------------+-------"
for field in "${FIELDS[@]}"; do
  printf "%-15s | %-10s | %-10s | %-10s | %s\n" "$field" "${ORIG[$field]}" "${CHANGED[$field]}" "${RESTORED[$field]}" "OK"
done

exit 0
