#!/bin/bash
# =============================================================================
# 07-node-maintenance.sh
#
# Node Maintenance 실습용 YAML 파일 생성
#   1. poc 템플릿으로 VM 2개 YAML 생성 (oc apply 없음)
#   2. NodeMaintenance YAML 생성 (oc apply 없음)
#   3. 수동 적용 안내 출력
#
# 사용법: ./07-node-maintenance.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# env.conf 자동 로드 (단독 실행 시)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-maintenance"
NODE1="${TEST_NODE}"

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

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template 이 없습니다. 01-template 을 먼저 실행하세요."
        exit 1
    fi
    print_ok "poc Template 확인"

    if [ -z "${NODE1:-}" ]; then
        print_error "TEST_NODE 가 설정되지 않았습니다. env.conf 를 확인하세요."
        exit 1
    fi
    print_ok "대상 노드: ${NODE1}"

    print_info "  NS    : ${NS}"
    print_info "  NODE1 : ${NODE1}"
}

# =============================================================================
# 1단계: VM YAML 생성
# =============================================================================
step_generate_vms() {
    print_step "1/2  VM YAML 생성"

    for VM in poc-maintenance-vm-1 poc-maintenance-vm-2; do
        oc process -n openshift poc -p NAME="$VM" | \
        python3 -c "
import sys, yaml
docs = list(yaml.safe_load_all(sys.stdin))
for d in docs:
    if d and d.get('kind') == 'VirtualMachine':
        spec = d.setdefault('spec', {})
        spec.pop('running', None)
        spec['runStrategy'] = 'Halted'
        tmpl = spec.setdefault('template', {}).setdefault('spec', {})
        tmpl['evictionStrategy'] = 'LiveMigrate'
        print('---')
        print(yaml.dump(d, default_flow_style=False))
" > "${VM}.yaml" 2>/dev/null || \
        oc process -n openshift poc -p NAME="$VM" | \
        sed 's/  running: false/  runStrategy: Halted/' > "${VM}.yaml"

        echo "생성된 파일: ${VM}.yaml"
        print_ok "VM YAML 생성 완료: ${VM}.yaml"
    done
}

# =============================================================================
# 2단계: NodeMaintenance YAML 생성
# =============================================================================
step_generate_maintenance() {
    print_step "2/2  NodeMaintenance YAML 생성 (${NODE1})"

    cat > "nodemaintenance-${NODE1}.yaml" <<EOF
apiVersion: nodemaintenance.medik8s.io/v1beta1
kind: NodeMaintenance
metadata:
  name: maintenance-${NODE1}
spec:
  nodeName: ${NODE1}
  reason: "POC 유지보수 실습"
EOF
    echo "생성된 파일: nodemaintenance-${NODE1}.yaml"
    print_ok "NodeMaintenance YAML 생성 완료"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! YAML 파일이 생성되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${CYAN}[ 1단계 ] 네임스페이스 및 VM 생성${NC}"
    echo -e "    oc new-project ${NS}"
    echo -e "    oc apply -n ${NS} -f poc-maintenance-vm-1.yaml"
    echo -e "    oc apply -n ${NS} -f poc-maintenance-vm-2.yaml"
    echo -e "    virtctl start poc-maintenance-vm-1 -n ${NS}"
    echo -e "    virtctl start poc-maintenance-vm-2 -n ${NS}"
    echo ""
    echo -e "  ${CYAN}[ 2단계 ] VM이 ${NODE1} 에 있는지 확인${NC}"
    echo -e "    oc get vmi -n ${NS} -o wide"
    echo ""
    echo -e "  ${CYAN}[ 3단계 ] NodeMaintenance 적용 → VM 자동 Migration${NC}"
    echo -e "    oc apply -f nodemaintenance-${NODE1}.yaml"
    echo ""
    echo -e "  ${CYAN}[ 4단계 ] Migration 모니터링${NC}"
    echo -e "    oc get vmi -n ${NS} -o wide --watch"
    echo -e "    oc get nodemaintenance"
    echo ""
    echo -e "  ${CYAN}[ 5단계 ] 유지보수 종료 (uncordon)${NC}"
    echo -e "    oc delete nodemaintenance maintenance-${NODE1}"
    echo ""
    echo -e "  자세한 내용: 07-node-maintenance.md 참조"
    echo ""
}

# =============================================================================
# 메인
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Node Maintenance 실습 YAML 생성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_generate_vms
    step_generate_maintenance
    print_summary
}

main
