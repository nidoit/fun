#!/bin/bash

echo "==================================================="
echo " QCA6174 와이파이 펌웨어 안정화 스크립트 (Arch Linux) "
echo "==================================================="

# 1. 임시 작업 디렉토리 생성
WORKDIR=$(mktemp -d)
cd "$WORKDIR"
echo "=> 임시 작업 디렉토리 생성 완료: $WORKDIR"

# 2. geeksloth 저장소에서 deb 파일 다운로드
DEB_FILE="surface-go-wifi.deb"
URL_MAIN="https://github.com/geeksloth/QCA6174-ubuntu-driver/raw/main/surface-go-wifi_0.0.5_amd64.deb"
URL_MASTER="https://github.com/geeksloth/QCA6174-ubuntu-driver/raw/master/surface-go-wifi_0.0.5_amd64.deb"

echo "=> 안정화된 펌웨어 패키지 다운로드 중..."
if curl -sL --fail -o "$DEB_FILE" "$URL_MAIN"; then
    echo "=> 다운로드 성공!"
elif curl -sL --fail -o "$DEB_FILE" "$URL_MASTER"; then
    echo "=> 다운로드 성공!"
else
    echo "=> [오류] 다운로드에 실패했습니다. 인터넷 연결을 확인하세요."
    exit 1
fi

# 3. deb 파일 압축 해제 (아치 리눅스 기본 툴 활용)
echo "=> 패키지 내부 파일 추출 중..."
# binutils의 ar 명령어 또는 기본 bsdtar 활용
ar x "$DEB_FILE" 2>/dev/null || bsdtar -xf "$DEB_FILE"

# 내부에 들어있는 data.tar.* (gz 또는 xz) 압축 풀기
tar -xf data.tar.*

# 4. 펌웨어 경로 설정
TARGET_DIR="/lib/firmware/ath10k/QCA6174/hw3.0"
SOURCE_DIR="lib/firmware/ath10k/QCA6174/hw3.0"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "=> [오류] 압축 해제된 파일에서 펌웨어 폴더를 찾을 수 없습니다."
    exit 1
fi

# 5. 기존 말썽꾸러기 펌웨어 백업 (삭제 대비)
echo "=> 기존 펌웨어 파일 백업 중... (${TARGET_DIR}/backup)"
sudo mkdir -p "${TARGET_DIR}/backup"
sudo mv ${TARGET_DIR}/board*.bin "${TARGET_DIR}/backup/" 2>/dev/null
sudo mv ${TARGET_DIR}/firmware*.bin "${TARGET_DIR}/backup/" 2>/dev/null

# 6. 새로운 안정화 펌웨어 복사 및 권한 설정
echo "=> 안정화된 board.bin 및 firmware 파일 복사 중..."
sudo cp -r ${SOURCE_DIR}/* ${TARGET_DIR}/
sudo chmod 644 ${TARGET_DIR}/*.bin

# 7. 적용을 위한 모듈 재시작
echo "=> 무선 랜카드 드라이버(ath10k) 재시작 중..."
sudo modprobe -r ath10k_pci 2>/dev/null
sudo modprobe -r ath10k_core 2>/dev/null
sleep 1
sudo modprobe ath10k_pci

# 8. 임시 파일 삭제
rm -rf "$WORKDIR"

echo "==================================================="
echo " 작업이 완료되었습니다! 와이파이가 정상 작동하는지 확인해 보세요."
echo "==================================================="
