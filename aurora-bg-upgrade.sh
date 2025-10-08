#!/usr/bin/env bash
# Aurora PostgreSQL Blue/Green upgrade script
# Requires: aws CLI, jq

set -euo pipefail
set -E
trap 'err "$LINENO" "$BASH_COMMAND"' ERR

# ========= UI helpers =========
is_tty(){ [[ -t 1 ]]; }
if is_tty; then
  C_RESET='\033[0m'
  C_DIM='\033[2m'
  C_BOLD='\033[1m'
  C_BLUE='\033[38;5;33m'
  C_CYAN='\033[38;5;44m'
  C_GREEN='\033[38;5;40m'
  C_YELLOW='\033[38;5;178m'
  C_RED='\033[38;5;160m'
  C_GREY='\033[38;5;245m'
else
  C_RESET=; C_DIM=; C_BOLD=; C_BLUE=; C_CYAN=; C_GREEN=; C_YELLOW=; C_RED=; C_GREY=
fi

banner(){
  printf "\n${C_BOLD}${C_BLUE}==============================================${C_RESET}\n"
  printf   "${C_BOLD}${C_CYAN} Aurora PostgreSQL Blue/Green Deployment Flow ${C_RESET}\n"
  printf   "${C_BOLD}${C_BLUE}==============================================${C_RESET}\n"
}
info(){   printf "${C_CYAN}ℹ %s${C_RESET}\n"   "$*"; }
ok(){     printf "${C_GREEN}✓ %s${C_RESET}\n"   "$*"; }
warn(){   printf "${C_YELLOW}! %s${C_RESET}\n"  "$*"; }
fail(){   printf "${C_RED}✗ %s${C_RESET}\n"   "$*"; }
dim(){    printf "${C_GREY}%s${C_RESET}\n"     "$*"; }
step_n=0
step(){   step_n=$((step_n+1)); printf "\n${C_BOLD}${C_BLUE}STEP %s:${C_RESET} %s\n" "$step_n" "$*"; }
say(){    printf "\n%s\n" "$*"; }
ask(){    local q="$1" ans; printf "${C_BOLD}>>> %s (y/n): ${C_RESET}" "$q"; read -r ans; [[ "$ans" =~ ^[Yy]$ ]]; }
err(){    local ln="$1" cmd="$2"; fail "ERROR at line ${ln}, last command: ${cmd}"; exit 99; }

# ========= inputs =========
REGION="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
CLUSTER_ID="${CLUSTER_ID:-}"
TARGET_VERSION="${TARGET_VERSION:-}"

# ========= generic helpers =========
require(){ command -v "$1" >/dev/null || { fail "Missing dependency: $1"; exit 1; }; }
require aws; require jq
ts(){ date +%Y%m%d-%H%M%S; }
major_of(){ echo "$1" | awk -F. '{print $1}'; }

ensure_region(){
  if [[ -z "${REGION:-}" ]]; then REGION="$(aws configure get region 2>/dev/null || true)"; fi
  while [[ -z "${REGION:-}" ]]; do read -r -p ">>> Enter AWS region, e.g. us-east-1: " REGION; done
  ok "Using region: $REGION"
}

prompt_cluster(){
  local input
  if [[ -n "${CLUSTER_ID:-}" ]]; then
    printf ">>> Enter Aurora cluster identifier to upgrade [${CLUSTER_ID}]: "
    read -r input
    CLUSTER_ID="${input:-$CLUSTER_ID}"
  else
    while [[ -z "${CLUSTER_ID:-}" ]]; do
      printf ">>> Enter Aurora cluster identifier to upgrade: "
      read -r CLUSTER_ID
    done
  fi
}

prompt_target_version(){
  local input
  if [[ -n "${TARGET_VERSION:-}" ]]; then
    printf ">>> Enter target Aurora engine version [${TARGET_VERSION}]: "
    read -r input
    TARGET_VERSION="${input:-$TARGET_VERSION}"
  else
    while [[ -z "${TARGET_VERSION:-}" ]]; do
      printf ">>> Enter target Aurora engine version, e.g. 15.4: "
      read -r TARGET_VERSION
    done
  fi
}

resolve_cluster(){
  local id="$1"
  if aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$id" >/dev/null 2>&1; then echo "$id"; return; fi
  local cid
  cid=$(aws rds describe-db-instances --region "$REGION" \
        --db-instance-identifier "$id" \
        --query "DBInstances[0].DBClusterIdentifier" --output text 2>/dev/null || true)
  [[ -n "${cid:-}" && "$cid" != "None" ]] && { echo "$cid"; return; }
  echo ""
}

sanitize_name(){
  local s="$1"
  s="${s//_/}"
  s=$(echo "$s" | tr -cd '[:alnum:]-')
  s=$(echo "$s" | sed -E 's/-+/-/g')
  s="${s%%-}"
  s="${s:0:60}"
  [[ "$s" =~ ^[A-Za-z] ]] || s="bg-${s}"
  echo "$s"
}

cluster_status(){
  aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$CLUSTER_ID" \
    --query 'DBClusters[0].Status' --output text
}
wait_cluster_available(){
  local s
  while :; do
    s="$(cluster_status 2>/dev/null || echo "unknown")"
    dim "Cluster status: $s"
    [[ "$s" == "available" ]] && break
    sleep 10
  done
}

members_json(){
  aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$CLUSTER_ID" \
    --query 'DBClusters[0].DBClusterMembers[].{id:DBInstanceIdentifier,writer:IsClusterWriter,status:DBClusterParameterGroupStatus}' --output json
}
members_count(){ jq -r 'length' <<<"$(members_json)"; }

reboot_instance(){
  local id="$1"
  info "Rebooting instance $id"
  aws rds reboot-db-instance --region "$REGION" --db-instance-identifier "$id" >/dev/null
  wait_cluster_available
}

cluster_failover(){
  local target="${1:-}"
  wait_cluster_available
  if [[ -n "$target" ]]; then
    info "Initiating cluster failover to reader $target"
    aws rds failover-db-cluster --region "$REGION" --db-cluster-identifier "$CLUSTER_ID" \
      --target-db-instance-identifier "$target" >/dev/null
  else
    info "Initiating cluster failover"
    aws rds failover-db-cluster --region "$REGION" --db-cluster-identifier "$CLUSTER_ID" >/dev/null
  fi
  wait_cluster_available
}

get_param_value(){
  local group="$1" name="$2"
  aws rds describe-db-cluster-parameters --region "$REGION" \
    --db-cluster-parameter-group-name "$group" \
    --query "Parameters[?ParameterName=='$name'].ParameterValue" --output text 2>/dev/null || true
}

wait_bg_status(){
  local bg_id="$1" target="$2" status attempts=0
  while :; do
    status=$(aws rds describe-blue-green-deployments --region "$REGION" \
      --blue-green-deployment-identifier "$bg_id" \
      --query "BlueGreenDeployments[0].Status" --output text)
    dim "BG status: $status"
    [[ "$status" == "$target" ]] && break
    case "$status" in
      SWITCHOVER_FAILED|INVALID_CONFIGURATION|DELETING) fail "Blue or Green deployment failed with state: $status";;
    esac
    sleep 15
    attempts=$((attempts+1))
    [[ $attempts -gt 240 ]] && fail "Timeout waiting for BG status $target"
  done
}

heal_until_insync(){
  local attempts=0
  while :; do
    if [[ "$(cluster_status)" != "available" ]]; then sleep 10; continue; fi
    local mj cnt
    mj="$(members_json)"
    cnt="$(members_count)"
    echo "$mj" | jq -r '.[] | " - \(.id): writer=\(.writer) status=\(.status)"' | sed "1 s/^/${C_GREY}CPG member statuses:\n${C_RESET}/"

    if [[ "$cnt" -eq 1 ]]; then
      local wid wst
      wid="$(jq -r '.[] | .id' <<<"$mj")"
      wst="$(jq -r '.[] | .status' <<<"$mj")"
      if [[ "$wst" == "pending-reboot" ]]; then
        warn "Single instance cluster, writer pending-reboot"
        if ask "Reboot writer $wid now, brief downtime will occur"; then
          reboot_instance "$wid"
        else
          fail "Cannot proceed without applying parameter group"
        fi
      fi
    else
      while IFS= read -r rid; do reboot_instance "$rid"; done \
        < <(jq -r '.[] | select(.writer==false and .status=="pending-reboot") | .id' <<<"$mj")
      local w_id w_status
      w_id="$(jq -r '.[] | select(.writer==true) | .id' <<<"$mj")"
      w_status="$(jq -r '.[] | select(.writer==true) | .status' <<<"$mj")"
      if [[ "$w_status" == "pending-reboot" ]]; then
        local target
        target="$(jq -r '.[] | select(.writer==false and .status=="in-sync") | .id' <<<"$mj" | head -n1 || true)"
        [[ -z "$target" ]] && target="$(jq -r '.[] | select(.writer==false) | .id' <<<"$mj" | head -n1 || true)"
        cluster_failover "$target"
        reboot_instance "$w_id"
      fi
    fi

    local ok_all
    ok_all=$(jq -r '[ .[] | .status=="in-sync" ] | all' <<<"$(members_json)")
    [[ "$ok_all" == "true" ]] && { ok "All instances are in-sync"; break; }
    sleep 10
    attempts=$((attempts+1))
    [[ $attempts -gt 120 ]] && fail "Timeout waiting for parameter group sync"
  done
}

# ---- Blue/Green helpers ----
find_existing_bg(){
  aws rds describe-blue-green-deployments --region "$REGION" \
    --query "BlueGreenDeployments[?Source=='$SRC_ARN' && Status!=\`DELETED\`].BlueGreenDeploymentIdentifier | [-1]" \
    --output text 2>/dev/null || true
}
bg_details_json(){
  local bg_id="$1"
  aws rds describe-blue-green-deployments --region "$REGION" \
    --blue-green-deployment-identifier "$bg_id"
}
bg_target_engine_version(){
  local bg_id="$1"
  bg_details_json "$bg_id" | jq -r '.BlueGreenDeployments[0].TargetEngineVersion // empty'
}

# ========= main =========
banner
ensure_region
prompt_target_version
info "Target version: ${TARGET_VERSION}"

prompt_cluster
info "Cluster input: ${CLUSTER_ID}"
ask "Continue with these settings" || exit 0

REAL_CLUSTER="$(resolve_cluster "$CLUSTER_ID")"
[[ -z "$REAL_CLUSTER" ]] && { fail "Cluster not found in region ${REGION}"; }
CLUSTER_ID="$REAL_CLUSTER"
ok "Using cluster: ${CLUSTER_ID}"

SRC_DESC=$(aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$CLUSTER_ID")
ENGINE=$(echo "$SRC_DESC" | jq -r '.DBClusters[0].Engine')
SRC_VERSION=$(echo "$SRC_DESC" | jq -r '.DBClusters[0].EngineVersion')
SRC_ARN=$(echo "$SRC_DESC" | jq -r '.DBClusters[0].DBClusterArn')
SRC_CPG=$(echo "$SRC_DESC" | jq -r '.DBClusters[0].DBClusterParameterGroup')
[[ "$ENGINE" == "aurora-postgresql" ]] || { fail "Unsupported engine"; }

SRC_MAJOR="$(major_of "$SRC_VERSION")"
TGT_MAJOR="$(major_of "$TARGET_VERSION")"
SRC_PG_FAMILY="aurora-postgresql${SRC_MAJOR}"
TGT_PG_FAMILY="aurora-postgresql${TGT_MAJOR}"

dim "Engine: $ENGINE"
dim "Current version: $SRC_VERSION"
dim "Cluster Parameter Group: $SRC_CPG"
ok  "Families: source $SRC_PG_FAMILY, target $TGT_PG_FAMILY"

aws rds describe-db-engine-versions --region "$REGION" --engine aurora-postgresql \
  --engine-version "$TARGET_VERSION" --query 'DBEngineVersions[0].EngineVersion' --output text >/dev/null
ok "Target engine version $TARGET_VERSION is offered in $REGION"

# STEP 0 logical replication on SOURCE
step "Ensure logical replication is enabled on SOURCE"
LR_VALUE="$(get_param_value "$SRC_CPG" 'rds.logical_replication' || echo off)"
if [[ "$LR_VALUE" == "on" || "$LR_VALUE" == "1" ]]; then
  ok "Logical replication already enabled on source CPG"
else
  warn "Logical replication is not enabled on current CPG"
  ask "Create or clone a custom CPG with rds.logical_replication=1 and apply it now" || { fail "Cannot proceed without logical replication"; }
  NEW_SRC_CPG="apg${SRC_MAJOR}-bgd-src-$(ts)"
  if [[ "$SRC_CPG" =~ ^default\. ]]; then
    info "Creating custom CPG $NEW_SRC_CPG family $SRC_PG_FAMILY"
    aws rds create-db-cluster-parameter-group --region "$REGION" \
      --db-cluster-parameter-group-name "$NEW_SRC_CPG" \
      --db-parameter-group-family "$SRC_PG_FAMILY" \
      --description "BGD source ${SRC_PG_FAMILY} with logical replication on" >/dev/null
  else
    info "Cloning existing CPG $SRC_CPG to $NEW_SRC_CPG"
    aws rds copy-db-cluster-parameter-group --region "$REGION" \
      --source-db-cluster-parameter-group-identifier "$SRC_CPG" \
      --target-db-cluster-parameter-group-identifier "$NEW_SRC_CPG" \
      --target-db-cluster-parameter-group-description "BGD source clone with logical replication on" >/dev/null
  fi
  info "Enable rds.logical_replication=1 on $NEW_SRC_CPG"
  aws rds modify-db-cluster-parameter-group --region "$REGION" \
    --db-cluster-parameter-group-name "$NEW_SRC_CPG" \
    --parameters "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot" >/dev/null
  info "Attach new CPG to cluster and apply immediately"
  aws rds modify-db-cluster --region "$REGION" \
    --db-cluster-identifier "$CLUSTER_ID" \
    --db-cluster-parameter-group-name "$NEW_SRC_CPG" \
    --apply-immediately >/dev/null
  wait_cluster_available
  heal_until_insync
  ok "Logical replication enabled and in-sync on source"
  SRC_CPG="$NEW_SRC_CPG"
fi

# STEP 1 snapshot
step "Backup snapshot before upgrade"
wait_cluster_available
SNAP="${CLUSTER_ID}-pre-bgd-$(ts)"
if ask "Create snapshot $SNAP"; then
  info "Creating snapshot"
  aws rds create-db-cluster-snapshot --region "$REGION" \
    --db-cluster-identifier "$CLUSTER_ID" \
    --db-cluster-snapshot-identifier "$SNAP" >/dev/null
  info "Waiting for snapshot to be available"
  aws rds wait db-cluster-snapshot-available --region "$REGION" \
    --db-cluster-snapshot-identifier "$SNAP"
  ok "Snapshot ready: $SNAP"
else
  warn "Snapshot creation skipped by user"
fi

# STEP 2 Blue or Green
step "Create or reuse Blue or Green deployment"
ask "Proceed to Blue or Green phase" || exit 0
wait_cluster_available
heal_until_insync

# try to reuse existing BG for this source
EXISTING_BG_ID="$(find_existing_bg)"
if [[ -n "$EXISTING_BG_ID" && "$EXISTING_BG_ID" != "None" ]]; then
  warn "Found existing Blue or Green deployment: $EXISTING_BG_ID, reusing it"
  BG_ID="$EXISTING_BG_ID"
  EXISTING_TGT_VER="$(bg_target_engine_version "$BG_ID")"
  if [[ -n "$EXISTING_TGT_VER" && "$EXISTING_TGT_VER" != "$TARGET_VERSION" ]]; then
    warn "Existing BG target version is $EXISTING_TGT_VER, requested $TARGET_VERSION. Continuing with existing BG."
  fi
else
  # prepare target parameter groups
  NEW_TGT_CPG="apg${TGT_MAJOR}-bgd-tgt-$(ts)"
  info "Creating target cluster CPG: $NEW_TGT_CPG, family: $TGT_PG_FAMILY"
  aws rds create-db-cluster-parameter-group --region "$REGION" \
    --db-cluster-parameter-group-name "$NEW_TGT_CPG" \
    --db-parameter-group-family "$TGT_PG_FAMILY" \
    --description "BGD target ${TGT_PG_FAMILY} with logical replication on" >/dev/null
  aws rds modify-db-cluster-parameter-group --region "$REGION" \
    --db-cluster-parameter-group-name "$NEW_TGT_CPG" \
    --parameters "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot" >/dev/null
  ok "Target cluster CPG prepared"

  NEW_TGT_IPG="apg${TGT_MAJOR}-bgd-tgt-inst-$(ts)"
  info "Creating target instance PG: $NEW_TGT_IPG, family: $TGT_PG_FAMILY"
  aws rds create-db-parameter-group --region "$REGION" \
    --db-parameter-group-name "$NEW_TGT_IPG" \
    --db-parameter-group-family "$TGT_PG_FAMILY" \
    --description "BGD target instance parameter group for ${TGT_PG_FAMILY}" >/dev/null
  ok "Target instance PG prepared"

  VERSION_SLUG="v${TARGET_VERSION//./-}"
  BG_NAME="$(sanitize_name "bg-${CLUSTER_ID}-${VERSION_SLUG}-$(ts)")"

  info "Creating Blue or Green deployment: $BG_NAME"
  BG_JSON=$(aws rds create-blue-green-deployment --region "$REGION" \
    --blue-green-deployment-name "$BG_NAME" \
    --source "$SRC_ARN" \
    --target-engine-version "$TARGET_VERSION" \
    --target-db-cluster-parameter-group-name "$NEW_TGT_CPG" \
    --target-db-parameter-group-name "$NEW_TGT_IPG" \
    --tags Key=owner,Value=sre Key=purpose,Value=apg-upgrade)
  BG_ID=$(echo "$BG_JSON" | jq -r '.BlueGreenDeployment.BlueGreenDeploymentIdentifier')
  ok "Created Blue or Green: $BG_ID"
fi

wait_bg_status "$BG_ID" "AVAILABLE"
ok "Green environment is ready and in sync"

GREEN_CLUSTER_ID=$(aws rds describe-blue-green-deployments --region "$REGION" \
  --blue-green-deployment-identifier "$BG_ID" \
  --query "BlueGreenDeployments[0].Targets[?TargetResourceType=='DB_CLUSTER']|[0].TargetDBClusterIdentifier" \
  --output text)
if [[ -n "$GREEN_CLUSTER_ID" && "$GREEN_CLUSTER_ID" != "None" ]]; then
  dim "$(aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$GREEN_CLUSTER_ID" \
       --query 'DBClusters[0].{GreenWriter:Endpoint,GreenReader:ReaderEndpoint,EngineVersion:EngineVersion}' --output table)"
fi

say "Run application tests against Green"
ask "Ready to switchover to ${TARGET_VERSION}" || exit 0

# STEP 3 switchover
step "Switchover"
aws rds switchover-blue-green-deployment --region "$REGION" \
  --blue-green-deployment-identifier "$BG_ID" \
  --switchover-timeout 600 >/dev/null
wait_bg_status "$BG_ID" "SWITCHOVER_COMPLETED"
ok "Switchover completed"

# STEP 4 cleanup
step "Cleanup wrapper, optional"
if ask "Delete Blue or Green wrapper but keep clusters"; then
  aws rds delete-blue-green-deployment --region "$REGION" \
    --blue-green-deployment-identifier "$BG_ID" --no-delete-target >/dev/null
  ok "Wrapper deleted"
else
  warn "Wrapper not deleted"
fi

say "${C_BOLD}${C_GREEN}DONE${C_RESET}  Production now runs on Aurora PostgreSQL ${C_BOLD}${TARGET_VERSION}${C_RESET}"
