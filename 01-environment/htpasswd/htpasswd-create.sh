#!/bin/bash
# =============================================================================
# htpasswd 사용자 생성 및 OpenShift Secret 업데이트 스크립트
#
# 사용법: source ../../env.conf && ./htpasswd-create.sh
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

HTPASSWD_FILE="${SCRIPT_DIR}/users.htpasswd"

echo "[INFO] htpasswd 파일 생성 중..."

# htpasswd 파일 초기화 (관리자 계정)
htpasswd -c -B -b "$HTPASSWD_FILE" "$HTPASSWD_ADMIN_USER" "$HTPASSWD_ADMIN_PASS"

# 일반 사용자 추가
htpasswd -B -b "$HTPASSWD_FILE" "$HTPASSWD_USER" "$HTPASSWD_USER_PASS"

echo "[OK] htpasswd 파일 생성 완료: $HTPASSWD_FILE"

# OpenShift Secret 생성 또는 업데이트
if oc get secret htpasswd-secret -n openshift-config &>/dev/null; then
    echo "[INFO] 기존 htpasswd-secret 업데이트 중..."
    oc set data secret/htpasswd-secret \
        --from-file=htpasswd="$HTPASSWD_FILE" \
        -n openshift-config
    echo "[OK] htpasswd-secret 업데이트 완료"
else
    echo "[INFO] htpasswd-secret 생성 중..."
    oc create secret generic htpasswd-secret \
        --from-file=htpasswd="$HTPASSWD_FILE" \
        -n openshift-config
    echo "[OK] htpasswd-secret 생성 완료"
fi

# OAuth 설정 적용
echo "[INFO] OAuth 설정 적용 중..."
envsubst < "${SCRIPT_DIR}/oauth-config.yaml" | oc apply -f -

echo ""
echo "[OK] htpasswd 설정 완료!"
echo ""
echo "  관리자 계정: ${HTPASSWD_ADMIN_USER}"
echo "  일반 사용자: ${HTPASSWD_USER}"
echo ""
echo "  cluster-admin 권한 부여:"
echo "  oc adm policy add-cluster-role-to-user cluster-admin ${HTPASSWD_ADMIN_USER}"
echo ""
echo "  로그인 테스트:"
echo "  oc login -u ${HTPASSWD_ADMIN_USER} ${CLUSTER_API}"
