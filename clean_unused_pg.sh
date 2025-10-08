#!/usr/bin/env bash
# Clean up unused Aurora PostgreSQL parameter groups safely
# Requires: aws CLI, jq
set -euo pipefail

REGION="${REGION:-us-east-1}"

require() { command -v "$1" >/dev/null || { echo "Missing dependency: $1"; exit 1; }; }
require aws
require jq

say() { printf "\n%s\n" "$*"; }
ask() { local q="$1"; read -r -p ">>> $q (y/n): " ans; [[ "$ans" =~ ^[Yy]$ ]]; }

say "=============================================="
say " Aurora PostgreSQL Parameter Groups Cleanup "
say "=============================================="
echo "Region: $REGION"

# --- Collect groups in use by clusters ---
echo "Fetching clusters in region..."
CLUSTERS=$(aws rds describe-db-clusters --region "$REGION" --query 'DBClusters[].{id:DBClusterIdentifier,cpg:DBClusterParameterGroup}' --output json)
USED_CLUSTER_PG=$(echo "$CLUSTERS" | jq -r '.[].cpg' | sort -u)
USED_INSTANCE_PG=$(aws rds describe-db-instances --region "$REGION" --query 'DBInstances[].DBParameterGroups[].DBParameterGroupName' --output text | sort -u)

echo "In-use Cluster Parameter Groups:"
echo "$USED_CLUSTER_PG"
echo
echo "In-use Instance Parameter Groups:"
echo "$USED_INSTANCE_PG"
echo

# --- All groups in region ---
ALL_CLUSTER_PG=$(aws rds describe-db-cluster-parameter-groups --region "$REGION" --query 'DBClusterParameterGroups[].DBClusterParameterGroupName' --output text | sort -u)
ALL_INSTANCE_PG=$(aws rds describe-db-parameter-groups --region "$REGION" --query 'DBParameterGroups[].DBParameterGroupName' --output text | sort -u)

# --- Determine unused ---
UNUSED_CLUSTER_PG=$(comm -23 <(echo "$ALL_CLUSTER_PG") <(echo "$USED_CLUSTER_PG"))
UNUSED_INSTANCE_PG=$(comm -23 <(echo "$ALL_INSTANCE_PG") <(echo "$USED_INSTANCE_PG"))

say "🧩 Unused CLUSTER Parameter Groups:"
echo "$UNUSED_CLUSTER_PG"
say "🧩 Unused INSTANCE Parameter Groups:"
echo "$UNUSED_INSTANCE_PG"

if [[ -z "$UNUSED_CLUSTER_PG" && -z "$UNUSED_INSTANCE_PG" ]]; then
  echo "✅ No unused parameter groups found. Nothing to delete."
  exit 0
fi

if ! ask "Proceed to delete unused parameter groups above"; then
  echo "❎ Aborted by user."
  exit 0
fi

# --- Delete unused cluster PGs ---
for pg in $UNUSED_CLUSTER_PG; do
  echo "Deleting unused cluster parameter group: $pg"
  aws rds delete-db-cluster-parameter-group --region "$REGION" --db-cluster-parameter-group-name "$pg" || echo "⚠️ Failed to delete $pg"
done

# --- Delete unused instance PGs ---
for pg in $UNUSED_INSTANCE_PG; do
  echo "Deleting unused instance parameter group: $pg"
  aws rds delete-db-parameter-group --region "$REGION" --db-parameter-group-name "$pg" || echo "⚠️ Failed to delete $pg"
done

echo "✅ Cleanup complete."
