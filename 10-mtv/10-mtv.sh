#!/bin/bash
# =============================================================================
# 10-mtv.sh
#
# Migration Toolkit for Virtualization (MTV) 실습 환경 구성
#   1. poc-mtv 네임스페이스 생성
#   2. MTV 사전 체크리스트 안내
#
# 사용법: ./10-mtv.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-mtv"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERR ]${NC} $1"; }
print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

preflight() {
    print_step "사전 확인"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift 에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접속: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${MTV_INSTALLED:-false}" != "true" ]; then
        print_warn "Migration Toolkit for Virtualization Operator 미설치 → 건너뜁니다."
        print_warn "  설치 가이드: 00-operator/mtv-operator.md"
        exit 77
    fi
    print_ok "MTV Operator 확인"
}

step_namespace() {
    print_step "1/2  네임스페이스 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "네임스페이스 $NS 이미 존재 — 스킵"
    else
        oc new-project "$NS" > /dev/null
        print_ok "네임스페이스 $NS 생성 완료"
    fi
}

step_checklist() {
    print_step "2/2  마이그레이션 전 체크리스트"

    echo ""
    echo -e "${YELLOW}  ┌─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}  │  VMware → OpenShift 마이그레이션 전 필수 확인 사항      │${NC}"
    echo -e "${YELLOW}  └─────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${CYAN}[1] Hot-plug 비활성화 (VMware)${NC}"
    echo -e "      VM Edit Settings → CPU/Memory Hot Add 체크 해제"
    echo -e "      vcpu.hotadd = FALSE / mem.hotadd = FALSE"
    echo ""
    echo -e "  ${CYAN}[2] Shared Disk 활성화 (Warm Migration 사용 시)${NC}"
    echo -e "      VM 디스크 → Advanced → Sharing → Multi-writer"
    echo ""
    echo -e "  ${CYAN}[3] Windows VM — 빠른 시작 비활성화 + 정상 종료${NC}"
    echo -e "      제어판 → 전원 옵션 → 빠른 시작 사용 체크 해제"
    echo -e "      반드시 완전 종료(Shutdown) 후 마이그레이션"
    echo ""
    echo -e "  ${CYAN}[4] Warm Migration — vSphere CBT 활성화${NC}"
    echo -e "      .vmx: ctkEnabled = TRUE / scsiN:M.ctkEnabled = TRUE"
    echo -e "      활성화 후 스냅샷 생성/삭제 한 번 수행 필요"
    echo ""
    echo -e "  자세한 내용: ${CYAN}10-mtv.md${NC} 참조"
    echo ""
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! MTV 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Provider 등록:"
    echo -e "    ${CYAN}oc get provider -n openshift-mtv${NC}"
    echo ""
    echo -e "  마이그레이션 진행 확인:"
    echo -e "    ${CYAN}oc get migration -n openshift-mtv${NC}"
    echo ""
    echo -e "  마이그레이션된 VM 확인:"
    echo -e "    ${CYAN}oc get vm -n ${NS}${NC}"
    echo ""
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  MTV 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_checklist
    print_summary
}

main
