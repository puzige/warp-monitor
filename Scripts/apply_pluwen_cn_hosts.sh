#!/usr/bin/env bash
set -euo pipefail

SOURCE_URL="${SOURCE_URL:-https://raw.githubusercontent.com/pluwen/china-domain-allowlist/master/allow-list.sorl}"
STATE_DIR="${STATE_DIR:-$HOME/.warp-monitor/pluwen-cn-hosts}"
RETRIES="${RETRIES:-5}"
SLEEP_SECONDS="${SLEEP_SECONDS:-2}"
APPLY=0

usage() {
  cat <<EOF
Usage: $0 [--apply]

Downloads pluwen/china-domain-allowlist and maintains its domains in
Cloudflare WARP Split Tunnel hosts. The default mode is a dry run.

Conversion:
  *.example.com -> example.com and *.example.com
  example.com   -> example.com
  IP wildcard rules are skipped.

Environment:
  SOURCE_URL      default: ${SOURCE_URL}
  STATE_DIR       default: ${STATE_DIR}
  RETRIES         default: ${RETRIES}
  SLEEP_SECONDS   default: ${SLEEP_SECONDS}
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
source_file="$STATE_DIR/allow-list-$stamp.sorl"
desired_file="$STATE_DIR/pluwen-hosts-$stamp.txt"
current_file="$STATE_DIR/warp-host-list-before-$stamp.txt"
managed_file="$STATE_DIR/managed-hosts.txt"
previous_managed_file="$STATE_DIR/managed-hosts-before-$stamp.txt"
missing_file="$STATE_DIR/missing-$stamp.txt"
stale_file="$STATE_DIR/stale-$stamp.txt"
log_file="$STATE_DIR/apply-$stamp.log"
failed_file="$STATE_DIR/failed-$stamp.txt"

echo "Downloading pluwen allow list..."
curl -fsSL "$SOURCE_URL" -o "$source_file"

python3 - "$source_file" "$desired_file" <<'PY'
import re
import sys
from pathlib import Path

source_file, desired_file = map(Path, sys.argv[1:])
hosts = set()

domain_re = re.compile(r"^(?:\*\.)?(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$", re.I)
ip_wildcard_re = re.compile(r"^\d{1,3}(?:\.\*|\.\d{1,3}){3}$")

for raw in source_file.read_text(encoding="utf-8", errors="ignore").splitlines():
    line = raw.strip().lower()
    if not line or line.startswith(";") or line.startswith("["):
        continue
    if line.startswith("@@") or line.startswith("/") or "://" in line:
        continue
    if ip_wildcard_re.match(line):
        continue

    # SwitchyOmega/AutoProxy domain shorthand.
    if line.startswith("||"):
        line = line[2:]
    if line.startswith("|"):
        line = line[1:]
    line = line.rstrip("^")

    if not domain_re.match(line):
        continue

    if line.startswith("*."):
        suffix = line[2:]
        # Keep wildcard-only TLD rules such as *.cn as-is.
        if "." in suffix:
            hosts.add(suffix)
        hosts.add(line)
    else:
        hosts.add(line)

Path(desired_file).write_text("\n".join(sorted(hosts)) + "\n")
print(f"desired={len(hosts)}")
PY

warp-cli tunnel host list > "$current_file"
if [ -f "$managed_file" ]; then
  cp "$managed_file" "$previous_managed_file"
else
  : > "$previous_managed_file"
fi

python3 - "$desired_file" "$current_file" "$previous_managed_file" "$missing_file" "$stale_file" <<'PY'
import sys
from pathlib import Path

desired_file, current_file, previous_file, missing_file, stale_file = map(Path, sys.argv[1:])
desired = {line.strip().lower() for line in desired_file.read_text().splitlines() if line.strip()}
previous = {line.strip().lower() for line in previous_file.read_text().splitlines() if line.strip()}
current = set()

for line in current_file.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("Excluded"):
        continue
    current.add(line.split()[0].lower())

missing = sorted(desired - current)
stale = sorted(previous - desired)
missing_file.write_text("\n".join(missing) + ("\n" if missing else ""))
stale_file.write_text("\n".join(stale) + ("\n" if stale else ""))

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

add_host() {
  local host="$1"
  local attempt=1
  while [ "$attempt" -le "$RETRIES" ]; do
    if warp-cli tunnel host add "$host" >>"$log_file" 2>&1; then
      return 0
    fi
    echo "retry add $attempt/$RETRIES: $host" >>"$log_file"
    sleep "$SLEEP_SECONDS"
    attempt=$((attempt + 1))
  done
  return 1
}

remove_host() {
  local host="$1"
  local attempt=1
  while [ "$attempt" -le "$RETRIES" ]; do
    if warp-cli tunnel host remove "$host" >>"$log_file" 2>&1; then
      return 0
    fi
    echo "retry remove $attempt/$RETRIES: $host" >>"$log_file"
    sleep "$SLEEP_SECONDS"
    attempt=$((attempt + 1))
  done
  return 1
}

added=0
removed=0
failed=0

while IFS= read -r host; do
  [ -z "$host" ] && continue
  if add_host "$host"; then
    added=$((added + 1))
  else
    failed=$((failed + 1))
    printf 'add %s\n' "$host" >>"$failed_file"
  fi
done < "$missing_file"

while IFS= read -r host; do
  [ -z "$host" ] && continue
  if remove_host "$host"; then
    removed=$((removed + 1))
  else
    failed=$((failed + 1))
    printf 'remove %s\n' "$host" >>"$failed_file"
  fi
done < "$stale_file"

if [ "$failed" -eq 0 ]; then
  cp "$desired_file" "$managed_file"
fi

echo
echo "Applied pluwen CN hosts:"
echo "  added:   $added"
echo "  removed: $removed"
echo "  failed:  $failed"
echo "  log:     $log_file"
if [ "$failed" -ne 0 ]; then
  echo "  failed:  $failed_file"
  exit 1
fi
