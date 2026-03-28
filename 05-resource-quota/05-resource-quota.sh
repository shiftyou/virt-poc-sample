#!/bin/bash
# =============================================================================
# 05-resource-quota.sh
#
# ResourceQuota 실습 환경 구성
#   1. poc-resource-quota 네임스페이스 생성
#   2. CPU / Memory / Pod / PVC 등 ResourceQuota 적용
#   3. VM 2개 배포 (Quota 내 통과) → 3번째 VM 생성 시도 → Quota 초과 거부
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

# VM 리소스: 각 750m / 1500m → 2개=1500m(통과), 3개=2250m(초과)
VM_CPU_REQUEST="750m"
VM_CPU_LIMIT="1500m"
VM_MEM_REQUEST="1Gi"
VM_MEM_LIMIT="2Gi"

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

    print_info "  NS : ${NS}"
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
# 2단계: ResourceQuota 적용
#   requests.cpu: "2" → VM 2개(각 750m=1500m)는 통과, 3번째(2250m)는 초과
# =============================================================================
step_quota() {
    print_step "2/4  ResourceQuota 적용 (${NS})"

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
    # CPU — requests.cpu: "2" → VM 각 750m 기준 2개(1500m) 통과, 3개(2250m) 초과
    requests.cpu: "2"
    limits.cpu: "4"
    # Memory
    requests.memory: 4Gi
    limits.memory: 8Gi
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

    print_ok "ResourceQuota poc-quota 적용 완료"
    print_info "  requests.cpu 한도: 2 core (VM 2개×750m=1500m 통과, 3개=2250m 초과)"
}

# =============================================================================
# 3단계: ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    print_step "3/4  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-resourcequota.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-resource-quota
spec:
  title: "POC ResourceQuota 설정"
  description: "네임스페이스의 CPU·Memory·Pod·PVC 등 리소스 사용량을 제한합니다. 네임스페이스 생성 후 적용하세요. 초과 시 새로운 리소스 생성이 거부됩니다."
  targetResource:
    apiVersion: v1
    kind: ResourceQuota
  yaml: |
    apiVersion: v1
    kind: ResourceQuota
    metadata:
      name: poc-quota
      namespace: poc-resource-quota    # 대상 네임스페이스로 변경
    spec:
      hard:
        pods: "10"
        requests.cpu: "2"
        limits.cpu: "4"
        requests.memory: 4Gi
        limits.memory: 8Gi
        persistentvolumeclaims: "10"
        requests.storage: 100Gi
        services: "10"
        services.loadbalancers: "2"
        services.nodeports: "0"
        configmaps: "20"
        secrets: "20"
EOF
    echo "생성된 파일: consoleyamlsample-resourcequota.yaml"
    oc apply -f consoleyamlsample-resourcequota.yaml
    print_ok "ConsoleYAMLSample poc-resource-quota 등록 완료"
}

# =============================================================================
# 4단계: VM 배포 및 Quota 초과 실증
#   - poc-quota-vm-1, poc-quota-vm-2: 정상 생성 (requests.cpu 합계 1500m < 2000m)
#   - poc-quota-vm-3: 생성 시도 → Quota 초과로 거부 (2250m > 2000m)
# =============================================================================
step_vms() {
    print_step "4/4  VM 배포 및 ResourceQuota 초과 실증"

    # VM 1, 2: 정상 생성
    for VM in poc-quota-vm-1 poc-quota-vm-2; do
        if oc get vm "$VM" -n "$NS" &>/dev/null; then
            print_ok "VM $VM 이미 존재 — 스킵"
            continue
        fi

        oc process -n openshift poc -p NAME="$VM" | \
        sed 's/  running: false/  runStrategy: Halted/' > "${VM}.yaml"
        echo "생성된 파일: ${VM}.yaml"
        oc apply -n "$NS" -f "${VM}.yaml"

        ensure_runstrategy "$VM" "$NS"
        oc patch vm "$VM" -n "$NS" --type=merge -p "{
          \"spec\": {
            \"template\": {
              \"spec\": {
                \"evictionStrategy\": \"LiveMigrate\",
                \"domain\": {
                  \"resources\": {
                    \"requests\": {
                      \"cpu\": \"${VM_CPU_REQUEST}\",
                      \"memory\": \"${VM_MEM_REQUEST}\"
                    },
                    \"limits\": {
                      \"cpu\": \"${VM_CPU_LIMIT}\",
                      \"memory\": \"${VM_MEM_LIMIT}\"
                    }
                  }
                }
              }
            }
          }
        }"

        virtctl start "$VM" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM 생성 완료 (cpu request: ${VM_CPU_REQUEST})"
    done

    # VM 3: Quota 초과 실증
    VM3="poc-quota-vm-3"
    if oc get vm "$VM3" -n "$NS" &>/dev/null; then
        print_warn "VM $VM3 이미 존재 — Quota 초과 실증 스킵"
        return
    fi

    print_info ""
    print_info "━━━ Quota 초과 실증 ━━━"
    print_info "현재 requests.cpu 사용량: $(oc get resourcequota poc-quota -n "$NS" \
        -o jsonpath='{.status.used.requests\.cpu}' 2>/dev/null || echo '?') / 2"
    print_info "VM $VM3 생성 시도 (requests.cpu ${VM_CPU_REQUEST} 추가 → 초과 예상)"

    oc process -n openshift poc -p NAME="$VM3" | \
        sed 's/  running: false/  runStrategy: Halted/' > "${VM3}.yaml"
    echo "생성된 파일: ${VM3}.yaml"

    # limits 포함 patch yaml 준비 (apply 후 patch 순서이므로 apply 단계에서 거부됨)
    # virt-launcher pod 생성 시 quota 초과 → VM은 생성되나 pod 기동 불가
    oc apply -n "$NS" -f "${VM3}.yaml"

    ensure_runstrategy "$VM3" "$NS"
    oc patch vm "$VM3" -n "$NS" --type=merge -p "{
      \"spec\": {
        \"template\": {
          \"spec\": {
            \"evictionStrategy\": \"LiveMigrate\",
            \"domain\": {
              \"resources\": {
                \"requests\": {
                  \"cpu\": \"${VM_CPU_REQUEST}\",
                  \"memory\": \"${VM_MEM_REQUEST}\"
                },
                \"limits\": {
                  \"cpu\": \"${VM_CPU_LIMIT}\",
                  \"memory\": \"${VM_MEM_LIMIT}\"
                }
              }
            }
          }
        }
      }
    }"

    virtctl start "$VM3" -n "$NS" 2>/dev/null || true

    print_warn "VM $VM3 오브젝트는 생성됨 — virt-launcher Pod 기동 시 Quota 초과로 거부됩니다."
    print_info "  확인: oc get events -n ${NS} --field-selector reason=FailedCreate"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! ResourceQuota 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ResourceQuota 현황:"
    echo -e "    ${CYAN}oc describe resourcequota poc-quota -n ${NS}${NC}"
    echo ""
    echo -e "  VM 상태:"
    echo -e "    ${CYAN}oc get vm -n ${NS}${NC}"
    echo ""
    echo -e "  Quota 초과 이벤트 확인:"
    echo -e "    ${CYAN}oc get events -n ${NS} --field-selector reason=FailedCreate${NC}"
    echo ""
    echo -e "  예상 결과:"
    echo -e "    poc-quota-vm-1  → Running  (cpu request: ${VM_CPU_REQUEST})"
    echo -e "    poc-quota-vm-2  → Running  (cpu request: ${VM_CPU_REQUEST})"
    echo -e "    poc-quota-vm-3  → Pending  (virt-launcher Pod Quota 초과 거부)"
    echo ""
    echo -e "  자세한 내용: 05-resource-quota.md 참조"
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
    step_consoleyamlsamples
    step_vms
    print_summary
}

main
