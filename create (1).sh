#!/bin/bash

set -e

# ============================================================
# Find script directory
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# Load configuration
# ============================================================

source "$SCRIPT_DIR/config.sh"

# ============================================================
# Logging
# ============================================================

LOG_FILE="droplet_creation_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================"
echo " DigitalOcean Droplet Creation"
echo "============================================================"

echo "Region        : $REGION"
echo "Image         : $IMAGE"
echo "Size          : $SIZE"
echo "Tag           : $TAG_NAME"
echo "Firewall      : $FIREWALL_NAME"
echo "Project       : $PROJECT_NAME"
echo "SSH Key       : $SSH_KEY_NAME"
echo "VPC           : ${VPC_NAME:-Default VPC}"
echo "Names file    : $DROPLET_NAME_FILE"
echo "============================================================"


# ============================================================
# Validate droplet names file
# ============================================================

if [[ ! -f "$SCRIPT_DIR/$DROPLET_NAME_FILE" ]]; then
    echo "❌ Droplet name file not found:"
    echo "   $SCRIPT_DIR/$DROPLET_NAME_FILE"
    exit 1
fi


# ============================================================
# Read droplet names
# ============================================================

mapfile -t DROPLET_NAMES < "$SCRIPT_DIR/$DROPLET_NAME_FILE"

if [ ${#DROPLET_NAMES[@]} -eq 0 ]; then
    echo "❌ No droplet names found in $DROPLET_NAME_FILE"
    exit 1
fi

echo ""
echo "📋 Droplets to be created:"

VALID_DROPLET_COUNT=0

for DROPLET_NAME in "${DROPLET_NAMES[@]}"; do

    # Ignore empty lines
    if [[ -z "$DROPLET_NAME" ]]; then
        continue
    fi

    echo "   - $DROPLET_NAME"
    ((VALID_DROPLET_COUNT+=1)) || true

done

if [ "$VALID_DROPLET_COUNT" -eq 0 ]; then
    echo "❌ No valid droplet names found."
    exit 1
fi


# ============================================================
# Check required tools
# ============================================================

echo ""
echo "🔍 Checking required tools..."

if ! command -v doctl >/dev/null 2>&1; then
    echo "❌ doctl is not installed."
    exit 1
fi

echo "✅ doctl found."


# ============================================================
# Check DigitalOcean authentication
# ============================================================

echo ""
echo "🔐 Checking DigitalOcean authentication..."

doctl account get

echo "✅ DigitalOcean authentication successful."


# ============================================================
# Fetch SSH Key ID
# ============================================================

echo ""
echo "🔑 Looking up SSH key: $SSH_KEY_NAME"

SSH_KEY_ID=$(
    doctl compute ssh-key list \
        --format Name,ID \
        --no-header |
    grep -w "$SSH_KEY_NAME" |
    awk '{print $2}'
)

if [ -z "$SSH_KEY_ID" ]; then
    echo "❌ SSH key not found: $SSH_KEY_NAME"
    exit 1
fi

echo "✅ SSH Key ID: $SSH_KEY_ID"


# ============================================================
# Fetch Project ID
# ============================================================

echo ""
echo "📦 Looking up project: $PROJECT_NAME"

PROJECT_ID=$(
    doctl projects list \
        --format Name,ID \
        --no-header |
    grep -w "$PROJECT_NAME" |
    awk '{print $2}'
)

if [ -z "$PROJECT_ID" ]; then
    echo "❌ Project not found: $PROJECT_NAME"
    exit 1
fi

echo "✅ Project ID: $PROJECT_ID"


# ============================================================
# Fetch VPC UUID if configured
# ============================================================

VPC_UUID=""

if [[ -n "$VPC_NAME" ]]; then

    echo ""
    echo "🌐 Looking up VPC: $VPC_NAME"

    VPC_UUID=$(
        doctl vpcs list \
            --format Name,ID \
            --no-header |
        grep -w "$VPC_NAME" |
        awk '{print $2}'
    )

    if [ -z "$VPC_UUID" ]; then
        echo "❌ VPC not found: $VPC_NAME"
        exit 1
    fi

    echo "✅ VPC UUID: $VPC_UUID"

else

    echo ""
    echo "ℹ️ No VPC specified."
    echo "   Default VPC will be used."

fi


# ============================================================
# Ensure Tag Exists
# ============================================================

echo ""
echo "🔖 Ensuring tag exists: $TAG_NAME"

if doctl compute tag create "$TAG_NAME"; then
    echo "✅ Tag created: $TAG_NAME"
else
    echo "ℹ️ Tag may already exist: $TAG_NAME"
fi


# ============================================================
# Create Droplets
# ============================================================

DROPLET_IDS=()
DROPLET_URNS=()
DROPLET_CREATED_NAMES=()

echo ""
echo "============================================================"
echo " Creating Droplets"
echo "============================================================"

for DROPLET_NAME in "${DROPLET_NAMES[@]}"; do

    # Skip empty lines
    if [[ -z "$DROPLET_NAME" ]]; then
        continue
    fi

    echo ""
    echo "🚀 Creating droplet: $DROPLET_NAME"

    CMD=(
        doctl compute droplet create "$DROPLET_NAME"
        --region "$REGION"
        --image "$IMAGE"
        --size "$SIZE"
        --ssh-keys "$SSH_KEY_ID"
        --tag-names "$TAG_NAME"
        --enable-monitoring
        --user-data-file "$SCRIPT_DIR/install-node-exporter.sh"
        --wait
        --format ID
        --no-header
    )

    if [[ -n "$VPC_UUID" ]]; then
        CMD+=(--vpc-uuid "$VPC_UUID")
    fi

    DROPLET_ID=$("${CMD[@]}")

    if [[ -n "$DROPLET_ID" ]]; then

        DROPLET_IDS+=("$DROPLET_ID")
        DROPLET_URNS+=("do:droplet:$DROPLET_ID")
        DROPLET_CREATED_NAMES+=("$DROPLET_NAME")

        echo "✅ Created droplet: $DROPLET_NAME"
        echo "   ID: $DROPLET_ID"

    else

        echo "⚠️ Failed to create droplet: $DROPLET_NAME"

    fi

done


# ============================================================
# Check whether droplets were created
# ============================================================

if [ ${#DROPLET_IDS[@]} -eq 0 ]; then
    echo ""
    echo "❌ No droplets were successfully created."
    exit 1
fi


# ============================================================
# Display created IDs
# ============================================================

echo ""
echo "============================================================"
echo " Created Droplets"
echo "============================================================"

echo "Droplet IDs:"
printf '   %s\n' "${DROPLET_IDS[@]}"

echo ""
echo "Droplet URNs:"
printf '   %s\n' "${DROPLET_URNS[@]}"


# ============================================================
# Assign Droplets to Project
# ============================================================

echo ""
echo "============================================================"
echo " Assigning Droplets to Project"
echo "============================================================"

for URN in "${DROPLET_URNS[@]}"; do

    echo "📦 Assigning $URN to $PROJECT_NAME"

    doctl projects resources assign \
        "$PROJECT_ID" \
        --resource "$URN"

done

echo "✅ Project assignment completed."


# ============================================================
# Find Existing Firewall
# ============================================================

echo ""
echo "============================================================"
echo " Firewall Configuration"
echo "============================================================"

echo "🛡️ Checking firewall: $FIREWALL_NAME"

FIREWALL_ID=$(
    doctl compute firewall list \
        --format Name,ID \
        --no-header |
    grep -w "$FIREWALL_NAME" |
    awk '{print $2}'
)


# ============================================================
# Existing Firewall
# ============================================================

if [[ -n "$FIREWALL_ID" ]]; then

    echo "✅ Firewall already exists."
    echo "   Firewall ID: $FIREWALL_ID"

    DROPLET_ID_LIST="$(IFS=,; echo "${DROPLET_IDS[*]}")"

    echo "🔗 Attaching droplets to firewall..."

    doctl compute firewall add-droplets \
        "$FIREWALL_ID" \
        --droplet-ids "$DROPLET_ID_LIST"

    echo "✅ Droplets attached to firewall."


# ============================================================
# Create New Firewall
# ============================================================

else

    echo "🛡️ Firewall '$FIREWALL_NAME' not found."
    echo "🚀 Creating firewall..."

    DROPLET_ID_LIST="$(IFS=,; echo "${DROPLET_IDS[*]}")"

    FIREWALL_ID=$(
        doctl compute firewall create \
            --name "$FIREWALL_NAME" \
            --inbound-rules \
                "protocol:tcp,ports:22,address:0.0.0.0/0" \
            --droplet-ids "$DROPLET_ID_LIST" \
            --format ID \
            --no-header
    )

    if [[ -z "$FIREWALL_ID" ]]; then
        echo "❌ Failed to create firewall."
        exit 1
    fi

    echo "✅ Firewall created."
    echo "   Firewall ID: $FIREWALL_ID"


    # --------------------------------------------------------
    # HTTP
    # --------------------------------------------------------

    echo "➕ Adding HTTP rule..."

    doctl compute firewall add-rules \
        "$FIREWALL_ID" \
        --inbound-rules \
            "protocol:tcp,ports:80,address:0.0.0.0/0"


    # --------------------------------------------------------
    # HTTPS
    # --------------------------------------------------------

    echo "➕ Adding HTTPS rule..."

    doctl compute firewall add-rules \
        "$FIREWALL_ID" \
        --inbound-rules \
            "protocol:tcp,ports:443,address:0.0.0.0/0"


    # --------------------------------------------------------
    # Outbound ICMP
    # --------------------------------------------------------

    echo "➕ Adding outbound ICMP rule..."

    doctl compute firewall add-rules \
        "$FIREWALL_ID" \
        --outbound-rules \
            "protocol:icmp,address:0.0.0.0/0"


    # --------------------------------------------------------
    # Outbound TCP
    # --------------------------------------------------------

    echo "➕ Adding outbound TCP rule..."

    doctl compute firewall add-rules \
        "$FIREWALL_ID" \
        --outbound-rules \
            "protocol:tcp,ports:all,address:0.0.0.0/0"


    # --------------------------------------------------------
    # Outbound UDP
    # --------------------------------------------------------

    echo "➕ Adding outbound UDP rule..."

    doctl compute firewall add-rules \
        "$FIREWALL_ID" \
        --outbound-rules \
            "protocol:udp,ports:all,address:0.0.0.0/0"

    echo "✅ All firewall rules configured."

fi


# ============================================================
# Output Public IPs
# ============================================================

echo ""
echo "============================================================"
echo " Public IP Addresses"
echo "============================================================"

for ID in "${DROPLET_IDS[@]}"; do

    if [[ -n "$ID" ]]; then

        doctl compute droplet get "$ID" \
            --format Name,PublicIPv4 \
            --no-header

    fi

done


# ============================================================
# Write structured droplet info for downstream pipelines
#
# This is the ONLY addition to this script: a small JSON file
# listing each created droplet's name/IP/ID. The Jenkinsfile
# archives it as an artifact so the separate watcher pipeline
# can read it via copyArtifacts, instead of scraping this log.
# ============================================================

echo ""
echo "Writing droplet-info.json..."

INFO_FILE="$SCRIPT_DIR/droplet-info.json"

{
    echo "["
    FIRST=1
    for ID in "${DROPLET_IDS[@]}"; do

        NAME=$(doctl compute droplet get "$ID" --format Name --no-header)
        IP=$(doctl compute droplet get "$ID" --format PublicIPv4 --no-header)

        if [[ "$FIRST" -eq 0 ]]; then
            echo ","
        fi
        FIRST=0

        printf '  {"name": "%s", "ip": "%s", "id": "%s"}' "$NAME" "$IP" "$ID"

    done
    echo ""
    echo "]"
} > "$INFO_FILE"

echo "✅ Wrote $INFO_FILE"


# ============================================================
# Finished
# ============================================================

echo ""
echo "============================================================"
echo " ✅ DROPLET CREATION COMPLETED"
echo "============================================================"

# ============================================================
# Register Droplets in Prometheus
# ============================================================

echo ""
echo "============================================================"
echo " Registering Droplets in Prometheus"
echo "============================================================"

: "${PROMETHEUS_HOST:?PROMETHEUS_HOST is required}"
: "${PROMETHEUS_USER:?PROMETHEUS_USER is required}"
: "${PROMETHEUS_SSH_PASSWORD:?PROMETHEUS_SSH_PASSWORD is required}"

command -v sshpass >/dev/null 2>&1 || {
    echo "ERROR: sshpass is not installed."
    exit 1
}

# sshpass -e reads the password from SSHPASS.
export SSHPASS="$PROMETHEUS_SSH_PASSWORD"

# Clear credentials when the script exits.
trap 'unset SSHPASS PROMETHEUS_SSH_PASSWORD' EXIT

for INDEX in "${!DROPLET_IDS[@]}"; do

    DROPLET_ID="${DROPLET_IDS[$INDEX]}"
    DROPLET_NAME="${DROPLET_CREATED_NAMES[$INDEX]}"

    echo ""
    echo "Looking up public IP for $DROPLET_NAME..."

    # Retry while the public IP is not yet available.
    PUBLIC_IP=""

    for ATTEMPT in {1..12}; do

        PUBLIC_IP=$(
            doctl compute droplet get "$DROPLET_ID" \
                --format PublicIPv4 \
                --no-header 2>/dev/null || true
        )

        PUBLIC_IP="$(echo "$PUBLIC_IP" | tr -d '[:space:]')"

        if [[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            break
        fi

        PUBLIC_IP=""
        echo "Public IP not ready (attempt $ATTEMPT/12). Waiting..."
        sleep 5

    done

    if [[ -z "$PUBLIC_IP" ]]; then
        echo "ERROR: Could not obtain public IP for $DROPLET_NAME"
        exit 1
    fi

    # Validate the name before using it in the remote command.
    if [[ ! "$DROPLET_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "ERROR: Invalid Droplet name: $DROPLET_NAME"
        exit 1
    fi

    echo "Droplet name : $DROPLET_NAME"
    echo "Public IP    : $PUBLIC_IP"

    echo "Adding target to target-common.yml..."

    ssh \
      -i /var/lib/jenkins/.ssh/grafana_deploy_ed25519 \
      -o IdentitiesOnly=yes \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile=/var/lib/jenkins/.ssh/known_hosts \
      jenkins-monitoring@"$PROMETHEUS_HOST" \
      "sudo -n /usr/local/sbin/register-do-target '$PUBLIC_IP' '$DROPLET_NAME'"

    echo "Prometheus target registration completed for $DROPLET_NAME"
done

# Restart Prometheus once, after all registrations succeed.
echo ""
echo "Restarting Prometheus..."

sshpass -e ssh \
    -o BatchMode=no \
    -o StrictHostKeyChecking=yes \
    "$PROMETHEUS_USER@$PROMETHEUS_HOST" \
    "sudo -n /usr/bin/systemctl restart prometheus"

echo "Checking Prometheus service status..."

sshpass -e ssh \
    -o BatchMode=no \
    -o StrictHostKeyChecking=yes \
    "$PROMETHEUS_USER@$PROMETHEUS_HOST" \
    "systemctl is-active prometheus"

echo ""
echo "============================================================"
echo " DROPLET CREATION AND PROMETHEUS REGISTRATION COMPLETED"
echo "============================================================"
