#!/bin/bash
# =============================================================================
# 05-network-policy.sh
#
# NetworkPolicy (pod network) 실습 환경 구성
#
#   - 네임스페이스: poc-network-policy-1, poc-network-policy-2
#   - 정책: networking.k8s.io/v1 NetworkPolicy (pod network / eth0)
#     1. deny-all               : 모든 Ingress 차단
#     2. allow-same-network     : 같은 네임스페이스 내 Pod 간 Ingress 허용
#     3. allow-access-from-ns1  : NS2에서 NS1 네임스페이스 Pod의 Ingress 허용
#
# 사용법: ./05-network-policy.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS1="poc-network-policy-1"
NS2="poc-network-policy-2"
TOTAL_STEPS=6

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

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator 미설치 → 건너뜁니다."
        exit 77
    fi

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접속: $(oc whoami) @ $(oc whoami --show-server)"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template이 없습니다. 01-template을 먼저 실행하세요."
        exit 1
    fi
    print_ok "poc Template 확인"

    print_info "  NS1 : ${NS1}"
    print_info "  NS2 : ${NS2}"
}

# =============================================================================
# 1단계: 네임스페이스 생성
# =============================================================================
step_namespaces() {
    print_step "1/${TOTAL_STEPS}  네임스페이스 생성"

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
# 2단계: Default Deny All 정책
# =============================================================================
step_deny_all() {
    print_step "2/${TOTAL_STEPS}  Default Deny All 정책 적용"

    for NS in "$NS1" "$NS2"; do
        cat > "netpol-deny-all-${NS}.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: ${NS}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
EOF
        echo "생성된 파일: netpol-deny-all-${NS}.yaml"
        oc apply -f "netpol-deny-all-${NS}.yaml"
        print_ok "deny-all 적용 완료 (namespace: ${NS})"
    done
}

# =============================================================================
# 3단계: Allow Same Network 정책
# =============================================================================
step_allow_same_network() {
    print_step "3/${TOTAL_STEPS}  Allow Same Network 정책 적용"

    for NS in "$NS1" "$NS2"; do
        cat > "netpol-allow-same-network-${NS}.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-network
  namespace: ${NS}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
EOF
        echo "생성된 파일: netpol-allow-same-network-${NS}.yaml"
        oc apply -f "netpol-allow-same-network-${NS}.yaml"
        print_ok "allow-same-network 적용 완료 (namespace: ${NS})"
    done
}

# =============================================================================
# 4단계: Allow Access From NS1 정책 (NS2에만 적용)
# =============================================================================
step_allow_from_ns1() {
    print_step "4/${TOTAL_STEPS}  Allow Access From ${NS1} 정책 적용 (${NS2})"

    cat > "netpol-allow-from-ns1-${NS2}.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-access-from-project1
  namespace: ${NS2}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${NS1}
EOF
    echo "생성된 파일: netpol-allow-from-ns1-${NS2}.yaml"
    oc apply -f "netpol-allow-from-ns1-${NS2}.yaml"
    print_ok "allow-access-from-project1 적용 완료 (namespace: ${NS2}, 허용 출처: ${NS1})"
}

# =============================================================================
# 5단계: VM 배포
# =============================================================================
step_vms() {
    print_step "5/${TOTAL_STEPS}  VM 배포 (poc 템플릿)"

    for NS in "$NS1" "$NS2"; do
        local suffix
        suffix=$(echo "$NS" | awk -F'-' '{print $NF}')
        local VM_NAME="poc-vm-${suffix}"

        if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
            print_ok "VM $VM_NAME 이미 존재 (namespace: $NS) — 스킵"
            continue
        fi

        oc process -n openshift poc -p NAME="$VM_NAME" | \
            sed 's/runStrategy: Always/runStrategy: Halted/' | \
            sed 's/  running: false/  runStrategy: Halted/' > "${VM_NAME}-${NS}.yaml"
        echo "생성된 파일: ${VM_NAME}-${NS}.yaml"
        oc apply -n "$NS" -f "${VM_NAME}-${NS}.yaml"

        virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM_NAME 배포 완료 (namespace: $NS)"
    done
}

# =============================================================================
# 6단계: ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    print_step "6/${TOTAL_STEPS}  ConsoleYAMLSample 등록"

    # Deny All 샘플
    cat > consoleyamlsample-deny-all.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-netpol-deny-all
spec:
  title: "POC NetworkPolicy — Deny All"
  description: "네임스페이스의 모든 Ingress를 차단합니다."
  targetResource:
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
  yaml: |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: deny-all
      namespace: ${NS1}
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
EOF
    echo "생성된 파일: consoleyamlsample-deny-all.yaml"
    oc apply -f consoleyamlsample-deny-all.yaml
    print_ok "ConsoleYAMLSample poc-netpol-deny-all 등록"

    # Allow Same Network 샘플
    cat > consoleyamlsample-allow-same-network.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-netpol-allow-same-network
spec:
  title: "POC NetworkPolicy — Allow Same Network"
  description: "같은 네임스페이스 내 Pod 간 Ingress 통신을 허용합니다."
  targetResource:
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
  yaml: |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: allow-same-network
      namespace: ${NS1}
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
      ingress:
        - from:
            - podSelector: {}
EOF
    echo "생성된 파일: consoleyamlsample-allow-same-network.yaml"
    oc apply -f consoleyamlsample-allow-same-network.yaml
    print_ok "ConsoleYAMLSample poc-netpol-allow-same-network 등록"

    # Allow Access From Project1 샘플
    cat > consoleyamlsample-allow-from-project1.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-netpol-allow-from-project1
spec:
  title: "POC NetworkPolicy — Allow Access From Project1"
  description: "특정 네임스페이스(project1)에서의 Ingress 접근을 허용합니다."
  targetResource:
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
  yaml: |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: allow-access-from-project1
      namespace: ${NS2}
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
      ingress:
        - from:
            - namespaceSelector:
                matchLabels:
                  kubernetes.io/metadata.name: ${NS1}
EOF
    echo "생성된 파일: consoleyamlsample-allow-from-project1.yaml"
    oc apply -f consoleyamlsample-allow-from-project1.yaml
    print_ok "ConsoleYAMLSample poc-netpol-allow-from-project1 등록"
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
    echo -e "  적용된 NetworkPolicy:"
    echo -e "    - deny-all                  : 모든 Ingress 차단 (${NS1}, ${NS2})"
    echo -e "    - allow-same-network        : 같은 네임스페이스 내 통신 허용 (${NS1}, ${NS2})"
    echo -e "    - allow-access-from-project1: ${NS1} → ${NS2} Ingress 허용"
    echo ""
    echo -e "  정책 확인:"
    echo -e "    ${CYAN}oc get networkpolicy -n ${NS1}${NC}"
    echo -e "    ${CYAN}oc get networkpolicy -n ${NS2}${NC}"
    echo ""
    echo -e "  VM 상태 확인:"
    echo -e "    ${CYAN}oc get vmi -n ${NS1}${NC}"
    echo -e "    ${CYAN}oc get vmi -n ${NS2}${NC}"
    echo ""
    echo -e "  다음 단계: 05-network-policy.md 참조"
    echo -e "    1. VM 기동 후 VM 콘솔에서 통신 테스트"
    echo -e "    2. ${NS1} VM → ${NS2} VM: 허용 (allow-access-from-project1)"
    echo -e "    3. ${NS2} VM → ${NS1} VM: 차단 (deny-all)"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: 05-network-policy 리소스 삭제"
    oc delete project poc-network-policy-1 poc-network-policy-2 --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample \
        poc-netpol-deny-all \
        poc-netpol-allow-same-network \
        poc-netpol-allow-from-project1 \
        --ignore-not-found 2>/dev/null || true
    print_ok "05-network-policy 리소스 삭제 완료"
}

# =============================================================================
# 메인
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  05-network-policy: NetworkPolicy 실습${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespaces
    step_deny_all
    step_allow_same_network
    step_allow_from_ns1
    step_vms
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
