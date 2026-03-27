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
    else
        DETECTED_API=""
        DETECTED_DOMAIN=""
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

# =============================================================================
# 1. 클러스터 기본 정보
# =============================================================================
print_header "1. 클러스터 기본 정보"

ask "클러스터 base domain (예: example.com)" "${DETECTED_DOMAIN:-example.com}" CLUSTER_DOMAIN
ask "API 서버 URL" "${DETECTED_API:-https://api.${CLUSTER_DOMAIN}:6443}" CLUSTER_API

# =============================================================================
# 2. htpasswd 사용자 계정
# =============================================================================
print_header "2. htpasswd 사용자 계정"

ask "관리자 계정 이름" "ocpadmin" HTPASSWD_ADMIN_USER
ask "관리자 계정 비밀번호" "Admin1234!" HTPASSWD_ADMIN_PASS "true"
ask "일반 사용자 계정 이름" "ocpuser" HTPASSWD_USER
ask "일반 사용자 비밀번호" "User1234!" HTPASSWD_USER_PASS "true"

# =============================================================================
# 3. 네트워크 설정 (NNCP / NAD)
# =============================================================================
print_header "3. 네트워크 설정 (NNCP / NAD)"

print_info "노드의 네트워크 인터페이스 확인: oc debug node/<node> -- ip link show"
ask "NNCP용 노드 네트워크 인터페이스 이름 (예: ens4, eth1)" "ens4" BRIDGE_INTERFACE
ask "생성할 Linux Bridge 이름" "br1" BRIDGE_NAME
ask "NAD 네임스페이스" "poc-nad" NAD_NAMESPACE

# =============================================================================
# 4. MinIO 설정
# =============================================================================
print_header "4. MinIO 설정 (OADP S3 backend)"

ask "MinIO Access Key" "minio" MINIO_ACCESS_KEY
ask "MinIO Secret Key" "minio123" MINIO_SECRET_KEY "true"
ask "OADP 백업 버킷 이름" "velero" MINIO_BUCKET
ask "MinIO 서비스 엔드포인트" "http://minio.poc-minio.svc.cluster.local:9000" MINIO_ENDPOINT

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

ask "Console 접근 허용 CIDR (쉼표로 구분, 예: 10.0.0.0/8,192.168.1.0/24)" "10.0.0.0/8" CONSOLE_ALLOWED_CIDRS
ask "API 서버 접근 허용 CIDR (쉼표로 구분)" "10.0.0.0/8" API_ALLOWED_CIDRS

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

# htpasswd 사용자 계정
HTPASSWD_ADMIN_USER=${HTPASSWD_ADMIN_USER}
HTPASSWD_ADMIN_PASS=${HTPASSWD_ADMIN_PASS}
HTPASSWD_USER=${HTPASSWD_USER}
HTPASSWD_USER_PASS=${HTPASSWD_USER_PASS}

# 네트워크 설정
BRIDGE_INTERFACE=${BRIDGE_INTERFACE}
BRIDGE_NAME=${BRIDGE_NAME}
NAD_NAMESPACE=${NAD_NAMESPACE}

# MinIO 설정
MINIO_ACCESS_KEY=${MINIO_ACCESS_KEY}
MINIO_SECRET_KEY=${MINIO_SECRET_KEY}
MINIO_BUCKET=${MINIO_BUCKET}
MINIO_ENDPOINT=${MINIO_ENDPOINT}

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
EOF

print_ok "env.conf 파일이 생성되었습니다: $ENV_FILE"

# =============================================================================
# 완료 메시지
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  설정 완료!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  다음 단계:"
echo -e "  1. ${CYAN}00-operators/${NC}   - Operator 설치 가이드를 참조하여 필요한 Operator를 설치하세요."
echo -e "  2. ${CYAN}01-environment/${NC} - 기본 환경을 구성하세요. (README.md 참조)"
echo -e "  3. ${CYAN}02-tests/${NC}       - 기능 테스트를 수행하세요. (README.md 참조)"
echo ""
echo -e "  YAML 적용 예시:"
echo -e "  ${YELLOW}source env.conf && envsubst < 01-environment/nncp/nncp-bridge.yaml | oc apply -f -${NC}"
echo ""
echo -e "  또는 각 디렉토리의 ${CYAN}apply.sh${NC} 를 실행하세요."
echo ""
