# virt-poc-sample

1

OpenShift 4.20 Virtualization 기능 테스트를 위한 POC(Proof of Concept) 샘플 모음입니다.

airgap 환경에서 GitHub으로부터 다운로드 후 바로 사용할 수 있도록 YAML, Shell 스크립트, 가이드 문서로 구성되어 있습니다.

---

## 전제 조건

- OpenShift 4.20 이상
- `oc` 명령어로 클러스터에 로그인된 상태
- cluster-admin 권한

---

## 빠른 시작

```bash
# 1. 저장소 clone
git clone https://github.com/shiftyou/virt-poc-sample.git
cd virt-poc-sample

# 2. 환경 설정 (env.conf 생성)
./setup.sh

# 3. Operator 설치 (가이드 참조)
# 00-operators/README.md 참조

# 4. 기본 환경 구성
# 01-environment/README.md 참조

# 5. 기능 테스트
# 02-tests/README.md 참조
```

---

## YAML 적용 방식

이 프로젝트는 **envsubst** 방식을 사용합니다.
`setup.sh` 실행 후 생성된 `env.conf`의 변수를 YAML에 치환하여 적용합니다.

```bash
# env.conf 로드 후 envsubst로 변수 치환하여 적용
source env.conf
envsubst < 01-environment/nncp/nncp-bridge.yaml | oc apply -f -

# 또는 각 디렉토리의 apply.sh 실행
cd 01-environment/nncp && ./apply.sh
```

---

## 디렉토리 구조

```
virt-poc-sample/
├── README.md                   # 이 파일
├── setup.sh                    # 환경 변수 수집 및 env.conf 생성
├── env.conf.example            # 환경 변수 예시 파일
│
├── 00-operators/               # Operator 설치 가이드
│   ├── 01-openshift-virtualization.md
│   ├── 02-oadp-operator.md
│   ├── 03-far-operator.md
│   ├── 04-snr-operator.md
│   └── 05-descheduler-operator.md
│
├── 01-environment/             # 기본 환경 구성
│   ├── htpasswd/               # htpasswd 사용자 생성
│   ├── vm-template/            # VM 템플릿 생성
│   ├── image-registry/         # 내부 이미지 레지스트리 + VDDK
│   ├── nncp/                   # NodeNetworkConfigurationPolicy
│   ├── nad/                    # NetworkAttachmentDefinition
│   ├── far/                    # Fence Agents Remediation
│   ├── snr/                    # Self Node Remediation
│   ├── oadp/                   # OADP 설정
│   ├── minio/                  # MinIO (S3 backend)
│   └── grafana/                # Grafana 모니터링
│
└── 02-tests/                   # 기능 테스트
    ├── console-ip-restriction/ # Console 접근 IP 제한
    ├── resource-limits/        # LimitRange + ResourceQuota
    ├── descheduler/            # Descheduler 설정
    ├── alerts/                 # PrometheusRule Alert 생성
    ├── network-policy/         # NetworkPolicy (allow/deny)
    ├── oadp-backup-restore/    # VM 백업/복원
    ├── cpu-overcommit/         # CPU Overcommit 설정
    ├── node-maintenance/       # 노드 유지보수
    ├── node-exporter/          # Node Exporter
    ├── vm-live-migration/      # VM 라이브 마이그레이션
    ├── vm-snapshot/            # VM 스냅샷/복원
    ├── multus-network/         # Multus 멀티 네트워크
    └── storage-dv/             # DataVolume + StorageProfile
```

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
| VM Live Migration | poc-live-migration |
| VM Snapshot | poc-vm-snapshot |
| Multus Network | poc-multus |
| Storage DV | poc-storage-dv |

---

## consoleYamlSample 활용

각 디렉토리의 `consoleYamlSample.yaml` 파일은 OpenShift Console에서 직접 붙여넣기 가능한 샘플 YAML입니다.

1. OpenShift Console 접속
2. 우측 상단 `+` 버튼 클릭 (Import YAML)
3. `consoleYamlSample.yaml` 내용 붙여넣기
4. `Create` 클릭

---

## 참고 문서

- [OpenShift Virtualization 공식 문서](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/index)
- [OADP 공식 문서](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/backup_and_restore/index)
- [OpenShift Networking 공식 문서](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/networking/index)
