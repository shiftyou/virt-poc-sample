# VM Liveness Probe 실습

KubeVirt의 Liveness / Readiness Probe를 VM에 설정하여
VM 내부 HTTP 서버 응답을 기반으로 자동 재시작 및 트래픽 차단을 실습합니다.

```
VM (poc-liveness-vm)
  │
  ├─ livenessProbe  — httpGet :1500  → 실패 시 VM 자동 재시작
  └─ readinessProbe — httpGet :1500  → 실패 시 Service 트래픽 차단
         │
         └─ virt-probe (KubeVirt 내부 에이전트)
              └─ VMI 내부 IP로 직접 HTTP 요청
```

---

## KubeVirt Probe 동작 방식

Kubernetes Pod의 Probe와 달리, KubeVirt VM Probe는 **virt-probe** 프로세스가
VMI(VirtualMachineInstance) 내부 IP로 직접 연결합니다.

| 항목 | Pod Probe | KubeVirt VM Probe |
|------|-----------|-------------------|
| 실행 주체 | kubelet | virt-probe (KubeVirt) |
| 대상 | 컨테이너 포트 | VMI 내부 IP:포트 |
| 지원 유형 | HTTP / TCP / Exec | HTTP / TCP / Exec |
| Liveness 실패 시 | 컨테이너 재시작 | VM 재시작 (VirtualMachine CR) |
| Readiness 실패 시 | Service 엔드포인트 제외 | Service 엔드포인트 제외 |

> **port 1500 사용 이유**
> pod network masquerade 환경에서 port 80은 virt-probe의 직접 접속이 제한될 수 있습니다.
> VM 내부에서 1500 포트로 HTTP 서버를 실행하여 Probe를 구성합니다.

---

## 사전 조건

- `01-template` 완료 — poc Template 및 DataSource 등록
- `07-liveness-probe.sh` 실행 완료

```bash
oc get template poc -n openshift
oc get namespace poc-liveness-probe
```

---

## Probe 설정 내용

```yaml
spec:
  template:
    spec:
      readinessProbe:
        httpGet:
          port: 1500
        initialDelaySeconds: 120   # VM 부팅 대기
        periodSeconds: 20
        timeoutSeconds: 10
        failureThreshold: 3
        successThreshold: 3
      livenessProbe:
        httpGet:
          port: 1500
        initialDelaySeconds: 120
        periodSeconds: 20
        timeoutSeconds: 10
        failureThreshold: 3        # 3회 연속 실패 → VM 재시작
```

### 파라미터 설명

| 파라미터 | 값 | 설명 |
|----------|----|------|
| `initialDelaySeconds` | 120 | VM 부팅 후 첫 Probe까지 대기 시간 |
| `periodSeconds` | 20 | Probe 실행 주기 |
| `timeoutSeconds` | 10 | 응답 대기 제한 시간 |
| `failureThreshold` | 3 | 연속 실패 횟수 초과 시 조치 |
| `successThreshold` | 3 | (Readiness) 연속 성공 횟수 초과 시 Ready |

---

## 실습 순서

### 1. VM 기동 및 콘솔 접속

```bash
# VM 상태 확인
oc get vm,vmi -n poc-liveness-probe

# 콘솔 접속
virtctl console poc-liveness-vm -n poc-liveness-probe
```

### 2. VM 내부에서 HTTP 서버 실행

poc 황금 이미지에는 **httpd(port 80)** 가 설치되어 있습니다.
Probe 테스트를 위해 추가로 **1500 포트 HTTP 서버**를 실행합니다.

```bash
# VM 내부에서 실행 (cloud-user로 로그인 후)
python3 -m http.server 1500 &

# 또는 소켓 기반 간이 서버 (python 미설치 시)
while true; do echo -e "HTTP/1.1 200 OK\r\n\r\nOK" | nc -l -p 1500 -q 1; done &
```

서버 확인:
```bash
curl http://localhost:1500
```

### 3. Probe 상태 확인

VM 외부(OCP 노드)에서:

```bash
# VMI conditions 확인 (ReadyIsFalse / AgentConnected 등)
oc get vmi poc-liveness-vm -n poc-liveness-probe \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.status}{"\n"}{end}'

# Probe 설정 확인
oc get vmi poc-liveness-vm -n poc-liveness-probe \
  -o jsonpath='{.spec.livenessProbe}'

# 이벤트 확인
oc describe vmi poc-liveness-vm -n poc-liveness-probe | grep -A 5 Events
```

---

## Liveness Probe 실패 시뮬레이션

### HTTP 서버 중단 → VM 자동 재시작 확인

```bash
# 1. VM 콘솔에서 HTTP 서버 중단
virtctl console poc-liveness-vm -n poc-liveness-probe
# VM 내부에서:
kill $(pgrep -f "http.server")

# 2. 외부에서 VM 상태 모니터링 (failureThreshold * periodSeconds = 60초 후 재시작)
oc get vmi poc-liveness-vm -n poc-liveness-probe -w

# 3. VM 재시작 이벤트 확인
oc get events -n poc-liveness-probe \
  --sort-by='.lastTimestamp' | tail -10
```

예상 결과:
```
NAME               AGE   PHASE     IP           NODENAME
poc-liveness-vm    2m    Running   10.128.x.x   worker-0
poc-liveness-vm    3m    Failed    <none>        worker-0   ← Probe 실패
poc-liveness-vm    3m    Running   10.128.x.x   worker-0   ← 자동 재시작
```

---

## Readiness Probe 실패 시뮬레이션

```bash
# 1. HTTP 서버 중단 (위와 동일)

# 2. VMI Ready 상태 변화 확인
oc get vmi poc-liveness-vm -n poc-liveness-probe \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# → False (Readiness 실패 시 Service 트래픽 차단)

# 3. HTTP 서버 재시작 후 Ready 복구 확인
# VM 내부:
python3 -m http.server 1500 &
```

---

## TCP Probe 예시

HTTP 대신 TCP 포트 연결 여부만 확인하는 방식:

```bash
oc patch vm poc-liveness-vm -n poc-liveness-probe --type=merge -p '{
  "spec": {
    "template": {
      "spec": {
        "livenessProbe": {
          "tcpSocket": {
            "port": 22
          },
          "initialDelaySeconds": 120,
          "periodSeconds": 20,
          "failureThreshold": 3
        }
      }
    }
  }
}'
```

> SSH(port 22)가 응답하는 동안 VM을 정상으로 판단합니다.

---

## Exec Probe 예시

VM 내부 명령어 실행 결과로 상태를 판단하는 방식:

```bash
oc patch vm poc-liveness-vm -n poc-liveness-probe --type=merge -p '{
  "spec": {
    "template": {
      "spec": {
        "livenessProbe": {
          "exec": {
            "command": ["cat", "/tmp/healthy"]
          },
          "initialDelaySeconds": 120,
          "periodSeconds": 20,
          "failureThreshold": 3
        }
      }
    }
  }
}'
```

VM 내부에서:
```bash
# 정상 상태 표시
touch /tmp/healthy

# 장애 시뮬레이션
rm /tmp/healthy
```

---

## Probe 제거

```bash
oc patch vm poc-liveness-vm -n poc-liveness-probe --type=merge -p '{
  "spec": {
    "template": {
      "spec": {
        "livenessProbe": null,
        "readinessProbe": null
      }
    }
  }
}'
```

---

## 롤백

```bash
# VM 정지 및 삭제
virtctl stop poc-liveness-vm -n poc-liveness-probe
oc delete vm poc-liveness-vm -n poc-liveness-probe

# 네임스페이스 삭제
oc delete namespace poc-liveness-probe
```

---

## 참고

- [KubeVirt Liveness and Readiness Probes](https://kubevirt.io/user-guide/virtual_machines/liveness_and_readiness_probes/)
- [OpenShift Virtualization — VM Health Checks](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/virtualization/monitoring-vms#virt-about-readiness-liveness-probes_virt-monitoring-vm-health)
