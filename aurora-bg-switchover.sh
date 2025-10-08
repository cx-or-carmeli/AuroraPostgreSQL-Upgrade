#!/usr/bin/env bash
set -euo pipefail

# stop aws cli from opening a pager and stalling
export AWS_PAGER=""
export AWS_DEFAULT_OUTPUT=json

# show exactly where a failure happened
trap 'echo; echo "💥 Script failed at line $LINENO"; exit 1' ERR

# Requirements: aws
REGION="${REGION:-us-east-1}"
TARGET_VERSION="${TARGET_VERSION:-14.15}"

BG_NAME="${BG_NAME:-}"           # optional: e.g. bg-ios-repos-scraper-ppe-v14-15
BLUE_CLUSTER="${BLUE_CLUSTER:-}" # optional: e.g. ios-repos-scraper-ppe

AUTO_SNAPSHOT=false
AUTO_SWITCH=false
DELETE_WRAPPER=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --bg-name) BG_NAME="$2"; shift 2 ;;
    --blue-cluster) BLUE_CLUSTER="$2"; shift 2 ;;
    --auto-snapshot) AUTO_SNAPSHOT=true; shift ;;
    --auto-switch) AUTO_SWITCH=true; shift ;;
    --delete-wrapper) DELETE_WRAPPER=true; shift ;;
    -y|--yes) AUTO_SNAPSHOT=true; AUTO_SWITCH=true; DELETE_WRAPPER=false; shift ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

require(){ command -v "$1" >/dev/null || { echo "Missing dependency: $1"; exit 1; }; }
require aws

say(){ printf "\n%s\n" "$1"; }
ask(){ read -r -p "$1 (y/n): " a; [[ "$a" =~ ^[Yy]$ ]]; }

# ---------- Resolve BG by name or blue cluster ----------
resolve_bg(){
  local id=""
  if [[ -n "$BG_NAME" ]]; then
    id=$(aws rds describe-blue-green-deployments --region "$REGION" \
      --query "BlueGreenDeployments[?BlueGreenDeploymentName=='$BG_NAME'].BlueGreenDeploymentIdentifier" \
      --output text | tr '\t' '\n' | head -n1)
  elif [[ -n "$BLUE_CLUSTER" ]]; then
    id=$(aws rds describe-blue-green-deployments --region "$REGION" \
      --query "BlueGreenDeployments[?contains(Sources[*].Source, '$BLUE_CLUSTER')].BlueGreenDeploymentIdentifier" \
      --output text | tr '\t' '\n' | head -n1)
  fi
  echo "$id"
}

wait_bg_available(){
  local id="$1" status rc
  say "Waiting for Blue/Green [$id] to be AVAILABLE..."
  while :; do
    set +e
    status=$(aws rds describe-blue-green-deployments --region "$REGION" \
      --blue-green-deployment-identifier "$id" \
      --query "BlueGreenDeployments[0].Status" --output text)
    rc=$?
    set -e
    [[ $rc -ne 0 || -z "$status" || "$status" == "None" ]] && { echo "BG status: <not ready yet>"; sleep 10; continue; }
    echo "BG status: $status"
    [[ "$status" == "AVAILABLE" ]] && break
    [[ "$status" =~ INVALID_CONFIGURATION|SWITCHOVER_FAILED ]] && { echo "BG error: $status"; exit 4; }
    sleep 15
  done
}

# ---------- Robust green id resolver (Targets → Tag → Name) ----------
get_green_cluster_id(){
  local bg_id="$1"
  local green="" blue=""

  # 1) standard field
  green=$(aws rds describe-blue-green-deployments --region "$REGION" \
    --blue-green-deployment-identifier "$bg_id" \
    --query "BlueGreenDeployments[0].Targets[?TargetDBClusterIdentifier!=''].TargetDBClusterIdentifier | [0]" \
    --output text 2>/dev/null || echo "")
  [[ -n "$green" && "$green" != "None" ]] && { echo "$green"; return 0; }

  # 2) any Target entry
  green=$(aws rds describe-blue-green-deployments --region "$REGION" \
    --blue-green-deployment-identifier "$bg_id" \
    --query "BlueGreenDeployments[0].Targets[].TargetDBClusterIdentifier" \
    --output text 2>/dev/null | tr '\t' '\n' | head -n1)
  [[ -n "$green" && "$green" != "None" ]] && { echo "$green"; return 0; }

  # 3) tag lookup on all clusters
  mapfile -t CLUSTERS < <(aws rds describe-db-clusters --region "$REGION" \
    --query "DBClusters[].{Arn:DBClusterArn,Id:DBClusterIdentifier}" \
    --output text 2>/dev/null || true)
  if [[ ${#CLUSTERS[@]} -gt 0 ]]; then
    local arn id
    for line in "${CLUSTERS[@]}"; do
      arn=$(awk '{print $1}' <<<"$line"); id=$(awk '{print $2}' <<<"$line")
      if aws rds list-tags-for-resource --region "$REGION" --resource-name "$arn" \
           --query "TagList[?Key=='aws:rds:blue-green-deployment-id' && Value=='$bg_id']" \
           --output text 2>/dev/null | grep -q .; then
        echo "$id"; return 0
      fi
    done
  fi

  # 4) final fallback by name pattern "<blue>-green-*"
  blue=$(aws rds describe-blue-green-deployments --region "$REGION" \
    --blue-green-deployment-identifier "$bg_id" \
    --query "BlueGreenDeployments[0].Sources[0].Source" --output text 2>/dev/null)
  if [[ -n "$blue" && "$blue" != "None" ]]; then
    green=$(aws rds describe-db-clusters --region "$REGION" \
      --query "reverse(sort_by(DBClusters[?starts_with(DBClusterIdentifier, '${blue}-green-')], &DBClusterCreateTime))[0].DBClusterIdentifier" \
      --output text 2>/dev/null)
  fi

  [[ "$green" == "None" ]] && green=""
  echo "$green"
}

resolve_green_with_timeout(){
  local id="$1" timeout_secs="${2:-900}" elapsed=0
  local green=""
  echo "Resolving GREEN cluster id..."
  while (( elapsed < timeout_secs )); do
    green="$(get_green_cluster_id "$id")"
    if [[ -n "$green" ]]; then
      echo "$green"; return 0
    fi
    echo "Waiting for green cluster id …"
    sleep 10; elapsed=$((elapsed+10))
  done
  echo ""; return 1
}

# ---------- Wait for green writer on the target version ----------
wait_green_writer(){
  local green="$1"
  say "Waiting for GREEN cluster [$green] writer on $TARGET_VERSION..."
  while :; do
    set +e
    local st ver members
    st=$(aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$green" \
      --query "DBClusters[0].Status" --output text 2>/dev/null || echo "")
    ver=$(aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$green" \
      --query "DBClusters[0].EngineVersion" --output text 2>/dev/null || echo "")
    members=$(aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$green" \
      --query "length(DBClusters[0].DBClusterMembers)" --output text 2>/dev/null || echo "0")
    set -e
    echo "GREEN status: ${st:-unknown}, members: ${members:-0}, engine: ${ver:-unknown}"
    if [[ "$st" == "available" && "$ver" == "$TARGET_VERSION" && "$members" =~ ^[1-9][0-9]*$ ]]; then
      echo "✅ Green writer is up on version $ver"
      break
    fi
    sleep 15
  done
}

show_green_endpoints(){
  local green="$1"
  say "GREEN endpoints"
  aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$green" \
    --query "DBClusters[0].{Writer:Endpoint,Reader:ReaderEndpoint,Engine:Engine,Version:EngineVersion}" \
    --output table
}

snapshot_blue_if_wanted(){
  local blue="$1"
  local snap="$blue-pre-switchover-$(date +%Y%m%d-%H%M%S)"
  if $AUTO_SNAPSHOT || ask "Create last-minute snapshot of BLUE [$blue]: $snap"; then
    say "Creating snapshot $snap"
    aws rds create-db-cluster-snapshot --region "$REGION" \
      --db-cluster-identifier "$blue" \
      --db-cluster-snapshot-identifier "$snap" >/dev/null
    aws rds wait db-cluster-snapshot-available --region "$REGION" \
      --db-cluster-snapshot-identifier "$snap"
    echo "Snapshot ready."
  else
    echo "Skipping snapshot."
  fi
}

switchover_now(){
  local bg_id="$1"
  if $AUTO_SWITCH || ask "Proceed with switchover now"; then
    say "Switching over..."
    aws rds switchover-blue-green-deployment --region "$REGION" \
      --blue-green-deployment-identifier "$bg_id" \
      --switchover-timeout 600 >/dev/null
    while :; do
      local s
      s=$(aws rds describe-blue-green-deployments --region "$REGION" \
        --blue-green-deployment-identifier "$bg_id" \
        --query "BlueGreenDeployments[0].Status" --output text)
      echo "BG status: $s"
      [[ "$s" == "SWITCHOVER_COMPLETED" ]] && break
      [[ "$s" == "SWITCHOVER_FAILED" ]] && { echo "Switchover failed"; exit 5; }
      sleep 10
    done
    echo "Switchover completed ✅"
  else
    echo "Switchover skipped."
  fi
}

delete_wrapper_if_wanted(){
  local bg_id="$1"
  if $DELETE_WRAPPER || ask "Delete the BG wrapper and keep both clusters"; then
    say "Deleting wrapper..."
    aws rds delete-blue-green-deployment --region "$REGION" \
      --blue-green-deployment-identifier "$bg_id" --no-delete-target >/dev/null
    echo "Wrapper deleted. Both clusters remain."
  else
    echo "Wrapper kept. You can delete later."
  fi
}

# ================= flow =================
say "Blue/Green switchover helper"
echo "Region: $REGION"

BG_ID="$(resolve_bg)"
if [[ -z "$BG_ID" || "$BG_ID" == "None" ]]; then
  echo "Could not resolve BG deployment. Provide --bg-name or --blue-cluster."
  exit 2
fi
echo "BG: $BG_ID"

wait_bg_available "$BG_ID"

GREEN="$(resolve_green_with_timeout "$BG_ID" 900)"   # up to 15 minutes
if [[ -z "$GREEN" ]]; then
  echo "Could not resolve green cluster id after waiting. Aborting safely."
  exit 3
fi
echo "GREEN cluster: $GREEN"

wait_green_writer "$GREEN"
show_green_endpoints "$GREEN"

BLUE=$(aws rds describe-blue-green-deployments --region "$REGION" \
  --blue-green-deployment-identifier "$BG_ID" \
  --query "BlueGreenDeployments[0].Sources[0].Source" --output text)
echo "BLUE cluster: $BLUE"

snapshot_blue_if_wanted "$BLUE"
switchover_now "$BG_ID"
delete_wrapper_if_wanted "$BG_ID"

say "Done. Please validate your app on the standard endpoints."
