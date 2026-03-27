# 01-environment: 기본 환경 구성

OpenShift Virtualization POC를 위한 기본 환경을 구성합니다.

## 구성 순서

1. [htpasswd](./htpasswd/README.md) - 사용자 계정 생성
2. [image-registry](./image-registry/README.md) - 내부 이미지 레지스트리 + VDDK
3. [vm-template](./vm-template/README.md) - VM 템플릿 생성
4. [nncp](./nncp/README.md) - 노드 네트워크 구성 (Bridge)
5. [nad](./nad/README.md) - NetworkAttachmentDefinition
6. [minio](./minio/README.md) - MinIO S3 백엔드
7. [oadp](./oadp/README.md) - OADP DataProtectionApplication
8. [far](./far/README.md) - Fence Agents Remediation
9. [snr](./snr/README.md) - Self Node Remediation
10. [grafana](./grafana/README.md) - Grafana 모니터링

## 공통 YAML 적용 방법

```bash
# 최상위 디렉토리에서
source env.conf

# 각 항목의 apply.sh 실행 예시
cd 01-environment/nncp && ./apply.sh
```
