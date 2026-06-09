# sushy-tools EC2 Driver — PoC Report

**Date:** 2026-06-09
**JIRA:** [OCPEDGE-2719](https://redhat.atlassian.net/browse/OCPEDGE-2719) (under epic OCPEDGE-1973)
**Status:** PoC complete. Fork frozen. Productionization deferred pending team decision.

---

## Problem

TNF (Two Nodes with Fencing) requires Redfish-compatible BMC for Pacemaker
STONITH. EC2 bare metal instances expose no BMC/IPMI/Redfish — AWS keeps the
BMC behind the Nitro system. Without a fencing path, TNF cannot be deployed or
tested on EC2.

## Approach

**Approach B: sushy-tools EC2 driver** — a new Python driver for
[sushy-tools](https://github.com/openstack/sushy-tools) that translates
Redfish API calls into EC2 API calls via boto3. The cluster sees standard
Redfish and runs the real `fence_redfish` fencing path. All changes stay outside
the cluster (sushy-tools runs on a separate t3.small host).

Three approaches were evaluated. Approach B was selected over:
- **A (fence_aws swap):** Different fence agent, doesn't test the production
  fencing path, fragile post-install hack.
- **C (native fence_aws in CEO):** Right long-term answer but requires
  multi-repo cross-team changes — scope inappropriate for a dev/test tool.

## What Was Built

| Component | Location | Lines |
|-----------|----------|-------|
| EC2 systems driver | `ec2driver.py` (AbstractSystemsDriver impl) | 169 |
| Unit tests | `test_ec2.py` (32 tests, mocked boto3) | ~350 |
| CLI integration | `--aws-region` arg in `main.py` | ~10 |
| Deploy/teardown scripts | `scripts/sushy-ec2/deploy.sh`, `teardown.sh` | ~450 |

Code lives on fork: `fonta-rh/sushy-tools` branch `sushy-ec2-driver`.
Fork is frozen at this PoC state — no upstream PR filed.

### Key Design Decisions

1. **Optimistic power state mapping** — `stopping` → `Off`, `pending` → `On`.
   `fence_redfish` sees immediate success; the actual EC2 state change is
   async. This is correct for STONITH: once EC2 accepts the stop/reboot, the
   node is on an irrecoverable path. Waiting for actual state change would
   exceed the 120s fencing timeout.

2. **Deterministic UUID generation** — EC2 instance IDs (`i-0abc...`) aren't
   UUIDs. Downstream sushy-tools modules (storage, chassis, drives) call
   `uuid.UUID()` on identity. Fixed with `uuid5(namespace, instance_id)` for
   deterministic, collision-free UUIDs.

3. **Tag-based instance filtering** — `SUSHY_EMULATOR_AWS_FILTER_TAG` /
   `FILTER_VALUE` scopes which instances the driver manages. Without this, it
   would list all instances in the region.

4. **Plain HTTP** — `redfish+http://` with `certificateVerification: Disabled`
   works. CEO passes hostname/port/path to `fence_redfish`, not the scheme.
   Confirmed via `fencing_test.go:94-117`. No TLS certs needed on sushy-tools
   host.

## Validation Results

### Phase 1: Virtual Instances (t3.small + 2x t3.micro)

**Result: PASS**

Full Redfish→EC2 translation validated:
- Driver init, instance discovery via tag filter
- Power state mapping: On/Off/ForceOff/ForceOn/ForceRestart
- Redfish Systems endpoint lists correct instances
- Power operations execute and report correctly

Bugs fixed during validation:
- **PBR versioning:** tarball install (no `.git`) needs `PBR_VERSION` env var
- **UUID validation:** downstream modules reject non-UUID identity strings

### Phase 2: Bare Metal Timing (t3.small + 2x c6g.metal Graviton2)

**Result: PASS with caveats**

Deployment to bare metal worked end-to-end. Architecture-aware AMI lookup
correctly resolved separate x86_64 and arm64 RHEL 9 images. Both c6g.metal
nodes were visible via the Redfish Systems endpoint with correct Name tags.

#### Timing Data

| Operation | Redfish reports success | SSH goes down | SSH comes back | EC2 reaches final state |
|-----------|------------------------|---------------|----------------|------------------------|
| **ForceOff** | 1s | not tested | N/A (stays off) | >10 min (`stopped`) |
| **ForceOn** | instant | N/A | not tested | 16s (`running`) |
| **ForceRestart** | instant | **12s** | **742s (~12.4 min)** | ~10 min (status `ok`) |

#### Analysis

**Fencing (split-brain prevention):**
The fenced node's processes die within **12 seconds** of `ForceRestart`.
This is well within the 120s fencing timeout. The optimistic state mapping
means `fence_redfish` returns success to Pacemaker almost immediately, so
recovery begins without waiting for the ~12 min reboot cycle.

**Recovery (node rejoin):**
The fenced node is unavailable for **~12 minutes** after a fence event.
This is the c6g.metal full hardware POST + OS boot cycle. For comparison,
physical servers with iDRAC/iLO typically reboot in 3-8 minutes. The bare
metal reboot goes through `ok` → `initializing` → `insufficient-data` →
`impaired` → `ok`, which is normal for bare metal hardware POST.

**ForceOff is slow (>10 min):**
`stop_instances(Force=True)` on bare metal triggers host deallocation
(firmware cleanup, memory scrubbing), not just an OS shutdown. This is only
relevant if Pacemaker uses `action=off` instead of `action=reboot`. The
optimistic `stopping` → `Off` mapping masks this from `fence_redfish`.

**Waiter timeout fix:**
The deploy script's `aws ec2 wait instance-status-ok` has a 10-minute
default timeout. Added retry logic for bare metal, extending effective
timeout to 20 minutes.

## Remaining Work (Epic Breakdown)

The following stories map the path from PoC to production-ready integration.
They are sequenced by dependency — later stories depend on earlier ones.

### Story 1: Upstream sushy-tools PR

File upstream PR to `openstack/sushy-tools` with the EC2 driver. Requires:
- Code review cleanup (docstrings, contributor docs)
- Integration test strategy (mocked boto3 in CI, no real EC2)
- boto3 as optional dependency (extras_require pattern)
- Release note

**Estimate:** 2-3 days (code exists, mostly packaging and review process)

### Story 2: Container image build

Build a container image with sushy-tools + boto3 + EC2 driver. Options:
- Extend the existing `SUSHY_TOOLS_IMAGE` Dockerfile
- New image published to quay.io

Needed for two-node-toolbox integration — Ansible deploys a container,
not a pip install.

**Estimate:** 1 day

### Story 3: two-node-toolbox integration

Add EC2 bare metal as a provisioning target in TNT. Requires:
- New Ansible role or playbook for EC2 bare metal provisioning
- sushy-tools host deployment (t3.small + container from Story 2)
- `install-config.yaml` generation with sushy-tools Redfish endpoint
- Makefile targets for EC2 bare metal lifecycle
- Integration with existing `inventory.ini` / `config.sh` patterns

**Estimate:** 3-5 days (most complex piece — touches provisioning flow)

### Story 4: Full TNF cycle validation

End-to-end test on EC2 bare metal:
- TNF install via dev-scripts or TNT
- CEO fencing configuration (automatic via sushy-tools endpoint)
- `pcs stonith fence <node>` test
- Recovery: fenced node rejoins cluster
- Document any timing/timeout adjustments needed

**Estimate:** 2-3 days (includes cluster install time and debugging)

### Story 5: Documentation

- EC2 bare metal setup guide for TNT
- Bare metal timing characteristics and constraints
- IAM permissions reference
- Troubleshooting (sushy-tools logs, EC2 state mismatches)

**Estimate:** 1-2 days

### Story 6 (Optional): Evaluate Approach C for production

If EC2 becomes an official TNF platform, evaluate native `fence_aws`
support in CEO. Multi-repo changes:
- CEO: agent-agnostic fencing config
- installer: extend install-config fencing schema
- MCO: fence-agents-aws package (may already be in fence-agents-all)

**Estimate:** Investigation spike: 1 week. Implementation: 2-4 weeks.

## Artifacts

| Artifact | Location |
|----------|----------|
| Fork (frozen) | `fonta-rh/sushy-tools` branch `sushy-ec2-driver` |
| Driver source | `sushy_tools/emulator/resources/systems/ec2driver.py` |
| Unit tests | `sushy_tools/tests/unit/emulator/resources/systems/test_ec2.py` |
| Deploy scripts | `scripts/sushy-ec2/deploy.sh`, `teardown.sh` |
| Design doc | `projects/sushy-ec2-driver/design.md` |
| Implementation plan | `projects/sushy-ec2-driver/implementation-plan.md` |
| Investigation notes | `projects/sushy-ec2-driver/investigation.md` |
