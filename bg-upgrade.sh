#!/usr/bin/env bash
set -euo pipefail

# ================= defaults =================
REGION="${REGION:-us-east-1}"
TARGET_VERSION="${TARGET_VERSION:-14.15}"
SRC_PG_FAMILY="aurora-postgresql13"
TGT_PG_FAMILY="aurora-postgresql14"

# ================= flags and args =================
AUTO_SWITCHOVER=false
DRY_RUN=false
INPLACE_OK=false
CLUSTER_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-switchover) AUTO_SWITCHOVER=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --inplace-ok) INPLACE_OK=true; shift ;;
    *) CLUSTER_ID="$1"; shift ;;
  esac
done

if [[ -z "$CLUSTER_ID" ]]; then
  read -rp "Enter Aurora cluster identifier: " CLUSTER_ID
fi

# ================= deps =================
require(){ command -v "$1" >/dev/null || { echo "Missing dependency: $1"; exit 1; }; }
require aws
require jq

# ================= helpers =================
say(){ printf "\n%s\n" "$1"; }
run(){ if $DRY_RUN; then echo "[DRY-RUN] aws $*"; else aws "$@"; fi; }

get_writer_and_readers(){
  WRITER_ID=$(aws rds describe-db-clusters --region "$REGION" \
    --db-cluster-identifier "$CLUSTER_ID" \
    --query "DBClusters[0].DBClusterMembers[?IsClusterWriter==\`true\`].DBInstanceIdentifier" \
    --output text 2>/dev/null || echo "")
  mapfile -t READERS < <(aws rds describe-db-clusters --region "$REGION" \
    --db-cluster-identifier "$CLUSTER_ID" \
    --query "DBClusters[0].DBClusterMembers[?IsClusterWriter==\`false\`].DBInstanceIdentifier" \
    --output text 2>/dev/null || true)

  if [[ -z "${WRITER_ID:-}" || "$WRITER_ID" == "None" ]]; then
    WRITER_ID=$(aws rds describe-db-instances --region "$REGION" \
      --query "DBInstances[?DBClusterIdentifier=='$CLUSTER_ID' && DBInstanceRole=='WRITER'].DBInstanceIdentifier" \
      --output text 2>/dev/null || echo "")
  fi
  if [[ ${#READERS[@]} -eq 0 || "${READERS[0]:-}" == "None" ]]; then
    mapfile -t READERS < <(aws rds describe-db-instances --region "$REGION" \
      --query "DBInstances[?DBClusterIdentifier=='$CLUSTER_ID' && DBInstanceRole=='READER'].DBInstanceIdentifier" \
      --output text 2>/dev/null || true)
  fi
}

wait_instances_available(){
  local cluster="$1"
  while :; do
    local states
    states=$(aws rds describe-db-instances --region "$REGION" \
      --query "DBInstances[?DBClusterIdentifier=='$cluster'].DBInstanceStatus" \
      --output text | tr '\n' ' ')
    echo "Instance states: ${states:-none}"
    [[ -n "$states" ]] || { sleep 8; continue; }
    if [[ "$states" =~ ^(available[[:space:]]+)*available[[:space:]]*$ ]]; then break; fi
    sleep 10
  done
}

# ---- quota helpers ----
cpgs_in_use(){
  aws rds describe-db-clusters --region "$REGION" \
    --query "DBClusters[].DBClusterParameterGroup" --output text | tr '\t' '\n' | sort -u
}
dpgs_in_use(){
  aws rds describe-db-instances --region "$REGION" \
    --query "DBInstances[?DBClusterIdentifier=='$CLUSTER_ID'].DBParameterGroups[].DBParameterGroupName" \
    --output text | tr '\t' '\n' | sort -u
}

gc_temp_cpgs(){
  local inuse; inuse="$(cpgs_in_use)"
  for p in $(aws rds describe-db-cluster-parameter-groups --region "$REGION" \
      --query "DBClusterParameterGroups[?starts_with(DBClusterParameterGroupName, 'apg13-bgd-') || starts_with(DBClusterParameterGroupName, 'apg14-bgd-')].DBClusterParameterGroupName" \
      --output text); do
    if ! grep -qx "$p" <<<"$inuse"; then
      echo "GC: deleting unused cluster parameter group $p"
      aws rds delete-db-cluster-parameter-group --region "$REGION" \
        --db-cluster-parameter-group-name "$p" >/dev/null 2>&1 || true
    fi
  done
}
gc_temp_dpgs(){
  local inuse; inuse="$(dpgs_in_use || true)"
  for p in $(aws rds describe-db-parameter-groups --region "$REGION" \
      --query "DBParameterGroups[?starts_with(DBParameterGroupName, 'apg14-bgd-inst-')].DBParameterGroupName" \
      --output text); do
    if ! grep -qx "$p" <<<"$inuse"; then
      echo "GC: deleting unused instance parameter group $p"
      aws rds delete-db-parameter-group --region "$REGION" \
        --db-parameter-group-name "$p" >/dev/null 2>&1 || true
    fi
  done
}

# ---- cluster CPG helpers ----
ensure_src_cpg(){
  local current="$1" family="$2"
  local reuse name rc

  if $INPLACE_OK && [[ ! "$current" =~ ^default\. ]]; then
    echo "$current"; return
  fi

  reuse=$(aws rds describe-db-cluster-parameter-groups --region "$REGION" \
    --query "reverse(sort_by(DBClusterParameterGroups[?starts_with(DBClusterParameterGroupName, 'apg13-bgd-src-')], &DBClusterParameterGroupName))[:1].DBClusterParameterGroupName" \
    --output text)
  if [[ -n "$reuse" && "$reuse" != "None" ]]; then echo "$reuse"; return; fi

  name="apg13-bgd-src-$(date +%Y%m%d-%H%M%S)"
  if [[ "$current" =~ ^default\. ]]; then
    set +e
    aws rds create-db-cluster-parameter-group --region "$REGION" \
      --db-cluster-parameter-group-name "$name" \
      --db-parameter-group-family "$family" \
      --description "BGD source with logical replication" >/dev/null 2>err.txt; rc=$?
    set -e
  else
    set +e
    aws rds copy-db-cluster-parameter-group --region "$REGION" \
      --source-db-cluster-parameter-group-identifier "$current" \
      --target-db-cluster-parameter-group-identifier "$name" \
      --target-db-cluster-parameter-group-description "BGD source with logical replication" >/dev/null 2>err.txt; rc=$?
    set -e
  fi
  if [[ ${rc:-0} -eq 0 ]]; then echo "$name"; return; fi
  if grep -qi "DBParameterGroupQuotaExceeded" err.txt; then
    gc_temp_cpgs
    aws rds create-db-cluster-parameter-group --region "$REGION" \
      --db-cluster-parameter-group-name "$name" \
      --db-parameter-group-family "$family" \
      --description "BGD source with logical replication" >/dev/null
    echo "$name"; return
  fi
  echo "Failed to prepare SOURCE CPG; see err.txt" >&2; exit 3
}

ensure_tgt_cpg(){
  local family="$1"
  local reuse name rc
  reuse=$(aws rds describe-db-cluster-parameter-groups --region "$REGION" \
    --query "reverse(sort_by(DBClusterParameterGroups[?starts_with(DBClusterParameterGroupName, 'apg14-bgd-tgt-')], &DBClusterParameterGroupName))[:1].DBClusterParameterGroupName" \
    --output text)
  if [[ -n "$reuse" && "$reuse" != "None" ]]; then echo "$reuse"; return; fi
  name="apg14-bgd-tgt-$(date +%Y%m%d-%H%M%S)"
  set +e
  aws rds create-db-cluster-parameter-group --region "$REGION" \
    --db-cluster-parameter-group-name "$name" \
    --db-parameter-group-family "$family" \
    --description "BGD target PG14 with logical replication" >/dev/null 2>err2.txt; rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then echo "$name"; return; fi
  if grep -qi "DBParameterGroupQuotaExceeded" err2.txt; then
    gc_temp_cpgs
    aws rds create-db-cluster-parameter-group --region "$REGION" \
      --db-cluster-parameter-group-name "$name" \
      --db-parameter-group-family "$family" \
      --description "BGD target PG14 with logical replication" >/dev/null
    echo "$name"; return
  fi
  echo "Failed to prepare TARGET CPG; see err2.txt" >&2; exit 3
}

# ---- INSTANCE DPG helper for target ----
ensure_tgt_dpg(){
  local family="$1"
  local reuse name rc
  reuse=$(aws rds describe-db-parameter-groups --region "$REGION" \
    --query "reverse(sort_by(DBParameterGroups[?starts_with(DBParameterGroupName, 'apg14-bgd-inst-')], &DBParameterGroupName))[:1].DBParameterGroupName" \
    --output text)
  if [[ -n "$reuse" && "$reuse" != "None" ]]; then echo "$reuse"; return; fi
  name="apg14-bgd-inst-$(date +%Y%m%d-%H%M%S)"
  set +e
  aws rds create-db-parameter-group --region "$REGION" \
    --db-parameter-group-name "$name" \
    --db-parameter-group-family "$family" \
    --description "BGD target PG14 INSTANCE parameter group" >/dev/null 2>err3.txt; rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then echo "$name"; return; fi
  if grep -qi "DBParameterGroupQuotaExceeded" err3.txt; then
    gc_temp_dpgs
    aws rds create-db-parameter-group --region "$REGION" \
      --db-parameter-group-name "$name" \
      --db-parameter-group-family "$family" \
      --description "BGD target PG14 INSTANCE parameter group" >/dev/null
    echo "$name"; return
  fi
  echo "Failed to prepare TARGET DPG; see err3.txt" >&2; exit 3
}

# ---- wait helpers for BG and green writer ----
wait_bg_available(){
  local id="$1"
  local status rc
  echo "Waiting for Blue/Green [$id] to be AVAILABLE..."
  while :; do
    set +e
    status=$(aws rds describe-blue-green-deployments --region "$REGION" \
      --blue-green-deployment-identifier "$id" \
      --query "BlueGreenDeployments[0].Status" --output text)
    rc=$?
    set -e
    if [[ $rc -ne 0 || -z "$status" || "$status" == "None" ]]; then
      echo "BG status: <not ready yet> …sleeping"
      sleep 10
      continue
    fi
    echo "BG status: $status"
    [[ "$status" == "AVAILABLE" ]] && break
    [[ "$status" == "INVALID_CONFIGURATION" || "$status" == "SWITCHOVER_FAILED" ]] && {
      echo "BG in error state: $status"
      exit 4
    }
    sleep 20
  done
}

wait_green_writer(){
  local bg_id="$1"
  local green
  green=$(aws rds describe-blue-green-deployments --region "$REGION" \
    --blue-green-deployment-identifier "$bg_id" \
    --query "BlueGreenDeployments[0].Targets[0].TargetDBClusterIdentifier" \
    --output text)
  echo "Green cluster id: $green"
  while :; do
    local ver st members
    ver=$(aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$green" \
      --query "DBClusters[0].EngineVersion" --output text)
    st=$(aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$green" \
      --query "DBClusters[0].Status" --output text)
    members=$(aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$green" \
      --query "length(DBClusters[0].DBClusterMembers)" --output text)
    echo "Green status: $st, members: $members, engine: $ver"
    if [[ "$st" == "available" && "$ver" == "$TARGET_VERSION" && $members -gt 0 ]]; then
      echo "Green writer is up on version $ver"
      break
    fi
    sleep 20
  done
}

# ---- create BG with retries, logs to stderr only, returns ID only ----
create_bg_with_retries(){
  local new_tgt_cpg="$1" new_tgt_dpg="$2"
  local retries=5 attempt=1
  local bg_name="bg-${CLUSTER_ID}-v${TARGET_VERSION//./-}"
  local account_id source_arn err rc bg_id

  account_id=$(aws sts get-caller-identity --query Account --output text)
  source_arn="arn:aws:rds:${REGION}:${account_id}:cluster:${CLUSTER_ID}"

  while (( attempt <= retries )); do
    >&2 echo "Attempt $attempt to create Blue/Green: $bg_name"
    set +e
    bg_id=$(aws rds create-blue-green-deployment --region "$REGION" \
      --blue-green-deployment-name "$bg_name" \
      --source "$source_arn" \
      --target-engine-version "$TARGET_VERSION" \
      --target-db-cluster-parameter-group-name "$new_tgt_cpg" \
      --target-db-parameter-group-name "$new_tgt_dpg" \
      --query "BlueGreenDeployment.BlueGreenDeploymentIdentifier" \
      --output text 2>err.txt)
    rc=$?
    set -e

    if [[ $rc -eq 0 && -n "$bg_id" && "$bg_id" != "None" ]]; then
      echo "$bg_id"
      return 0
    fi

    err="$(cat err.txt || true)"
    >&2 echo "AWS said: $err"

    if grep -qi "requires writer instance to be in-sync with cluster parameter group" <<<"$err"; then
      >&2 echo "Writer not in-sync yet. Rebooting writer and retrying..."
      get_writer_and_readers
      if [[ -n "${WRITER_ID:-}" && "$WRITER_ID" != "None" ]]; then
        aws rds reboot-db-instance --region "$REGION" --db-instance-identifier "$WRITER_ID"
        aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$WRITER_ID"
        wait_instances_available "$CLUSTER_ID"
      else
        >&2 echo "No writer resolved during retry, aborting."
        return 1
      fi
      sleep 10
    else
      >&2 echo "Create failed with unexpected error, not retrying this type."
      return 1
    fi
    ((attempt++))
  done

  >&2 echo "Failed to create Blue/Green after $retries attempts."
  return 1
}

# ================= intro =================
say "=============================================="
say " Aurora PostgreSQL Blue/Green Deployment Flow "
say "=============================================="
echo "Cluster:         $CLUSTER_ID"
echo "Region:          $REGION"
echo "Target version:  $TARGET_VERSION"
echo "Auto switchover: $AUTO_SWITCHOVER"
echo "Dry run:         $DRY_RUN"
echo "In-place OK:     $INPLACE_OK"
echo

# ---- describe cluster ----
SRC_DESC=$(aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$CLUSTER_ID")
ENGINE=$(echo "$SRC_DESC" | jq -r '.DBClusters[0].Engine')
SRC_VERSION=$(echo "$SRC_DESC" | jq -r '.DBClusters[0].EngineVersion')
SRC_CPG=$(echo "$SRC_DESC" | jq -r '.DBClusters[0].DBClusterParameterGroup')
if [[ "$ENGINE" != "aurora-postgresql" ]]; then
  echo "Cluster engine is '$ENGINE', expected 'aurora-postgresql'. Exiting."
  exit 2
fi
echo "Current engine version: $SRC_VERSION"
echo "Current cluster parameter group: $SRC_CPG"

# ---- Step 1: snapshot ----
SNAP="${CLUSTER_ID}-pre-bgd-$(date +%Y%m%d-%H%M%S)"
say "STEP 1: Create snapshot $SNAP"
run rds create-db-cluster-snapshot --region "$REGION" \
  --db-cluster-identifier "$CLUSTER_ID" \
  --db-cluster-snapshot-identifier "$SNAP"
if ! $DRY_RUN; then
  aws rds wait db-cluster-snapshot-available --region "$REGION" --db-cluster-snapshot-identifier "$SNAP"
  echo "Snapshot ready."
fi

# ---- Step 2: source CPG with logical replication ----
say "STEP 2: Prepare SOURCE parameter group with logical replication"
NEW_SRC_CPG="$(ensure_src_cpg "$SRC_CPG" "$SRC_PG_FAMILY")"
NEW_SRC_CPG="${NEW_SRC_CPG//$'\r'/}"; NEW_SRC_CPG="${NEW_SRC_CPG//$'\n'/}"
echo "Using SOURCE CPG: $NEW_SRC_CPG"

run rds modify-db-cluster-parameter-group --region "$REGION" \
  --db-cluster-parameter-group-name "$NEW_SRC_CPG" \
  --parameters "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot"

run rds modify-db-cluster --region "$REGION" \
  --db-cluster-identifier "$CLUSTER_ID" \
  --db-cluster-parameter-group-name "$NEW_SRC_CPG" \
  --apply-immediately

say "Rebooting DB instances to apply new CPG"
get_writer_and_readers
echo "Detected writer: ${WRITER_ID:-<none>}"
echo "Detected readers: ${READERS[*]:-<none>}"

if [[ ${#READERS[@]} -gt 0 ]]; then
  for id in "${READERS[@]}"; do run rds reboot-db-instance --region "$REGION" --db-instance-identifier "$id" & done
  wait
fi

if [[ -n "${WRITER_ID:-}" && "$WRITER_ID" != "None" ]]; then
  run rds reboot-db-instance --region "$REGION" --db-instance-identifier "$WRITER_ID"
  if ! $DRY_RUN; then
    echo "Waiting for writer $WRITER_ID to be available..."
    aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$WRITER_ID"
  fi
else
  echo "No writer instance found for cluster $CLUSTER_ID. Stopping to avoid unsafe state."
  exit 2
fi

if ! $DRY_RUN; then wait_instances_available "$CLUSTER_ID"; fi

# ---- Step 3: create Blue/Green with retries ----
say "STEP 3: Create Blue/Green deployment targeting $TARGET_VERSION"
NEW_TGT_CPG="$(ensure_tgt_cpg "$TGT_PG_FAMILY")"
NEW_TGT_CPG="${NEW_TGT_CPG//$'\r'/}"; NEW_TGT_CPG="${NEW_TGT_CPG//$'\n'/}"
echo "Using TARGET CPG (cluster): $NEW_TGT_CPG"

NEW_TGT_DPG="$(ensure_tgt_dpg "$TGT_PG_FAMILY")"
NEW_TGT_DPG="${NEW_TGT_DPG//$'\r'/}"; NEW_TGT_DPG="${NEW_TGT_DPG//$'\n'/}"
echo "Using TARGET DPG (instance): $NEW_TGT_DPG"

# enable logical replication on target cluster CPG as well
run rds modify-db-cluster-parameter-group --region "$REGION" \
  --db-cluster-parameter-group-name "$NEW_TGT_CPG" \
  --parameters "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot"

if $DRY_RUN; then
  echo "[DRY-RUN] would create Blue/Green deployment"
  BG_ID="dry-run-bgd-id"
else
  set +e
  BG_ID="$(create_bg_with_retries "$NEW_TGT_CPG" "$NEW_TGT_DPG")"
  rc=$?
  set -e
  BG_ID="${BG_ID//$'\r'/}"; BG_ID="${BG_ID//$'\n'/}"
  BG_ID="${BG_ID//$'\t'/}"; BG_ID="${BG_ID//[$' \f\v']/}"
  if [[ $rc -ne 0 || -z "${BG_ID:-}" || "$BG_ID" == "None" ]]; then
    echo "Create Blue/Green failed. Last error:"
    [[ -f err.txt ]] && sed -n '1,200p' err.txt || echo "(no err.txt captured)"
    exit 6
  fi
fi

if ! $DRY_RUN; then
  # new robust waits
  wait_bg_available "$BG_ID"
  wait_green_writer "$BG_ID"
  echo "Blue/Green deployment $BG_ID is AVAILABLE and Green has a writer on $TARGET_VERSION"
fi

# ---- Step 4: switchover ----
if $AUTO_SWITCHOVER; then
  say "STEP 4: Auto switchover"
  run rds switchover-blue-green-deployment --region "$REGION" \
    --blue-green-deployment-identifier "$BG_ID" \
    --switchover-timeout 600
  if ! $DRY_RUN; then
    echo "Waiting for SWITCHOVER_COMPLETED..."
    while :; do
      status=$(aws rds describe-blue-green-deployments --region "$REGION" \
        --blue-green-deployment-identifier "$BG_ID" \
        --query "BlueGreenDeployments[0].Status" --output text)
      echo "Blue/Green status: $status"
      [[ "$status" == "SWITCHOVER_COMPLETED" ]] && break
      [[ "$status" == "SWITCHOVER_FAILED" ]] && { echo "Switchover failed"; exit 5; }
      sleep 10
    done
    echo "Switchover completed."
  fi
else
  say "STEP 4: Manual switchover"
  echo "Test GREEN endpoints first, then run:"
  echo "aws rds switchover-blue-green-deployment --region $REGION --blue-green-deployment-identifier $BG_ID"
fi

# ---- Step 5: cleanup wrapper ----
say "STEP 5: Cleanup wrapper, clusters are kept"
run rds delete-blue-green-deployment --region "$REGION" \
  --blue-green-deployment-identifier "$BG_ID" --no-delete-target
echo "Done. Wrapper deleted. Old blue cluster remains for rollback."
