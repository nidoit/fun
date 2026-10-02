#!/usr/bin/env bash
# han.sh - 한컴오피스 2022 (hoffice) 리눅스 베타를 Arch에서 패키징/설치/한글입력(kime) 설정까지 한번에
#
# 사용법:
#   chmod +x han.sh && ./han.sh [옵션]
#
# 옵션:
#   --clean       설치 성공 후 작업 폴더(WORKDIR) 삭제
#   --skip-kime   kime Qt 플러그인 복사 단계 생략
#   --deb PATH    직접 받아둔 hoffice_*.deb 를 사용 (다운로드 단계 생략)
#   -h, --help    도움말
#
# 환경변수:
#   WORKDIR=~/hoffice-build   작업 폴더 (여유공간 약 12GB 필요)
#   SKIP_SPACE_CHECK=1        디스크 여유공간 검사 생략
#
# 단계:
#   1) 의존 도구 확인 (yay/paru, debtap, bsdtar, zstd)
#   2) deb 다운로드 (arter97.com, 이어받기 + 무결성 검사)
#   3) debtap 으로 Arch 패키지 변환 (질문 없이)
#   4) .INSTALL 교정 + license=custom 으로 재패키징
#   5) pacman -U 설치
#   6) kime Qt 플러그인을 한컴 입력기 폴더에 복사

set -euo pipefail

# ----------------------------- 설정 -----------------------------
PKGNAME="hoffice"
DEB_NAME="hoffice_11.20.0.1520_amd64.deb"
DEB_URL="${DEB_URL:-https://arter97.com/.191066/${DEB_NAME}}"   # 환경변수 DEB_URL 로 덮어쓰기 가능
DEB_MIN_BYTES=1000000000            # 약 1.3GB 짜리라 1GB 미만이면 끊긴 파일

KIME_URL="https://github.com/Riey/kime/releases/latest/download/libkime-qt-5.11.3.so"
KIME_LIB="libkime-qt-5.11.3.so"
HNCCONTEXT="/opt/hnc/hoffice11/Bin/qt/plugins/platforminputcontexts"

WORKDIR="${WORKDIR:-$HOME/hoffice-build}"
NEED_BYTES=$((12 * 1024 * 1024 * 1024))

DO_CLEAN=0
DO_KIME=1

# ----------------------------- 출력 -----------------------------
if [[ -t 1 ]]; then
  C_B=$'\e[1;34m'; C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_R=$'\e[1;31m'; C_0=$'\e[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
step() { echo; echo "${C_B}==>${C_0} $*"; }
ok()   { echo "${C_G} ✓${C_0} $*"; }
warn() { echo "${C_Y} !${C_0} $*" >&2; }
die()  { echo "${C_R} ✗ $*${C_0}" >&2; exit 1; }

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

USER_DEB=""
while (( $# )); do
  case "$1" in
    --clean)     DO_CLEAN=1 ;;
    --skip-kime) DO_KIME=0 ;;
    --deb)       shift; [[ -n "${1:-}" && -f "$1" ]] || die "--deb 뒤에 존재하는 .deb 파일 경로를 주세요."
                 USER_DEB="$(realpath "$1")" ;;
    -h|--help)   usage ;;
    *) die "알 수 없는 옵션: $1 (--help 참고)" ;;
  esac
  shift
done

# ----------------------------- 사전 검사 -----------------------------
[[ $EUID -eq 0 ]] && die "root 로 실행하지 마세요. 필요한 곳에서만 sudo 를 씁니다."
command -v pacman >/dev/null || die "Arch 계열 시스템이 아닙니다 (pacman 없음)."
command -v sudo   >/dev/null || die "sudo 가 필요합니다."

mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [[ "${SKIP_SPACE_CHECK:-0}" != "1" ]]; then
  avail=$(df --output=avail -B1 "$WORKDIR" | tail -n1 | tr -d ' ')
  if (( avail < NEED_BYTES )); then
    die "여유공간 부족: $(numfmt --to=iec "$avail") 남음, 약 12GB 필요 (deb 1.3GB + 변환 + 재패키징). SKIP_SPACE_CHECK=1 로 무시 가능."
  fi
fi

# 충돌 패키지
if pacman -Q hoffice-hwp &>/dev/null; then
  warn "hoffice-hwp 가 설치돼 있어 hoffice 와 충돌합니다. 제거합니다."
  sudo pacman -Rns hoffice-hwp
fi

# ----------------------------- 1) 도구 -----------------------------
step "1/6 필요한 도구 확인"

for pkg in base-devel git libarchive zstd curl pacman-contrib pkgfile fakeroot; do
  pacman -Qq "$pkg" &>/dev/null || sudo pacman -S --needed --noconfirm "$pkg"
done

# 작업이 길어서(변환+재패키징) sudo 인증이 중간에 만료되지 않도록 갱신 유지
sudo -v
( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# debtap 이 임시 작업에 /tmp 를 쓸 수 있는데, Arch 기본 /tmp 는 tmpfs(램 크기 제한)
tmp_avail=$(df --output=avail -B1 /tmp | tail -n1 | tr -d ' ')
if (( tmp_avail < 8 * 1024 * 1024 * 1024 )); then
  warn "/tmp 여유공간이 $(numfmt --to=iec "$tmp_avail") 입니다. 3단계에서 'No space left' 가 나면 /tmp 용량 문제일 수 있습니다."
fi

aur_install() {   # $1 = 패키지
  if command -v yay >/dev/null; then
    yay -S --needed --noconfirm "$1"
  elif command -v paru >/dev/null; then
    paru -S --needed --noconfirm "$1"
  else
    warn "yay/paru 없음 -> git clone + makepkg 로 $1 설치"
    local d="$WORKDIR/aur-$1"
    rm -rf "$d"
    git clone "https://aur.archlinux.org/$1.git" "$d"
    (cd "$d" && makepkg -si --noconfirm)
  fi
}

if ! command -v debtap >/dev/null; then
  aur_install debtap
fi
ok "debtap 준비됨"

step "debtap 패키지 DB 업데이트 (sudo debtap -u)"
# debtap 은 `pacman -Qi base | grep ^Depends` 로 base 의존성을 읽는데, 한국어/중국어 등
# 비영어 로케일에서는 'Depends' 라벨이 번역되어 목록이 비어 버린다 -> LC_ALL=C 로 실행해야 한다.
sudo env LC_ALL=C debtap -u

# debtap -u 가 "완료"라고 해도 DB 가 비어 있는 경우가 있다 (extended-base-packages-list 가 사실상 빈 파일).
# 이 상태로 변환하면 3단계에서 'You must run at least once debtap -u' 로 실패하므로 여기서 미리 확인한다.
EXT_LIST=/var/cache/debtap/extended-base-packages-list
ext_lines=$(wc -l < "$EXT_LIST" 2>/dev/null || echo 0)
if (( ext_lines < 20 )); then
  warn "debtap DB 가 불완전합니다: $EXT_LIST 항목 ${ext_lines}줄 (정상이면 100줄 안팎)"
  warn "  - base 패키지 의존성 읽기: $(LC_ALL=C pacman -Qi base 2>/dev/null | grep -c '^Depends') (0이면 base 메타패키지 미설치/조회 실패)"
  warn "  - /etc/pacman.conf 에 공식 저장소 외 저장소(예: [blunux2])가 있으면 잠시 주석 처리 후 'sudo env LC_ALL=C debtap -u' 를 다시 실행해 보세요."
  warn "  - 그래도 안 되면: sudo rm -rf /var/cache/debtap && sudo env LC_ALL=C debtap -u"
  die "debtap DB 준비 실패. 위를 조치한 뒤 ./han.sh 를 다시 실행하세요 (받은 deb 는 재사용됩니다)."
fi
ok "debtap DB 업데이트 완료"

# ----------------------------- 2) 다운로드 -----------------------------
step "2/6 deb 다운로드 (${DEB_NAME})"

size_of() { stat -L -c %s "$1" 2>/dev/null || echo 0; }

# 직접 받아둔 deb 를 쓰는 경우 (--deb PATH)
if [[ -n "$USER_DEB" ]]; then
  ln -sf "$USER_DEB" "$DEB_NAME"
  ok "지정한 deb 사용: $USER_DEB"
fi

download() {
  curl -fL -C - --retry 5 --retry-delay 3 --retry-all-errors \
       -o "$DEB_NAME" "$DEB_URL"
}

deb_ok() {
  [[ -f "$DEB_NAME" ]] || return 1
  (( $(size_of "$DEB_NAME") >= DEB_MIN_BYTES )) || return 1
  bsdtar -tf "$DEB_NAME" >/dev/null 2>&1       # ar 구조가 깨졌는지 확인
}

if deb_ok; then
  ok "이미 받은 파일이 정상입니다. 다운로드 생략"
else
  # 이전 시도에서 남은 쓰레기 파일(에러 페이지 등)에서 이어받지 않도록 정리
  if [[ -z "$USER_DEB" && -f "$DEB_NAME" ]] && (( $(size_of "$DEB_NAME") < 1048576 )); then
    rm -f "$DEB_NAME"
  fi
  tries=0
  until download && deb_ok; do
    # 서버가 deb 대신 아주 작은 응답(에러 문구 등)을 준 경우: 재시도해도 소용없으니 바로 중단
    if [[ -n "$USER_DEB" ]]; then
      die "--deb 로 지정한 파일이 정상 deb 가 아닙니다 (1GB 미만이거나 손상)."
    fi
    if [[ -f "$DEB_NAME" ]] && (( $(size_of "$DEB_NAME") < 1048576 )); then
      warn "서버가 deb 대신 $(size_of "$DEB_NAME") 바이트짜리 응답을 줬습니다. 내용:"
      head -c 300 "$DEB_NAME" >&2; echo >&2
      rm -f "$DEB_NAME"
      die "이 URL 에서 deb 를 받을 수 없습니다 (삭제/이동/차단). 다른 경로로 받은 deb 를 './han.sh --deb /경로/${DEB_NAME}' 로 지정하세요."
    fi
    tries=$((tries + 1))
    (( tries >= 5 )) && die "다운로드 실패/손상. URL 이 막혔거나(404) 연결이 계속 끊깁니다. 로그를 확인하세요."
    # 크기는 충분한데 ar 구조가 깨진 경우: 이어받기로는 못 고치므로 지우고 처음부터
    if [[ -f "$DEB_NAME" ]] && (( $(size_of "$DEB_NAME") >= DEB_MIN_BYTES )) && ! bsdtar -tf "$DEB_NAME" >/dev/null 2>&1; then
      warn "파일이 손상됐습니다. 삭제 후 처음부터 다시 받습니다."
      rm -f "$DEB_NAME"
    fi
    warn "다시 시도합니다 (${tries}/5) - 현재 $(numfmt --to=iec "$(size_of "$DEB_NAME")")"
    sleep 3
  done
  ok "다운로드 완료: $(numfmt --to=iec "$(size_of "$DEB_NAME")")"
fi
echo "   출처: $DEB_URL"
echo "   sha256: $(sha256sum "$DEB_NAME" | cut -d' ' -f1)"

# ----------------------------- 3) debtap 변환 -----------------------------
step "3/6 debtap 으로 Arch 패키지 변환 (시간이 꽤 걸립니다)"

rm -f ./${PKGNAME}-*.pkg.tar.*
# -Q : 모든 질문 생략 (패키지명은 deb 이름에서 가져옴, license 는 아래에서 custom 으로 교정)
LC_ALL=C debtap -Q "$DEB_NAME"

shopt -s nullglob
converted=( ./${PKGNAME}-*.pkg.tar.* )
shopt -u nullglob
(( ${#converted[@]} >= 1 )) || die "debtap 결과물(.pkg.tar.*)을 찾지 못했습니다."
CONVERTED="${converted[0]}"
ok "변환 완료: $CONVERTED"

# ----------------------------- 4) 재패키징 -----------------------------
step "4/6 .INSTALL 교정 + license=custom 으로 재패키징"

REPACK_DIR="$WORKDIR/repack"
FINAL_PKG="$WORKDIR/$(basename "${CONVERTED%%.pkg.tar*}").pkg.tar.zst"

rm -rf "$REPACK_DIR"
mkdir -p "$REPACK_DIR"
bsdtar -xpf "$CONVERTED" -C "$REPACK_DIR"

# 교정된 .INSTALL (원 글의 최종본)
cat > "$REPACK_DIR/.INSTALL" <<'INSTALL_EOF'
set -e
SYSCONTEXT=/usr/lib/qt/plugins/platforminputcontexts
HNCCONTEXT=/opt/hnc/hoffice11/Bin/qt/plugins/platforminputcontexts
NIMFLIB=libqt5im-nimf.so

post_install() {
  xdg-icon-resource forceupdate --theme hicolor &> /dev/null

  if [[ ! -d "$HNCCONTEXT" ]]; then
    mkdir -p "$HNCCONTEXT"
  fi

  if [[ -f "$SYSCONTEXT/$NIMFLIB" ]]; then
    ln -sf "$SYSCONTEXT/$NIMFLIB" "$HNCCONTEXT/$NIMFLIB"
  else
    echo "Can't find $SYSCONTEXT/$NIMFLIB"
    echo "You should copy or link \"$NIMFLIB\" to \"$HNCCONTEXT\""
  fi

  update-desktop-database -q
}

post_upgrade() {
  post_install
}

pre_remove() {
  if [[ -f "$HNCCONTEXT/$NIMFLIB" ]]; then
    rm -vf "$HNCCONTEXT/$NIMFLIB"
  fi
}

post_remove() {
  xdg-icon-resource forceupdate --theme hicolor &> /dev/null
  update-desktop-database -q
}
INSTALL_EOF

sed -i 's/^license = .*/license = custom/' "$REPACK_DIR/.PKGINFO"
grep -q '^license = custom' "$REPACK_DIR/.PKGINFO" || echo "license = custom" >> "$REPACK_DIR/.PKGINFO"

(
  cd "$REPACK_DIR"
  shopt -s dotglob nullglob
  rm -f .MTREE
  files=( * )
  # .INSTALL 이 바뀌었으니 .MTREE 도 makepkg 방식으로 재생성
  # 일반 사용자로 풀었기 때문에 그대로 묶으면 파일 소유자가 내 계정(uid 1000 등)이 된다.
  # pacman 은 아카이브의 uid/gid 를 그대로 쓰므로 반드시 root:root 로 고정해서 묶는다.
  OWNER_OPTS=( --uid 0 --gid 0 --uname root --gname root --numeric-owner )
  LANG=C bsdtar -czf .MTREE --format=mtree "${OWNER_OPTS[@]}" \
    --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
    "${files[@]}"
  files+=( .MTREE )
  bsdtar -cf - "${OWNER_OPTS[@]}" "${files[@]}" | zstd -T0 -3 -q -f -o "$FINAL_PKG"
)

# 소유자 검증: root 가 아닌 항목이 하나라도 있으면 중단
if bsdtar -tvf "$FINAL_PKG" | awk '{n++} $3!="root" && $3!="0" {bad=1} END{exit (bad || n==0)}'; then
  ok "소유자 검증 통과 (전부 root)"
else
  die "재패키징된 파일 중 root 소유가 아닌 항목이 있습니다. 설치를 중단합니다."
fi

# 읽기전용 디렉터리가 있어도 지워지도록 권한 복구 후 삭제
chmod -R u+rwX "$REPACK_DIR" 2>/dev/null || true
rm -rf "$REPACK_DIR"
ok "재패키징 완료: $FINAL_PKG ($(numfmt --to=iec "$(size_of "$FINAL_PKG")"))"

# ----------------------------- 5) 설치 -----------------------------
step "5/6 pacman -U 설치"
sudo pacman -U --noconfirm "$FINAL_PKG"
ok "hoffice 설치 완료"

# ----------------------------- 6) kime -----------------------------
if (( DO_KIME )); then
  step "6/6 kime Qt 플러그인 설치 -> $HNCCONTEXT"

  sudo mkdir -p "$HNCCONTEXT"

  # 기존 nimf 라이브러리는 백업 (원 글: .bak 로 이름 변경)
  if [[ -e "$HNCCONTEXT/libqt5im-nimf.so" || -L "$HNCCONTEXT/libqt5im-nimf.so" ]]; then
    sudo mv -f "$HNCCONTEXT/libqt5im-nimf.so" "$HNCCONTEXT/libqt5im-nimf.so.bak"
    ok "libqt5im-nimf.so -> libqt5im-nimf.so.bak"
  fi

  if [[ ! -f "$WORKDIR/$KIME_LIB" ]]; then
    curl -fL --retry 3 -o "$WORKDIR/$KIME_LIB" "$KIME_URL"
  fi
  sudo install -m 755 "$WORKDIR/$KIME_LIB" "$HNCCONTEXT/$KIME_LIB"
  ok "$KIME_LIB 설치 완료"

  echo
  echo "  한글이 안 쳐지면 환경변수를 확인하세요 (kime 사용 시):"
  echo "    QT_IM_MODULE=kime  GTK_IM_MODULE=kime  XMODIFIERS=@im=kime"
else
  warn "--skip-kime: 6단계 생략"
fi

# ----------------------------- 마무리 -----------------------------
if (( DO_CLEAN )); then
  step "작업 폴더 삭제: $WORKDIR"
  cd "$HOME"
  rm -rf "$WORKDIR"
  ok "삭제 완료"
else
  echo
  echo "작업 폴더는 남겨뒀습니다: $WORKDIR (deb 1.3GB + 패키지 포함)"
  echo "정리하려면: rm -rf \"$WORKDIR\"   (또는 다음에 --clean 옵션)"
fi

echo
ok "끝! 실행: hoffice  (또는 앱 메뉴에서 한컴오피스)"
