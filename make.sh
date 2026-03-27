#!/bin/bash
# =============================================================================
# make.sh
#
# 번호로 시작하는 디렉토리(01-, 02-, ...)의 .sh 파일을 순서대로 실행합니다.
# 각 디렉토리의 스크립트 이름은 디렉토리 이름과 동일합니다.
#   예) 01-make-template/01-make-template.sh
#
# 사용법: ./make.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

print_info()  { echo -e "${CYAN}[make]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[make]${NC} $1"; }
print_error() { echo -e "${RED}[make]${NC} $1"; }

cd "$SCRIPT_DIR"

# 번호로 시작하는 디렉토리를 정렬해서 수집
STEPS=()
while IFS= read -r dir; do
    STEPS+=("$dir")
done < <(ls -d [0-9][0-9]-* 2>/dev/null | sort)

if [ ${#STEPS[@]} -eq 0 ]; then
    print_error "실행할 단계가 없습니다. (01-, 02-... 디렉토리 없음)"
    exit 1
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  virt-poc-sample 전체 실행${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  실행 단계:"
for dir in "${STEPS[@]}"; do
    echo -e "    ${YELLOW}▶${NC} ${dir}"
done
echo ""

# 순서대로 실행
TOTAL=${#STEPS[@]}
IDX=0
for dir in "${STEPS[@]}"; do
    IDX=$((IDX + 1))
    SH_FILE="${dir}/${dir}.sh"

    echo ""
    echo -e "${CYAN}━━━ [${IDX}/${TOTAL}] ${dir} ━━━${NC}"

    if [ ! -f "$SH_FILE" ]; then
        print_error "스크립트를 찾을 수 없습니다: $SH_FILE — 건너뜁니다"
        continue
    fi

    print_info "실행: $SH_FILE"
    bash "$SH_FILE"
    print_ok "${dir} 완료"
done

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  모든 단계 완료!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
