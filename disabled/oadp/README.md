# OADP (OpenShift API for Data Protection) 구성

## 개요

OADP를 사용하여 VM 백업/복원 환경을 구성합니다.
MinIO를 S3 백엔드로 사용하여 VM 스냅샷과 데이터를 저장합니다.

---

## 사전 조건

- OADP Operator 설치 완료 (`00-operators/02-oadp-operator.md` 참조)
- MinIO 배포 완료 (`01-environment/minio/` 참조)
- MinIO 버킷 생성 완료

---

## 적용 방법

```bash
# 프로젝트 루트에서
source env.conf

cd 01-environment/oadp

# MinIO 엔드포인트 자동 설정 (MinIO Route 사용)
export MINIO_ENDPOINT="http://$(oc get route minio -n poc-minio -o jsonpath='{.spec.host}')"

# OADP Secret 및 DPA 생성
envsubst < oadp-dpa.yaml | oc apply -f -

# 또는 apply.sh 사용
./apply.sh
```

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| [`oadp-dpa.yaml`](oadp-dpa.yaml) | DataProtectionApplication + Cloud Credentials |
| [`backupstoragelocation.yaml`](backupstoragelocation.yaml) | BackupStorageLocation (별도 설정 시) |
| [`consoleYamlSample.yaml`](consoleYamlSample.yaml) | Console에서 직접 적용 가능한 샘플 |
| [`apply.sh`](apply.sh) | MinIO 엔드포인트 자동 설정 후 적용 |

---

## 상태 확인

```bash
# DPA 상태 확인 (Reconciled가 True여야 함)
oc get dataprotectionapplication -n openshift-adp

# BackupStorageLocation 상태 확인 (Available이어야 함)
oc get backupstoragelocation -n openshift-adp

# Velero Pod 상태 확인
oc get pods -n openshift-adp

# VolumeSnapshotLocation 확인
oc get volumesnapshotlocation -n openshift-adp

# OADP 전체 상태 확인
oc get all -n openshift-adp
```

---

## 테스트 백업

```bash
# 간단한 백업 생성 테스트
oc apply -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: test-backup
  namespace: openshift-adp
spec:
  includedNamespaces:
    - poc-oadp-test
  storageLocation: velero-sample-1
  ttl: 24h0m0s
EOF

# 백업 상태 확인
oc get backup test-backup -n openshift-adp

# 백업 로그 확인
oc logs -n openshift-adp deployment/velero | grep test-backup
```

---

## 트러블슈팅

```bash
# DPA 이벤트 확인
oc describe dataprotectionapplication velero-sample -n openshift-adp

# BackupStorageLocation 연결 오류 확인
oc describe backupstoragelocation -n openshift-adp

# Velero 로그 확인
oc logs -n openshift-adp deployment/velero --tail=100

# MinIO 연결 테스트
curl -I ${MINIO_ENDPOINT}/${MINIO_BUCKET}
```
