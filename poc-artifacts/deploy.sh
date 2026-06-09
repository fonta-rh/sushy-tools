#!/bin/bash
# Deploy sushy-tools with EC2 driver on a small RHEL instance,
# plus fencing target nodes (virtual or bare metal).
# Usage: source config.env && ./deploy.sh
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

AWS_REGION="${AWS_REGION:-us-east-1}"
SUSHY_HOST_TYPE="${SUSHY_HOST_TYPE:-t3.small}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519.pub}"
SSH_PRIVATE_KEY="${SSH_KEY_PATH%.pub}"
VPC_ID="${VPC_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"
INSTANCE_PROFILE="${INSTANCE_PROFILE:-}"
FILTER_TAG="${FILTER_TAG:-}"
FILTER_VALUE="${FILTER_VALUE:-}"
SUSHY_AWS_ACCESS_KEY="${SUSHY_AWS_ACCESS_KEY:-}"
SUSHY_AWS_SECRET_KEY="${SUSHY_AWS_SECRET_KEY:-}"
SUSHY_PORT=8000
SSH_USER="ec2-user"

# Fencing target nodes
DEPLOY_NODES="${DEPLOY_NODES:-true}"
NODE_TYPE="${NODE_TYPE:-c6g.metal}"
NODE_COUNT="${NODE_COUNT:-2}"
NODE_NAMES=("master-0" "master-1")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."
STATE_DIR="${REPO_ROOT}/.work/sushy-ec2"
WORKTREE_DIR="${REPO_ROOT}/repos/sushy-tools/.worktrees/sushy-ec2-driver"
KEY_NAME="${USER}-sushy-ec2"
SG_NAME="${USER}-sushy-ec2"

AWS="aws --region ${AWS_REGION} --no-cli-pager"

# ── Helpers ──────────────────────────────────────────────────────────────────

instance_arch() {
    local itype="$1"
    # Graviton instances have 'g' in the family: c6g, c7g, m6g, m7g, t4g, etc.
    if [[ "$itype" =~ ^[a-z]+[0-9]+g ]]; then
        echo "arm64"
    else
        echo "x86_64"
    fi
}

find_rhel9_ami() {
    local arch="$1"
    local ami
    ami=$($AWS ec2 describe-images \
        --query 'reverse(sort_by(Images, &CreationDate))[0].ImageId' \
        --filters "Name=name,Values=RHEL-9.*GA*${arch}*" \
        --owners amazon \
        --output text)
    if [[ -z "$ami" || "$ami" == "None" ]]; then
        echo "ERROR: No RHEL 9 ${arch} AMI found in $AWS_REGION" >&2
        return 1
    fi
    echo "$ami"
}

ssh_cmd() {
    ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 "${SSH_USER}@${PUBLIC_IP}" "$@"
}

scp_cmd() {
    scp -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new "$@"
}

# ── Preflight ─────────────────────────────────────────────────────────────────

if [[ ! -f "$SSH_KEY_PATH" ]]; then
    echo "ERROR: SSH public key not found: $SSH_KEY_PATH" >&2
    exit 1
fi

if [[ ! -d "$WORKTREE_DIR" ]]; then
    echo "ERROR: sushy-tools worktree not found: $WORKTREE_DIR" >&2
    exit 1
fi

if [[ -f "$STATE_DIR/instance-id" ]]; then
    echo "ERROR: Deployment already exists ($(cat "$STATE_DIR/instance-id")). Run teardown.sh first." >&2
    exit 1
fi

mkdir -p "$STATE_DIR"

SUSHY_ARCH=$(instance_arch "$SUSHY_HOST_TYPE")
NODE_ARCH=$(instance_arch "$NODE_TYPE")
IS_BARE_METAL=false
[[ "$NODE_TYPE" == *.metal* ]] && IS_BARE_METAL=true

# ── 1. Find RHEL 9 AMIs ─────────────────────────────────────────────────────

echo "==> Finding RHEL 9 AMIs..."
SUSHY_AMI=$(find_rhel9_ami "$SUSHY_ARCH")
echo "    sushy-tools host (${SUSHY_ARCH}): $SUSHY_AMI"

if [[ "$DEPLOY_NODES" == "true" ]]; then
    if [[ "$NODE_ARCH" == "$SUSHY_ARCH" ]]; then
        NODE_AMI="$SUSHY_AMI"
    else
        NODE_AMI=$(find_rhel9_ami "$NODE_ARCH")
    fi
    echo "    fencing nodes (${NODE_ARCH}): $NODE_AMI"
fi

# ── 2. Security group ────────────────────────────────────────────────────────

echo "==> Setting up security group..."
SG_ID=""

sg_lookup_args=(--filters "Name=group-name,Values=${SG_NAME}")
[[ -n "$VPC_ID" ]] && sg_lookup_args+=(--filters "Name=vpc-id,Values=${VPC_ID}")

SG_ID=$($AWS ec2 describe-security-groups \
    "${sg_lookup_args[@]}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || true)

if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
    echo "    Reusing existing: $SG_ID"
else
    sg_create_args=(--group-name "$SG_NAME" --description "sushy-tools EC2 driver (dev)")
    [[ -n "$VPC_ID" ]] && sg_create_args+=(--vpc-id "$VPC_ID")

    SG_ID=$($AWS ec2 create-security-group "${sg_create_args[@]}" \
        --query 'GroupId' --output text)

    $AWS ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
    $AWS ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" --protocol tcp --port $SUSHY_PORT --cidr 0.0.0.0/0 >/dev/null
    echo "    Created: $SG_ID (SSH + port $SUSHY_PORT)"
fi

# ── 3. SSH key pair ───────────────────────────────────────────────────────────

echo "==> Importing SSH key pair..."
$AWS ec2 import-key-pair \
    --key-name "$KEY_NAME" \
    --public-key-material "fileb://$SSH_KEY_PATH" >/dev/null 2>&1 || true
echo "    Key: $KEY_NAME"

# ── 3b. Auto-configure filter tag for managed nodes ─────────────────────────

if [[ "$DEPLOY_NODES" == "true" && -z "$FILTER_TAG" ]]; then
    FILTER_TAG="sushy-cluster"
    FILTER_VALUE="${USER}"
    echo "    Auto-set filter: ${FILTER_TAG}=${FILTER_VALUE}"
fi

# ── 4. Launch sushy-tools instance ───────────────────────────────────────────

echo "==> Launching $SUSHY_HOST_TYPE (sushy-tools host)..."

run_args=(
    --image-id "$SUSHY_AMI"
    --instance-type "$SUSHY_HOST_TYPE"
    --key-name "$KEY_NAME"
    --security-group-ids "$SG_ID"
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${USER}-sushy-ec2}]"
    --query 'Instances[0].InstanceId'
    --output text
)

if [[ -n "$SUBNET_ID" ]]; then
    run_args+=(--subnet-id "$SUBNET_ID")
else
    run_args+=(--associate-public-ip-address)
fi

[[ -n "$INSTANCE_PROFILE" ]] && \
    run_args+=(--iam-instance-profile "Name=${INSTANCE_PROFILE}")

INSTANCE_ID=$($AWS ec2 run-instances "${run_args[@]}")
echo "    Instance: $INSTANCE_ID"

# ── 4b. Launch fencing target nodes ─────────────────────────────────────────

NODE_IDS=()

if [[ "$DEPLOY_NODES" == "true" ]]; then
    echo "==> Launching ${NODE_COUNT}x ${NODE_TYPE} fencing nodes..."
    if [[ "$IS_BARE_METAL" == "true" ]]; then
        echo "    (bare metal — allocation may take 1-2 min)"
    fi

    for i in $(seq 0 $((NODE_COUNT - 1))); do
        node_name="${NODE_NAMES[$i]}"
        tag_spec="ResourceType=instance,Tags=["
        tag_spec+="{Key=Name,Value=${node_name}}"
        tag_spec+=",{Key=${FILTER_TAG},Value=${FILTER_VALUE}}"
        tag_spec+="]"

        node_args=(
            --image-id "$NODE_AMI"
            --instance-type "$NODE_TYPE"
            --key-name "$KEY_NAME"
            --security-group-ids "$SG_ID"
            --tag-specifications "$tag_spec"
            --query 'Instances[0].InstanceId'
            --output text
        )
        [[ -n "$SUBNET_ID" ]] && node_args+=(--subnet-id "$SUBNET_ID")

        node_id=$($AWS ec2 run-instances "${node_args[@]}")
        NODE_IDS+=("$node_id")
        echo "    ${node_name}: ${node_id}"
    done
fi

# ── 5. Wait for all instances ────────────────────────────────────────────────

ALL_IDS=("$INSTANCE_ID" "${NODE_IDS[@]}")

if [[ "$IS_BARE_METAL" == "true" ]]; then
    echo "==> Waiting for ${#ALL_IDS[@]} instance(s) — bare metal takes 10-20 min..."
    # Built-in waiter polls for ~10 min (40 × 15s). Bare metal can exceed that,
    # so retry once — the second call picks up current status, not transitions.
    $AWS ec2 wait instance-status-ok --instance-ids "${ALL_IDS[@]}" 2>/dev/null || {
        echo "    ... still waiting (extending to 20 min for bare metal)..."
        $AWS ec2 wait instance-status-ok --instance-ids "${ALL_IDS[@]}"
    }
else
    echo "==> Waiting for ${#ALL_IDS[@]} instance(s) to pass status checks (1-3 min)..."
    $AWS ec2 wait instance-status-ok --instance-ids "${ALL_IDS[@]}"
fi

# ── 6. Get public IP ─────────────────────────────────────────────────────────

PUBLIC_IP=$($AWS ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == "None" ]]; then
    echo "ERROR: No public IP assigned. Ensure the subnet has auto-assign public IP," >&2
    echo "       or set SUBNET_ID to a public subnet." >&2
    echo "    Terminating all launched instances..."
    $AWS ec2 terminate-instances --instance-ids "${ALL_IDS[@]}" >/dev/null
    exit 1
fi
echo "    Public IP: $PUBLIC_IP"

# ── 7. Save state early (so teardown works if later steps fail) ───────────────

echo "$INSTANCE_ID" > "$STATE_DIR/instance-id"
echo "$PUBLIC_IP" > "$STATE_DIR/public-ip"
echo "$SG_ID" > "$STATE_DIR/sg-id"
echo "$KEY_NAME" > "$STATE_DIR/key-name"
echo "$AWS_REGION" > "$STATE_DIR/region"

if [[ ${#NODE_IDS[@]} -gt 0 ]]; then
    printf '%s\n' "${NODE_IDS[@]}" > "$STATE_DIR/fake-node-ids"
fi

# ── 8. Install Python 3.11 ───────────────────────────────────────────────────

echo "==> Installing Python 3.11 on remote..."
ssh_cmd "sudo dnf install -y python3.11 python3.11-pip 2>&1 | tail -1"

# ── 9. Upload and install sushy-tools ─────────────────────────────────────────

echo "==> Uploading sushy-tools worktree..."
tar -czf "$STATE_DIR/sushy-tools.tar.gz" \
    -C "$WORKTREE_DIR" \
    --exclude='.git' \
    --exclude='*.pyc' \
    --exclude='__pycache__' \
    --exclude='.tox' \
    .

scp_cmd "$STATE_DIR/sushy-tools.tar.gz" "${SSH_USER}@${PUBLIC_IP}:~/"

echo "==> Installing sushy-tools + boto3..."
ssh_cmd bash <<'INSTALL'
set -euo pipefail
mkdir -p ~/sushy-tools
tar -xzf ~/sushy-tools.tar.gz -C ~/sushy-tools
rm ~/sushy-tools.tar.gz
cd ~/sushy-tools
export PBR_VERSION=0.0.1.dev0
python3.11 -m pip install --user -e . 2>&1 | tail -3
python3.11 -m pip install --user boto3 2>&1 | tail -1
echo "--- Verify ---"
~/.local/bin/sushy-emulator --help | head -1
INSTALL

# ── 10. Write config file (if needed) ────────────────────────────────────────

NEED_CONFIG=false
CONFIG_LINES=()

if [[ -n "$SUSHY_AWS_ACCESS_KEY" && -n "$SUSHY_AWS_SECRET_KEY" ]]; then
    CONFIG_LINES+=("SUSHY_EMULATOR_AWS_ACCESS_KEY = '${SUSHY_AWS_ACCESS_KEY}'")
    CONFIG_LINES+=("SUSHY_EMULATOR_AWS_SECRET_KEY = '${SUSHY_AWS_SECRET_KEY}'")
    NEED_CONFIG=true
fi

if [[ -n "$FILTER_TAG" && -n "$FILTER_VALUE" ]]; then
    CONFIG_LINES+=("SUSHY_EMULATOR_AWS_FILTER_TAG = '${FILTER_TAG}'")
    CONFIG_LINES+=("SUSHY_EMULATOR_AWS_FILTER_VALUE = '${FILTER_VALUE}'")
    NEED_CONFIG=true
fi

CONFIG_FLAG=""
if [[ "$NEED_CONFIG" == "true" ]]; then
    echo "==> Writing sushy-tools config..."
    printf '%s\n' "${CONFIG_LINES[@]}" | ssh_cmd "cat > ~/sushy-tools.conf"
    CONFIG_FLAG="--config /home/${SSH_USER}/sushy-tools.conf"
fi

# ── 11. Create systemd user service ──────────────────────────────────────────

echo "==> Setting up systemd service..."
ssh_cmd bash <<SERVICE
set -euo pipefail
mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/sushy-emulator.service <<EOF
[Unit]
Description=Sushy Emulator (EC2 driver)
After=network-online.target

[Service]
Environment=PBR_VERSION=0.0.1.dev0
ExecStart=%h/.local/bin/sushy-emulator \\
    --aws-region ${AWS_REGION} \\
    --interface 0.0.0.0 \\
    --port ${SUSHY_PORT} \\
    ${CONFIG_FLAG}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

loginctl enable-linger ${SSH_USER}
systemctl --user daemon-reload
systemctl --user enable --now sushy-emulator
sleep 2
systemctl --user status sushy-emulator --no-pager || true
SERVICE

# ── 12. Summary ──────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo "  sushy-tools EC2 driver deployed"
echo "========================================"
echo ""
echo "  Redfish endpoint:  http://${PUBLIC_IP}:${SUSHY_PORT}/redfish/v1/"
echo "  Systems list:      http://${PUBLIC_IP}:${SUSHY_PORT}/redfish/v1/Systems"
echo "  sushy-tools host:  ${INSTANCE_ID} (${SUSHY_HOST_TYPE})"
echo "  Region:            ${AWS_REGION}"

if [[ ${#NODE_IDS[@]} -gt 0 ]]; then
    echo ""
    echo "  Fencing targets (${NODE_TYPE}):"
    for i in $(seq 0 $((${#NODE_IDS[@]} - 1))); do
        echo "    ${NODE_NAMES[$i]}: ${NODE_IDS[$i]}"
    done
    echo "  Filter: ${FILTER_TAG}=${FILTER_VALUE}"
fi

echo ""
echo "  SSH:    ssh -i ${SSH_PRIVATE_KEY} ${SSH_USER}@${PUBLIC_IP}"
echo "  Logs:   ssh -i ${SSH_PRIVATE_KEY} ${SSH_USER}@${PUBLIC_IP} journalctl --user-unit sushy-emulator -f"
echo ""
echo "  Verify:"
echo "    curl http://${PUBLIC_IP}:${SUSHY_PORT}/redfish/v1/"
echo "    curl http://${PUBLIC_IP}:${SUSHY_PORT}/redfish/v1/Systems"
if [[ ${#NODE_IDS[@]} -gt 0 ]]; then
    echo "    curl http://${PUBLIC_IP}:${SUSHY_PORT}/redfish/v1/Systems/${NODE_IDS[0]}"
fi
echo ""
echo "  Teardown: $(dirname "$0")/teardown.sh"
echo ""
