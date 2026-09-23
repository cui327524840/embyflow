#!/usr/bin/env bash
#
# 构建一个未签名的 IPA，用来丢给巨魔（TrollStore）安装。
# 用法： bash build-ipa.sh      （若提示 permission denied，先 chmod +x build-ipa.sh）
# 需要： macOS + Xcode（已同意许可）+ XcodeGen
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="EmbyFlow"
SCHEME="EmbyFlow"
PROJECT="${APP_NAME}.xcodeproj"
BUILD_DIR="build"
OUTPUT_IPA="${APP_NAME}.ipa"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "✗ 找不到 xcodebuild：请先安装 Xcode，并执行 sudo xcodebuild -license accept"
  exit 1
fi

if [ ! -d "$PROJECT" ]; then
  if command -v xcodegen >/dev/null 2>&1; then
    echo "▸ 生成 Xcode 工程…"
    xcodegen generate
  else
    echo "✗ 找不到 $PROJECT，也没有 xcodegen：请先 brew install xcodegen"
    exit 1
  fi
fi

echo "▸ 编译 Release（关闭签名）…"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  build

APP_PATH="$BUILD_DIR/Build/Products/Release-iphoneos/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
  echo "✗ 没有找到编译产物：$APP_PATH"
  exit 1
fi

echo "▸ 打包 IPA…"
rm -rf Payload "$OUTPUT_IPA"
mkdir -p Payload
cp -R "$APP_PATH" Payload/
zip -qry "$OUTPUT_IPA" Payload
rm -rf Payload

echo ""
echo "✓ 完成：$(pwd)/${OUTPUT_IPA}"
echo "  把 ipa 传到 iPhone（隔空投送或「文件」App），用巨魔打开安装即可。"
