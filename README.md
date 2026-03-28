# virt-poc-sample

OpenShift Virtualization POC(Proof of Concept) 샘플 모음입니다.

---

## 빠른 시작

```bash
# 1. 저장소 clone
git clone https://github.com/shiftyou/virt-poc-sample.git
cd virt-poc-sample

# 2. 환경 설정 (env.conf 생성)
./setup.sh

# 3. 전체 순서대로 실행
./make.sh
```

`make.sh` 는 `01-`, `02-` ... 번호 순서로 각 디렉토리의 `.sh` 파일을 차례로 실행합니다.
개별 단계를 수동으로 실행하려면 각 디렉토리의 `.sh` 파일을 직접 실행하세요.

---

## 전제 조건

- OpenShift 4.17 이상
- `oc` 명령어로 클러스터에 로그인된 상태 (cluster-admin 권한)
- `virtctl` 설치 — Console > `?` > **Command line tools**

---

## 사전 준비: 오퍼레이터 설치

`setup.sh` 실행 시 오퍼레이터 설치 여부를 자동으로 확인합니다.
미설치 오퍼레이터는 `00-operator/` 하위 가이드를 참조하여 설치하세요.

| 오퍼레이터 | 가이드 | 필수 여부 |
|-----------|--------|----------|
| OpenShift Virtualization | [kubevirt-hyperconverged-operator.md](00-operator/kubevirt-hyperconverged-operator.md) | 필수 |
| Migration Toolkit for Virtualization (MTV) | [mtv-operator.md](00-operator/mtv-operator.md) | VM 마이그레이션 사용 시 |
| Kubernetes NMState | [nmstate-operator.md](00-operator/nmstate-operator.md) | NNCP/NAD 사용 시 필수 |
| OADP | [oadp-operator.md](00-operator/oadp-operator.md) | 백업/복원 사용 시 |
| Fence Agents Remediation | [far-operator.md](00-operator/far-operator.md) | 노드 장애 복구 사용 시 |
| Self Node Remediation | [snr-operator.md](00-operator/snr-operator.md) | 노드 자동 복구 사용 시 |
| Kube Descheduler | [descheduler-operator.md](00-operator/descheduler-operator.md) | VM 재배치 사용 시 |
| Node Health Check | [nhc-operator.md](00-operator/nhc-operator.md) | 노드 헬스체크 사용 시 |
| Node Maintenance | [node-maintenance-operator.md](00-operator/node-maintenance-operator.md) | 노드 유지보수 사용 시 |
| Grafana | [grafana-operator.md](00-operator/grafana-operator.md) | 모니터링 대시보드 사용 시 |

---

## 환경 구성 단계

| 순서 | 디렉토리 | 설명 |
|------|----------|------|
| 01 | [01-template](01-template/01-template.md) | RHEL9 qcow2 → DataVolume → DataSource → Template 등록 |
| 02 | [02-network](02-network/02-network.md) | NNCP Linux Bridge 생성 + NAD 등록 + poc 템플릿으로 NAD 보조 네트워크 VM 생성 |
| 03 | [03-vm-management](03-vm-management/03-vm-management.md) | 네임스페이스 + NAD 준비, VM 생성·스토리지·네트워크·Static IP·Live Migration |
| 04 | [04-network-policy](04-network-policy/04-network-policy.md) | NetworkPolicy 실습 — Deny All / Allow Same NS / Allow IP |
| 05 | [05-resource-quota](05-resource-quota/05-resource-quota.md) | ResourceQuota 실습 — CPU·Memory·Pod·PVC 제한 |
| 06 | [06-descheduler](06-descheduler/06-descheduler.md) | Descheduler 실습 — VM 3개를 Live Migration으로 TEST_NODE에 집중 후 트리거 VM으로 과부하 유발 → 자동 재배치 |
| 07 | [07-node-maintenance](07-node-maintenance/07-node-maintenance.md) | Node Maintenance 실습 — NodeMaintenance 생성으로 노드 cordon+drain → VM 자동 Live Migration → 유지보수 완료 후 uncordon |
| 08 | [08-snr](08-snr/08-snr.md) | SNR 실습 — NHC가 비정상 노드 감지 → SelfNodeRemediation으로 노드 자가 재시작 (IPMI 불필요) |
| 09 | [09-far](09-far/09-far.md) | FAR 실습 — NHC가 비정상 노드 감지 → FenceAgentsRemediation으로 IPMI/BMC 전원 재시작 |
| 10 | [10-liveness-probe](10-liveness-probe/10-liveness-probe.md) | VM Liveness/Readiness Probe 실습 — HTTP(port 1500)·TCP·Exec Probe 설정 및 실패 시 자동 재시작 |
| 11 | [11-alert](11-alert/11-alert.md) | VM Alert 실습 — PrometheusRule로 VM 상태 알림 (VMNotRunning·VMStuckPending·VMLowMemory) |
| 12 | [12-node-exporter](12-node-exporter/12-node-exporter.md) | Node Exporter 실습 — 내장 node-exporter 설명 + 커스텀 DaemonSet 추가 |
| 13 | [13-monitoring](13-monitoring/13-monitoring.md) | 모니터링 실습 — Grafana 배포·Prometheus 연동·Dell/Hitachi 스토리지 모니터링 |
| 14 | [14-oadp](14-oadp/14-oadp.md) | OADP 실습 — VM 백업/복원 (MinIO S3 backend·DataProtectionApplication·Schedule) |
| 15 | [15-hyperconverged](15-hyperconverged/15-hyperconverged.md) | HyperConverged 설정 — CPU Overcommit 비율·Live Migration 설정·Feature Gates |
| 16 | [16-mtv](16-mtv/16-mtv.md) | MTV 실습 — VMware → OpenShift 마이그레이션 (Hot-plug 비활성화·CBT·Windows 빠른시작 등 체크리스트) |

> 번호 순서가 실행 순서입니다.

---

## 디렉토리 구조

```
virt-poc-sample/
├── README.md
├── make.sh                     # 번호 순으로 전체 실행
├── setup.sh                    # 환경 변수 수집 및 env.conf 생성 (영문)
├── setup-kr.sh                 # 환경 변수 수집 및 env.conf 생성 (한글)
├── env.conf.example
│
├── 00-operator/                # 오퍼레이터 설치 가이드 (사전 준비)
│   ├── kubevirt-hyperconverged-operator.md  # 필수
│   ├── mtv-operator.md
│   ├── nmstate-operator.md
│   ├── oadp-operator.md
│   ├── far-operator.md
│   ├── snr-operator.md
│   ├── descheduler-operator.md
│   ├── nhc-operator.md
│   ├── node-maintenance-operator.md
│   └── grafana-operator.md
│
├── 01-template/                # RHEL9 황금 이미지 → Template 등록
│   ├── 01-template.md          # 가이드 문서
│   └── 01-template.sh          # 자동화 스크립트
│
├── 02-network/                 # NNCP Linux Bridge + NAD + VM 생성
│   ├── 02-network.md               # 가이드 문서
│   ├── 02-network.sh               # 자동화 스크립트 (NNCP·NAD·poc템플릿VM+NAD보조네트워크)
│   ├── consoleyamlsample-nncp.yaml # Console YAML Sample (NNCP)
│   └── consoleyamlsample-nad.yaml  # Console YAML Sample (NAD)
│
├── 03-vm-management/           # VM 생성 및 관리
│   ├── 03-vm-management.md     # 가이드 문서 (VM 생성·스토리지·네트워크·Static IP·Live Migration)
│   └── 03-vm-management.sh     # 자동화 스크립트 (네임스페이스 + NAD)
│
├── 04-network-policy/          # NetworkPolicy 실습
│   ├── 04-network-policy.md    # 가이드 문서
│   ├── 04-network-policy.sh    # 자동화 스크립트 (NS·NAD·정책·VM 배포)
│   └── netpol-allow-from-ns1-ip.yaml  # NS1→NS2 IP 허용 정책 (IP 수정 후 적용)
│
├── 05-resource-quota/          # ResourceQuota 실습
│   ├── 05-resource-quota.md    # 가이드 문서
│   ├── 05-resource-quota.sh    # 자동화 스크립트 (NS + ResourceQuota 적용)
│   └── consoleyamlsample-resourcequota.yaml  # Console YAML Sample
│
├── 06-descheduler/             # Descheduler 실습
│   ├── 06-descheduler.md       # 가이드 문서
│   └── 06-descheduler.sh       # 자동화 스크립트 (NS·VM3개·Live Migration→NODE1·Descheduler·트리거VM)
│
├── 07-node-maintenance/        # Node Maintenance 실습
│   ├── 07-node-maintenance.md  # 가이드 문서
│   └── 07-node-maintenance.sh  # 자동화 스크립트 (NS·VM2개·Live Migration→NODE1·NodeMaintenance)
│
├── 08-snr/                     # Self Node Remediation 실습
│   ├── 08-snr.md               # 가이드 문서
│   └── 08-snr.sh               # 자동화 스크립트 (NS·VM2개·SNRTemplate·NHC, SNR_INSTALLED 필요)
│
├── 09-far/                     # Fence Agents Remediation 실습
│   ├── 09-far.md               # 가이드 문서
│   └── 09-far.sh               # 자동화 스크립트 (NS·VM2개·FARTemplate·NHC, FAR_INSTALLED 필요)
│
├── 10-liveness-probe/          # VM Liveness/Readiness Probe 실습
│   ├── 10-liveness-probe.md    # 가이드 문서 (HTTP·TCP·Exec Probe·자동 재시작)
│   └── 10-liveness-probe.sh    # 자동화 스크립트 (NS·poc템플릿VM·Probe 설정)
│
├── 11-alert/                   # VM Alert 실습
│   ├── 11-alert.md             # 가이드 문서 (PrometheusRule·AlertManager)
│   └── 11-alert.sh             # 자동화 스크립트 (NS·UserWorkloadMonitoring·PrometheusRule)
│
├── 12-node-exporter/           # Node Exporter 실습
│   ├── 12-node-exporter.md     # 가이드 문서 (내장 node-exporter·커스텀 DaemonSet·textfile)
│   └── 12-node-exporter.sh     # 자동화 스크립트 (NS·SA·DaemonSet·ServiceMonitor)
│
├── 13-monitoring/              # 모니터링 실습 (Grafana·Dell·Hitachi)
│   ├── 13-monitoring.md        # 가이드 문서
│   └── 13-monitoring.sh        # 자동화 스크립트 (NS·Grafana·DataSource, GRAFANA_INSTALLED 필요)
│
├── 14-oadp/                    # OADP 백업/복원 실습
│   ├── 14-oadp.md              # 가이드 문서 (DPA·Backup·Restore·Schedule)
│   └── 14-oadp.sh              # 자동화 스크립트 (NS·Secret·DPA·BSL 확인, OADP_INSTALLED 필요)
│
├── 15-hyperconverged/          # HyperConverged 설정 실습
│   ├── 15-hyperconverged.md    # 가이드 문서 (CPU Overcommit·LiveMigration·FeatureGates)
│   └── 15-hyperconverged.sh    # 자동화 스크립트 (현재 설정 출력·변경 가이드)
│
├── 16-mtv/                     # Migration Toolkit for Virtualization 실습
│   ├── 16-mtv.md               # 가이드 문서 (체크리스트: Hot-plug·CBT·Windows·Shared Disk)
│   └── 16-mtv.sh               # 자동화 스크립트 (NS 생성·체크리스트 출력, MTV_INSTALLED 필요)
│
└── disabled/                   # 비활성 항목 (참고용)
```

---

## 참고 문서

- [OpenShift Virtualization 공식 문서](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/virtualization/index)
