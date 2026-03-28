#!/bin/bash
# =============================================================================
# 12-node-exporter.sh
#
# OpenShift에 node-exporter Service 등록
#   1. poc 템플릿으로 VM 생성 (monitor=metrics 레이블 포함)
#   2. node-exporter-service.yaml 적용
#   3. Endpoints 확인 안내
#
# 사용법: ./12-node-exporter.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-node-exporter"
VM_NAME="poc-node-exporter-vm"
SERVICE_YAML="${SCRIPT_DIR}/node-exporter-service.yaml"

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
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접속: $(oc whoami) @ $(oc whoami --show-server)"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "네임스페이스 $NS 이미 존재 — 스킵"
    else
        oc new-project "$NS" > /dev/null
        print_ok "네임스페이스 $NS 생성 완료"
    fi

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template 이 없습니다. 01-template 을 먼저 실행하세요."
        exit 1
    fi
    print_ok "poc Template 확인"

    if ! command -v virtctl &>/dev/null; then
        print_error "virtctl 을 찾을 수 없습니다."
        exit 1
    fi
    print_ok "virtctl 확인"

    if [ ! -f "$SERVICE_YAML" ]; then
        print_error "Service YAML 파일을 찾을 수 없습니다: $SERVICE_YAML"
        exit 1
    fi
}

step_vm() {
    print_step "1/3  VM 생성 (${VM_NAME})"

    if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
        print_ok "VM $VM_NAME 이미 존재 — 스킵"
    else
        oc process -n openshift poc -p NAME="$VM_NAME" > "${VM_NAME}.yaml"
        echo "생성된 파일: ${VM_NAME}.yaml"
        oc apply -n "$NS" -f "${VM_NAME}.yaml"
        print_ok "VM $VM_NAME 생성 완료"
    fi

    # virt-launcher Pod에 monitor=metrics 레이블 전파를 위해 spec.template.metadata.labels 설정
    oc patch vm "$VM_NAME" -n "$NS" --type=merge -p '{
      "spec": {
        "template": {
          "metadata": {
            "labels": {
              "monitor": "metrics"
            }
          }
        }
      }
    }' 2>/dev/null && print_ok "레이블 monitor=metrics 설정 완료" || true

    virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
    print_info "VM 시작 요청 완료 (Running 상태까지 시간이 걸릴 수 있습니다)"
    print_info "  ${CYAN}oc get vmi $VM_NAME -n $NS${NC}"
}

step_apply_service() {
    print_step "2/3  node-exporter Service 적용"

    oc apply -f "$SERVICE_YAML"
    print_ok "node-exporter-service 적용 완료"
}

step_check_endpoints() {
    print_step "3/3  Endpoints 확인"

    local ep_count
    ep_count=$(oc get endpoints node-exporter-service -n "$NS" \
        -o jsonpath='{.subsets[*].addresses}' 2>/dev/null | wc -w | tr -d ' ')

    if [ "$ep_count" -gt 0 ] 2>/dev/null; then
        print_ok "Endpoints 등록됨 (${ep_count}개)"
        oc get endpoints node-exporter-service -n "$NS"
    else
        print_warn "Endpoints가 아직 없습니다."
        print_info "VM Pod에 레이블이 있는지 확인하세요:"
        echo -e "    ${CYAN}oc get pods -n ${NS} --show-labels | grep monitor${NC}"
        echo -e "    ${CYAN}oc label pod <pod-name> -n ${NS} monitor=metrics${NC}"
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! node-exporter Service가 등록되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  VM 상태 확인:"
    echo -e "    ${CYAN}oc get vmi ${VM_NAME} -n ${NS}${NC}"
    echo ""
    echo -e "  Service 상태 확인:"
    echo -e "    ${CYAN}oc get svc node-exporter-service -n ${NS}${NC}"
    echo ""
    echo -e "  Endpoints 확인:"
    echo -e "    ${CYAN}oc get endpoints node-exporter-service -n ${NS}${NC}"
    echo ""
    echo -e "  메트릭 접근 (port-forward):"
    echo -e "    ${CYAN}oc port-forward svc/node-exporter-service 9100:9100 -n ${NS}${NC}"
    echo -e "    ${CYAN}curl http://localhost:9100/metrics${NC}"
    echo ""
    echo -e "  VM에 node_exporter 설치:"
    echo -e "    ${CYAN}bash node-exporter-install.sh${NC}"
    echo ""
    echo -e "  자세한 내용: 12-node-exporter.md 참조"
    echo ""
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Node Exporter Service 등록${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_vm
    step_apply_service
    step_check_endpoints
    print_summary
}

main
