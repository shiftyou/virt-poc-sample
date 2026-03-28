#!/bin/bash
# =============================================================================
# 06-descheduler.sh
#
# Descheduler 실습 환경 구성
#   1. poc-descheduler 네임스페이스 생성
#   2. poc 템플릿으로 3개 VM을 TEST_NODE에 배포
#      - vm-1, vm-2 : descheduler 대상
#      - vm-fixed   : PDB로 보호 (descheduler 제외)
#   3. KubeDescheduler — LifecycleAndUtilization / High / 네임스페이스 한정
#   4. TEST_NODE의 CPU/Memory 현황 분석 → 트리거 VM 리소스 산출
#   5. 트리거 VM 배포 → 노드 임계값 초과 → Descheduler 발동
#
# 사용법: ./06-descheduler.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# env.conf 자동 로드 (단독 실행 시)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-descheduler"
NODE1="${TEST_NODE}"           # env.conf 의 TEST_NODE 사용
DESCHEDULER_NS="openshift-kube-descheduler-operator"

# 초기 VM CPU request (각 250m)
VM_CPU_REQUEST="250m"
VM_MEM_REQUEST="512Mi"

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

    if ! oc get node "$NODE1" &>/dev/null; then
        print_error "노드 $NODE1 를 찾을 수 없습니다. env.conf 의 TEST_NODE 를 확인하세요."
        exit 1
    fi
    print_ok "대상 노드: $NODE1"

    if [ "${DESCHEDULER_INSTALLED:-false}" != "true" ]; then
        print_warn "DESCHEDULER_INSTALLED=false — KubeDescheduler 설치를 확인하세요."
        print_warn "00-operator/descheduler-operator.md 참조"
    else
        print_ok "Kube Descheduler Operator 확인"
    fi

    print_info "  NS    : ${NS}"
    print_info "  NODE1 : ${NODE1}"
}

# =============================================================================
# 1단계: 네임스페이스 생성
# =============================================================================
step_namespace() {
    print_step "1/5  네임스페이스 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "네임스페이스 $NS 이미 존재 — 스킵"
    else
        oc new-project "$NS"
        print_ok "네임스페이스 $NS 생성 완료"
    fi
}

# =============================================================================
# 2단계: 3개 VM 배포 (NODE1 고정)
# =============================================================================
step_vms() {
    print_step "2/5  VM 3개 배포 (노드: ${NODE1})"

    # vm-1, vm-2: descheduler 대상 / vm-fixed: annotation으로 descheduler 제외
    for VM in poc-descheduler-vm-1 poc-descheduler-vm-2 poc-descheduler-vm-fixed; do
        if oc get vm "$VM" -n "$NS" &>/dev/null; then
            print_ok "VM $VM 이미 존재 — 스킵"
            continue
        fi

        # poc 템플릿으로 VM 생성
        oc process -n openshift poc -p NAME="$VM" | oc apply -n "$NS" -f -

        # nodeSelector + CPU/Memory request + LiveMigrate 전략 패치
        oc patch vm "$VM" -n "$NS" --type=merge -p "{
          \"spec\": {
            \"template\": {
              \"spec\": {
                \"nodeSelector\": {\"kubernetes.io/hostname\": \"${NODE1}\"},
                \"evictionStrategy\": \"LiveMigrate\",
                \"domain\": {
                  \"resources\": {
                    \"requests\": {
                      \"cpu\": \"${VM_CPU_REQUEST}\",
                      \"memory\": \"${VM_MEM_REQUEST}\"
                    }
                  }
                }
              }
            }
          }
        }"

        # vm-fixed: descheduler 제외 annotation 추가
        if [ "$VM" = "poc-descheduler-vm-fixed" ]; then
            oc patch vm "$VM" -n "$NS" --type=merge -p '{
              "spec": {
                "template": {
                  "metadata": {
                    "annotations": {
                      "descheduler.alpha.kubernetes.io/evict": "false"
                    }
                  }
                }
              }
            }'
            print_info "  → descheduler.alpha.kubernetes.io/evict: false 적용"
        fi

        virtctl start "$VM" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM 배포 완료 (node: ${NODE1}, cpu: ${VM_CPU_REQUEST})"
    done
}

# =============================================================================
# 3단계: KubeDescheduler 설정 (LifecycleAndUtilization / High / 네임스페이스 한정)
# =============================================================================
step_descheduler() {
    print_step "3/4  KubeDescheduler 설정"

    cat > kubedescheduler.yaml <<'EOF'
apiVersion: operator.openshift.io/v1
kind: KubeDescheduler
metadata:
  name: cluster
  namespace: openshift-kube-descheduler-operator
spec:
  deschedulingIntervalSeconds: 60
  profiles:
    - LifecycleAndUtilization
  profileCustomizations:
    devLowNodeUtilizationThresholds: High
    namespaces:
      included:
        - poc-descheduler
EOF
    echo "생성된 파일: kubedescheduler.yaml"
    oc apply -f kubedescheduler.yaml
    print_ok "KubeDescheduler 설정 완료"
    print_info "  Profile   : LifecycleAndUtilization"
    print_info "  Threshold : High (underutilized <40%, overutilized >60%)"
    print_info "  Interval  : 60초"
    print_info "  Namespace : ${NS}"
}

# =============================================================================
# 5단계: 노드 리소스 분석 → 트리거 VM 산출 및 배포
# =============================================================================
step_trigger_vm() {
    print_step "4/4  트리거 VM 배포 (노드 임계값 초과)"

    print_info "${NODE1} 리소스 현황 분석 중..."

    # Allocatable CPU → 밀리코어
    ALLOC_CPU_RAW=$(oc get node "$NODE1" -o jsonpath='{.status.allocatable.cpu}')
    if [[ "$ALLOC_CPU_RAW" == *m ]]; then
        ALLOC_CPU="${ALLOC_CPU_RAW%m}"
    else
        ALLOC_CPU=$(awk "BEGIN{printf \"%d\", ${ALLOC_CPU_RAW}*1000}")
    fi

    # Allocatable Memory → MiB
    ALLOC_MEM_RAW=$(oc get node "$NODE1" -o jsonpath='{.status.allocatable.memory}')
    ALLOC_MEM_MIB=$(echo "$ALLOC_MEM_RAW" | awk '
        /Ki$/ { printf "%d", $0/1024; next }
        /Mi$/ { printf "%d", $0; next }
        /Gi$/ { printf "%d", $0*1024; next }
    ')

    # 현재 노드의 CPU requests 합산 (밀리코어)
    USED_CPU=$(oc get pods --all-namespaces \
        --field-selector="spec.nodeName=${NODE1}" \
        -o jsonpath='{range .items[*].spec.containers[*]}{.resources.requests.cpu}{"\n"}{end}' \
        2>/dev/null | awk '
        /^[0-9]+m$/ { sum += substr($0,1,length($0)-1); next }
        /^[0-9]+(\.[0-9]+)?$/ { sum += $0*1000; next }
        END { print int(sum) }')

    # 현재 노드의 Memory requests 합산 (MiB)
    USED_MEM_MIB=$(oc get pods --all-namespaces \
        --field-selector="spec.nodeName=${NODE1}" \
        -o jsonpath='{range .items[*].spec.containers[*]}{.resources.requests.memory}{"\n"}{end}' \
        2>/dev/null | awk '
        /^[0-9]+Ki$/ { sum += substr($0,1,length($0)-2)/1024; next }
        /^[0-9]+Mi$/ { sum += substr($0,1,length($0)-2); next }
        /^[0-9]+Gi$/ { sum += substr($0,1,length($0)-2)*1024; next }
        /^[0-9]+$/ { sum += $0/1048576; next }
        END { print int(sum) }')

    CPU_PCT=$((USED_CPU * 100 / ALLOC_CPU))
    MEM_PCT=$((USED_MEM_MIB * 100 / ALLOC_MEM_MIB))

    print_info "  Allocatable CPU  : ${ALLOC_CPU}m"
    print_info "  Allocatable Mem  : ${ALLOC_MEM_MIB}Mi"
    print_info "  Used CPU requests: ${USED_CPU}m  (${CPU_PCT}%)"
    print_info "  Used Mem requests: ${USED_MEM_MIB}Mi (${MEM_PCT}%)"
    print_info "  Descheduler 임계값: overutilized > 60%"

    # 61% 초과를 위해 필요한 추가 CPU requests 계산
    THRESHOLD_CPU=$((ALLOC_CPU * 61 / 100))
    NEEDED_CPU=$((THRESHOLD_CPU - USED_CPU))

    THRESHOLD_MEM=$((ALLOC_MEM_MIB * 61 / 100))
    NEEDED_MEM=$((THRESHOLD_MEM - USED_MEM_MIB))

    if [ "$NEEDED_CPU" -le 0 ]; then
        print_warn "이미 CPU 61% 초과 상태 — 소규모 트리거 VM 배포"
        TRIGGER_CPU="250m"
    else
        TRIGGER_CPU="${NEEDED_CPU}m"
    fi

    if [ "$NEEDED_MEM" -le 0 ]; then
        TRIGGER_MEM="256Mi"
    else
        TRIGGER_MEM="${NEEDED_MEM}Mi"
    fi

    print_ok "트리거 VM 리소스 산출"
    print_info "  TRIGGER_CPU : ${TRIGGER_CPU}  (노드 ${NODE1} CPU를 61% 이상으로)"
    print_info "  TRIGGER_MEM : ${TRIGGER_MEM}"

    if oc get vm poc-descheduler-vm-trigger -n "$NS" &>/dev/null; then
        print_ok "트리거 VM 이미 존재 — 스킵"
        return
    fi

    oc process -n openshift poc -p NAME="poc-descheduler-vm-trigger" | oc apply -n "$NS" -f -

    oc patch vm poc-descheduler-vm-trigger -n "$NS" --type=merge -p "{
      \"spec\": {
        \"template\": {
          \"spec\": {
            \"nodeSelector\": {\"kubernetes.io/hostname\": \"${NODE1}\"},
            \"evictionStrategy\": \"LiveMigrate\",
            \"domain\": {
              \"resources\": {
                \"requests\": {
                  \"cpu\": \"${TRIGGER_CPU}\",
                  \"memory\": \"${TRIGGER_MEM}\"
                }
              }
            }
          }
        }
      }
    }"

    virtctl start poc-descheduler-vm-trigger -n "$NS" 2>/dev/null || true
    print_ok "트리거 VM poc-descheduler-vm-trigger 배포 완료"
    print_info "  → Descheduler 가 ${NODE1} 를 overutilized 로 감지하면"
    print_info "    vm-1, vm-2 가 다른 노드로 Live Migration 됩니다."
    print_info "    vm-fixed 는 PDB 로 보호되어 이동되지 않습니다."
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! Descheduler 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  VM 노드 배치 확인:"
    echo -e "    ${CYAN}oc get vmi -n ${NS} -o wide${NC}"
    echo ""
    echo -e "  Descheduler 동작 확인 (60초 후):"
    echo -e "    ${CYAN}oc get vmi -n ${NS} -o wide --watch${NC}"
    echo ""
    echo -e "  예상 결과:"
    echo -e "    poc-descheduler-vm-1       → 다른 노드로 Migration"
    echo -e "    poc-descheduler-vm-2       → 다른 노드로 Migration"
    echo -e "    poc-descheduler-vm-fixed   → ${NODE1} 유지 (PDB 보호)"
    echo -e "    poc-descheduler-vm-trigger → ${NODE1} 유지 (가장 최근 배포)"
    echo ""
    echo -e "  자세한 내용: 06-descheduler.md 참조"
    echo ""
}

# =============================================================================
# 메인
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Descheduler 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_vms
    step_descheduler
    step_trigger_vm
    print_summary
}

main
