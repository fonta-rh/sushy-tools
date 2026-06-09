#!/bin/bash
# Tear down the sushy-tools EC2 deployment.
# Reads state from .work/sushy-ec2/ written by deploy.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/../../.work/sushy-ec2"

if [[ ! -d "$STATE_DIR" ]]; then
    echo "Nothing to tear down — no state directory at $STATE_DIR"
    exit 0
fi

read_state() { [[ -f "$STATE_DIR/$1" ]] && cat "$STATE_DIR/$1" || echo ""; }

INSTANCE_ID=$(read_state instance-id)
SG_ID=$(read_state sg-id)
KEY_NAME=$(read_state key-name)
REGION=$(read_state region)
REGION="${REGION:-us-east-1}"

FAKE_NODE_IDS=()
if [[ -f "$STATE_DIR/fake-node-ids" ]]; then
    mapfile -t FAKE_NODE_IDS < "$STATE_DIR/fake-node-ids"
fi

AWS="aws --region ${REGION} --no-cli-pager"

echo "==> Tearing down sushy-tools EC2 deployment"

# ── Terminate all instances (sushy-tools host + fake nodes) ───────────────────

ALL_IDS=()
[[ -n "$INSTANCE_ID" ]] && ALL_IDS+=("$INSTANCE_ID")
ALL_IDS+=("${FAKE_NODE_IDS[@]}")

TERMINATE_IDS=()
for id in "${ALL_IDS[@]}"; do
    STATE=$($AWS ec2 describe-instances --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo "not-found")

    if [[ "$STATE" != "terminated" && "$STATE" != "not-found" ]]; then
        TERMINATE_IDS+=("$id")
        echo "    Will terminate $id (was: $STATE)"
    else
        echo "    Instance $id already $STATE"
    fi
done

if [[ ${#TERMINATE_IDS[@]} -gt 0 ]]; then
    $AWS ec2 terminate-instances --instance-ids "${TERMINATE_IDS[@]}" >/dev/null
    echo "    Waiting for ${#TERMINATE_IDS[@]} instance(s) to terminate..."
    # Built-in waiter polls for ~10 min. Bare metal termination can exceed that.
    $AWS ec2 wait instance-terminated --instance-ids "${TERMINATE_IDS[@]}" 2>/dev/null || {
        echo "    ... still waiting (extending for bare metal)..."
        $AWS ec2 wait instance-terminated --instance-ids "${TERMINATE_IDS[@]}"
    }
fi

# ── Delete security group ────────────────────────────────────────────────────

if [[ -n "$SG_ID" ]]; then
    echo "    Deleting security group $SG_ID..."
    # SG deletion may need a short wait after instance termination
    for attempt in 1 2 3; do
        if $AWS ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null; then
            break
        fi
        [[ $attempt -lt 3 ]] && sleep 5
    done
fi

# ── Delete key pair ──────────────────────────────────────────────────────────

if [[ -n "$KEY_NAME" ]]; then
    echo "    Deleting key pair $KEY_NAME..."
    $AWS ec2 delete-key-pair --key-name "$KEY_NAME" 2>/dev/null || true
fi

# ── Clean state ──────────────────────────────────────────────────────────────

rm -rf "$STATE_DIR"

echo ""
echo "    Done. All resources cleaned up."
