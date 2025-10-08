#!/usr/bin/env bash
set -euo pipefail

REGION="us-east-1"
CLUSTER="ios-repos-scraper-ppe"
ORIGINAL_CPG="microservice-iosreposscraper-ppe-dbclusterparametergroupiosreposscraper-qy2qriwe5hrg"

echo "Attach original cluster parameter group back"
aws rds modify-db-cluster \
  --region "$REGION" \
  --db-cluster-identifier "$CLUSTER" \
  --db-cluster-parameter-group-name "$ORIGINAL_CPG" \
  --apply-immediately

echo "Reboot all DB instances so the change takes effect"
mapfile -t INSTANCES < <(aws rds describe-db-instances --region "$REGION" \
  --query "DBInstances[?DBClusterIdentifier=='$CLUSTER'].DBInstanceIdentifier" --output text)
for id in "${INSTANCES[@]}"; do
  echo "Rebooting $id"
  aws rds reboot-db-instance --region "$REGION" --db-instance-identifier "$id"
done

echo "Wait until all instances are available"
while :; do
  states=$(aws rds describe-db-instances --region "$REGION" \
    --query "DBInstances[?DBClusterIdentifier=='$CLUSTER'].DBInstanceStatus" --output text | tr '\n' ' ')
  echo "Instance states: ${states:-none}"
  [[ -n "$states" && "$states" =~ ^(available[[:space:]]+)*available[[:space:]]*$ ]] && break
  sleep 12
done

echo "Verify the cluster is using the original parameter group"
aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$CLUSTER" \
  --query "DBClusters[0].[DBClusterIdentifier,DBClusterParameterGroup]" --output table

echo "Done. Parameter group reverted."

