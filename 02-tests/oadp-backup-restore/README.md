# OADP VM 백업/복원 테스트

## 개요

OADP를 사용하여 VM을 백업하고 복원하는 절차를 테스트합니다.
Velero를 통해 VM의 정의(YAML)와 데이터 볼륨(PVC)을 모두 백업합니다.

---

## 사전 조건

- OADP 구성 완료 (`01-environment/oadp/` 참조)
- MinIO 버킷 생성 완료
- BackupStorageLocation 상태 `Available`

---

## 적용 방법

```bash
source ../../env.conf
cd 02-tests/oadp-backup-restore
./apply.sh
```

---

## 파일 설명

| 파일 | 설명 |
|------|------|
| [`namespace.yaml`](namespace.yaml) | poc-oadp-test 네임스페이스 |
| [`test-vm.yaml`](test-vm.yaml) | 백업 테스트용 Fedora VM |
| [`backup.yaml`](backup.yaml) | Velero Backup CR (poc-oadp-test 전체, CSI 스냅샷 포함) |
| [`restore.yaml`](restore.yaml) | Velero Restore CR (test-vm-backup에서 복원) |
| [`apply.sh`](apply.sh) | 적용 스크립트 |

---

## 테스트 절차

### 1. 테스트 VM 생성

```bash
# 테스트 VM 생성
oc apply -f namespace.yaml
oc apply -f test-vm.yaml

# VM 시작
oc patch vm test-backup-vm -n poc-oadp-test \
  --type merge -p '{"spec":{"running":true}}'

# VM 상태 확인
oc get vm,vmi -n poc-oadp-test
```

### 2. VM 백업 생성

```bash
# 백업 실행
oc apply -f backup.yaml

# 백업 상태 확인
oc get backup test-vm-backup -n openshift-adp

# 백업 로그 확인
oc logs -n openshift-adp deployment/velero | grep test-vm-backup
```

### 3. VM 삭제 (복원 테스트를 위해)

```bash
# VM 삭제
oc delete vm test-backup-vm -n poc-oadp-test
oc get vm -n poc-oadp-test  # 삭제 확인
```

### 4. VM 복원

```bash
# 복원 실행
oc apply -f restore.yaml

# 복원 상태 확인
oc get restore test-vm-restore -n openshift-adp

# VM 복원 확인
oc get vm -n poc-oadp-test
```

---

## 상태 확인

```bash
# 백업 목록 확인
oc get backup -n openshift-adp

# 복원 목록 확인
oc get restore -n openshift-adp

# MinIO에서 백업 파일 확인
mc ls local/${MINIO_BUCKET}/velero/backups/
```

---

## 트러블슈팅

```bash
# 백업 실패 시 Velero 로그 확인
oc logs -n openshift-adp deployment/velero --tail=100

# 백업 상세 정보 확인
oc describe backup test-vm-backup -n openshift-adp

# CSI VolumeSnapshot 확인
oc get volumesnapshot -n poc-oadp-test
```
