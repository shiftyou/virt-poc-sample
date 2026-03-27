#!/bin/bash
# =============================================================================
# virt-poc-sample 환경 설정 스크립트
# OpenShift Virtualization POC 테스트를 위한 환경 변수를 수집하고
# env.conf 파일을 생성합니다.
#
# 사용법: ./setup.sh
# =============================================================================

set -euo pipefail

ENV_FILE="./env.conf"
EXAMPLE_FILE="./env.conf.example"

# 색상 출력 설정
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 값 입력 함수: prompt 메시지, 기본값, 변수명
ask() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local is_secret="${4:-false}"

    if [ "$is_secret" = "true" ]; then
        echo -n -e "${YELLOW}  $prompt${NC} [기본값: ****]: "
        read -s input_val
        echo ""
    else
        echo -n -e "${YELLOW}  $prompt${NC} [기본값: ${default}]: "
        read input_val
    fi

    if [ -z "$input_val" ]; then
        input_val="$default"
    fi

    eval "$var_name='$input_val'"
}

# oc 명령어 확인
check_oc() {
    if ! command -v oc &> /dev/null; then
        print_warn "oc 명령어를 찾을 수 없습니다. OpenShift 클러스터 연결 없이 설정만 저장합니다."
        return 1
    fi

    if ! oc whoami &> /dev/null; then
        print_warn "OpenShift 클러스터에 로그인되어 있지 않습니다. 설정만 저장합니다."
        return 1
    fi

    print_ok "OpenShift 클러스터 연결 확인: $(oc whoami)"
    return 0
}

# 오퍼레이터 설치 확인
check_operators() {
    print_header "사전 준비: 오퍼레이터 설치 확인"

    DESCHEDULER_INSTALLED=false
    FAR_INSTALLED=false
    NMO_INSTALLED=false
    NHC_INSTALLED=false
    SNR_INSTALLED=false

    if check_oc 2>/dev/null; then
        oc get csv -A 2>/dev/null > /tmp/_poc_csv.txt || true

        grep -qi "kube-descheduler"          /tmp/_poc_csv.txt 2>/dev/null && DESCHEDULER_INSTALLED=true
        grep -qi "fence-agents-remediation"  /tmp/_poc_csv.txt 2>/dev/null && FAR_INSTALLED=true
        grep -qi "node-maintenance"          /tmp/_poc_csv.txt 2>/dev/null && NMO_INSTALLED=true
        grep -qi "node-healthcheck"          /tmp/_poc_csv.txt 2>/dev/null && NHC_INSTALLED=true
        grep -qi "self-node-remediation"     /tmp/_poc_csv.txt 2>/dev/null && SNR_INSTALLED=true
        rm -f /tmp/_poc_csv.txt
    else
        print_warn "클러스터에 연결되지 않아 오퍼레이터 상태를 확인할 수 없습니다."
        print_info "오퍼레이터 설치 방법: 00-init/README.md 참조"
        echo ""
        return
    fi

    local ok="${GREEN}[✔]${NC}"
    local ng="${RED}[✘]${NC}"
    local wa="${YELLOW}[~]${NC}"

    echo ""
    printf "  %-45s %s\n" "오퍼레이터" "상태"
    echo "  ──────────────────────────────────────────────────────────"
    if [ "$DESCHEDULER_INSTALLED" = "true" ]; then
        echo -e "  $ok Kube Descheduler Operator          → descheduler 구성 가능"
    else
        echo -e "  $ng Kube Descheduler Operator          → descheduler 구성 건너뜀  (00-init/05-descheduler-operator.md)"
    fi
    if [ "$FAR_INSTALLED" = "true" ]; then
        echo -e "  $ok Fence Agents Remediation           → FAR 구성 가능"
    else
        echo -e "  $ng Fence Agents Remediation           → FAR 구성 건너뜀  (00-init/03-far-operator.md)"
    fi
    if [ "$NMO_INSTALLED" = "true" ]; then
        echo -e "  $ok Node Maintenance Operator          → 노드 유지보수 가능"
    else
        echo -e "  $ng Node Maintenance Operator          → 노드 유지보수 건너뜀  (00-init/07-node-maintenance-operator.md)"
    fi
    if [ "$NHC_INSTALLED" = "true" ] && [ "$SNR_INSTALLED" = "true" ]; then
        echo -e "  $ok NHC + Self Node Remediation        → SNR 구성 가능"
    elif [ "$NHC_INSTALLED" = "true" ]; then
        echo -e "  $wa NHC (설치됨) / SNR (없음)           → SNR 구성 불완전  (00-init/04-snr-operator.md)"
    elif [ "$SNR_INSTALLED" = "true" ]; then
        echo -e "  $wa SNR (설치됨) / NHC (없음)           → SNR 구성 불완전  (00-init/06-nhc-operator.md)"
    else
        echo -e "  $ng NHC + Self Node Remediation        → SNR 구성 건너뜀  (00-init/04-snr-operator.md)"
    fi
    echo "  ──────────────────────────────────────────────────────────"
    echo ""
}

# 클러스터 정보 자동 감지
auto_detect_cluster() {
    if check_oc; then
        DETECTED_API=$(oc whoami --show-server 2>/dev/null || echo "")
        DETECTED_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null | sed 's/^apps\.//' || echo "")
        if [ -n "$DETECTED_API" ]; then
            print_info "감지된 API 서버: $DETECTED_API"
        fi
        if [ -n "$DETECTED_DOMAIN" ]; then
            print_info "감지된 클러스터 도메인: $DETECTED_DOMAIN"
        fi

        # 스토리지클래스 자동 감지: virtualization 전용 → ceph-rbd 계열 → 기본값 순
        DETECTED_SC=$(oc get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | \
            grep -i "virtualization" | head -1 || true)
        if [ -z "$DETECTED_SC" ]; then
            DETECTED_SC=$(oc get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | \
                grep -i "ceph-rbd" | head -1 || true)
        fi
        if [ -z "$DETECTED_SC" ]; then
            DETECTED_SC=$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
        fi
        if [ -n "$DETECTED_SC" ]; then
            print_info "감지된 스토리지클래스: $DETECTED_SC"
        fi
        ALL_SC=$(oc get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | tr '\n' ' ' || echo "")
        if [ -n "$ALL_SC" ]; then
            print_info "사용 가능한 스토리지클래스: $ALL_SC"
        fi

        # 노드 네트워크 인터페이스 자동 감지
        # 방법 1: NodeNetworkState (NMState operator, 빠름)
        FIRST_WORKER_FOR_NNS=$(oc get nodes -l node-role.kubernetes.io/worker \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        DETECTED_IFACES=""
        if [ -n "$FIRST_WORKER_FOR_NNS" ]; then
            DETECTED_IFACES=$(oc get nns "$FIRST_WORKER_FOR_NNS" \
                -o jsonpath='{range .status.currentState.interfaces[?(@.type=="ethernet")]}{.name}{"\n"}{end}' \
                2>/dev/null | grep -vE '^(br-ex|ovs-system)' | tr '\n' ' ' | xargs || true)
        fi
        # 방법 2: oc debug node (폴백, 느림 ~30초)
        if [ -z "$DETECTED_IFACES" ] && [ -n "$FIRST_WORKER_FOR_NNS" ]; then
            print_info "NodeNetworkState 없음 → oc debug node 로 인터페이스 감지 중 (약 30초)..."
            DETECTED_IFACES=$(oc debug node/"$FIRST_WORKER_FOR_NNS" -- \
                chroot /host ip -o link show 2>/dev/null | \
                awk -F': ' '{print $2}' | \
                grep -vE '^(lo|ovs-system|br-ex|br-int|genev_sys|veth|tun|docker|ovn)' | \
                grep -E '^(ens|eth|eno|enp|em|bond)' | tr '\n' ' ' | xargs || true)
        fi
        DETECTED_IFACE=$(echo "$DETECTED_IFACES" | awk '{print $1}')
        if [ -n "$DETECTED_IFACES" ]; then
            print_info "감지된 네트워크 인터페이스 (노드: $FIRST_WORKER_FOR_NNS): $DETECTED_IFACES"
        fi
    else
        DETECTED_API=""
        DETECTED_DOMAIN=""
        DETECTED_SC=""
        DETECTED_IFACE=""
        DETECTED_IFACES=""
    fi
}

# =============================================================================
# 메인 실행
# =============================================================================

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  OpenShift Virtualization POC 환경 설정${NC}"
echo -e "${GREEN}  virt-poc-sample setup.sh${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""

# 기존 env.conf 확인
if [ -f "$ENV_FILE" ]; then
    print_warn "기존 env.conf 파일이 존재합니다."
    echo -n -e "${YELLOW}  덮어쓰시겠습니까? (y/N): ${NC}"
    read overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
        print_info "설정을 취소했습니다. 기존 env.conf 파일을 사용합니다."
        exit 0
    fi
fi

# 클러스터 자동 감지
auto_detect_cluster

# 오퍼레이터 설치 확인
check_operators

# =============================================================================
# 1. 클러스터 기본 정보
# =============================================================================
print_header "1. 클러스터 기본 정보"

ask "클러스터 base domain (예: example.com)" "${DETECTED_DOMAIN:-example.com}" CLUSTER_DOMAIN
ask "API 서버 URL" "${DETECTED_API:-https://api.${CLUSTER_DOMAIN}:6443}" CLUSTER_API

# =============================================================================
# 2. 네트워크 설정 (NNCP / NAD)
# =============================================================================
print_header "2. 네트워크 설정 (NNCP / NAD)"

if [ -n "${DETECTED_IFACES:-}" ]; then
    print_info "감지된 인터페이스 목록: $DETECTED_IFACES"
else
    print_info "노드의 네트워크 인터페이스 확인: oc debug node/<node> -- ip link show"
fi
ask "NNCP용 노드 네트워크 인터페이스 이름 (예: ens4, eth1)" "${DETECTED_IFACE:-ens4}" BRIDGE_INTERFACE
ask "생성할 Linux Bridge 이름" "br1" BRIDGE_NAME
ask "NAD 네임스페이스" "poc-nad" NAD_NAMESPACE

# =============================================================================
# 3. MinIO 설정
# =============================================================================
print_header "3. MinIO 설정 (OADP S3 backend)"

ask "MinIO Access Key" "minio" MINIO_ACCESS_KEY
ask "MinIO Secret Key" "minio123" MINIO_SECRET_KEY "true"
ask "OADP 백업 버킷 이름" "velero" MINIO_BUCKET
ask "MinIO 서비스 엔드포인트" "http://minio.poc-minio.svc.cluster.local:9000" MINIO_ENDPOINT

# =============================================================================
# 4. 스토리지클래스
# =============================================================================
print_header "4. 스토리지클래스 설정"

ask "VM 이미지 업로드에 사용할 스토리지클래스" "${DETECTED_SC:-ocs-external-storagecluster-ceph-rbd}" STORAGE_CLASS

# =============================================================================
# 5. VDDK 이미지
# =============================================================================
print_header "5. VDDK 이미지 설정"

print_info "VDDK 이미지를 내부 레지스트리에 push하는 방법: 01-environment/image-registry/README.md 참조"
ask "VDDK 이미지 경로" "image-registry.openshift-image-registry.svc:5000/openshift/vddk:latest" VDDK_IMAGE

# =============================================================================
# 6. Console / API 접근 IP 제한
# =============================================================================
print_header "6. Console / API 접근 IP 제한"

ask "Console 접근 허용 CIDR (쉼표로 구분, 예: 10.0.0.0/8,192.168.1.0/24)" "0.0.0.0/0" CONSOLE_ALLOWED_CIDRS
ask "API 서버 접근 허용 CIDR (쉼표로 구분)" "0.0.0.0/0" API_ALLOWED_CIDRS

# =============================================================================
# 7. Fence Agents Remediation
# =============================================================================
print_header "7. Fence Agents Remediation (FAR)"

ask "IPMI/BMC IP 주소" "192.168.1.100" FENCE_AGENT_IP
ask "IPMI 사용자 이름" "admin" FENCE_AGENT_USER
ask "IPMI 비밀번호" "password" FENCE_AGENT_PASS "true"

# =============================================================================
# 8. 노드 정보
# =============================================================================
print_header "8. 노드 정보"

# 노드 자동 감지
if check_oc 2>/dev/null; then
    DETECTED_WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$DETECTED_WORKERS" ]; then
        print_info "감지된 워커 노드: $DETECTED_WORKERS"
        FIRST_WORKER=$(echo $DETECTED_WORKERS | awk '{print $1}')
    else
        FIRST_WORKER="worker-0"
    fi
else
    DETECTED_WORKERS=""
    FIRST_WORKER="worker-0"
fi

ask "워커 노드 이름 목록 (공백으로 구분)" "${DETECTED_WORKERS:-worker-0 worker-1 worker-2}" WORKER_NODES
ask "테스트용 단일 노드 이름" "${FIRST_WORKER:-worker-0}" TEST_NODE

# =============================================================================
# 9. Grafana
# =============================================================================
print_header "9. Grafana 설정"

ask "Grafana admin 비밀번호" "grafana123" GRAFANA_ADMIN_PASS "true"

# =============================================================================
# env.conf 파일 저장
# =============================================================================
print_header "env.conf 저장 중..."

cat > "$ENV_FILE" << EOF
# =============================================================================
# virt-poc-sample 환경 설정 파일
# setup.sh 에 의해 자동 생성됨: $(date)
# 이 파일은 .gitignore 에 등록되어 있으므로 git에 커밋되지 않습니다.
# =============================================================================

# 클러스터 기본 정보
CLUSTER_DOMAIN=${CLUSTER_DOMAIN}
CLUSTER_API=${CLUSTER_API}

# 네트워크 설정
BRIDGE_INTERFACE=${BRIDGE_INTERFACE}
BRIDGE_NAME=${BRIDGE_NAME}
NAD_NAMESPACE=${NAD_NAMESPACE}

# MinIO 설정
MINIO_ACCESS_KEY=${MINIO_ACCESS_KEY}
MINIO_SECRET_KEY=${MINIO_SECRET_KEY}
MINIO_BUCKET=${MINIO_BUCKET}
MINIO_ENDPOINT=${MINIO_ENDPOINT}

# 스토리지클래스
STORAGE_CLASS=${STORAGE_CLASS}

# VDDK 이미지
VDDK_IMAGE=${VDDK_IMAGE}

# Console / API 접근 IP 제한
CONSOLE_ALLOWED_CIDRS=${CONSOLE_ALLOWED_CIDRS}
API_ALLOWED_CIDRS=${API_ALLOWED_CIDRS}

# Fence Agents Remediation
FENCE_AGENT_IP=${FENCE_AGENT_IP}
FENCE_AGENT_USER=${FENCE_AGENT_USER}
FENCE_AGENT_PASS=${FENCE_AGENT_PASS}

# 노드 정보
WORKER_NODES="${WORKER_NODES}"
TEST_NODE=${TEST_NODE}

# Grafana
GRAFANA_ADMIN_PASS=${GRAFANA_ADMIN_PASS}

# 오퍼레이터 설치 여부 (setup.sh 실행 시 자동 감지)
DESCHEDULER_INSTALLED=${DESCHEDULER_INSTALLED:-false}
FAR_INSTALLED=${FAR_INSTALLED:-false}
NMO_INSTALLED=${NMO_INSTALLED:-false}
NHC_INSTALLED=${NHC_INSTALLED:-false}
SNR_INSTALLED=${SNR_INSTALLED:-false}
EOF

print_ok "env.conf 파일이 생성되었습니다: $ENV_FILE"

# =============================================================================
# rendered yaml 생성
# =============================================================================
print_header "환경변수 적용된 YAML 생성 중..."

RENDERED_DIR="./rendered"

# 기존 rendered 디렉토리 정리
if [ -d "$RENDERED_DIR" ]; then
    rm -rf "$RENDERED_DIR"
fi

# env.conf 로드
set -a
# shellcheck source=./env.conf
source "$ENV_FILE"
set +a

RENDERED_COUNT=0

# env.conf 변수 목록만 envsubst에 전달 (OpenShift Template 파라미터 보호)
# ${NAME}, ${NAMESPACE} 등 OpenShift Template 파라미터를 치환하지 않음
ENVSUBST_VARS=$(grep -E '^[A-Z_]+=' "$ENV_FILE" | cut -d= -f1 | \
    awk '{printf "${%s} ", $1}')

# 렌더링 대상:
#   1. 환경변수 플레이스홀더(${...})가 포함된 yaml 파일
#   2. 모든 consoleYamlSample.yaml 파일 (env vars 없어도 rendered/ 에 복사)
while IFS= read -r yaml_file; do
    # 상대 경로 계산
    rel_path="${yaml_file#./}"
    out_file="${RENDERED_DIR}/${rel_path}"
    out_dir="$(dirname "$out_file")"

    mkdir -p "$out_dir"
    envsubst "$ENVSUBST_VARS" < "$yaml_file" > "$out_file"
    print_ok "  생성: $out_file"
    RENDERED_COUNT=$((RENDERED_COUNT + 1))
done < <({ grep -rl '\${' . --include="*.yaml" --exclude-dir=rendered 2>/dev/null; \
           find . -name "consoleYamlSample.yaml" -not -path "*/rendered/*" 2>/dev/null; \
         } | sort -u)

print_ok "총 ${RENDERED_COUNT}개 YAML 파일이 rendered/ 에 생성되었습니다."

# =============================================================================
# 완료 메시지
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  설정 완료!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  다음 단계:"
echo -e ""
echo -e "  ${CYAN}[사전 준비]${NC}"
echo -e "  1. 00-init/README.md              — 오퍼레이터 설치 확인 및 설치 가이드"
echo -e "  2. 00-init/custom-vm-image.md     — POC용 커스텀 VM 이미지 생성 가이드"
echo -e "  3. 00-init/pvc-to-qcow2.md        — qcow2 업로드 및 openshift-virtualization-os-images 등록"
echo -e ""
echo -e "  ${CYAN}[환경 구성]${NC}"
echo -e "  4. 01-environment/README.md       — 기본 환경 구성"
echo -e ""
echo -e "  ${CYAN}[기능 테스트]${NC} (오퍼레이터 설치 필요 항목)"

if [ "${DESCHEDULER_INSTALLED:-false}" = "true" ]; then
    echo -e "  ${GREEN}[✔]${NC} 02-tests/descheduler/           — Descheduler 테스트 가능"
else
    echo -e "  ${RED}[✘]${NC} 02-tests/descheduler/           — Kube Descheduler Operator 미설치 (건너뜀)"
fi
if [ "${FAR_INSTALLED:-false}" = "true" ]; then
    echo -e "  ${GREEN}[✔]${NC} 01-environment/far/             — FAR 구성 가능"
else
    echo -e "  ${RED}[✘]${NC} 01-environment/far/             — Fence Agents Remediation 미설치 (건너뜀)"
fi
if [ "${NMO_INSTALLED:-false}" = "true" ]; then
    echo -e "  ${GREEN}[✔]${NC} 02-tests/node-maintenance/      — 노드 유지보수 테스트 가능"
else
    echo -e "  ${RED}[✘]${NC} 02-tests/node-maintenance/      — Node Maintenance Operator 미설치  (00-init/07-node-maintenance-operator.md)"
fi
if [ "${NHC_INSTALLED:-false}" = "true" ] && [ "${SNR_INSTALLED:-false}" = "true" ]; then
    echo -e "  ${GREEN}[✔]${NC} 01-environment/snr/             — SNR 구성 가능"
else
    echo -e "  ${RED}[✘]${NC} 01-environment/snr/             — NHC + SNR Operator 미설치 (건너뜀)"
fi
echo ""
echo -e "  환경변수가 적용된 최종 YAML:"
echo -e "  ${CYAN}rendered/${NC} 디렉토리에서 각 YAML을 바로 적용할 수 있습니다."
echo ""
echo -e "  YAML 적용 예시:"
echo -e "  ${YELLOW}oc apply -f rendered/01-environment/nncp/nncp-bridge.yaml${NC}"
echo ""
echo -e "  또는 각 디렉토리의 ${CYAN}apply.sh${NC} 를 실행하세요."
echo ""
