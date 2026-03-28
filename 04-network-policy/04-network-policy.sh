#!/bin/bash
# =============================================================================
# 04-network-policy.sh
#
# NetworkPolicy 실습 환경 구성
#   - poc-netpol-1, poc-netpol-2 네임스페이스 생성
#   - 각 네임스페이스에 NAD 등록
#   - Default Deny All / Allow Same Namespace 정책 적용
#   - poc 템플릿으로 각 네임스페이스에 VM 1대씩 배포
#
# 사용법: ./04-network-policy.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# env.conf 자동 로드 (단독 실행 시)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS1="poc-netpol-1"
NS2="poc-netpol-2"
BRIDGE_NAME="${BRIDGE_NAME}"

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

    # OpenShift Virtualization Operator 확인
    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator 미설치 → 건너뜁니다."
        print_warn "  설치 가이드: 00-operator/kubevirt-hyperconverged-operator.md"
        exit 77
    fi

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

    print_info "  NS1         : ${NS1}"
    print_info "  NS2         : ${NS2}"
    print_info "  BRIDGE_NAME : ${BRIDGE_NAME}"
}

# =============================================================================
# 1단계: 네임스페이스 생성
# =============================================================================
step_namespaces() {
    print_step "1/6  네임스페이스 생성"

    for NS in "$NS1" "$NS2"; do
        if oc get namespace "$NS" &>/dev/null; then
            print_ok "네임스페이스 $NS 이미 존재 — 스킵"
        else
            oc new-project "$NS" > /dev/null
            print_ok "네임스페이스 $NS 생성 완료"
        fi
    done
}

# =============================================================================
# 2단계: NAD 등록
# =============================================================================
step_nad() {
    print_step "2/6  NAD 등록 (${NS1}, ${NS2})"

    for NS in "$NS1" "$NS2"; do
        cat > "nad-${NS}.yaml" <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-bridge-nad
  namespace: ${NS}
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/${BRIDGE_NAME}
spec:
  config: '{"cniVersion":"0.3.1","name":"poc-bridge-nad","type":"cnv-bridge","bridge":"${BRIDGE_NAME}","macspoofchk":true,"ipam":{}}'
EOF
        echo "생성된 파일: nad-${NS}.yaml"
        oc apply -f "nad-${NS}.yaml"
        print_ok "NAD 등록 완료 (namespace: ${NS})"
    done
}

# =============================================================================
# 3단계: Default Deny All NetworkPolicy
# =============================================================================
step_deny_all() {
    print_step "3/6  NetworkPolicy — Default Deny All"

    for NS in "$NS1" "$NS2"; do
        cat > "netpol-deny-all-${NS}.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: ${NS}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
EOF
        echo "생성된 파일: netpol-deny-all-${NS}.yaml"
        oc apply -f "netpol-deny-all-${NS}.yaml"
        print_ok "Default Deny All 적용 완료 (namespace: ${NS})"
    done
}

# =============================================================================
# 4단계: Allow Same Namespace NetworkPolicy
# =============================================================================
step_allow_same_ns() {
    print_step "4/6  NetworkPolicy — Allow Same Namespace"

    for NS in "$NS1" "$NS2"; do
        cat > "netpol-allow-same-ns-${NS}.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: ${NS}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
EOF
        echo "생성된 파일: netpol-allow-same-ns-${NS}.yaml"
        oc apply -f "netpol-allow-same-ns-${NS}.yaml"
        print_ok "Allow Same Namespace 적용 완료 (namespace: ${NS})"
    done
}

# =============================================================================
# 5단계: VM 배포 (poc 템플릿)
# =============================================================================
step_vms() {
    print_step "5/6  VM 배포 (poc 템플릿)"

    for NS in "$NS1" "$NS2"; do
        VM_NAME="poc-vm-$(echo "$NS" | awk -F'-' '{print $NF}')"

        if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
            print_ok "VM $VM_NAME 이미 존재 (namespace: $NS) — 스킵"
            continue
        fi

        oc process -n openshift poc -p NAME="$VM_NAME" > "${VM_NAME}.yaml"
        echo "생성된 파일: ${VM_NAME}.yaml"
        oc apply -n "$NS" -f "${VM_NAME}.yaml"

        virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM_NAME 배포 완료 (namespace: $NS)"
    done
}

# =============================================================================
# 6단계: ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    print_step "6/6  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-netpol-deny-all.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-netpol-deny-all
spec:
  title: "POC NetworkPolicy — Default Deny All"
  description: "네임스페이스의 모든 Ingress/Egress를 차단합니다. 다른 허용 정책과 함께 사용하세요."
  targetResource:
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
  yaml: |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: default-deny-all
      namespace: poc-netpol-1    # 적용할 네임스페이스로 변경
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
        - Egress
EOF
    echo "생성된 파일: consoleyamlsample-netpol-deny-all.yaml"
    oc apply -f consoleyamlsample-netpol-deny-all.yaml
    print_ok "ConsoleYAMLSample poc-netpol-deny-all 등록 완료"

    cat > consoleyamlsample-netpol-allow-same-ns.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-netpol-allow-same-ns
spec:
  title: "POC NetworkPolicy — Allow Same Namespace"
  description: "같은 네임스페이스 내 Pod 간 통신을 허용합니다. Default Deny All 정책과 함께 사용하세요."
  targetResource:
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
  yaml: |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: allow-same-namespace
      namespace: poc-netpol-1    # 적용할 네임스페이스로 변경
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
        - Egress
      ingress:
        - from:
            - podSelector: {}
      egress:
        - to:
            - podSelector: {}
EOF
    echo "생성된 파일: consoleyamlsample-netpol-allow-same-ns.yaml"
    oc apply -f consoleyamlsample-netpol-allow-same-ns.yaml
    print_ok "ConsoleYAMLSample poc-netpol-allow-same-ns 등록 완료"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! NetworkPolicy 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  NetworkPolicy 확인:"
    echo -e "    ${CYAN}oc get networkpolicy -n ${NS1}${NC}"
    echo -e "    ${CYAN}oc get networkpolicy -n ${NS2}${NC}"
    echo ""
    echo -e "  VM 상태 확인:"
    echo -e "    ${CYAN}oc get vmi -n ${NS1}${NC}"
    echo -e "    ${CYAN}oc get vmi -n ${NS2}${NC}"
    echo ""
    echo -e "  다음 단계: 04-network-policy.md 참조"
    echo -e "    - VM IP 확인 후 NS1 → NS2 Allow IP 정책 적용"
    echo ""
}

# =============================================================================
# 메인
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  NetworkPolicy 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespaces
    step_nad
    step_deny_all
    step_allow_same_ns
    step_consoleyamlsamples
    step_vms
    print_summary
}

main
