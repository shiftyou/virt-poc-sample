#!/bin/bash
# =============================================================================
# 커스텀 이미지를 openshift-virtualization-os-images 에 등록하는 스크립트
#
# 지원 방식:
#   1. 로컬 파일 업로드  (virtctl image-upload)
#   2. HTTP/HTTPS URL   (DataVolume import)
#
# 사용법: ./upload-image.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../../env.conf"
TARGET_NS="openshift-virtualization-os-images"

# 색상 출력
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# DataSource 생성 (공통)
# openshift-virtualization-os-images 에 DataSource를 만들어야
# Virtualization UI > Templates 에서 이미지를 선택할 수 있습니다.
# =============================================================================
create_datasource() {
    local DS_NAME="$1"
    local DV_NAME="$2"

    echo ""
    print_info "DataSource 생성 중: $DS_NAME"

    oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: ${DS_NAME}
  namespace: ${TARGET_NS}
  labels:
    app: custom-os-image
spec:
  source:
    pvc:
      namespace: ${TARGET_NS}
      name: ${DV_NAME}
EOF

    print_ok "DataSource 생성 완료: ${DS_NAME}"
    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}  등록 완료!${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo ""
    echo -e "  등록된 이미지 확인:"
    echo -e "  ${CYAN}oc get datasource ${DS_NAME} -n ${TARGET_NS}${NC}"
    echo ""
    echo -e "  VM 템플릿에서 사용 방법:"
    echo -e "  ${YELLOW}sourceRef:"
    echo -e "    kind: DataSource"
    echo -e "    name: ${DS_NAME}"
    echo -e "    namespace: ${TARGET_NS}${NC}"
    echo ""
    echo -e "  Virtualization > Create VirtualMachine > From catalog 에서"
    echo -e "  '${DS_NAME}' 이미지를 선택할 수 있습니다."
    echo ""
}

# =============================================================================
# 1. 로컬 파일 업로드
# =============================================================================
upload_local() {
    echo ""
    echo -e "${CYAN}--- 로컬 파일 업로드 ---${NC}"
    echo ""

    # virtctl 확인
    if ! command -v virtctl &>/dev/null; then
        print_error "virtctl 명령어를 찾을 수 없습니다."
        echo ""
        echo "  설치 방법:"
        echo "  oc get ConsoleCLIDownload virtctl-clidownloads-kubevirt-hyperconverged \\"
        echo "    -o jsonpath='{.spec.links[0].href}'"
        echo "  또는: https://github.com/kubevirt/kubevirt/releases"
        exit 1
    fi

    echo -n -e "${YELLOW}  이미지 파일 경로 (예: /path/to/custom.qcow2): ${NC}"
    read -r IMAGE_PATH

    if [ ! -f "$IMAGE_PATH" ]; then
        print_error "파일을 찾을 수 없습니다: $IMAGE_PATH"
        exit 1
    fi

    echo -n -e "${YELLOW}  DataSource 이름 (VM 생성 시 표시될 이름, 예: my-custom-os): ${NC}"
    read -r DS_NAME

    echo -n -e "${YELLOW}  볼륨 크기 (예: 30Gi): ${NC}"
    read -r VOLUME_SIZE

    local DEFAULT_SC="${STORAGE_CLASS:-ocs-storagecluster-ceph-rbd-virtualization}"
    echo -n -e "${YELLOW}  스토리지 클래스 [${DEFAULT_SC}]: ${NC}"
    read -r SC_INPUT
    local SC="${SC_INPUT:-${DEFAULT_SC}}"

    echo ""
    print_info "이미지 업로드 시작..."
    print_info "  파일: $IMAGE_PATH"
    print_info "  DataSource: $DS_NAME"
    print_info "  크기: $VOLUME_SIZE"
    print_info "  스토리지 클래스: $SC"
    echo ""

    # virtctl image-upload 실행
    virtctl image-upload dv "${DS_NAME}-dv" \
        --image-path="$IMAGE_PATH" \
        --size="$VOLUME_SIZE" \
        --namespace="$TARGET_NS" \
        --access-mode=ReadWriteMany \
        --volume-mode=Block \
        --storage-class="$SC" \
        --wait-secs=600

    print_ok "이미지 업로드 완료"
    create_datasource "$DS_NAME" "${DS_NAME}-dv"
}

# =============================================================================
# 2. HTTP/HTTPS URL 가져오기
# =============================================================================
upload_http() {
    echo ""
    echo -e "${CYAN}--- HTTP/HTTPS URL 가져오기 ---${NC}"
    echo ""

    echo -n -e "${YELLOW}  이미지 URL (예: https://example.com/custom.qcow2): ${NC}"
    read -r IMAGE_URL

    echo -n -e "${YELLOW}  DataSource 이름 (VM 생성 시 표시될 이름, 예: my-custom-os): ${NC}"
    read -r DS_NAME

    echo -n -e "${YELLOW}  볼륨 크기 (예: 30Gi): ${NC}"
    read -r VOLUME_SIZE

    local DEFAULT_SC="${STORAGE_CLASS:-ocs-storagecluster-ceph-rbd-virtualization}"
    echo -n -e "${YELLOW}  스토리지 클래스 [${DEFAULT_SC}]: ${NC}"
    read -r SC_INPUT
    local SC="${SC_INPUT:-${DEFAULT_SC}}"

    echo ""
    print_info "DataVolume 생성 시작..."
    print_info "  URL: $IMAGE_URL"
    print_info "  DataSource: $DS_NAME"
    print_info "  크기: $VOLUME_SIZE"
    print_info "  스토리지 클래스: $SC"
    echo ""

    # DataVolume 생성
    oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${DS_NAME}-dv
  namespace: ${TARGET_NS}
  annotations:
    cdi.kubevirt.io/storage.import.requiresScratch: "true"
spec:
  source:
    http:
      url: "${IMAGE_URL}"
  storage:
    resources:
      requests:
        storage: ${VOLUME_SIZE}
    storageClassName: ${SC}
    accessModes:
      - ReadWriteMany
    volumeMode: Block
EOF

    print_info "DataVolume 임포트 대기 중 (최대 30분)..."
    if oc wait datavolume "${DS_NAME}-dv" \
        --for=condition=Ready \
        --namespace="$TARGET_NS" \
        --timeout=1800s 2>/dev/null; then
        print_ok "DataVolume 임포트 완료"
    else
        local PHASE
        PHASE=$(oc get datavolume "${DS_NAME}-dv" -n "$TARGET_NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$PHASE" = "Succeeded" ]; then
            print_ok "DataVolume 임포트 완료 (Succeeded)"
        else
            print_warn "DataVolume 상태: $PHASE"
            print_warn "상태를 직접 확인하세요: oc get dv ${DS_NAME}-dv -n ${TARGET_NS}"
            exit 1
        fi
    fi

    create_datasource "$DS_NAME" "${DS_NAME}-dv"
}

# =============================================================================
# 메인 실행
# =============================================================================

# env.conf 로드
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    print_error "env.conf 파일을 찾을 수 없습니다. setup.sh를 먼저 실행하세요."
    exit 1
fi

# oc 로그인 확인
if ! oc whoami &>/dev/null; then
    print_error "OpenShift 클러스터에 로그인되어 있지 않습니다."
    exit 1
fi

echo ""
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}  커스텀 이미지 → openshift-virtualization-os-images 등록${NC}"
echo -e "${CYAN}================================================================${NC}"
echo ""

# 업로드 방식 선택
echo -e "${YELLOW}업로드 방식을 선택하세요:${NC}"
echo "  1) 로컬 파일 업로드  (qcow2, raw, iso)"
echo "  2) HTTP/HTTPS URL   (원격 이미지 가져오기)"
echo ""
echo -n -e "${YELLOW}  선택 [1/2]: ${NC}"
read -r METHOD

case "$METHOD" in
    1) upload_local ;;
    2) upload_http ;;
    *) print_error "잘못된 선택입니다."; exit 1 ;;
esac
