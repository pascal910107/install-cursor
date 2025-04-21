#!/bin/bash
# install_cursor.sh — 在 Ubuntu 18.04（或相容版本）上安裝 Cursor AI IDE

set -e

# 依賴清單（新增 jq 以解析 JSON）
deps=(
  libfuse2 libnotify4 libnss3 libxss1 libasound2
  libatk1.0-0 libatk-bridge2.0-0 libcups2 libx11-xcb1
  libxcomposite1 libxdamage1 libxrandr2 libgbm1
  libpango-1.0-0 libgtk-3-0 libgconf-2-4 libsecret-1-0
  libcanberra-gtk-module libcanberra-gtk3-module curl jq
)

# 1. 更新套件並安裝系統依賴
echo "步驟 1：檢查並安裝系統依賴..."
missing=()
for pkg in "${deps[@]}"; do
  if ! dpkg -s "$pkg" &> /dev/null; then
    missing+=("$pkg")
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "尚未安裝的套件： ${missing[*]}"
  echo "開始安裝缺失套件..."
  sudo apt-get update
  sudo apt-get install -y "${missing[@]}"
else
  echo "所有依賴已滿足，跳過安裝步驟。"
fi

# 2. 從 API 取得真正的 AppImage 下載 URL，並安裝 Cursor
API_URL="https://www.cursor.com/api/download?platform=linux-x64&releaseTrack=stable"
echo "步驟 2：從 API ($API_URL) 取得下載資訊..."
response=$(curl -sL "$API_URL")
download_url=$(echo "$response" | jq -r '.downloadUrl')
version=$(echo "$response" | jq -r '.version')

if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
  echo "無法從 API 取得 downloadUrl，請檢查網路或 API 狀態。"
  exit 1
fi

echo "取得版本： $version"
echo "下載網址： $download_url"

# 移除舊有非二進位 AppImage
APPIMAGE_PATH="/opt/cursor.AppImage"
if [ -f "$APPIMAGE_PATH" ] && file "$APPIMAGE_PATH" | grep -q -E 'ASCII|text'; then
  echo "發現非二進位 AppImage，已刪除 $APPIMAGE_PATH"
  sudo rm "$APPIMAGE_PATH"
fi

echo "下載 Cursor AppImage 到 $APPIMAGE_PATH ..."
sudo curl -L "$download_url" -o "$APPIMAGE_PATH"

echo "賦予執行權限..."
sudo chmod +x "$APPIMAGE_PATH"

# 3. 下載圖示（可選）
ICON_PATH="/opt/cursor.png"
echo "步驟 3：下載 Cursor 圖示到 $ICON_PATH ..."
sudo curl -L "https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/dark/cursor.png" \
  -o "$ICON_PATH" || echo "下載圖示失敗，已跳過。"

# 4. 建立桌面啟動器
DESKTOP_FILE="/usr/share/applications/cursor.desktop"
echo "步驟 4：建立桌面啟動器 $DESKTOP_FILE ..."
sudo tee "$DESKTOP_FILE" > /dev/null <<EOF
[Desktop Entry]
Name=Cursor AI IDE
Exec=$APPIMAGE_PATH --no-sandbox
Icon=$ICON_PATH
Type=Application
Categories=Development;
EOF

# 5. 新增 shell alias（可快速在終端以 cursor 啟動）
BASHRC="$HOME/.bashrc"
echo "步驟 5：將 alias 寫入 $BASHRC ..."
if ! grep -qxF "alias cursor=" "$BASHRC"; then
  cat >> "$BASHRC" <<'EOL'

# Cursor AI IDE 快速啟動
alias cursor='/opt/cursor.AppImage --no-sandbox'
EOL
  echo "已將 alias 新增到 ~/.bashrc ，請執行："
  echo "  source ~/.bashrc"
else
  echo "alias 已存在，跳過此步驟。"
fi

echo "🎉 安裝完成！"
echo "– 你可以在應用程式選單找到 “Cursor AI IDE”"
echo "– 或在任何終端輸入： cursor 來啟動（需先 source ~/.bashrc）"
