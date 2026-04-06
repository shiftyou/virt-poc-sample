#!/bin/bash
# =============================================================================
# 16-far.sh
#
# Fence Agents Remediation (FAR) 실습 환경 구성
#   1. poc-far 네임스페이스 생성
#   2. IPMI credentials Secret 생성 (openshift-workload-availability)
#   3. FenceAgentsRemediationTemplate 생성 (IPMI 설정)
#   4. NodeHealthCheck CR 생성 (FAR 연동)
#
# 사용법: ./16-far.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-far"
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

# YAML 미리보기 후 적용
confirm_and_apply() {
    local file="$1"
    echo ""
    print_info "적용할 YAML:"
    echo "────────────────────────────────────────"
    cat "$file"
    echo "────────────────────────────────────────"
    oc apply -f "$file"
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

    if [ "${FAR_INSTALLED:-false}" != "true" ]; then
        print_warn "Fence Agents Remediation Operator 미설치 → 건너뜁니다."
        print_warn "  설치 가이드: 00-operator/far-operator.md"
        exit 77
    fi
    print_ok "Fence Agents Remediation Operator 확인"

    if [ "${NHC_INSTALLED:-false}" != "true" ]; then
        print_warn "Node Health Check Operator 미설치 → 건너뜁니다."
        print_warn "  설치 가이드: 00-operator/nhc-operator.md"
        exit 77
    fi
    print_ok "Node Health Check Operator 확인"

    if ! oc get node "$NODE1" &>/dev/null; then
        print_error "노드 $NODE1 를 찾을 수 없습니다. env.conf 의 TEST_NODE 를 확인하세요."
        exit 1
    fi
    print_ok "대상 노드: $NODE1"

    if [ -z "${FENCE_AGENT_IP:-}" ] || [ "${FENCE_AGENT_IP}" = "192.168.1.100" ]; then
        print_warn "FENCE_AGENT_IP 가 기본값입니다. env.conf 의 FENCE_AGENT_IP 를 실제 BMC IP로 변경하세요."
    else
        print_ok "FENCE_AGENT_IP: ${FENCE_AGENT_IP}"
    fi

    print_info "  NS    : ${NS}"
    print_info "  NODE1 : ${NODE1}"
    print_info "  BMC IP: ${FENCE_AGENT_IP:-미설정}"
}

# =============================================================================
# 1단계: 네임스페이스 생성
# =============================================================================
step_namespace() {
    print_step "1/3  네임스페이스 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "네임스페이스 $NS 이미 존재 — 스킵"
    else
        oc new-project "$NS" > /dev/null
        print_ok "네임스페이스 $NS 생성 완료"
    fi
}

# =============================================================================
# 2단계: IPMI credentials Secret 생성
# =============================================================================
step_secret() {
    print_step "2/4  IPMI Credentials Secret 생성 (ns: ${REMEDIATION_NS})"

    if oc get secret poc-far-credentials -n "${REMEDIATION_NS}" &>/dev/null; then
        print_ok "Secret poc-far-credentials 이미 존재 — 스킵"
        return
    fi

    cat > far-credentials-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: poc-far-credentials
  namespace: ${REMEDIATION_NS}
stringData:
  --password: "${FENCE_AGENT_PASS:-password}"
EOF
    confirm_and_apply far-credentials-secret.yaml
    print_ok "Secret poc-far-credentials 생성 완료 → ns: ${REMEDIATION_NS}"
}

# =============================================================================
# 3단계: FenceAgentsRemediationTemplate 생성
# =============================================================================
step_far_template() {
    print_step "3/4  FenceAgentsRemediationTemplate 생성"

    # 클러스터에서 워커 노드 FQDN 목록 수집
    local worker_nodes
    worker_nodes=$(oc get nodes -l node-role.kubernetes.io/worker \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || \
        echo "${WORKER_NODES:-worker-0}" | tr ' ' '\n')

    if [ -z "$worker_nodes" ]; then
        worker_nodes="${WORKER_NODES:-worker-0}"
        worker_nodes=$(echo "$worker_nodes" | tr ' ' '\n')
    fi

    # YAML 헤더 작성
    cat > far-template.yaml <<EOF
apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
kind: FenceAgentsRemediationTemplate
metadata:
  annotations:
    remediation.medik8s.io/multiple-templates-support: "true"
  name: poc-far-template
  namespace: ${REMEDIATION_NS}
spec:
  template:
    spec:
      agent: fence_ipmilan
      nodeparameters:
        --ip:
EOF

    # 노드별 BMC IP 항목 추가 (env.conf FENCE_AGENT_IP 를 공통 BMC IP로 사용)
    while IFS= read -r node; do
        [ -z "$node" ] && continue
        echo "          ${node}: ${FENCE_AGENT_IP:-192.168.1.100}" >> far-template.yaml
        print_info "  노드 → BMC IP: ${node} → ${FENCE_AGENT_IP:-192.168.1.100}"
    done <<< "$worker_nodes"

    # YAML 나머지 작성
    cat >> far-template.yaml <<EOF
      remediationStrategy: ResourceDeletion
      retrycount: 5
      retryinterval: 5s
      sharedSecretName: poc-far-credentials
      sharedparameters:
        --action: reboot
        --lanplus: ""
        --username: ${FENCE_AGENT_USER:-admin}
      timeout: 1m0s
EOF

    confirm_and_apply far-template.yaml
    print_ok "FenceAgentsRemediationTemplate poc-far-template 생성 완료"
    print_info "  agent           : fence_ipmilan"
    print_info "  sharedSecretName: poc-far-credentials (--password 포함)"
    print_info "  BMC IP          : ${FENCE_AGENT_IP:-192.168.1.100}"
}

# =============================================================================
# 3단계: NodeHealthCheck 생성
# =============================================================================
step_nhc() {
    print_step "4/5  NodeHealthCheck 생성 (FAR 연동)"

    cat > nhc-far.yaml <<EOF
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: poc-far-nhc
spec:
  minHealthy: "51%"
  remediationTemplate:
    apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
    kind: FenceAgentsRemediationTemplate
    name: poc-far-template
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
    confirm_and_apply nhc-far.yaml
    print_ok "NodeHealthCheck poc-far-nhc 생성 완료"
    print_info "  조건: Ready=False 또는 Unknown 300초 이상 → FAR 발동 (IPMI reboot)"
}

# =============================================================================
# 완료 요약
# =============================================================================
step_consoleyamlsamples() {
    print_step "5/5  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-nhc-far.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-nodehealthcheck-far
spec:
  title: "POC NodeHealthCheck (FAR 연동)"
  description: "Fence Agents Remediation과 연동하여 비정상 워커 노드를 IPMI로 자동 재부팅하는 NodeHealthCheck CR 예시입니다. Ready=False 또는 Unknown 상태가 300초 이상 지속되면 FAR이 발동됩니다."
  targetResource:
    apiVersion: remediation.medik8s.io/v1alpha1
    kind: NodeHealthCheck
  yaml: |
    apiVersion: remediation.medik8s.io/v1alpha1
    kind: NodeHealthCheck
    metadata:
      name: poc-far-nhc
    spec:
      minHealthy: "51%"
      remediationTemplate:
        apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
        kind: FenceAgentsRemediationTemplate
        name: poc-far-template
        namespace: openshift-workload-availability
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
    oc apply -f consoleyamlsample-nhc-far.yaml
    print_ok "ConsoleYAMLSample poc-nodehealthcheck-far 등록 완료"

    cat > consoleyamlsample-far-template.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-fenceagentsremediationtemplate
spec:
  title: "POC FenceAgentsRemediationTemplate (IPMI)"
  description: "fence_ipmilan을 사용하여 노드를 IPMI로 재부팅하는 FenceAgentsRemediationTemplate 예시입니다. 노드별 BMC IP와 공유 자격증명 Secret을 설정합니다."
  targetResource:
    apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
    kind: FenceAgentsRemediationTemplate
  yaml: |
    apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
    kind: FenceAgentsRemediationTemplate
    metadata:
      annotations:
        remediation.medik8s.io/multiple-templates-support: "true"
      name: poc-far-template
      namespace: openshift-workload-availability
    spec:
      template:
        spec:
          agent: fence_ipmilan
          nodeparameters:
            --ip:
              worker-0: 192.168.1.100
              worker-1: 192.168.1.101
          remediationStrategy: ResourceDeletion
          retrycount: 5
          retryinterval: 5s
          sharedSecretName: poc-far-credentials
          sharedparameters:
            --action: reboot
            --lanplus: ""
            --username: admin
          timeout: 1m0s
EOF
    oc apply -f consoleyamlsample-far-template.yaml
    print_ok "ConsoleYAMLSample poc-fenceagentsremediationtemplate 등록 완료"
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! FAR 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  NHC 상태 확인:"
    echo -e "    ${CYAN}oc get nodehealthcheck poc-far-nhc${NC}"
    echo ""
    echo -e "  IPMI 연결 테스트:"
    echo -e "    ${CYAN}ipmitool -I lanplus -H ${FENCE_AGENT_IP:-<BMC_IP>} -U ${FENCE_AGENT_USER:-admin} -P <PASS> chassis power status${NC}"
    echo ""
    echo -e "  장애 시뮬레이션:"
    echo -e "    ${CYAN}oc debug node/${NODE1} -- chroot /host systemctl stop kubelet${NC}"
    echo ""
    echo -e "  FAR 발동 확인 (300초 후):"
    echo -e "    ${CYAN}oc get fenceagentsremediation -A${NC}"
    echo -e "    ${CYAN}oc get nodes -w${NC}"
    echo ""
    echo -e "  자세한 내용: 16-far.md 참조"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: 16-far 리소스 삭제"
    local _rem_ns="openshift-workload-availability"
    oc delete project poc-far --ignore-not-found 2>/dev/null || true
    oc delete nodehealthcheck poc-far-nhc --ignore-not-found 2>/dev/null || true
    oc delete fenceagentsremediationtemplate poc-far-template -n "$_rem_ns" --ignore-not-found 2>/dev/null || true
    oc delete secret poc-far-credentials -n "$_rem_ns" --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-nodehealthcheck-far poc-fenceagentsremediationtemplate --ignore-not-found 2>/dev/null || true
    print_ok "16-far 리소스 삭제 완료"
}

# =============================================================================
# 메인
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  FAR 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_secret
    step_far_template
    step_nhc
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
