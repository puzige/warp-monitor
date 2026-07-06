#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${STATE_DIR:-$HOME/.warp-monitor/cn-split-tunnel}"
RETRIES="${RETRIES:-5}"
SLEEP_SECONDS="${SLEEP_SECONDS:-2}"
APPLY=0

usage() {
  cat <<EOF
Usage: $0 [--apply]

Adds a common mainland China service host overlay to Cloudflare WARP Split
Tunnel. This complements the compact CN CIDR helper with domain rules for
services whose CDN IPs often live in smaller ranges.

Default mode is a dry run. Use --apply to update WARP.

Environment:
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

command -v warp-cli >/dev/null || { echo "warp-cli is required" >&2; exit 1; }

mkdir -p "$STATE_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"
desired_file="$STATE_DIR/common-service-hosts-$stamp.txt"
current_file="$STATE_DIR/warp-host-list-before-overlay-$stamp.txt"
missing_file="$STATE_DIR/common-service-hosts-missing-$stamp.txt"
log_file="$STATE_DIR/common-service-hosts-apply-$stamp.log"
failed_file="$STATE_DIR/common-service-hosts-failed-$stamp.txt"
managed_file="$STATE_DIR/managed-service-hosts.txt"

cat > "$desired_file" <<'EOF'
bilibili.com
*.bilibili.com
bilivideo.com
*.bilivideo.com
hdslb.com
*.hdslb.com
acgvideo.com
*.acgvideo.com
qq.com
*.qq.com
tencent.com
*.tencent.com
wechat.com
*.wechat.com
weixin.qq.com
mp.weixin.qq.com
gtimg.com
*.gtimg.com
qpic.cn
*.qpic.cn
myqcloud.com
*.myqcloud.com
qcloud.com
*.qcloud.com
douyin.com
*.douyin.com
snssdk.com
*.snssdk.com
byteimg.com
*.byteimg.com
bytedance.com
*.bytedance.com
bytednsdoc.com
*.bytednsdoc.com
bytegoofy.com
*.bytegoofy.com
douyincdn.com
*.douyincdn.com
zijieapi.com
*.zijieapi.com
toutiao.com
*.toutiao.com
ixigua.com
*.ixigua.com
taobao.com
*.taobao.com
tmall.com
*.tmall.com
aliyun.com
*.aliyun.com
alipay.com
*.alipay.com
alicdn.com
*.alicdn.com
tbcdn.cn
*.tbcdn.cn
mmstat.com
*.mmstat.com
jd.com
*.jd.com
360buyimg.com
*.360buyimg.com
jingxi.com
*.jingxi.com
baidu.com
*.baidu.com
bdstatic.com
*.bdstatic.com
bdimg.com
*.bdimg.com
163.com
*.163.com
126.net
*.126.net
netease.com
*.netease.com
music.163.com
moutai.163.com
xiaohongshu.com
*.xiaohongshu.com
xhscdn.com
*.xhscdn.com
meituan.com
*.meituan.com
dianping.com
*.dianping.com
kuaishou.com
*.kuaishou.com
ksapisrv.com
*.ksapisrv.com
gifshow.com
*.gifshow.com
EOF

warp-cli tunnel host list > "$current_file"

python3 - "$desired_file" "$current_file" "$missing_file" <<'PY'
import sys
from pathlib import Path

desired_file, current_file, missing_file = map(Path, sys.argv[1:])
desired = {line.strip().lower() for line in desired_file.read_text().splitlines() if line.strip()}
current = set()
for line in current_file.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("Excluded"):
        continue
    current.add(line.split()[0].lower())

missing = sorted(desired - current)
missing_file.write_text("\n".join(missing) + ("\n" if missing else ""))
print(f"desired={len(desired)}")
print(f"current={len(current)}")
print(f"to_add={len(missing)}")
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
    echo "retry $attempt/$RETRIES: $host" >>"$log_file"
    sleep "$SLEEP_SECONDS"
    attempt=$((attempt + 1))
  done
  return 1
}

ok=0
bad=0
while IFS= read -r host; do
  [ -z "$host" ] && continue
  if add_host "$host"; then
    ok=$((ok + 1))
  else
    bad=$((bad + 1))
    printf '%s\n' "$host" >>"$failed_file"
  fi
done < "$missing_file"

if [ "$bad" -eq 0 ]; then
  cp "$desired_file" "$managed_file"
fi

echo
echo "Applied host overlay:"
echo "  added:  $ok"
echo "  failed: $bad"
echo "  log:    $log_file"
if [ "$bad" -ne 0 ]; then
  echo "  failed: $failed_file"
  exit 1
fi
