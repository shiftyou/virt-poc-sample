#!/usr/bin/env bash
# =============================================================================
# sample.sh - 모든 ConsoleYAMLSample을 OpenShift 클러스터에 적용
# rendered/ 디렉토리의 consoleYamlSample.yaml 파일을 oc apply
# 사전 준비: setup.sh 를 먼저 실행하여 rendered/ 디렉토리를 생성하세요.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDERED_DIR="${SCRIPT_DIR}/rendered"

if [[ ! -d "${RENDERED_DIR}" ]]; then
  echo "[ERROR] rendered/ 디렉토리가 없습니다. setup.sh 를 먼저 실행하세요."
  exit 1
fi

echo "=== ConsoleYAMLSample 적용 시작 ==="
echo ""

COUNT=0
FAILED=0

while IFS= read -r yaml_file; do
  echo "  Applying: ${yaml_file#${RENDERED_DIR}/}"
  if oc apply -f "${yaml_file}"; then
    COUNT=$((COUNT + 1))
  else
    echo "  [ERROR] 적용 실패: ${yaml_file}"
    FAILED=$((FAILED + 1))
  fi
done < <(find "${RENDERED_DIR}" -name "consoleYamlSample.yaml" | sort)

echo ""
echo "=== 완료: ${COUNT}개 적용됨, ${FAILED}개 실패 ==="

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
