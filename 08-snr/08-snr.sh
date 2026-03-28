#!/bin/bash
# =============================================================================
# 08-snr.sh
#
# Self Node Remediation (SNR) 실습 환경 구성
#   1. poc-snr 네임스페이스 생성
#   2. SelfNodeRemediationTemplate 생성
#   3. NodeHealthCheck CR 생성 (SNR 연동)
#   4. poc 템플릿으로 VM 2개 배포 → TEST_NODE에 배치
#
# 사용법: ./08-snr.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-snr"
REMEDIATION_NS="openshift-workload-availability"
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

# spec.running(deprecated) -> spec.runStrategy 마이그레이션
# oc patch vm 전에 호출하여 admission webhook 경고 제거
ensure_runstrategy() {
    local vm="$1" ns="$2"
    local running
    running=$(oc get vm "$vm" -n "$ns" \
        -o jsonpath='{.spec.running}' 2>/dev/null || true)
    [ -z "$running" ] && return 0
    local rs="Halted"
    [ "$running" = "true" ] && rs="Always"
    oc patch vm "$vm" -n "$ns" --type=json -p "[
      {\"op\":\"remove\",\"path\":\"/spec/running\"},
      {\"op\":\"add\",\"path\":\"/spec/runStrategy\",\"value\":\"${rs}\"}
    ]" &>/dev/null || true
}

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

    if [ "${SNR_INSTALLED:-false}" != "true" ]; then
        print_warn "Self Node Remediation Operator 미설치 → 건너뜁니다."
        print_warn "  설치 가이드: 00-operator/snr-operator.md"
        exit 77
    fi
    print_ok "Self Node Remediation Operator 확인"

    if [ "${NHC_INSTALLED:-false}" != "true" ]; then
        print_warn "Node Health Check Operator 미설치 → 건너뜁니다."
        print_warn "  설치 가이드: 00-operator/nhc-operator.md"
        exit 77
    fi
    print_ok "Node Health Check Operator 확인"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template 이 없습니다. 01-template 을 먼저 실행하세요."
        exit 1
    fi
    print_ok "poc Template 확인"

    if ! oc get node "$NODE1" &>/dev/null; then
        print_error "노드 $NODE1 를 찾을 수 없습니다. env.conf 의 TEST_NODE 를 확인하세요."
        exit 1
    fi
    print_ok "대상 노드: $NODE1"
}

# =============================================================================
# 1단계: 네임스페이스 생성
# =============================================================================
step_namespace() {
    print_step "1/4  네임스페이스 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "네임스페이스 $NS 이미 존재 — 스킵"
    else
        oc new-project "$NS" > /dev/null
        print_ok "네임스페이스 $NS 생성 완료"
    fi
}

# =============================================================================
# 2단계: SelfNodeRemediationTemplate 생성
# =============================================================================
step_snr_template() {
    print_step "2/4  SelfNodeRemediationTemplate 생성"

    cat > snr-template.yaml <<EOF
apiVersion: self-node-remediation.medik8s.io/v1alpha1
kind: SelfNodeRemediationTemplate
metadata:
  name: poc-snr-template
  namespace: ${REMEDIATION_NS}
spec:
  template:
    spec:
      remediationStrategy: ResourceDeletion
EOF
    oc apply -f snr-template.yaml
    print_ok "SelfNodeRemediationTemplate poc-snr-template 생성 완료"
}

# =============================================================================
# 3단계: NodeHealthCheck 생성
# =============================================================================
step_nhc() {
    print_step "3/4  NodeHealthCheck 생성 (SNR 연동)"

    cat > nhc-snr.yaml <<EOF
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: poc-snr-nhc
spec:
  minHealthy: "51%"
  remediationTemplate:
    apiVersion: self-node-remediation.medik8s.io/v1alpha1
    kind: SelfNodeRemediationTemplate
    name: poc-snr-template
    namespace: ${REMEDIATION_NS}
  selector:
    matchExpressions:
      - key: node-role.kubernetes.io/worker
        operator: Exists
  unhealthyConditions:
    - type: Ready
      status: "False"
      duration: 300s
    - type: Ready
      status: Unknown
      duration: 300s
EOF
    oc apply -f nhc-snr.yaml
    print_ok "NodeHealthCheck poc-snr-nhc 생성 완료"
    print_info "  조건: Ready=False 또는 Unknown 300초 이상 → SNR 발동"
}

# =============================================================================
# 4단계: VM 배포
# =============================================================================
step_vms() {
    print_step "4/4  VM 배포 → ${NODE1}"

    for VM in poc-snr-vm-1 poc-snr-vm-2; do
        if oc get vm "$VM" -n "$NS" &>/dev/null; then
            print_ok "VM $VM 이미 존재 — 스킵"
            continue
        fi

        oc process -n openshift poc -p NAME="$VM" | \
        sed 's/  running: false/  runStrategy: Halted/' > "${VM}.yaml"
        oc apply -n "$NS" -f "${VM}.yaml"

        ensure_runstrategy "$VM" "$NS"
        oc patch vm "$VM" -n "$NS" --type=merge -p "{
          \"spec\": {
            \"template\": {
              \"spec\": {
                \"nodeSelector\": {\"kubernetes.io/hostname\": \"${NODE1}\"},
                \"evictionStrategy\": \"LiveMigrate\"
              }
            }
          }
        }"

        virtctl start "$VM" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM 배포 완료 (노드: ${NODE1})"
    done
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! SNR 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  VM 배치 확인:"
    echo -e "    ${CYAN}oc get vmi -n ${NS} -o wide${NC}"
    echo ""
    echo -e "  NHC 상태 확인:"
    echo -e "    ${CYAN}oc get nodehealthcheck poc-snr-nhc${NC}"
    echo ""
    echo -e "  장애 시뮬레이션:"
    echo -e "    ${CYAN}oc debug node/${NODE1} -- chroot /host systemctl stop kubelet${NC}"
    echo ""
    echo -e "  SNR 발동 확인 (300초 후):"
    echo -e "    ${CYAN}oc get selfnoderemediation -A${NC}"
    echo -e "    ${CYAN}oc get nodes -w${NC}"
    echo ""
    echo -e "  자세한 내용: 08-snr.md 참조"
    echo ""
}

# =============================================================================
# 메인
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  SNR 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_snr_template
    step_nhc
    step_vms
    print_summary
}

main
