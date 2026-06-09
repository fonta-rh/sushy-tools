# PoC Artifacts - EC2 Driver for TNF on AWS Bare Metal

This directory contains proof-of-concept validation artifacts for the EC2 systems driver.

**Note:** These files are NOT part of the upstream PR to `openstack/sushy-tools`. They document the PoC validation process and deployment tooling used for Red Hat's Two-Node with Fencing (TNF) use case on EC2 bare metal.

## Files

- **poc-report.md** — Full PoC report with Phase 1 (virtual) and Phase 2 (bare metal) validation results, timing data, key findings, and epic breakdown for productionization
- **design.md** — Three approaches evaluated, rationale for selecting Approach B (sushy-tools EC2 driver), EC2 API details
- **deploy.sh** — Deploy script that provisions sushy-tools host (t3.small) + bare metal fencing nodes (c6g.metal), with architecture-aware AMI lookup for mixed x86_64/arm64 deployments
- **teardown.sh** — Cleanup script with bare metal waiter retry logic
- **config.env.template** — Configuration template for AWS credentials, region, instance types, filtering

## Key Findings (Phase 2 - Bare Metal)

| Operation | Redfish success | SSH down (processes killed) | SSH back (recovery) | EC2 final state |
|-----------|----------------|----------------------------|---------------------|-----------------|
| **ForceRestart** | instant | **12s** | ~12.4 min | ~10 min (status OK) |
| **ForceOff** | 1s | not tested | N/A | >10 min (`stopped`) |
| **ForceOn** | instant | N/A | not tested | 16s (`running`) |

**Split-brain protection:** Fenced node processes die in 12 seconds — well within the 120s fence timeout. This validates that the EC2 driver meets TNF STONITH requirements.

**Recovery:** Full bare metal reboot takes ~12.4 minutes (hardware POST + OS boot), comparable to physical servers with iDRAC/iLO (3-8 min).

## JIRA

- Story: [OCPEDGE-2719](https://redhat.atlassian.net/browse/OCPEDGE-2719)
- Epic: [OCPEDGE-1973](https://redhat.atlassian.net/browse/OCPEDGE-1973)

## Fork Status

PoC complete (2026-06-09). Fork frozen pending team decision on whether EC2 bare metal becomes an official TNF platform.
