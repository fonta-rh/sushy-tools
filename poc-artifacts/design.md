# Design

## Problem

TNF requires Redfish-compatible BMC for Pacemaker fencing (STONITH). EC2 bare
metal instances expose no BMC/IPMI/Redfish — AWS keeps the BMC behind the Nitro
system. Three approaches were evaluated.

## Approach Comparison

| | A: Post-install fence_aws swap | B: sushy-tools EC2 driver | C: Native fence_aws in CEO |
|---|---|---|---|
| **New code** | Zero (4 pcs commands) | ~250-350 lines Python | Multi-repo Go/Ansible/API |
| **Package install** | None (fence-agents-all included) | sushy-tools on a host | None |
| **Running processes** | None extra | sushy-tools daemon (SPOF) | None |
| **Time to prototype** | Minutes | Days | Weeks/months |
| **CEO changes** | None | None | fencing.go, secrets, installer |
| **Fragility** | Don't touch fencing secrets | sushy-tools crash = no fencing | Robust |
| **Production viable** | No (dev/test only) | No (sushy-tools warns against prod) | Yes |

**Selected for dev/test: Approach B.** See project CLAUDE.md for rationale.

---

## Approach A: Post-Install fence_aws Swap (Recommended)

### Architecture

```
                     Install phase                 Post-install swap
                     ─────────────                 ──────────────────
install-config.yaml ──► CEO fencing job ──►  pcs stonith (fence_redfish, dummy)
                                                       │
                                              manual/ansible swap
                                                       │
                                                       ▼
                                              pcs stonith (fence_aws)
                                                       │
                                                       ▼ boto3
                                                  AWS EC2 API
                                                       │
                                                       ▼
                                              EC2 instance power state
```

### Procedure

#### 1. Install with dummy Redfish creds

```yaml
# install-config.yaml
fencing:
  credentials:
    - nodeName: master-0
      address: redfish+https://127.0.0.1:8000/redfish/v1/Systems/1
      username: dummy
      password: dummy
      certificateVerification: Disabled
    - nodeName: master-1
      address: redfish+https://127.0.0.1:8001/redfish/v1/Systems/1
      username: dummy
      password: dummy
      certificateVerification: Disabled
```

Addresses must contain "redfish" to pass CEO validation
(`strings.Contains(address, "redfish")` in fencing.go:149-151).

#### 2. Wait for cluster install and fencing job completion

CEO creates fence_redfish STONITH resources with dummy creds. Fencing is
"configured" but non-functional.

#### 3. Swap STONITH resources to fence_aws

```bash
# Delete dummy fence_redfish resources
pcs stonith delete master-0_redfish
pcs stonith delete master-1_redfish

# Create fence_aws resources
pcs stonith create fence-master-0 fence_aws \
    plug=<ec2-instance-id-of-master-0> \
    region=us-east-1 \
    access_key=AKIA... \
    secret_key=... \
    pcmk_host_list=master-0

pcs stonith create fence-master-1 fence_aws \
    plug=<ec2-instance-id-of-master-1> \
    region=us-east-1 \
    access_key=AKIA... \
    secret_key=... \
    pcmk_host_list=master-1
```

#### 4. Validate

```bash
pcs stonith status
pcs stonith fence master-1   # test fence (will power off the node)
```

### Constraints

- **Don't modify fencing secrets** after swap — `handleFencingSecretChange()`
  in CEO's starter.go triggers `RestartJobOrRunController()`, which would
  re-apply fence_redfish and overwrite fence_aws config.
- CEO fencing is one-shot (runner.go `RunFencingSetup()`), no continuous
  reconciliation. Status collector is monitoring-only.
- IAM: nodes need `ec2:StopInstances`, `ec2:StartInstances`,
  `ec2:RebootInstances`, `ec2:DescribeInstances` permissions (instance role
  or explicit creds in STONITH config).

### Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Fencing secret change re-triggers CEO fencing job | Medium | Don't touch fencing secrets after swap |
| Pacemaker health monitor reports unexpected agent type | Low | Cosmetic — monitor doesn't enforce |
| Fencing triggers during install before swap | Low | Install is usually stable; swap quickly |
| Node upgrade/reboot re-runs fencing setup | Low-Medium | Verify: does CEO re-run fencing on node restart? |

---

## Approach B: sushy-tools EC2 Driver

A new sushy-tools systems driver (`ec2driver.py`) translating Redfish to EC2
API. Preserves the Redfish interface so CEO/installer remain unchanged.

### Driver Interface (8 required methods from AbstractSystemsDriver)

| Method | EC2 Implementation |
|--------|-------------------|
| `driver` (property) | Return `'<ec2>'` |
| `systems` (property) | `DescribeInstances` with filters → instance ID list |
| `uuid(identity)` | EC2 instance ID |
| `name(identity)` | Instance `Name` tag |
| `get_power_state(identity)` | `DescribeInstances` → `running`→`On`, `stopped`→`Off` |
| `set_power_state(identity, state)` | `ForceOff`→`StopInstances(Force=True)`, `On`→`StartInstances`, etc. |
| `get_boot_device(identity)` | Return `'Hdd'` (static) |
| `set_boot_device(identity, boot_source)` | No-op / `NotSupportedError` |

### Power State Mapping

| EC2 State | Redfish State |
|-----------|--------------|
| `running` | `On` |
| `stopped` | `Off` |
| `stopping` | `Off` (transitional) |
| `pending` | `On` (transitional) |
| `shutting-down` | `Off` |
| `terminated` | Error |

### Upstream

sushy-tools is Apache-2.0, Red Hat-owned (OpenStack/Ironic). Pluggable driver
architecture. `fakedriver.py` is ~258 lines — EC2 driver will be ~250-350 (includes EC2 eventual consistency handling, error recovery, and boto3 client management).

---

## Approach C: Native fence_aws in CEO

Make `fence_aws` a first-class fencing agent in the TNF stack. Requires:

| Layer | Change |
|-------|--------|
| cluster-etcd-operator | Refactor `getFencingConfig()` — agent-agnostic, new secret schema |
| Fencing secrets | New fields: `accessKeyId`, `secretAccessKey`, `region`, `instanceId` |
| installer | Extend install-config fencing credential schema |
| two-node-toolbox | New Ansible role or conditional in redfish role |
| Tests | New cases in `fencing_test.go` |

Architecturally cleanest but requires cross-team coordination.

---

## EC2 Bare Metal Instance Options

| Instance | Arch | vCPUs | RAM | ~$/hr |
|----------|------|-------|-----|-------|
| `m5zn.metal` | x86 | 48 | 192 GiB | ~$3.96 |
| `c6g.metal` | ARM (Graviton 2) | 64 | 128 GiB | ~$2.18 |
| `c7g.metal` | ARM (Graviton 3) | 64 | 128 GiB | ~$2.32 |
| `m7g.metal` | ARM (Graviton 3) | 64 | 256 GiB | ~$2.61 |

## IAM Permissions Required

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:RebootInstances"
    ],
    "Resource": "*"
  }]
}
```

## Open Questions

- Does CEO re-run the fencing job on node restart or cluster upgrade?
- Can fence_aws use an EC2 instance role instead of explicit access keys?
- ~~Should the dummy Redfish address point to a real loopback port or any fake URL?~~ — N/A for Approach B (real sushy-tools endpoint, not dummy)
- Would OpenShift on Graviton ARM64 work for TNF? (RHCOS aarch64 + full stack)
- How long does `reboot_instances()` take on EC2 bare metal? Must complete within fence timeout (~120s)

## Related PRs

| PR | Repo | Status | Description |
|----|------|--------|-------------|
