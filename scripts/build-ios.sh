#!/usr/bin/env bash
#
# 在 macOS + Xcode 上编译 / 归档 / 导出 IoTCenter。
# Linux 上无法执行本脚本（没有 Xcode 和 iOS SDK），请改用 scripts/build-on-mac.sh，
# 或参考 BUILD.md 用 CI 在 macOS runner 上构建。
#
# 示例：
#   scripts/build-ios.sh                       # 归档 + 导出 App Store 包
#   scripts/build-ios.sh --simulator           # 只验证能否为模拟器编译（不签名）
#   scripts/build-ios.sh --unsigned --no-export # 不签名归档，仅验证编译链路
#   scripts/build-ios.sh --method ad-hoc --upload
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/IoTCenter.xcodeproj"
SCHEME="IoTCenter"
OUTPUT_DIR="$REPO_ROOT/build"
MODE="archive"
EXPORT_METHOD="app-store-connect"
DO_EXPORT=1
DO_UPLOAD=0
UNSIGNED=0
VERSION=""
BUILD_NUMBER=""
TEAM="${DEVELOPMENT_TEAM:-E6PHPA54WZ}"
RUN_PREFLIGHT=1

usage() {
  cat <<'EOF'
用法：scripts/build-ios.sh [选项]

  --simulator            为 iOS 模拟器编译（Debug，无需签名），用于快速验证代码能否编译
  --unsigned             归档时不签名，只验证编译/打包链路
  --no-export            只 archive，不导出 ipa
  --method <method>      导出方式：app-store-connect(默认)|release-testing|ad-hoc|development|enterprise
  --upload               导出后上传到 App Store Connect（需要 ASC_KEY_ID / ASC_ISSUER_ID）
  --version <x.y.z>      覆盖 MARKETING_VERSION
  --build-number <n>     覆盖 CURRENT_PROJECT_VERSION（重复上传前必须递增）
  --team <TEAM_ID>       开发团队，默认 $DEVELOPMENT_TEAM 或工程里的 E6PHPA54WZ
  --output <dir>         产物目录，默认 build/
  --no-preflight         跳过 scripts/preflight.py 预检
  -h, --help             显示本帮助
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulator) MODE="simulator"; DO_EXPORT=0 ;;
    --unsigned) UNSIGNED=1 ;;
    --no-export) DO_EXPORT=0 ;;
    --upload) DO_UPLOAD=1 ;;
    --method) EXPORT_METHOD="${2:?--method 需要参数}"; shift ;;
    --version) VERSION="${2:?--version 需要参数}"; shift ;;
    --build-number) BUILD_NUMBER="${2:?--build-number 需要参数}"; shift ;;
    --team) TEAM="${2:?--team 需要参数}"; shift ;;
    --output) OUTPUT_DIR="${2:?--output 需要参数}"; shift ;;
    --no-preflight) RUN_PREFLIGHT=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "未知参数 $1" ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  cat >&2 <<'EOF'
本机不是 macOS，无法直接运行 xcodebuild。

可以：
  1) 用 scripts/build-on-mac.sh user@mac 在这台机器上触发远端 Mac 编译
  2) 在 Mac 上克隆/拷贝工程后执行本脚本
  3) 用 .github/workflows/ios-build.yml 在 GitHub 的 macOS runner 上编译
详见 BUILD.md。
EOF
  exit 3
fi

command -v xcodebuild >/dev/null || die "找不到 xcodebuild，请先安装 Xcode 并执行 sudo xcode-select -s /Applications/Xcode.app"

mkdir -p "$OUTPUT_DIR"
TS="$(date +%Y%m%d-%H%M%S)"

echo "== Xcode 环境 =="
xcodebuild -version
echo

if [[ "$RUN_PREFLIGHT" -eq 1 ]]; then
  echo "== 预检 =="
  python3 "$REPO_ROOT/scripts/preflight.py" || die "预检未通过，先修工程再打包"
  echo
fi

# macOS 自带 bash 3.2，空数组加 set -u 会报 unbound，用 ${arr[@]+...} 兼容
EXTRA_ARGS=()
if [[ -n "$VERSION" ]]; then EXTRA_ARGS+=("MARKETING_VERSION=$VERSION"); fi
if [[ -n "$BUILD_NUMBER" ]]; then EXTRA_ARGS+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER"); fi
EXTRA_EXPANDED=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})

DERIVED="$OUTPUT_DIR/DerivedData"

if [[ "$MODE" == "simulator" ]]; then
  LOG="$OUTPUT_DIR/simulator-$TS.log"
  echo "== 编译（iOS 模拟器，不签名）=="
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    ${EXTRA_EXPANDED[@]+"${EXTRA_EXPANDED[@]}"} 2>&1 | tee "$LOG"
  echo
  echo "编译成功。日志：$LOG"
  echo "产物：$DERIVED/Build/Products/Debug-iphonesimulator/IoTCenter.app"
  exit 0
fi

STEM="IoTCenter"
if [[ -n "$VERSION" ]]; then STEM+="-$VERSION"; fi
if [[ -n "$BUILD_NUMBER" ]]; then STEM+="-$BUILD_NUMBER"; fi
STEM+="-$TS"
ARCHIVE="$OUTPUT_DIR/$STEM.xcarchive"
LOG="$OUTPUT_DIR/archive-$TS.log"

# 签名方式：
#   默认自动签名（本机 Xcode 已登录开发者账号即可）
#   设置 PROFILE_NAME 后改为手动签名（CI 上导入了证书和描述文件时用）
SIGN_ARGS=()
SIGNING_STYLE="automatic"
BUNDLE_ID="${BUNDLE_ID:-$(grep -m1 'PRODUCT_BUNDLE_IDENTIFIER = ' "$PROJECT/project.pbxproj" | sed -E 's/.*= ([^;]+);.*/\1/' | tr -d ' ')}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Apple Distribution}"
if [[ "$UNSIGNED" -eq 1 ]]; then
  SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
elif [[ -n "${PROFILE_NAME:-}" ]]; then
  SIGNING_STYLE="manual"
  SIGN_ARGS=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
    PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME"
    DEVELOPMENT_TEAM="$TEAM"
  )
  echo "手动签名：identity=$SIGNING_IDENTITY profile=$PROFILE_NAME bundle=$BUNDLE_ID"
else
  SIGN_ARGS=(-allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM")
fi

echo "== 归档 =="
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED" \
  "${SIGN_ARGS[@]}" \
  ${EXTRA_EXPANDED[@]+"${EXTRA_EXPANDED[@]}"} 2>&1 | tee "$LOG"

echo "归档完成：$ARCHIVE"

if [[ "$DO_EXPORT" -eq 0 || "$UNSIGNED" -eq 1 ]]; then
  echo "已跳过导出（unsigned 或 --no-export）。"
  exit 0
fi

EXPORT_DIR="$OUTPUT_DIR/export-$EXPORT_METHOD-$TS"
OPTIONS_PLIST="$OUTPUT_DIR/ExportOptions-$EXPORT_METHOD-$TS.plist"

# 只有手动签名才需要 provisioningProfiles，自动签名时留空避免 exportArchive 找不到描述文件
PROFILE_BLOCK=""
if [[ -n "${PROFILE_NAME:-}" ]]; then
  PROFILE_BLOCK="	<key>provisioningProfiles</key>
	<dict>
		<key>$BUNDLE_ID</key>
		<string>$PROFILE_NAME</string>
	</dict>"
fi

cat > "$OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>export</string>
	<key>method</key>
	<string>$EXPORT_METHOD</string>
	<key>signingStyle</key>
	<string>$SIGNING_STYLE</string>
	<key>teamID</key>
	<string>$TEAM</string>
$PROFILE_BLOCK
	<key>stripSwiftSymbols</key>
	<true/>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
EOF

echo
echo "== 导出 ipa（$EXPORT_METHOD）=="
EXPORT_ARGS=(-exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" -exportOptionsPlist "$OPTIONS_PLIST")
if [[ "$SIGNING_STYLE" == "automatic" ]]; then EXPORT_ARGS+=(-allowProvisioningUpdates); fi
xcodebuild "${EXPORT_ARGS[@]}"

IPA="$(find "$EXPORT_DIR" -type f -name '*.ipa' | head -1)"
echo "ipa：${IPA:-未生成}"

if [[ "$DO_UPLOAD" -eq 1 ]]; then
  [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]] || die "上传需要环境变量 ASC_KEY_ID 和 ASC_ISSUER_ID"
  [[ -f "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8" ]] || \
    echo "提示：把 App Store Connect API Key 放到 ~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8" >&2
  echo
  echo "== 上传 App Store Connect =="
  xcrun altool --upload-app \
    --file "$IPA" \
    --type ios \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID"
fi

echo
echo "完成。"
echo "  xcarchive: $ARCHIVE"
echo "  ipa:       ${IPA:-无}"
