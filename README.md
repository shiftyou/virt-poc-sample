# virt-poc-sample

OpenShift Virtualization POC(Proof of Concept) 샘플 모음입니다.

---

## 빠른 시작

```bash
# 1. 저장소 clone
git clone https://github.com/shiftyou/virt-poc-sample.git
cd virt-poc-sample

# 2. rhel9-poc-golden.qcow2 파일 다운로드(1.8G)
https://mega.nz/file/qpAnGZoJ#-P_M8SkNvL_X8wktZQ5cE-KcwSjrDwrcxPxf1Nyvqvw
혹은
wget http://krssa.ddns.net/vm-images/rhel9-poc-golden.qcow2
mv rhel9-poc-golden.qcow2 ./vm-images/

# 3. 환경 설정 (env.conf 생성)
./setup.sh

# 4. 전체 순서대로 실행
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
| Cluster Observability Operator (COO) | OperatorHub → "Cluster Observability Operator" | 네임스페이스 독립 모니터링 사용 시 |

---

## 환경 구성 단계

| 순서 | 디렉토리 | 설명 |
|---------|---------------------------|------|
| 01 | [01-template](01-template/01-template.md) | RHEL9 qcow2 → DataVolume → DataSource → Template 등록 |
| 02 | [02-network](02-network/02-network.md) | NNCP Linux Bridge 생성 + NAD 등록 + poc 템플릿으로 NAD 보조 네트워크 VM 생성 |
| 03 | [03-vm-management](03-vm-management/03-vm-management.md) | 네임스페이스 + NAD 준비, VM 생성·스토리지·네트워크·Static IP·Live Migration |
| 04 | [04-multitenancy](04-multitenancy/04-multitenancy.md) | 멀티 테넌트 — 네임스페이스 2개·사용자 4명·RBAC(admin/view)·VM 각 1개 |
| 05 | [05-network-policy](05-network-policy/05-network-policy.md) | NetworkPolicy 실습 — Deny All / Allow Same NS / Allow IP |
| 06 | [06-resource-quota](06-resource-quota/06-resource-quota.md) | ResourceQuota 실습 — CPU·Memory·Pod·PVC 제한 |
| 07 | [07-descheduler](07-descheduler/07-descheduler.md) | Descheduler 실습 — VM 3개를 Live Migration으로 TEST_NODE에 집중 후 트리거 VM으로 과부하 유발 → 자동 재배치 |
| 08 | [08-liveness-probe](08-liveness-probe/08-liveness-probe.md) | VM Liveness/Readiness Probe 실습 — HTTP(port 1500)·TCP·Exec Probe 설정 및 실패 시 자동 재시작 |
| 09 | [09-alert](09-alert/09-alert.md) | VM Alert 실습 — PrometheusRule로 VM 상태 알림 (VMNotRunning·VMStuckPending·VMLowMemory) |
| 10 | [10-node-exporter](10-node-exporter/10-node-exporter.md) | Node Exporter 실습 — poc 템플릿 VM 생성 + node-exporter Service + ServiceMonitor 등록 |
| 11 | [11-monitoring](11-monitoring/11-monitoring.md) | 모니터링 실습 — OpenShift Console·COO MonitoringStack·Grafana·Dell/Hitachi 스토리지 모니터링 |
| 12 | [12-mtv](12-mtv/12-mtv.md) | MTV 실습 — VMware → OpenShift 마이그레이션 (Hot-plug 비활성화·CBT·Windows 빠른시작 등 체크리스트) |
| 13 | [13-oadp](13-oadp/13-oadp.md) | OADP 실습 — VM 백업/복원 (MinIO S3 backend·DataProtectionApplication·Schedule) |
| 14 | [14-node-maintenance](14-node-maintenance/14-node-maintenance.md) | Node Maintenance 실습 — NodeMaintenance 생성으로 노드 cordon+drain → VM 자동 Live Migration → 유지보수 완료 후 uncordon |
| 15 | [15-snr](15-snr/15-snr.md) | SNR 실습 — NHC가 비정상 노드 감지 → SelfNodeRemediation으로 노드 자가 재시작 (IPMI 불필요) |
| 16 | [16-far](16-far/16-far.md) | FAR 실습 — NHC가 비정상 노드 감지 → FenceAgentsRemediation으로 IPMI/BMC 전원 재시작 |
| 17 | [17-add-node](17-add-node/17-add-node.md) | 워커 노드 제거 후 재조인 — kubelet 중지·노드 오브젝트 삭제·CSR 승인·재조인 확인 |
| 18 | [18-hyperconverged](18-hyperconverged/18-hyperconverged.md) | HyperConverged 설정 — CPU Overcommit 비율·Live Migration 설정·Feature Gates |
| 20 | [20-upgrade](20-upgrade/20-upgrade.md) | Airgap 환경 OCP 4.20→4.21 업그레이드 — oc-mirror·IDMS·OSUS·ClusterVersion 설정 |

> 번호 순서가 실행 순서입니다.

---

## 참고 문서

- [OpenShift Virtualization 공식 문서](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/virtualization/index)
