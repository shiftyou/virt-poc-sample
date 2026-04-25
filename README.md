# virt-poc-sample

A collection of OpenShift Virtualization POC (Proof of Concept) samples.

---

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/shiftyou/virt-poc-sample.git
cd virt-poc-sample

# 2. Configure the environment (creates env.conf)
./setup.sh

# 3. Run all steps in order
./make.sh
```

`make.sh` runs the `.sh` files in each directory in numeric order (`01-`, `02-`, ...).
To run individual steps manually, execute the `.sh` file in each directory directly.

---

## Prerequisites

- OpenShift 4.17 or later
- Logged into the cluster with the `oc` command (cluster-admin privileges)
- `virtctl` installed — Console > `?` > **Command line tools**

---

## Pre-requisites: Operator Installation

`setup.sh` automatically checks whether operators are installed when run.
For uninstalled operators, refer to the guides under `00-operator/` to install them.

| Operator | Guide | Required |
|-----------|--------|----------|
| OpenShift Virtualization | [kubevirt-hyperconverged-operator.md](00-operator/kubevirt-hyperconverged-operator.md) | Required |
| Migration Toolkit for Virtualization (MTV) | [mtv-operator.md](00-operator/mtv-operator.md) | When using VM migration |
| Kubernetes NMState | [nmstate-operator.md](00-operator/nmstate-operator.md) | Required when using NNCP/NAD |
| OADP | [oadp-operator.md](00-operator/oadp-operator.md) | When using backup/restore |
| Fence Agents Remediation | [far-operator.md](00-operator/far-operator.md) | When using node failure recovery |
| Self Node Remediation | [snr-operator.md](00-operator/snr-operator.md) | When using node auto-recovery |
| Kube Descheduler | [descheduler-operator.md](00-operator/descheduler-operator.md) | When using VM rescheduling |
| Node Health Check | [nhc-operator.md](00-operator/nhc-operator.md) | When using node health checks |
| Node Maintenance | [node-maintenance-operator.md](00-operator/node-maintenance-operator.md) | When using node maintenance |
| Grafana | [grafana-operator.md](00-operator/grafana-operator.md) | When using monitoring dashboards |
| Cluster Observability Operator (COO) | OperatorHub → "Cluster Observability Operator" | When using namespace-scoped monitoring |
| OpenShift Logging | OperatorHub → "Red Hat OpenShift Logging" | When collecting audit logs |
| Loki Operator | OperatorHub → "Loki Operator" | When using log storage (LokiStack) |

---

## Environment Setup Steps

| Order | Directory | Description |
|---------|---------------------------|------|
| 01 | [01-template](01-template/01-template.md) | RHEL9 qcow2 → DataVolume → DataSource → Template registration |
| 02 | [02-network](02-network/02-network.md) | NNCP Linux Bridge creation + NAD registration + VM with NAD secondary network using poc template |
| 03 | [03-vm-management](03-vm-management/03-vm-management.md) | Namespace + NAD preparation, VM creation, storage, networking, Static IP, Live Migration |
| 04 | [04-multitenancy](04-multitenancy/04-multitenancy.md) | Multi-tenancy — 2 namespaces, 4 users, RBAC (admin/view), 1 VM each |
| 05 | [05-network-policy](05-network-policy/05-network-policy.md) | NetworkPolicy lab — Deny All / Allow Same NS / Allow IP |
| 06 | [06-resource-quota](06-resource-quota/06-resource-quota.md) | ResourceQuota lab — CPU, Memory, Pod, PVC limits |
| 07 | [07-descheduler](07-descheduler/07-descheduler.md) | Descheduler lab — Concentrate 3 VMs on TEST_NODE via Live Migration, then trigger overload with trigger VM → automatic rescheduling |
| 08 | [08-liveness-probe](08-liveness-probe/08-liveness-probe.md) | VM Liveness/Readiness Probe lab — HTTP (port 1500), TCP, Exec Probe configuration and automatic restart on failure |
| 09 | [09-alert](09-alert/09-alert.md) | VM Alert lab — VM status notifications via PrometheusRule (VMNotRunning, VMStuckPending, VMLowMemory) |
| 10 | [10-node-exporter](10-node-exporter/10-node-exporter.md) | Node Exporter lab — Create poc template VM + node-exporter Service + ServiceMonitor registration |
| 11 | [11-monitoring](11-monitoring/11-monitoring.md) | Monitoring lab — OpenShift Console, COO MonitoringStack, Grafana, Dell/Hitachi storage monitoring |
| 12 | [12-mtv](12-mtv/12-mtv.md) | MTV lab — VMware to OpenShift migration (Hot-plug disabled, CBT, Windows quick-start checklist) |
| 13 | [13-oadp](13-oadp/13-oadp.md) | OADP lab — VM backup/restore (MinIO S3 backend, DataProtectionApplication, Schedule) |
| 14 | [14-node-maintenance](14-node-maintenance/14-node-maintenance.md) | Node Maintenance lab — Node cordon+drain via NodeMaintenance creation → VM automatic Live Migration → uncordon after maintenance |
| 15 | [15-snr](15-snr/15-snr.md) | SNR lab — NHC detects unhealthy node → SelfNodeRemediation performs node self-restart (no IPMI required) |
| 16 | [16-far](16-far/16-far.md) | FAR lab — NHC detects unhealthy node → FenceAgentsRemediation performs IPMI/BMC power restart |
| 17 | [17-add-node](17-add-node/17-add-node.md) | Worker node removal and rejoin — stop kubelet, delete node object, approve CSR, verify rejoin |
| 18 | [18-hyperconverged](18-hyperconverged/18-hyperconverged.md) | HyperConverged configuration — CPU Overcommit ratio, Live Migration settings, Feature Gates |
| 19 | [19-logging](19-logging/19-logging.md) | Audit Logging lab — APIServer Audit Policy configuration, ClusterLogging, LokiStack, ClusterLogForwarder setup |
| 20 | [20-upgrade](20-upgrade/20-upgrade.md) | Airgap OCP 4.20→4.21 upgrade — oc-mirror, IDMS, OSUS, ClusterVersion configuration |

> The numeric order is the execution order.

---

## Reference Documentation

- [OpenShift Virtualization Official Documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/virtualization/index)
