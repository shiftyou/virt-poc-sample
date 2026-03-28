#!/bin/bash
# =============================================================================
# make.sh
#
# 번호 순 디렉토리(01-, 02-, ...)의 .sh를 순서대로 실행합니다.
# setup.sh 를 먼저 실행하여 env.conf 를 생성하세요.
#   예) 01-template/01-template.sh
#       02-network/02-network.sh
#       03-vm-management/03-vm-management.sh
#
# 사용법: ./make.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env.conf"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

print_info()  { echo -e "${CYAN}[make]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[make]${NC} $1"; }
print_error() { echo -e "${RED}[make]${NC} $1"; }

# env.conf 확인 및 로드
if [ ! -f "$ENV_FILE" ]; then
    print_error "env.conf 가 없습니다. 먼저 setup.sh 를 실행하세요."
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

POC_SETUP_DIR="${SCRIPT_DIR}/poc-setup"

# 번호 디렉토리를 정렬해서 수집
STEPS=()
while IFS= read -r dir; do
    STEPS+=("$(basename "$dir")")
done < <(find "$SCRIPT_DIR" -maxdepth 1 -type d -name '[0-9][0-9]-*' | sort)

if [ ${#STEPS[@]} -eq 0 ]; then
    print_error "실행할 단계가 없습니다. 01-, 02-... 디렉토리 없음"
    exit 1
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  virt-poc-sample 전체 실행${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  실행 단계:"
for dir in "${STEPS[@]}"; do
    echo -e "    ${YELLOW}▶${NC} ${dir}/${dir}.sh"
done
echo ""

# 순서대로 실행
TOTAL=${#STEPS[@]}
IDX=0
for dir in "${STEPS[@]}"; do
    IDX=$((IDX + 1))
    SH_FILE="${SCRIPT_DIR}/${dir}/${dir}.sh"

    echo ""
    echo -e "${CYAN}━━━ [${IDX}/${TOTAL}] ${dir} ━━━${NC}"

    if [ ! -f "$SH_FILE" ]; then
        print_error "스크립트를 찾을 수 없습니다: ${dir}/${dir}.sh — 건너뜁니다"
        continue
    fi

    OUT_DIR="${POC_SETUP_DIR}/${dir}"
    mkdir -p "$OUT_DIR"

    print_info "실행: ${dir}/${dir}.sh  (생성 파일 → poc-setup/${dir}/)"
    set +e
    (cd "$OUT_DIR" && bash "$SH_FILE")
    EXIT_CODE=$?
    set -e
    if [ $EXIT_CODE -eq 0 ]; then
        print_ok "${dir} 완료"
    elif [ $EXIT_CODE -eq 77 ]; then
        echo -e "${YELLOW}[make]${NC} ${dir} 건너뜀 (오퍼레이터 미설치)"
    else
        print_error "${dir} 실패 (exit code: ${EXIT_CODE})"
        exit $EXIT_CODE
    fi
done

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  모든 단계 완료!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
