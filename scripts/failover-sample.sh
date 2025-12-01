#!/usr/bin/env bash
set -euo pipefail

echo "1) Confirm primary site health (site-a) and replication status."
echo "2) If primary is lost or to be taken down for maintenance:"
echo "   - Stop application writers on primary."
echo "   - Ensure final WALs are replicated / applied on standby."
echo "3) Promote standby (site-b) to primary using your EDB operator procedure."
echo "4) Re-point application connections to the new primary."
echo "5) Decide what to do with the old primary when it returns."
