#!/bin/bash
# =============================================================================
# 05-resource-quota.sh
#
# ResourceQuota 실습 환경 구성
#   - poc-resource-quota 네임스페이스 생성
#   - CPU / Memory / Pod / PVC 등 ResourceQuota 적용
#
# 사용법: ./05-resource-quota.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# env.conf 자동 로드 (단독 실행 시)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-resource-quota"

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

# =============================================================================
# 사전 확인
# =============================================================================
preflight() {
    print_step "사전 확인"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift 에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접속: $(oc whoami) @ $(oc whoami --show-server)"
    print_info "  NS : ${NS}"
}

# =============================================================================
# 1단계: 네임스페이스 생성
# =============================================================================
step_namespace() {
    print_step "1/2  네임스페이스 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "네임스페이스 $NS 이미 존재 — 스킵"
    else
        oc new-project "$NS"
        print_ok "네임스페이스 $NS 생성 완료"
    fi
}

# =============================================================================
# 2단계: ResourceQuota 적용
# =============================================================================
step_quota() {
    print_step "2/2  ResourceQuota 적용 (${NS})"

    cat > resourcequota-poc.yaml <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: poc-quota
  namespace: poc-resource-quota
spec:
  hard:
    # Pod 수
    pods: "10"
    # CPU (requests / limits)
    requests.cpu: "4"
    limits.cpu: "8"
    # Memory (requests / limits)
    requests.memory: 8Gi
    limits.memory: 16Gi
    # PersistentVolumeClaim 수 및 용량
    persistentvolumeclaims: "10"
    requests.storage: 100Gi
    # Service
    services: "10"
    services.loadbalancers: "2"
    services.nodeports: "0"
    # ConfigMap / Secret
    configmaps: "20"
    secrets: "20"
EOF
    echo "생성된 파일: resourcequota-poc.yaml"
    oc apply -f resourcequota-poc.yaml

    print_ok "ResourceQuota poc-quota 적용 완료 (namespace: ${NS})"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! ResourceQuota 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ResourceQuota 현황:"
    echo -e "    ${CYAN}oc get resourcequota -n ${NS}${NC}"
    echo -e "    ${CYAN}oc describe resourcequota poc-quota -n ${NS}${NC}"
    echo ""
    echo -e "  다음 단계: 05-resource-quota.md 참조"
    echo ""
}

# =============================================================================
# 메인
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  ResourceQuota 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_quota
    print_summary
}

main
