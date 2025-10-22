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

