# Node Exporter 실습

VM(Linux) 내부에 node_exporter를 직접 설치하고, OpenShift에서 해당 메트릭을 수집할 수 있도록 Service를 등록하는 과정을 설명합니다.

---

## 구성 개요

```
VM (Linux)                          OpenShift
┌─────────────────────┐             ┌──────────────────────────────┐
│  node_exporter      │             │  Namespace: poscodx4         │
│  (systemd service)  │◄────────────│                              │
│  :9100/metrics      │             │  Service: node-exporter-service│
└─────────────────────┘             │  selector: monitor: metrics  │
                                    └──────────────────────────────┘
```

- node_exporter는 VM 내부에 **바이너리 + systemd** 방식으로 설치합니다.
- 최신 릴리즈: https://github.com/prometheus/node_exporter/releases
- OpenShift에는 VM Pod를 가리키는 **ClusterIP Service**를 등록합니다.

---

## 1. VM에 node_exporter 설치

VM(또는 Bare-metal 호스트)에 SSH로 접속한 뒤 `node-exporter-install.sh`를 실행합니다.

```bash
# 기본 버전(1.10.2)으로 설치
bash node-exporter-install.sh

# 특정 버전 지정
VERSION=1.10.2 bash node-exporter-install.sh
```

### 설치 과정 요약

| 단계 | 내용 |
|------|------|
| 1 | GitHub Releases에서 바이너리 다운로드 |
| 2 | `/usr/bin/node_exporter`로 압축 해제 |
| 3 | 전용 시스템 유저 `node_exporter` 생성 |
| 4 | 파일 소유권 설정 |
| 5 | systemd 서비스 파일 생성 (`/etc/systemd/system/node_exporter.service`) |
| 6 | 서비스 활성화 및 시작 (`systemctl enable --now`) |

### 설치 확인

```bash
# 서비스 상태 확인
systemctl status node_exporter

# 메트릭 수집 확인
curl http://localhost:9100/metrics | head -20

# 주요 메트릭 확인
curl -s http://localhost:9100/metrics | grep -E '^node_(cpu|memory|filesystem|load)'
```

---

## 2. OpenShift Service 등록

node_exporter가 설치된 VM Pod에 레이블 `monitor: metrics`가 있어야 합니다.

```bash
# VM Pod에 레이블 확인
oc get pods -n poscodx4 --show-labels | grep monitor

# 레이블이 없는 경우 추가
oc label pod <pod-name> -n poscodx4 monitor=metrics
```

Service를 적용합니다.

```bash
oc apply -f node-exporter-service.yaml
```

### Service 확인

```bash
# Service 상태
oc get svc node-exporter-service -n poscodx4

# Endpoints 확인 (VM Pod IP:9100 이 등록되어야 함)
oc get endpoints node-exporter-service -n poscodx4
```

---

## 3. 메트릭 접근 확인

```bash
# Service를 통해 메트릭 접근 (port-forward)
oc port-forward svc/node-exporter-service 9100:9100 -n poscodx4 &

curl http://localhost:9100/metrics | grep node_memory_MemAvailable_bytes
```

---

## 트러블슈팅

```bash
# node_exporter 서비스 재시작 (VM 내부)
sudo systemctl restart node_exporter
sudo journalctl -u node_exporter -f

# 방화벽 확인 (VM 내부, 9100 포트 허용 여부)
sudo firewall-cmd --list-ports
sudo firewall-cmd --add-port=9100/tcp --permanent && sudo firewall-cmd --reload

# Endpoints가 비어 있는 경우 → Pod 레이블 확인
oc describe svc node-exporter-service -n poscodx4
oc get pods -n poscodx4 --show-labels
```

---

## 롤백

```bash
# OpenShift Service 삭제
oc delete -f node-exporter-service.yaml

# VM 내부 node_exporter 제거
sudo systemctl disable --now node_exporter
sudo rm /etc/systemd/system/node_exporter.service
sudo rm /usr/bin/node_exporter
sudo userdel node_exporter
sudo systemctl daemon-reload
```
