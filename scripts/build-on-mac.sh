#!/usr/bin/env bash
#
# 在这台 Linux 机器上触发远端 Mac 编译：rsync 同步工程 → ssh 执行 build-ios.sh → 取回产物。
# 需要：到 Mac 的 SSH 免密登录、Mac 上已装 Xcode 且 xcode-select 指向它。
#
# 示例：
#   scripts/build-on-mac.sh shuaijq@192.168.1.20 --simulator
#   scripts/build-on-mac.sh shuaijq@192.168.1.20 --method app-store-connect --version 1.3.2 --build-number 8
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="~/iotcenter-ios-build"
LOCAL_ARTIFACT_DIR="$REPO_ROOT/build/remote"

usage() {
  cat <<'EOF'
用法：scripts/build-on-mac.sh <user@host> [build-ios.sh 的参数...]

  user@host   远端 Mac（需已配置 SSH 免密登录）
  其余参数    原样透传给 Mac 上的 scripts/build-ios.sh，例如：
                --simulator                    只验证模拟器编译
                --unsigned --no-export         不签名归档
                --method app-store-connect     导出 App Store 包
                --version 1.3.2 --build-number 8

环境变量：
  REMOTE_DIR          远端工程目录，默认 ~/iotcenter-ios-build
  SSH_OPTS            ssh 额外参数，例如 "-p 2222"
  SKIP_SYNC=1         跳过同步，直接用远端已有代码
EOF
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
HOST="$1"
shift

REMOTE_DIR="${REMOTE_DIR:-~/iotcenter-ios-build}"
SSH_OPTS="${SSH_OPTS:-}"

echo "目标：$HOST:$REMOTE_DIR"
if ! ssh $SSH_OPTS -o ConnectTimeout=10 -o BatchMode=yes "$HOST" true; then
  echo "错误：无法通过 SSH 连接 $HOST（检查密钥/网络，或先用 ssh-copy-id 配置）" >&2
  exit 1
fi

if [[ "${SKIP_SYNC:-0}" != "1" ]]; then
  echo "== 同步工程到远端 =="
  # 只同步源码与脚本，排除本地产物和 App Store 素材，避免每次传几十 MB
  rsync -az --delete \
    --exclude 'build/' \
    --exclude '.git/' \
    --exclude '.smoke/' \
    --exclude 'www.backup-*' \
    --exclude 'DerivedData/' \
    --exclude '.DS_Store' \
    --exclude 'appstore_screenshots/' \
    --exclude 'original_screenshots/' \
    --exclude '*.jpg' \
    "$REPO_ROOT/" "$HOST:$REMOTE_DIR/"
fi

echo "== 远端编译 =="
ssh $SSH_OPTS "$HOST" "cd $REMOTE_DIR && bash scripts/build-ios.sh $*"

echo "== 取回产物 =="
mkdir -p "$LOCAL_ARTIFACT_DIR"
rsync -az --exclude 'DerivedData/' "$HOST:$REMOTE_DIR/build/" "$LOCAL_ARTIFACT_DIR/"

echo "产物已同步到：$LOCAL_ARTIFACT_DIR"
find "$LOCAL_ARTIFACT_DIR" -maxdepth 2 \( -name '*.ipa' -o -name '*.xcarchive' \) -print
