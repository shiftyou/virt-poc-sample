# htpasswd 사용자 생성

## 개요

OpenShift에서 htpasswd Identity Provider를 사용하여 로컬 사용자 계정을 생성합니다.
기본 kubeadmin 계정 대신 관리자/일반 사용자를 생성하여 RBAC 테스트에 활용합니다.

---

## 사전 조건

- `htpasswd` 명령어 설치 (`httpd-tools` 패키지)
  ```bash
  # RHEL/CentOS
  sudo dnf install httpd-tools -y
  # macOS
  brew install httpd
  ```
- `setup.sh` 실행 후 `env.conf` 생성 완료

---

## 적용 방법

```bash
# 프로젝트 루트에서
source env.conf

# 1. htpasswd 파일 생성 및 Secret 업데이트
cd 01-environment/htpasswd
./htpasswd-create.sh

# 2. OAuth 설정 적용
envsubst < oauth-config.yaml | oc apply -f -
```

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| [`htpasswd-create.sh`](htpasswd-create.sh) | htpasswd 파일 생성 + OpenShift Secret 생성/업데이트 |
| [`htpasswd-secret.yaml`](htpasswd-secret.yaml) | htpasswd Secret 템플릿 |
| [`oauth-config.yaml`](oauth-config.yaml) | OAuth IdentityProvider 설정 |
| [`consoleYamlSample.yaml`](consoleYamlSample.yaml) | Console에서 직접 적용 가능한 샘플 |

---

## 상태 확인

```bash
# OAuth 설정 확인
oc get oauth cluster -o yaml

# htpasswd Secret 확인
oc get secret htpasswd-secret -n openshift-config

# 사용자 목록 확인
oc get users

# 특정 사용자 로그인 테스트
oc login -u ${HTPASSWD_ADMIN_USER} -p ${HTPASSWD_ADMIN_PASS} ${CLUSTER_API}

# 현재 로그인 사용자 확인
oc whoami
```

---

## 권한 부여

```bash
# 관리자 계정에 cluster-admin 권한 부여
oc adm policy add-cluster-role-to-user cluster-admin ${HTPASSWD_ADMIN_USER}

# 일반 사용자에 특정 네임스페이스 edit 권한 부여
oc adm policy add-role-to-user edit ${HTPASSWD_USER} -n <namespace>

# 사용자의 ClusterRoleBinding 확인
oc get clusterrolebinding | grep ${HTPASSWD_ADMIN_USER}
```

---

## 트러블슈팅

```bash
# OAuth 서버 Pod 확인
oc get pods -n openshift-authentication

# OAuth 서버 로그 확인
oc logs -n openshift-authentication deployment/oauth-openshift

# Identity 확인
oc get identity

# 사용자-Identity 매핑 확인
oc get useridentitymapping
```

---

## 모든 namespace에서 사용 가능한 Template 위치

VM Template을 모든 네임스페이스에서 사용하려면 **`openshift` 네임스페이스**에 생성해야 합니다.

```bash
# openshift 네임스페이스의 Template 목록
oc get template -n openshift

# 특정 namespace에서 openshift namespace의 template 사용
oc process -n openshift <template-name> | oc apply -f -
```
