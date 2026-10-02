#!/bin/bash
set -e
WORKDIR=$(mktemp -d); cd "$WORKDIR"
DEB="w.deb"
for b in main master; do
  curl -sL --fail -o "$DEB" "https://github.com/geeksloth/QCA6174-ubuntu-driver/raw/$b/surface-go-wifi_0.0.5_amd64.deb" && break
done

if ! file "$DEB" | grep -q "Debian binary package"; then
  echo "[오류] 받은 파일이 .deb가 아닙니다:"; file "$DEB"; head -c 300 "$DEB"; exit 1
fi

bsdtar -xf "$DEB"
tar -xf data.tar.*

SRC=$(find . -type d -path "*ath10k/QCA6174/hw3.0" | head -n1)
if [ -z "$SRC" ]; then
  echo "[오류] hw3.0 폴더 없음. 패키지 내용:"; find . -type f; exit 1
fi
echo "=> 펌웨어 위치: $SRC"; ls -l "$SRC"

TARGET=/usr/lib/firmware/ath10k/QCA6174/hw3.0
sudo mkdir -p "$TARGET/backup"
for f in "$SRC"/*; do
  name=$(basename "$f")
  # 같은 이름의 .bin / .bin.zst / .bin.xz 모두 백업
  sudo mv -f "$TARGET/$name" "$TARGET/$name.zst" "$TARGET/$name.xz" "$TARGET/backup/" 2>/dev/null || true
done
# board.bin을 교체하는 경우 board-2.bin이 우선 로드되므로 함께 치워둠
if [ -e "$SRC/board.bin" ]; then
  sudo mv -f "$TARGET"/board-2.bin* "$TARGET/backup/" 2>/dev/null || true
fi

sudo cp "$SRC"/* "$TARGET/"
sudo chmod 644 "$TARGET"/*.bin

sudo modprobe -r ath10k_pci ath10k_core || true
sleep 1
sudo modprobe ath10k_pci
rm -rf "$WORKDIR"
echo "완료 — 'sudo dmesg | grep ath10k'로 로드된 펌웨어를 확인하세요."
