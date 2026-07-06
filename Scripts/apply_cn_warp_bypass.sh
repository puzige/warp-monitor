#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY=0
SKIP_IPS=0
SKIP_HOSTS=0

usage() {
  cat <<EOF
Usage: $0 [--apply] [--skip-ips] [--skip-hosts]

One-shot helper for mainland China WARP Split Tunnel bypass rules.

It applies the two recommended rule sets used by WARP Monitor:
  1. Compact CN CIDR rules from mayaxcn/china-ip-list
  2. CN domain host rules from pluwen/china-domain-allowlist

DNS mode is intentionally left unchanged. This script only changes WARP Split
Tunnel IP and Host exclusions.

Default mode is a dry run. Use --apply to update WARP.

Examples:
  $0
  $0 --apply
  $0 --apply --skip-hosts
  $0 --apply --skip-ips
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --skip-ips) SKIP_IPS=1 ;;
    --skip-hosts) SKIP_HOSTS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$SKIP_IPS" -eq 1 ] && [ "$SKIP_HOSTS" -eq 1 ]; then
  echo "Nothing to do: both --skip-ips and --skip-hosts were provided." >&2
  exit 2
fi

command -v warp-cli >/dev/null || { echo "warp-cli is required" >&2; exit 1; }

run_helper() {
  local label="$1"
  local script="$2"
  shift 2

  echo
  echo "==> $label"
  "$script" "$@"
}

if [ "$APPLY" -eq 0 ]; then
  echo "Dry run mode. Re-run with --apply to update WARP."
fi

if [ "$SKIP_IPS" -eq 0 ]; then
  if [ "$APPLY" -eq 1 ]; then
    run_helper "Compact CN IP ranges" "$SCRIPT_DIR/apply_cn_split_tunnel.sh" --apply
  else
    run_helper "Compact CN IP ranges" "$SCRIPT_DIR/apply_cn_split_tunnel.sh"
  fi
fi

if [ "$SKIP_HOSTS" -eq 0 ]; then
  if [ "$APPLY" -eq 1 ]; then
    run_helper "CN domain host rules" "$SCRIPT_DIR/apply_pluwen_cn_hosts.sh" --apply
  else
    run_helper "CN domain host rules" "$SCRIPT_DIR/apply_pluwen_cn_hosts.sh"
  fi
fi

echo
if [ "$APPLY" -eq 1 ]; then
  echo "Done. WARP Split Tunnel bypass rules have been updated."
else
  echo "Done. No changes were made."
fi
