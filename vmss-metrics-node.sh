#!/usr/bin/env bash

# Script: vmss-metrics-node.sh
# Purpose: Collect per-node VMSS network metrics, summarize results, and export to CSV/JSON.
# Requirements: Azure CLI logged in, jq installed. Works in Azure Cloud Shell.

set -uo pipefail

# ====== DEFAULTS ======
RESOURCE_GROUP=""
VMSS_NAME=""
TIME_RANGE="1h"
INTERVAL="PT1M"
OUT_DIR="."
PREFIX="vmss_metrics"

safe_exit() {
    local code="${1:-1}"
    # If sourced, return to prompt instead of closing the shell session.
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
        return "$code"
    fi
    exit "$code"
}

usage() {
    cat <<'EOF'
Usage:
  ./vmss-metrics-node.sh -g <resource-group> -n <vmss-name> [options]

Required:
  -g, --resource-group     Resource group of the VMSS
  -n, --vmss-name          VMSS name

Optional:
    -t, --time-range         Offset duration (examples: 1h, 30m, 1d; also accepts PT1H/PT30M/PT1D)
  -i, --interval           ISO8601 interval (default: PT1M)
  -o, --out-dir            Output directory (default: .)
  -p, --prefix             Output filename prefix (default: vmss_metrics)
  -h, --help               Show this help

Examples:
  ./vmss-metrics-node.sh -g rg-prod -n app-vmss
  ./vmss-metrics-node.sh -g rg-prod -n app-vmss -t 6h -i PT5M -o ./out -p nightly
EOF
}

normalize_offset() {
    local input="$1"
    if [[ "$input" =~ ^[0-9]+[dhm]$ ]]; then
        echo "$input"
        return 0
    fi

    if [[ "$input" =~ ^PT([0-9]+)H$ ]]; then
        echo "${BASH_REMATCH[1]}h"
        return 0
    fi
    if [[ "$input" =~ ^PT([0-9]+)M$ ]]; then
        echo "${BASH_REMATCH[1]}m"
        return 0
    fi
    if [[ "$input" =~ ^P([0-9]+)D$ ]]; then
        echo "${BASH_REMATCH[1]}d"
        return 0
    fi

    echo "Error: Invalid time range '$input'. Use values like 1h, 30m, 1d, PT1H, PT30M, or P1D." >&2
    return 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -n|--vmss-name)
            VMSS_NAME="$2"
            shift 2
            ;;
        -t|--time-range)
            TIME_RANGE="$2"
            shift 2
            ;;
        -i|--interval)
            INTERVAL="$2"
            shift 2
            ;;
        -o|--out-dir)
            OUT_DIR="$2"
            shift 2
            ;;
        -p|--prefix)
            PREFIX="$2"
            shift 2
            ;;
        -h|--help)
            usage
            safe_exit 0
            ;;
        *)
            echo "Error: Unknown argument '$1'" >&2
            usage
            safe_exit 1
            ;;
    esac
done

if [[ -z "$RESOURCE_GROUP" || -z "$VMSS_NAME" ]]; then
    echo "Error: --resource-group and --vmss-name are required." >&2
    usage
    safe_exit 1
fi

if ! TIME_RANGE=$(normalize_offset "$TIME_RANGE"); then
    safe_exit 1
fi

# ====== VALIDATION ======
if ! command -v az >/dev/null 2>&1; then
    echo "Error: Azure CLI (az) is not installed." >&2
    safe_exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for JSON parsing." >&2
    safe_exit 1
fi

if ! az account show >/dev/null 2>&1; then
    echo "Error: Not logged into Azure CLI. Run 'az login' first." >&2
    safe_exit 1
fi

mkdir -p "$OUT_DIR"

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
CSV_FILE="$OUT_DIR/${PREFIX}_${VMSS_NAME}_${TIMESTAMP}.csv"
JSON_FILE="$OUT_DIR/${PREFIX}_${VMSS_NAME}_${TIMESTAMP}.json"
TMP_FILE=$(mktemp)

trap 'rm -f "$TMP_FILE"' EXIT

echo "Fetching VMSS instances from $VMSS_NAME..."
INSTANCE_IDS=$(az vmss list-instances \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VMSS_NAME" \
    --query "[].instanceId" -o tsv)

if [[ -z "$INSTANCE_IDS" ]]; then
    echo "No instances found in VMSS '$VMSS_NAME'."
    safe_exit 1
fi

echo "instanceId,networkInBytes,networkOutBytes,totalBytes" > "$CSV_FILE"

echo "Collecting network traffic metrics per instance..."
for INSTANCE_ID in $INSTANCE_IDS; do
    RESOURCE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Compute/virtualMachineScaleSets/$VMSS_NAME/virtualMachines/$INSTANCE_ID"

    if ! METRICS_JSON=$(az monitor metrics list \
        --resource "$RESOURCE_ID" \
        --metrics "Network In Total" "Network Out Total" \
        --interval "$INTERVAL" \
        --aggregation Total \
        --offset "$TIME_RANGE" \
        -o json); then
        echo "Warning: Failed to fetch metrics for instance $INSTANCE_ID. Skipping." >&2
        continue
    fi

    if ! NET_IN=$(jq -r '[.value[] | select(.name.value=="Network In Total") | .timeseries[].data[].total // 0] | add // 0' <<< "$METRICS_JSON"); then
        echo "Warning: Failed to parse Network In Total for instance $INSTANCE_ID. Skipping." >&2
        continue
    fi
    if ! NET_OUT=$(jq -r '[.value[] | select(.name.value=="Network Out Total") | .timeseries[].data[].total // 0] | add // 0' <<< "$METRICS_JSON"); then
        echo "Warning: Failed to parse Network Out Total for instance $INSTANCE_ID. Skipping." >&2
        continue
    fi
    if ! TOTAL=$(jq -nr --argjson i "$NET_IN" --argjson o "$NET_OUT" '$i + $o'); then
        echo "Warning: Failed to calculate totals for instance $INSTANCE_ID. Skipping." >&2
        continue
    fi

    jq -n \
        --arg instanceId "$INSTANCE_ID" \
        --argjson networkInBytes "$NET_IN" \
        --argjson networkOutBytes "$NET_OUT" \
        --argjson totalBytes "$TOTAL" \
        '{instanceId:$instanceId, networkInBytes:$networkInBytes, networkOutBytes:$networkOutBytes, totalBytes:$totalBytes}' >> "$TMP_FILE"

    printf '%s,%s,%s,%s\n' "$INSTANCE_ID" "$NET_IN" "$NET_OUT" "$TOTAL" >> "$CSV_FILE"
    echo "Instance $INSTANCE_ID: IN=$NET_IN, OUT=$NET_OUT, TOTAL=$TOTAL bytes"
done

if ! jq -s '.' "$TMP_FILE" > "$JSON_FILE"; then
    echo "Error: Failed to write JSON export file." >&2
    safe_exit 1
fi

echo
echo "=== Traffic Comparison (Highest to Lowest) ==="
sort -t, -k4,4nr "$CSV_FILE" | awk -F',' 'NR>1 {printf "Instance %s: %s bytes total (IN=%s, OUT=%s)\n", $1, $4, $2, $3}'

SUMMARY=$(jq '
  {
    nodeCount: length,
        totalInBytes: (map(.networkInBytes) | add // 0),
        totalOutBytes: (map(.networkOutBytes) | add // 0),
        totalBytes: (map(.totalBytes) | add // 0),
        averageBytesPerNode: (if length == 0 then 0 else ((map(.totalBytes) | add // 0) / length) end),
        highest: (if length == 0 then null else max_by(.totalBytes) end),
        lowest: (if length == 0 then null else min_by(.totalBytes) end)
  }
' "$JSON_FILE")

echo
echo "=== Summary ==="
echo "$SUMMARY" | jq '.'

echo
echo "Exported files:"
echo "- CSV: $CSV_FILE"
echo "- JSON: $JSON_FILE"