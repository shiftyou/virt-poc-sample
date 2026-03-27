#!/bin/bash
# =============================================================================
# VDDK 이미지를 OpenShift 내부 레지스트리에 Push하는 스크립트
#
# VDDK(VMware Virtual Disk Development Kit)는 VMware VM을 OpenShift로
# 마이그레이션할 때 필요합니다.
#
# 사전 조건:
#   1. VMware로부터 VDDK tar 파일 다운로드
#   2. podman 설치
#   3. 내부 레지스트리 활성화 (enable-registry.sh 실행 완료)
#
# 사용법: source ../../env.conf && ./push-vddk.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../../env.conf"

# env.conf 로드
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "[ERROR] env.conf 파일을 찾을 수 없습니다. setup.sh를 먼저 실행하세요."
    exit 1
fi

# VDDK tar 파일 경로 확인
VDDK_TAR="${SCRIPT_DIR}/VMware-vix-disklib-*.x86_64.tar.gz"
VDDK_FILES=(${VDDK_TAR})

if [ ${#VDDK_FILES[@]} -eq 0 ] || [ ! -f "${VDDK_FILES[0]}" ]; then
    echo "[ERROR] VDDK tar 파일을 찾을 수 없습니다."
    echo ""
    echo "  다음 위치에 VDDK tar 파일을 복사하세요:"
    echo "  ${SCRIPT_DIR}/VMware-vix-disklib-<version>.x86_64.tar.gz"
    echo ""
    echo "  VDDK 다운로드:"
    echo "  https://developer.vmware.com/web/sdk/8.0/vddk"
    exit 1
fi

VDDK_TAR_FILE="${VDDK_FILES[0]}"
echo "[INFO] VDDK tar 파일: $VDDK_TAR_FILE"

# 작업 디렉토리 생성
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

echo "[INFO] VDDK tar 파일 압축 해제 중..."
tar -xzf "$VDDK_TAR_FILE" -C "$WORK_DIR"

# Dockerfile 생성
cat > "$WORK_DIR/Dockerfile" << 'DOCKERFILE'
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

# VDDK 라이브러리 복사
COPY vmware-vix-disklib-distrib /vmware-vix-disklib-distrib

RUN mkdir -p /opt
RUN ln -s /vmware-vix-disklib-distrib /opt/vmware-vix-disklib-distrib
DOCKERFILE

echo "[INFO] VDDK 이미지 빌드 중..."
podman build -t vddk:latest "$WORK_DIR"

# 내부 레지스트리 로그인
echo "[INFO] 내부 레지스트리 로그인 중..."
REGISTRY="image-registry.openshift-image-registry.svc:5000"
REGISTRY_ROUTE=$(oc get route default-route -n openshift-image-registry \
    -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

if [ -n "$REGISTRY_ROUTE" ]; then
    echo "[INFO] Route를 통한 로그인: $REGISTRY_ROUTE"
    podman login -u $(oc whoami) -p $(oc whoami -t) \
        --tls-verify=false "$REGISTRY_ROUTE"
    PUSH_TARGET="$REGISTRY_ROUTE/openshift/vddk:latest"
else
    echo "[WARN] Route가 없습니다. 클러스터 내부에서 직접 push합니다."
    PUSH_TARGET="$REGISTRY/openshift/vddk:latest"
fi

echo "[INFO] VDDK 이미지 Push 중: $PUSH_TARGET"
podman push --tls-verify=false vddk:latest "$PUSH_TARGET"

echo "[OK] VDDK 이미지 Push 완료!"
echo ""
echo "  내부 레지스트리 경로: ${VDDK_IMAGE}"
echo ""
echo "  MTV(Migration Toolkit for Virtualization) 설정에서 VDDK 이미지 경로:"
echo "  ${VDDK_IMAGE}"
