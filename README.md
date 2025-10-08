````markdown
# Aurora PostgreSQL Blue/Green Upgrade Script

`aurora-bg-upgrade.sh` automates an Aurora PostgreSQL Blue/Green deployment for in-place major or minor upgrades with minimal downtime.  
The script prepares parameter groups, enables logical replication on the source, creates or reuses a Blue/Green deployment, waits for synchronization, presents endpoints for validation, then performs a controlled switchover.

---

## Features

- Prompts interactively for the **target engine version**  
- Verifies that the version is available in the chosen AWS Region  
- Ensures `rds.logical_replication` is enabled on the source cluster parameter group  
- Creates a pre-upgrade **cluster snapshot**  
- Reuses an existing Blue/Green deployment if found, otherwise creates a new one  
- Displays Green writer/reader endpoints for testing  
- Performs a safe **switchover** and offers to delete the Blue/Green wrapper  
- Includes health checks, timeouts, and clear color-coded progress output  

---

## Requirements

- Bash  
- AWS CLI  
- jq  

**IAM permissions required:**
- `rds:Describe*`, `rds:CreateBlueGreenDeployment`, `rds:SwitchoverBlueGreenDeployment`, `rds:DeleteBlueGreenDeployment`
- `rds:CreateDBClusterParameterGroup`, `rds:ModifyDBClusterParameterGroup`, `rds:CopyDBClusterParameterGroup`
- `rds:ModifyDBCluster`, `rds:DescribeDBClusters`, `rds:FailoverDBCluster`, `rds:RebootDBInstance`
- `rds:CreateDBClusterSnapshot`, `rds:DescribeDBClusterSnapshots`

---

## Inputs

You can set environment variables or provide inputs interactively.

| Variable | Description | Example |
|-----------|--------------|----------|
| `REGION` | AWS region | `us-east-1` |
| `CLUSTER_ID` | Aurora cluster identifier (or instance, resolved automatically) | `my-aurora-cluster` |
| `TARGET_VERSION` | Target Aurora PostgreSQL engine version | `15.4` |

---

## Usage

```bash
# Make script executable
chmod +x aurora-bg-upgrade.sh

# Run interactively
./aurora-bg-upgrade.sh

# Run with predefined variables
REGION=us-east-1 CLUSTER_ID=my-cluster ./aurora-bg-upgrade.sh

# Run fully automated
REGION=us-east-1 CLUSTER_ID=my-cluster TARGET_VERSION=15.4 ./aurora-bg-upgrade.sh
````

---

## Step-by-step process

1. **Discover context**
   Detects region, cluster, and version information; validates that target version is offered.

2. **Enable logical replication on source**
   Clones or creates a custom cluster parameter group with `rds.logical_replication=1`, applies and waits until all members are in-sync.

3. **Create pre-upgrade snapshot**
   Offers to create a safety snapshot before continuing.

4. **Create or reuse Blue/Green deployment**
   If one exists for this source, it reuses it. Otherwise, it creates new cluster/instance parameter groups and deploys the Blue/Green setup.

5. **Validate Green environment**
   Prints endpoints and version for testing before switchover.

6. **Switchover**
   Executes controlled switchover to the new (Green) environment and confirms completion.

7. **Cleanup (optional)**
   Offers to delete the Blue/Green wrapper while keeping clusters intact.

---

## Safety and idempotency

* Designed to be **re-runnable** — reuses existing deployments when found
* All waits include timeouts and clear status logs
* Creates snapshot before upgrade for rollback safety
* Minimizes downtime using controlled failovers

---

## Exit codes

| Code  | Meaning                               |
| ----- | ------------------------------------- |
| 0     | Success                               |
| 99    | Trapped error (with line and command) |
| Other | AWS CLI error code                    |

---

## Troubleshooting

* **`non-fast-forward` push**:
  Run `git pull --rebase origin main` then `git push`.

* **`Invalid endpoint: https://rds..amazonaws.com`**:
  Region not set — specify `REGION` manually or choose interactively.

* **Timeout waiting for sync**:
  Check instance events and maintenance actions, then re-run script.

* **Blue/Green stuck**:
  Use `aws rds describe-blue-green-deployments` to inspect details, then re-run.

---

## Related utilities in this repo

* `aurora-bg-switchover.sh`: Performs switchover only
* `clean_unused_pg.sh`: Finds and deletes unused parameter groups
* `revert_to_previous_parameter_group.sh`: Restores previous parameter group
* `bg-upgrade.sh`: Simplified upgrade version

---

## Disclaimer

Always test in a **staging** environment first.
Review downtime impact, failover behavior, and application reconnection before applying to production.

