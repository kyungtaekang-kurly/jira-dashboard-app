#!/bin/bash
set -e

APP_NAME="Kurly Jira"
REPO="kyungtaekang-kurly/jira-dashboard-app"

# 아키텍처 감지
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  DMG_SUFFIX="aarch64"
else
  DMG_SUFFIX="x64"
fi

# 최신 릴리스에서 DMG URL 찾기
echo "최신 버전 확인 중..."
DMG_URL=$(curl -sL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep "browser_download_url.*${DMG_SUFFIX}.dmg" \
  | head -1 \
  | cut -d '"' -f 4)

if [ -z "$DMG_URL" ]; then
  echo "다운로드 URL을 찾을 수 없습니다."
  exit 1
fi

DMG_FILE="/tmp/${APP_NAME}_latest.dmg"

# 다운로드
echo "다운로드 중: ${DMG_URL}"
curl -L -o "$DMG_FILE" "$DMG_URL"

# 기존 앱 제거
if [ -d "/Applications/${APP_NAME}.app" ]; then
  echo "기존 버전 제거 중..."
  rm -rf "/Applications/${APP_NAME}.app"
fi

# DMG 마운트
echo "설치 중..."
hdiutil attach "$DMG_FILE" -nobrowse < /dev/null 2>/dev/null
MOUNT_DIR=$(ls -d /Volumes/Kurly\ Jira* 2>/dev/null | head -1)

if [ -z "$MOUNT_DIR" ]; then
  echo "DMG 마운트에 실패했습니다."
  exit 1
fi

# 앱 복사
cp -R "${MOUNT_DIR}/${APP_NAME}.app" /Applications/

# DMG 언마운트
hdiutil detach "${MOUNT_DIR}" -quiet 2>/dev/null

# Gatekeeper 우회
xattr -cr "/Applications/${APP_NAME}.app"

# 임시 파일 정리
rm -f "$DMG_FILE"

echo ""
echo "✅ ${APP_NAME} 설치 완료!"
echo "Applications 폴더에서 실행하세요."
