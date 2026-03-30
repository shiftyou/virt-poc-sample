#!/bin/bash
# =============================================================================
# 07-liveness-probe.sh
#
# VM Liveness Probe 실습 환경 구성
#   1. poc-liveness-probe 네임스페이스 생성
#   2. poc 템플릿으로 VM 생성
#   3. VM에 HTTP Liveness Probe (port 80) 설정
#
# 사용법: ./07-liveness-probe.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-liveness-probe"
VM_NAME="poc-liveness-vm"

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

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template 이 없습니다. 01-template 을 먼저 실행하세요."
        exit 1
    fi
    print_ok "poc Template 확인"
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
# 2단계: VM 생성 (poc 템플릿 + Liveness Probe)
# =============================================================================
step_vm() {
    print_step "2/3  VM 생성 (poc 템플릿 + HTTP Liveness Probe port 80)"

    if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
        print_ok "VM $VM_NAME 이미 존재 — 스킵"
        return
    fi

    # poc 템플릿으로 VM 생성
    oc process -n openshift poc -p NAME="$VM_NAME" | \
        sed 's/  running: false/  runStrategy: Halted/' > "${VM_NAME}.yaml"
    echo "생성된 파일: ${VM_NAME}.yaml"
    oc apply -n "$NS" -f "${VM_NAME}.yaml"
    print_ok "VM $VM_NAME 생성 완료"

    # HTTP Liveness Probe (port 80) 패치
    # spec.template.spec.readinessProbe / livenessProbe → KubeVirt VMI 수준에서 지원
    ensure_runstrategy "$VM_NAME" "$NS"
    oc patch vm "$VM_NAME" -n "$NS" --type=merge -p '{
      "spec": {
        "template": {
          "spec": {
            "readinessProbe": {
              "httpGet": {
                "port": 80
              },
              "initialDelaySeconds": 120,
              "periodSeconds": 20,
              "timeoutSeconds": 10,
              "failureThreshold": 3,
              "successThreshold": 3
            },
            "livenessProbe": {
              "httpGet": {
                "port": 80
              },
              "initialDelaySeconds": 120,
              "periodSeconds": 20,
              "timeoutSeconds": 10,
              "failureThreshold": 3
            }
          }
        }
      }
    }'
    print_ok "Liveness/Readiness Probe 설정 완료 (port 80)"
    print_info "  initialDelaySeconds: 120  (VM 부팅 시간 확보)"
    print_info "  periodSeconds      : 20"
    print_info "  failureThreshold   : 3    (3회 실패 시 VM 재시작)"

    virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
    print_ok "VM $VM_NAME 시작"
}

# =============================================================================
# 3단계: Probe 확인용 서비스 안내
# =============================================================================
step_service() {
    print_step "3/3  VM 내부 httpd 포트 안내"

    print_info "KubeVirt Probe는 virt-probe가 VMI 내부 IP로 직접 접속합니다."
    print_info "httpGet.port 는 VM 내부 포트를 지정합니다 (Service 불필요)."
    echo ""
    print_info "VM 내부에서 port 80 HTTP 서버가 실행 중이어야 Probe가 성공합니다."
    print_info "poc 황금 이미지에 httpd 가 설치되어 있으면 자동으로 통과됩니다."
    echo ""
    print_info "httpd 미설치 시 VM 접속 후 간이 서버 실행:"
    echo -e "    ${CYAN}virtctl console $VM_NAME -n $NS${NC}"
    echo -e "    ${CYAN}# VM 내부에서:${NC}"
    echo -e "    ${CYAN}nohup python3 -m http.server 80 &>/dev/null &${NC}"
    echo -e "    ${CYAN}# python3 미설치 시: nohup nc -lk -p 80 -e /bin/echo &>/dev/null &${NC}"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! Liveness Probe 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  VM 상태 확인:"
    echo -e "    ${CYAN}oc get vm,vmi -n ${NS}${NC}"
    echo ""
    echo -e "  Probe 상태 확인:"
    echo -e "    ${CYAN}oc get vmi $VM_NAME -n $NS -o jsonpath='{range .status.conditions[*]}{.type}: {.status}  {.message}{\"\\n\"}{end}'${NC}"
    echo ""
    echo -e "  VM 콘솔 접속:"
    echo -e "    ${CYAN}virtctl console $VM_NAME -n $NS${NC}"
    echo ""
    echo -e "  자세한 내용: ${CYAN}10-liveness-probe.md${NC} 참조"
    echo ""
}

# =============================================================================
# 메인
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  VM Liveness Probe 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_vm
    step_service
    print_summary
}

main
