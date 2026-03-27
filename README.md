# virt-poc-sample

OpenShift 4.20 Virtualization 기능 테스트를 위한 POC(Proof of Concept) 샘플 모음입니다.

airgap 환경에서 GitHub으로부터 다운로드 후 바로 사용할 수 있도록 YAML, Shell 스크립트, 가이드 문서로 구성되어 있습니다.

---

## 문서 목록

### 사전 준비
- [00-init/README.md](00-init/README.md) — Operator 설치 순서 및 개요
- [00-init/01-make-template.md](00-init/01-make-template.md) — POC용 커스텀 VM 이미지 생성
- [00-init/pvc-to-qcow2.md](00-init/pvc-to-qcow2.md) — qcow2 ↔ openshift-virtualization-os-images 변환 가이드

### 환경 구성

**기본 환경**
- [01-environment/htpasswd/README.md](01-environment/htpasswd/README.md) — htpasswd 사용자 생성
- [01-environment/vm-template/README.md](01-environment/vm-template/README.md) — VM 템플릿 생성
- [01-environment/image-registry/README.md](01-environment/image-registry/README.md) — 내부 이미지 레지스트리 + VDDK
- [01-environment/nncp/README.md](01-environment/nncp/README.md) — NodeNetworkConfigurationPolicy
- [01-environment/nad/README.md](01-environment/nad/README.md) — NetworkAttachmentDefinition
- [01-environment/far/README.md](01-environment/far/README.md) — Fence Agents Remediation
- [01-environment/snr/README.md](01-environment/snr/README.md) — Self Node Remediation + NHC
- [01-environment/oadp/README.md](01-environment/oadp/README.md) — OADP 설정
- [01-environment/minio/README.md](01-environment/minio/README.md) — MinIO (S3 백엔드)
- [01-environment/grafana/README.md](01-environment/grafana/README.md) — Grafana 모니터링

**기능 테스트**
- [01-environment/console-ip-restriction/README.md](01-environment/console-ip-restriction/README.md) — Console 접근 IP 제한
- [01-environment/resource-limits/README.md](01-environment/resource-limits/README.md) — LimitRange + ResourceQuota
- [01-environment/descheduler/README.md](01-environment/descheduler/README.md) — Descheduler 설정
- [01-environment/alerts/README.md](01-environment/alerts/README.md) — PrometheusRule Alert
- [01-environment/network-policy/README.md](01-environment/network-policy/README.md) — NetworkPolicy
- [01-environment/oadp-backup-restore/README.md](01-environment/oadp-backup-restore/README.md) — VM 백업/복원
- [01-environment/cpu-overcommit/README.md](01-environment/cpu-overcommit/README.md) — CPU Overcommit
- [01-environment/node-maintenance/README.md](01-environment/node-maintenance/README.md) — 노드 유지보수
- [01-environment/node-exporter/README.md](01-environment/node-exporter/README.md) — Node Exporter
- [01-environment/vm-snapshot/README.md](01-environment/vm-snapshot/README.md) — VM 스냅샷/복원
- [01-environment/multus-network/README.md](01-environment/multus-network/README.md) — Multus 멀티 네트워크
- [01-environment/storage-dv/README.md](01-environment/storage-dv/README.md) — DataVolume + StorageProfile

---

## 전제 조건

- OpenShift 4.20 이상
- \`oc\` 명령어로 클러스터에 로그인된 상태
- cluster-admin 권한

---

## 빠른 시작

\`\`\`bash
# 1. 저장소 clone
git clone https://github.com/shiftyou/virt-poc-sample.git
cd virt-poc-sample

# 2. 환경 설정 (env.conf 생성)
./setup.sh

# 3. Operator 설치 (가이드 참조)
# → 00-init/README.md

# 4. 환경 구성
# → 01-environment/README.md
\`\`\`

---

## YAML 적용 방식

\`setup.sh\` 실행 후 생성된 \`env.conf\`의 변수를 YAML에 치환하여 적용합니다.

\`\`\`bash
# rendered/ 디렉토리의 파일 바로 적용
oc apply -f rendered/01-environment/nncp/nncp-bridge.yaml

# 또는 각 디렉토리의 apply.sh 실행
cd 01-environment/nncp && ./apply.sh
\`\`\`

---

## 디렉토리 구조

\`\`\`
virt-poc-sample/
├── README.md
├── setup.sh                    # 환경 변수 수집 및 env.conf 생성
├── setup-kr.sh                 # 환경 변수 수집 및 env.conf 생성 (한글)
├── env.conf.example
│
├── 00-init/                    # 사전 준비
│   ├── 01-openshift-virtualization.md
│   ├── 02-oadp-operator.md
│   ├── 03-far-operator.md
│   ├── 04-snr-operator.md
│   ├── 05-descheduler-operator.md
│   ├── 06-nhc-operator.md
│   ├── 07-node-maintenance-operator.md
│   ├── 08-nmstate-operator.md
│   ├── 09-grafana-operator.md
│   ├── custom-vm-image.md
│   └── pvc-to-qcow2.md
│
└── 01-environment/             # 환경 구성
    ├── htpasswd/               # htpasswd 사용자 생성
    ├── vm-template/            # VM 템플릿 생성
    ├── image-registry/         # 내부 이미지 레지스트리 + VDDK
    ├── nncp/                   # NodeNetworkConfigurationPolicy
    ├── nad/                    # NetworkAttachmentDefinition
    ├── far/                    # Fence Agents Remediation
    ├── snr/                    # Self Node Remediation
    ├── oadp/                   # OADP 설정
    ├── minio/                  # MinIO (S3 backend)
    ├── grafana/                # Grafana 모니터링
    ├── console-ip-restriction/ # Console 접근 IP 제한
    ├── resource-limits/        # LimitRange + ResourceQuota
    ├── descheduler/            # Descheduler 설정
    ├── alerts/                 # PrometheusRule Alert
    ├── network-policy/         # NetworkPolicy
    ├── oadp-backup-restore/    # VM 백업/복원
    ├── cpu-overcommit/         # CPU Overcommit
    ├── node-maintenance/       # 노드 유지보수
    ├── node-exporter/          # Node Exporter
    ├── vm-snapshot/            # VM 스냅샷/복원
    ├── multus-network/         # Multus 멀티 네트워크
    └── storage-dv/             # DataVolume + StorageProfile
\`\`\`

---

## 네임스페이스 목록

| 항목 | 네임스페이스 |
|------|-------------|
| htpasswd | (클러스터 수준) |
| NNCP | (클러스터 수준) |
| NAD | poc-nad |
| FAR | openshift-workload-availability |
| SNR | openshift-workload-availability |
| OADP | openshift-adp |
| MinIO | poc-minio |
| Grafana | poc-grafana |
| Console IP 제한 | (클러스터 수준) |
| Resource Limits | poc-resource-limits |
| Descheduler | openshift-kube-descheduler-operator |
| Alerts | poc-alerts |
| Network Policy | poc-netpol |
| OADP 백업/복원 테스트 | poc-oadp-test |
| CPU Overcommit | (클러스터 수준) |
| Node Exporter | (기존 openshift-monitoring) |
| VM Snapshot | poc-vm-snapshot |
| Multus Network | poc-multus |
| Storage DV | poc-storage-dv |

---

## 참고 문서

- [OpenShift Virtualization 공식 문서](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/index)
- [OADP 공식 문서](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/backup_and_restore/index)
- [OpenShift Networking 공식 문서](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/networking/index)
