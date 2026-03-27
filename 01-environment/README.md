# 01-environment: 환경 구성

OpenShift Virtualization POC를 위한 환경을 구성합니다.

## 기본 환경 구성

| 항목 | 설명 |
|------|------|
| [htpasswd](./htpasswd/README.md) | 사용자 계정 생성 |
| [image-registry](./image-registry/README.md) | 내부 이미지 레지스트리 + VDDK |
| [vm-template](./vm-template/README.md) | VM 템플릿 생성 |
| [nncp](./nncp/README.md) | NodeNetworkConfigurationPolicy (Bridge) |
| [nad](./nad/README.md) | NetworkAttachmentDefinition |
| [minio](./minio/README.md) | MinIO S3 백엔드 |
| [oadp](./oadp/README.md) | OADP DataProtectionApplication |
| [far](./far/README.md) | Fence Agents Remediation |
| [snr](./snr/README.md) | Self Node Remediation + NHC |
| [grafana](./grafana/README.md) | Grafana 모니터링 |

## 기능 테스트

| 항목 | 네임스페이스 | 사전 조건 |
|------|------------|---------|
| [console-ip-restriction](./console-ip-restriction/README.md) | 클러스터 수준 | - |
| [resource-limits](./resource-limits/README.md) | poc-resource-limits | - |
| [descheduler](./descheduler/README.md) | openshift-kube-descheduler-operator | Descheduler Operator |
| [alerts](./alerts/README.md) | poc-alerts | - |
| [network-policy](./network-policy/README.md) | poc-netpol | - |
| [oadp-backup-restore](./oadp-backup-restore/README.md) | poc-oadp-test | OADP 구성 완료 |
| [cpu-overcommit](./cpu-overcommit/README.md) | 클러스터 수준 | OpenShift Virtualization |
| [node-maintenance](./node-maintenance/README.md) | - | Node Maintenance Operator |
| [node-exporter](./node-exporter/README.md) | openshift-monitoring | - |
| [vm-snapshot](./vm-snapshot/README.md) | poc-vm-snapshot | OpenShift Virtualization |
| [multus-network](./multus-network/README.md) | poc-multus | NNCP + NAD 구성 완료 |
| [storage-dv](./storage-dv/README.md) | poc-storage-dv | OpenShift Virtualization |

## 공통 YAML 적용 방법

```bash
# 최상위 디렉토리에서
source env.conf

# 각 항목의 apply.sh 실행 예시
cd 01-environment/nncp && ./apply.sh
```
