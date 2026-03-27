# 02-tests: 기능 테스트

OpenShift Virtualization 기능 테스트 모음입니다.
각 테스트는 별도의 네임스페이스에서 독립적으로 실행됩니다.

## 테스트 목록

| 번호 | 테스트 | 네임스페이스 | 사전 조건 |
|------|--------|------------|---------|
| 01 | [console-ip-restriction](./console-ip-restriction/README.md) | 클러스터 수준 | - |
| 02 | [resource-limits](./resource-limits/README.md) | poc-resource-limits | - |
| 03 | [descheduler](./descheduler/README.md) | openshift-kube-descheduler-operator | Descheduler Operator |
| 04 | [alerts](./alerts/README.md) | poc-alerts | - |
| 05 | [network-policy](./network-policy/README.md) | poc-netpol | - |
| 06 | [oadp-backup-restore](./oadp-backup-restore/README.md) | poc-oadp-test | OADP 구성 완료 |
| 07 | [cpu-overcommit](./cpu-overcommit/README.md) | 클러스터 수준 | OpenShift Virtualization |
| 08 | [node-maintenance](./node-maintenance/README.md) | - | - |
| 09 | [node-exporter](./node-exporter/README.md) | openshift-monitoring | - |
| 10 | [vm-live-migration](./vm-live-migration/README.md) | poc-live-migration | OpenShift Virtualization |
| 11 | [vm-snapshot](./vm-snapshot/README.md) | poc-vm-snapshot | OpenShift Virtualization |
| 12 | [multus-network](./multus-network/README.md) | poc-multus | NNCP + NAD 구성 완료 |
| 13 | [storage-dv](./storage-dv/README.md) | poc-storage-dv | OpenShift Virtualization |

## 공통 적용 방법

```bash
# 각 테스트 디렉토리에서
source ../../env.conf

# YAML 파일 직접 적용
envsubst < <파일>.yaml | oc apply -f -

# 또는 apply.sh 실행
./apply.sh
```

## 테스트 정리

```bash
# 특정 네임스페이스 삭제
oc delete namespace poc-<test-name>

# 모든 poc- 네임스페이스 삭제 (주의!)
oc get namespace | grep poc- | awk '{print $1}' | xargs oc delete namespace
```
