#!/usr/bin/env bash
set -euo pipefail

SOURCE_BASE="${SOURCE_BASE:-https://raw.githubusercontent.com/mayaxcn/china-ip-list/master}"
V4_MAX_PREFIX="${V4_MAX_PREFIX:-16}"
V6_MAX_PREFIX="${V6_MAX_PREFIX:-24}"
STATE_DIR="${STATE_DIR:-$HOME/.warp-monitor/cn-split-tunnel}"
APPLY=0

usage() {
  cat <<EOF
Usage: $0 [--apply]

Downloads mayaxcn/china-ip-list and maintains a compact China CIDR set in
Cloudflare WARP Split Tunnel:

  IPv4: CN ranges with prefix <= /${V4_MAX_PREFIX}
  IPv6: CN ranges with prefix <= /${V6_MAX_PREFIX}

Default mode is a dry run. Use --apply to add/remove the managed ranges.

Environment:
  V4_MAX_PREFIX   default: 16
  V6_MAX_PREFIX   default: 24
  SOURCE_BASE     default: ${SOURCE_BASE}
  STATE_DIR       default: ${STATE_DIR}
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v warp-cli >/dev/null || { echo "warp-cli is required" >&2; exit 1; }

mkdir -p "$STATE_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"
v4_file="$STATE_DIR/chnroute-$stamp.txt"
v6_file="$STATE_DIR/chnroute-v6-$stamp.txt"
desired_file="$STATE_DIR/cn-common-cidr-$stamp.txt"
current_file="$STATE_DIR/warp-ip-list-before-$stamp.txt"
managed_file="$STATE_DIR/managed-cidrs.txt"
previous_managed_file="$STATE_DIR/managed-cidrs-before-$stamp.txt"
missing_file="$STATE_DIR/missing-$stamp.txt"
stale_file="$STATE_DIR/stale-$stamp.txt"
log_file="$STATE_DIR/apply-$stamp.log"
failed_file="$STATE_DIR/failed-$stamp.txt"

echo "Downloading CN CIDR lists..."
curl -fsSL "$SOURCE_BASE/chnroute.txt" -o "$v4_file"
curl -fsSL "$SOURCE_BASE/chnroute_v6.txt" -o "$v6_file"

python3 - "$v4_file" "$v6_file" "$desired_file" "$V4_MAX_PREFIX" "$V6_MAX_PREFIX" <<'PY'
import ipaddress
import sys
from pathlib import Path

v4_file, v6_file, out_file, v4_max, v6_max = sys.argv[1:]
v4_max = int(v4_max)
v6_max = int(v6_max)
items = []

for raw in Path(v4_file).read_text().splitlines():
    raw = raw.strip()
    if not raw:
        continue
    net = ipaddress.ip_network(raw, strict=False)
    if net.version == 4 and net.prefixlen <= v4_max:
        items.append(str(net))

for raw in Path(v6_file).read_text().splitlines():
    raw = raw.strip()
    if not raw:
        continue
    net = ipaddress.ip_network(raw, strict=False)
    if net.version == 6 and net.prefixlen <= v6_max:
        items.append(str(net))

Path(out_file).write_text("\n".join(sorted(set(items))) + "\n")
print(len(set(items)))
PY

warp-cli tunnel ip list > "$current_file"
if [ -f "$managed_file" ]; then
  cp "$managed_file" "$previous_managed_file"
else
  : > "$previous_managed_file"
fi

python3 - "$desired_file" "$current_file" "$previous_managed_file" "$missing_file" "$stale_file" <<'PY'
import sys
from pathlib import Path

desired_file, current_file, previous_file, missing_file, stale_file = map(Path, sys.argv[1:])
desired = {line.strip() for line in desired_file.read_text().splitlines() if line.strip()}
previous = {line.strip() for line in previous_file.read_text().splitlines() if line.strip()}
current = set()
for line in current_file.read_text().splitlines():
    line = line.strip()
    if "/" in line and not line.startswith("Excluded"):
        current.add(line.split()[0])

missing = sorted(desired - current)
stale = sorted(previous - desired)
missing_file.write_text("\n".join(missing) + ("\n" if missing else ""))
stale_file.write_text("\n".join(stale) + ("\n" if stale else ""))

print(f"desired={len(desired)}")
print(f"current={len(current)}")
print(f"previous_managed={len(previous)}")
print(f"to_add={len(missing)}")
print(f"to_remove={len(stale)}")
PY

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "Dry run only. Re-run with --apply to update WARP."
  echo "Desired list: $desired_file"
  echo "Current backup: $current_file"
  exit 0
fi

add_count=0
remove_count=0
failed_count=0

while IFS= read -r cidr; do
  [ -z "$cidr" ] && continue
  if warp-cli tunnel ip add-range "$cidr" >>"$log_file" 2>&1; then
    add_count=$((add_count + 1))
  else
    failed_count=$((failed_count + 1))
    printf 'add %s\n' "$cidr" >>"$failed_file"
  fi
done < "$missing_file"

while IFS= read -r cidr; do
  [ -z "$cidr" ] && continue
  if warp-cli tunnel ip remove-range "$cidr" >>"$log_file" 2>&1; then
    remove_count=$((remove_count + 1))
  else
    failed_count=$((failed_count + 1))
    printf 'remove %s\n' "$cidr" >>"$failed_file"
  fi
done < "$stale_file"

if [ "$failed_count" -eq 0 ]; then
  cp "$desired_file" "$managed_file"
fi

echo
echo "Applied:"
echo "  added:   $add_count"
echo "  removed: $remove_count"
echo "  failed:  $failed_count"
echo "  log:     $log_file"
if [ "$failed_count" -ne 0 ]; then
  echo "  failed:  $failed_file"
  exit 1
fi
