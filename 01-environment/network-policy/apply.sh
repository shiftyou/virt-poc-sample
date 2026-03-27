#!/bin/bash
# =============================================================================
# Network Policy 기본 설정 적용 스크립트
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Network Policy 기본 설정 적용 ==="
echo ""

# 네임스페이스 생성
echo "[1/3] 네임스페이스 생성..."
oc apply -f "${SCRIPT_DIR}/namespace.yaml"

# Deny-All 정책 적용
echo "[2/3] Deny-All 정책 적용..."
oc apply -f "${SCRIPT_DIR}/networkpolicy-deny-all.yaml"

# Allow-Same-Namespace 정책 적용
echo "[3/3] Allow-Same-Namespace 정책 적용..."
oc apply -f "${SCRIPT_DIR}/networkpolicy-allow-same-ns.yaml"

echo ""
echo "=== 기본 정책 적용 완료 ==="
echo ""
echo "현재 정책 확인:"
oc get networkpolicy -n poc-network-policy1
echo "---"
oc get networkpolicy -n poc-network-policy2
echo ""
echo "다음 단계: VM을 생성하고 시작하세요."
echo "  oc apply -f vm-ns1.yaml"
echo "  oc apply -f vm-ns2.yaml"
echo "  virtctl start network-policy1-vm -n poc-network-policy1"
echo "  virtctl start network-policy2-vm -n poc-network-policy2"
