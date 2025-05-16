#!/bin/bash
# install_cursor.sh — 在 Ubuntu 18.04（或相容版本）上安裝並重建 Cursor AI IDE（支援 C++20）

set -e

# 依賴清單（新增 jq、software-properties-common 以解析 JSON 及管理 PPA）
deps=(
  libfuse2 libnotify4 libnss3 libxss1 libasound2
  libatk1.0-0 libatk-bridge2.0-0 libcups2 libx11-xcb1
  libxcomposite1 libxdamage1 libxrandr2 libgbm1
  libpango-1.0-0 libgtk-3-0 libgconf-2-4 libsecret-1-0
  libcanberra-gtk-module libcanberra-gtk3-module curl jq
  libsqlite3-dev software-properties-common
)

echo "步驟 1：檢查並安裝系統依賴"
missing=()
for pkg in "${deps[@]}"; do
  if ! dpkg -s "$pkg" &> /dev/null; then
    missing+=("$pkg")
  fi
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "尚未安裝的套件： ${missing[*]}"
  sudo apt-get update
  sudo apt-get install -y "${missing[@]}"
else
  echo "所有依賴已滿足，跳過安裝。"
fi

# 安裝並設定新版 GCC/G++ 以支援 C++20
echo "步驟 2：安裝並設定 gcc-10 / g++-10"
sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
sudo apt-get update
sudo apt-get install -y gcc-10 g++-10
export CC=gcc-10
export CXX=g++-10

# 安裝 appimagetool
if ! command -v appimagetool &> /dev/null; then
  echo "尚未偵測到 appimagetool，開始安裝"
  wget -qO appimagetool-x86_64.AppImage \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x appimagetool-x86_64.AppImage
  sudo mv appimagetool-x86_64.AppImage /usr/local/bin/appimagetool
  echo "appimagetool 安裝完成"
else
  echo "已安裝 appimagetool，跳過此步驟。"
fi

# 從 API 取得真正的 AppImage 下載 URL，並檢查版本
API_URL="https://www.cursor.com/api/download?platform=linux-x64&releaseTrack=stable"
echo "步驟 3：從 API ($API_URL) 取得下載資訊"
response=$(curl -sL "$API_URL")
download_url=$(echo "$response" | jq -r '.downloadUrl')
version=$(echo "$response" | jq -r '.version')

if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
  echo "無法從 API 取得 downloadUrl，請檢查網路或 API 狀態。"
  exit 1
fi

echo "取得版本： $version"
echo "下載網址： $download_url"

# 檢查是否已安裝相同版本
APPIMAGE_NAME="cursor.AppImage"
if [ -f "/opt/$APPIMAGE_NAME" ]; then
  INSTALLED_VERSION=$(/opt/$APPIMAGE_NAME --version 2>/dev/null || echo "")
  if [ "$INSTALLED_VERSION" = "$version" ]; then
    echo "已安裝相同版本 $version，跳過安裝。"
    exit 0
  fi
fi

# 下載 AppImage 到暫存
WORKDIR="/tmp/cursor-install"
TEMP_APPIMAGE="$WORKDIR/$APPIMAGE_NAME"
echo "步驟 4：下載 AppImage 至：$TEMP_APPIMAGE"
sudo rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
curl -L "$download_url" -o "$TEMP_APPIMAGE"
chmod +x "$TEMP_APPIMAGE"

# 移除舊版（可選）
if [ -f "/opt/$APPIMAGE_NAME" ]; then
  echo "移除舊版 AppImage：/opt/$APPIMAGE_NAME"
  sudo rm -f "/opt/$APPIMAGE_NAME"
fi
if [ -f "/usr/share/applications/cursor.desktop" ]; then
  echo "移除舊版桌面啟動器"
  sudo rm /usr/share/applications/cursor.desktop
  rm "$HOME/.local/share/applications/cursor.desktop" 2>/dev/null || true
fi
if grep -q "^alias cursor=" "$HOME/.bashrc"; then
  echo "移除舊版 alias cursor="
  sed -i '/^alias cursor=/d' "$HOME/.bashrc"
fi

# 解包 AppImage（先試 --appimage-extract，失敗則用 unsquashfs）
echo "步驟 5：解包 AppImage"
cd "$WORKDIR"
if "$TEMP_APPIMAGE" --appimage-extract 2>/dev/null; then
  EXTRACT_ROOT="$WORKDIR/squashfs-root"
else
  EXTRACT_DIR="$WORKDIR/extract"
  mkdir -p "$EXTRACT_DIR"
  echo "— 使用 unsquashfs 後備解包 → $EXTRACT_DIR"
  unsquashfs -d "$EXTRACT_DIR" "$TEMP_APPIMAGE"
  EXTRACT_ROOT="$EXTRACT_DIR"
fi

# 動態尋找 resources/app 目錄並在 package.json 中修正設定
echo "步驟 6：尋找 resources/app 目錄"
APP_RESOURCES=$(find "$EXTRACT_ROOT" -type d -path "*/resources/app" | head -n1)
if [ -z "$APP_RESOURCES" ]; then
  echo "找不到 resources/app 目錄，請手動檢查 $EXTRACT_ROOT"
  exit 1
fi
echo "進入 App 目錄 → $APP_RESOURCES"
cd "$APP_RESOURCES"

# 設定環境變數以跳過 Playwright 自動下載瀏覽器
echo "  6.1 設定環境變數：PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1"
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

# 刪除 devDependencies.typescript，並設定 overrides.typescript
TS_VERSION="4.9.5"
echo "  6.2 調整 package.json：刪除 devDependencies.typescript、覆蓋 overrides.typescript = $TS_VERSION"
jq \
  'del(.devDependencies.typescript) |
   .overrides.typescript = "'"$TS_VERSION"'"' \
  package.json > package.json.tmp && mv package.json.tmp package.json

# 安裝並從原始碼編譯 sqlite3（強制使用新版編譯器）
echo "  6.3 安裝並從原始碼編譯 sqlite3"
npm install @vscode/sqlite3 --build-from-source --legacy-peer-deps

# 安裝 electron-rebuild 並重建 sqlite3
echo "  6.4 安裝 electron-rebuild 並重建 sqlite3"
npm install --no-save-dev electron-rebuild --legacy-peer-deps
npx electron-rebuild -f -w @vscode/sqlite3

# 重包成新的 AppImage
echo "步驟 7：使用 appimagetool 重包 AppDir"
cd "$EXTRACT_ROOT"
appimagetool . "$WORKDIR/$APPIMAGE_NAME"
chmod +x "$WORKDIR/$APPIMAGE_NAME"

# 部署到 /opt
TARGET_APPIMAGE="/opt/$APPIMAGE_NAME"
echo "步驟 8：部署至 $TARGET_APPIMAGE"
sudo mv "$WORKDIR/$APPIMAGE_NAME" "$TARGET_APPIMAGE"
sudo chmod +x "$TARGET_APPIMAGE"

# 下載並設定圖示（可選）
ICON_PATH="/opt/cursor.png"
echo "步驟 9：下載圖示到 $ICON_PATH"
sudo curl -L "https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/dark/cursor.png" \
  -o "$ICON_PATH" || echo "下載圖示失敗，已跳過。"

# 建立桌面啟動器
DESKTOP_FILE="/usr/share/applications/cursor.desktop"
echo "步驟 10：建立桌面啟動器 $DESKTOP_FILE"
sudo tee "$DESKTOP_FILE" > /dev/null <<EOF
[Desktop Entry]
Name=Cursor AI IDE
Exec=env GTK_IM_MODULE=ibus QT_IM_MODULE=ibus XMODIFIERS=@im=ibus $TARGET_APPIMAGE --no-sandbox
Icon=$ICON_PATH
Type=Application
Categories=Development;
EOF
cp "$DESKTOP_FILE" ~/.local/share/applications

# 新增 shell alias
BASHRC="$HOME/.bashrc"
echo "步驟 11：新增 alias 到 $BASHRC"
if ! grep -qxF "alias cursor=" "$BASHRC"; then
  cat >> "$BASHRC" <<'EOL'

# Cursor AI IDE 快速啟動
alias cursor='/opt/cursor.AppImage --no-sandbox'
EOL
  echo "已將 alias 新增到 ~/.bashrc。請執行：source ~/.bashrc"
else
  echo "alias 已存在，跳過此步驟。"
fi

# 清理暫存
echo "步驟 12：清理暫存資料"
rm -rf "$WORKDIR"

echo "安裝完成！"
echo "– 你可以在應用程式選單找到 “Cursor AI IDE”"
echo "– 或在任何終端輸入： cursor 來啟動（需先 source ~/.bashrc）"
