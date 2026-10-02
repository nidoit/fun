#!/bin/bash
set -e
WORKDIR=$(mktemp -d); cd "$WORKDIR"
curl -sL --fail -o w.deb "https://github.com/geeksloth/QCA6174-ubuntu-driver/raw/main/surface-go-wifi_0.0.5_amd64.deb" \
 || curl -sL --fail -o w.deb "https://github.com/geeksloth/QCA6174-ubuntu-driver/raw/master/surface-go-wifi_0.0.5_amd64.deb"

bsdtar -xf w.deb
tar -xf data.tar.xz

SRC="usr/lib/surface-go-wifi/template/hw3.0/board.bin"
TARGET=/usr/lib/firmware/ath10k/QCA6174/hw3.0
[ -f "$SRC" ] || { echo "[오류] board.bin 없음"; exit 1; }

echo "=> 기존 board 파일 백업"
sudo mkdir -p "$TARGET/backup"
sudo mv -f "$TARGET"/board-2.bin* "$TARGET"/board.bin* "$TARGET/backup/" 2>/dev/null || true

echo "=> 새 board.bin 설치"
sudo install -m 644 "$SRC" "$TARGET/board.bin"
ls -l "$TARGET"

echo "=> ath10k 재시작"
sudo modprobe -r ath10k_pci ath10k_core || true
sleep 1
sudo modprobe ath10k_pci

rm -rf "$WORKDIR"
echo "완료! 확인: sudo dmesg | grep -i 'ath10k.*board'"
