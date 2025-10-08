# Aurora PostgreSQL Blue/Green Upgrade Script

`aurora-bg-upgrade.sh` automates an Aurora PostgreSQL Blue/Green deployment for in-place major or minor upgrades with minimal downtime.  
The script prepares parameter groups, enables logical replication on the source, creates or reuses a Blue/Green deployment, waits for synchronization, presents endpoints for validation, then performs a controlled switchover.

## Features

1. Prompts interactively for the **target engine version**.  
2. Verifies that the target version is available in the chosen AWS Region.  
3. Ensures `rds.logical_replication` is enabled on the source cluster parameter group and safely applies it.  
4. Creates a pre-upgrade **cluster snapshot**.  
5. Reuses an existing Blue/Green deployment for the same source when found, otherwise creates a new one with matching parameter groups.  
6. Prints Green writer and reader endpoints for testing before switchover.  
7. Performs the **switchover** and optionally deletes the Blue/Green “wrapper” while keeping the clusters.  
8. Includes health checks, progress output, and timeouts.

## Requirements

- **Bash**, **AWS CLI**, **jq**
- AWS credentials with permissions:
  - `rds:Describe*`
  - `rds:CreateBlueGreenDeployment`, `rds:SwitchoverBlueGreenDeployment`, `rds:DeleteBlueGreenDeployment`
  - `rds:CreateDBClusterParameterGroup`, `rds:ModifyDBClusterParameterGroup`, `rds:CopyDBClusterParameterGroup`
  - `rds:ModifyDBCluster`, `rds:FailoverDBCluster`, `rds:RebootDBInstance`
  - `rds:CreateDBClusterSnapshot`, `rds:DescribeDBClusterSnapshots`
- Network access to AWS RDS APIs in your Region


## Inputs

Environment variables can be preset or entered interactively.

| Variable | Description | Example |
|-----------|--------------|----------|
| `REGION` | AWS Region | `us-east-1` |
| `CLUSTER_ID` | Aurora cluster identifier | `my-prod-cluster` |
| `TARGET_VERSION` | Target Aurora PostgreSQL engine version | `15.4` |


## Usage

```bash
# Make executable
chmod +x aurora-bg-upgrade.sh

# Option A: fully interactive
./aurora-bg-upgrade.sh

# Option B: predefine some inputs
REGION=us-east-1 CLUSTER_ID=my-aurora ./aurora-bg-upgrade.sh

# Option C: everything preset
REGION=us-east-1 CLUSTER_ID=my-aurora TARGET_VERSION=15.4 ./aurora-bg-upgrade.sh
```

You will see clearly numbered steps, confirmation prompts, and real-time cluster status updates.

## Step Overview

1. **Discover cluster details**  
   Confirms Region, current engine version, and verifies that the target version exists.

2. **Enable logical replication**  
   Clones or creates a custom parameter group if needed, enables `rds.logical_replication`, applies it, and waits until instances are in sync.

3. **Create pre-upgrade snapshot**  
   Optional but highly recommended for rollback safety.

4. **Create or reuse Blue/Green deployment**  
   - Reuses an existing deployment for the same source if available.  
   - Otherwise, creates new cluster and instance parameter groups for the target family.

5. **Validate Green cluster**  
   Displays Green writer and reader endpoints and waits for user confirmation before switchover.

6. **Switchover**  
   Performs switchover with a timeout and confirms completion.

7. **Cleanup (optional)**  
   Optionally deletes only the Blue/Green wrapper, preserving clusters.


## Safety and Idempotency

- **Re-runnable**: If a Blue/Green deployment already exists, it is reused.  
- **Wait loops** with clear timeouts and error messages.  
- **Safe parameter group application order** to minimize downtime.  
- **Pre-upgrade snapshot** prompt for rollback safety.

## Exit Codes

| Code | Meaning |
|------|----------|
| `0` | Success |
| `99` | Trapped error (line and command shown) |
| Non-zero | AWS CLI error codes |

## Related Scripts

- `aurora-bg-switchover.sh`: Perform only the switchover step.  
- `clean_unused_pg.sh`: Detect and clean unused parameter groups.  
- `revert_to_previous_parameter_group.sh`: Reattach a previous parameter group after rollback.  
- `bg-upgrade.sh`: Alternative entry point for specific environments.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| **“Invalid endpoint: https://rds..amazonaws.com”** | Ensure `REGION` is set correctly. |
| **Timeout waiting for parameter group sync** | Check instance reboots or pending maintenance. Re-run the script. |
| **Blue/Green stuck** | Inspect with `aws rds describe-blue-green-deployments` and fix configuration before re-running. |
| **Push to GitHub rejected (non-fast-forward)** | Run `git pull --rebase origin main` then `git push`. |


## Disclaimer

Use at your own risk.  
Test in a **staging environment** before applying to production.  
Ensure maintenance windows and failover behavior align with your SLA.

---
