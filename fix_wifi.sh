#!/bin/bash
# QCA6174 (ath10k) 안정화용 커널 파라미터 추가/제거 스크립트 (Arch / Blunux)
#   추가:  sudo ./add_ath10k_params.sh
#   제거:  sudo ./add_ath10k_params.sh --remove
# GRUB, systemd-boot, /etc/kernel/cmdline(UKI) 를 자동 감지합니다.

set -e
PARAMS=("pcie_aspm=off" "ath10k_core.skip_otp=y")
MODE="add"; [ "$1" = "--remove" ] && MODE="remove"
STAMP=$(date +%Y%m%d-%H%M%S)
DONE=0

if [ "$EUID" -ne 0 ]; then
    echo "[오류] sudo로 실행하세요: sudo $0 $*"; exit 1
fi

# 문자열(공백 구분 파라미터 목록)에 PARAMS를 추가/제거
edit_params() {
    local line="$1" p
    for p in "${PARAMS[@]}"; do
        if [ "$MODE" = "add" ]; then
            [[ " $line " == *" $p "* ]] || line="$line $p"
        else
            line=$(echo " $line " | sed "s/ $p / /g")
        fi
    done
    echo "$line" | xargs   # 앞뒤 공백 정리
}

echo "=== ath10k 커널 파라미터 ${MODE} ==="

# ---------- 1. GRUB ----------
if [ -f /etc/default/grub ] && command -v grub-mkconfig >/dev/null; then
    echo "=> GRUB 감지"
    cp /etc/default/grub "/etc/default/grub.bak-$STAMP"
    cur=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | head -n1 \
          | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT=["'\'']?//; s/["'\'']?$//')
    new=$(edit_params "$cur")
    sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$new\"|" /etc/default/grub
    echo "   이전: $cur"
    echo "   이후: $new"
    CFG=/boot/grub/grub.cfg
    [ -d /boot/grub ] || CFG=$(find /boot /efi -name grub.cfg 2>/dev/null | head -n1)
    grub-mkconfig -o "$CFG"
    DONE=1
fi

# ---------- 2. systemd-boot ----------
if command -v bootctl >/dev/null && bootctl is-installed >/dev/null 2>&1; then
    echo "=> systemd-boot 감지"
    # ESP와 /boot 가 같은 경로면 한 번만 처리 (백업이 덮어써지지 않도록)
    for dir in $(printf '%s\n' "$(bootctl --print-boot-path 2>/dev/null)" "$(bootctl --print-esp-path 2>/dev/null)" | sort -u); do
        [ -d "$dir/loader/entries" ] || continue
        for f in "$dir"/loader/entries/*.conf; do
            [ -f "$f" ] || continue
            grep -qE '^options' "$f" || continue
            cp "$f" "$f.bak-$STAMP"
            cur=$(grep -E '^options' "$f" | head -n1 | sed -E 's/^options[[:space:]]+//')
            new=$(edit_params "$cur")
            sed -i -E "0,/^options.*/s|^options.*|options $new|" "$f"
            echo "   수정: $f"
            DONE=1
        done
    done
fi

# ---------- 3. UKI / kernel-install (/etc/kernel/cmdline) ----------
if [ -f /etc/kernel/cmdline ]; then
    echo "=> /etc/kernel/cmdline 감지 (UKI)"
    cp /etc/kernel/cmdline "/etc/kernel/cmdline.bak-$STAMP"
    new=$(edit_params "$(cat /etc/kernel/cmdline)")
    echo "$new" > /etc/kernel/cmdline
    echo "   이후: $new"
    command -v mkinitcpio >/dev/null && mkinitcpio -P
    DONE=1
fi

if [ "$DONE" -eq 0 ]; then
    echo "[오류] 지원하는 부트로더(GRUB / systemd-boot / UKI)를 찾지 못했습니다."
    echo "       'bootctl status' 또는 'ls /boot' 결과를 확인해 주세요."
    exit 1
fi

echo "==================================================="
echo " 완료! 재부팅 후 아래 명령으로 적용 여부를 확인하세요:"
echo "   cat /proc/cmdline"
echo "   sudo dmesg | grep -i ath10k"
echo " 백업 파일에는 .bak-$STAMP 가 붙어 있습니다."
echo "==================================================="#!/bin/bash
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
