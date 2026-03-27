# Console 접근 IP 제한

## 개요

OpenShift Console 및 API 서버에 접근할 수 있는 IP 주소를 제한합니다.
`APIServer` CR에 `clientCA`와 allowedCIDRs를 설정하여 특정 IP 대역만 접근을 허용합니다.

---

## 사전 조건

- cluster-admin 권한
- `setup.sh`에서 CONSOLE_ALLOWED_CIDRS, API_ALLOWED_CIDRS 입력

> **주의:** 잘못된 설정 시 클러스터 접근이 차단될 수 있습니다.
> 현재 접속 IP가 허용 목록에 포함되어 있는지 확인 후 적용하세요.

---

## 적용 방법

```bash
# 현재 접속 IP 확인
curl ifconfig.me

# 프로젝트 루트에서
source env.conf

cd 02-tests/console-ip-restriction

# 현재 설정 확인
oc get apiserver cluster -o yaml

# IP 제한 적용
envsubst < apiserverconfig.yaml | oc apply -f -

# 또는 apply.sh 사용
./apply.sh
```

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| `apiserverconfig.yaml` | APIServer IP 제한 설정 |
| `consoleYamlSample.yaml` | Console에서 직접 적용 가능한 샘플 |

---

## 상태 확인

```bash
# APIServer 설정 확인
oc get apiserver cluster -o yaml

# Console Operator 상태 확인
oc get consoleplugin

# 적용된 IP 제한 확인
oc get apiserver cluster -o jsonpath='{.spec.clientCA}'

# Console Pod 재시작 상태 확인 (설정 변경 시 재시작됨)
oc get pods -n openshift-console
```

---

## IP 제한 해제

```bash
# IP 제한 설정 제거
oc patch apiserver cluster --type=merge -p '{"spec":{"clientCA":null}}'

# 또는 YAML에서 allowedCIDRs 제거 후 재적용
```

---

## 트러블슈팅

```bash
# Console 접근 오류 시 kube-apiserver 로그 확인
oc logs -n openshift-kube-apiserver \
  -l app=openshift-kube-apiserver \
  --tail=50 | grep -i "forbidden\|denied"

# ingress 설정 확인
oc get ingress.config cluster -o yaml

# OAuth 서버 접근 확인
oc get route oauth-openshift -n openshift-authentication
```
