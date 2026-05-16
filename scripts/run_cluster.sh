#!/usr/bin/env bash
# Launch a RAMCloud cluster via scripts/cluster.py and run a smoke-test client.
# Runs cluster.py under sudo so it ssh's to peers as root (the user account
# has no ssh key, root does).
set -euo pipefail

ROOT="/users/entall/ramcloud_aqueduct"
RC="$ROOT/RAMCloud"
NODES="$ROOT/nodes.txt"

[[ -d "$RC" ]]      || { echo "ERROR: $RC missing - run setup_ramcloud.sh first" >&2; exit 1; }
[[ -f "$NODES" ]]   || { echo "ERROR: $NODES missing" >&2; exit 1; }

N=$(wc -l < "$NODES")
SERVERS=$((N - 1))
(( SERVERS >= 1 )) || { echo "ERROR: need >=2 hosts; got $N" >&2; exit 1; }

# NOTE: The CloudLab Mellanox cards on this experiment are ConnectX-4 Lx
# (MT4117) in Ethernet link-layer mode (RoCE-capable, but no native IB SM
# in this profile). 'basic+infud' fails with lid=0. 'basic+udp' is too
# lossy for enlistment (the coordinator can't keep up and servers flag
# each other as crashed). TCP is the reliable fallback.
TRANSPORT="${TRANSPORT:-tcp}"
# ClusterPerf lives at obj.<branch>/apps/ClusterPerf. cluster.py runs the
# client from the RAMCloud/ working directory, so a relative path is fine.
BRANCH="$(git -C "$RC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo master)"
CLIENT="${CLIENT:-obj.${BRANCH}/apps/ClusterPerf basic}"

echo "launching cluster: ${SERVERS} server(s), transport=${TRANSPORT}"
echo "client: ${CLIENT}"
echo

# Clean up any stale RAMCloud processes / backup files from prior runs.
# cluster.py's kill-on-timeout doesn't reliably reach re-parented daemons.
# Use `pkill -x` (exact process name) rather than `-f` (full cmdline) to
# avoid self-matching the pkill invocation's own argv.
echo "cleaning up stale processes/files on all hosts..."
for h in $(cat "$NODES"); do
    sudo ssh -o BatchMode=yes -o UserKnownHostsFile=/root/.ssh/known_hosts "$h" \
        'pkill -9 -x coordinator 2>/dev/null; \
         pkill -9 -x server 2>/dev/null; \
         pkill -9 -x ClusterPerf 2>/dev/null; \
         rm -f /tmp/ramcloud-backup.log; \
         true'
done

cd "$RC"
# HOME=/root so ssh uses /root/.ssh (known_hosts + id_rsa); CloudLab only
# provisions root's ssh key, not the invoking user's.
# cluster.py exits 1 if logs contain ANY WARNING (including benign teardown
# noise), so we don't trust its exit code -- we trust the client log.
set +e
sudo -E HOME=/root python2 scripts/cluster.py \
    --servers="$SERVERS" \
    --replicas=1 \
    --transport="$TRANSPORT" \
    --timeout=300 \
    --client="$CLIENT"
set -e

# Relax error handling for the report phase — cluster.py just exited (maybe
# with status 1 due to benign teardown warnings) and we still want to print
# the client log.
set +e
set +o pipefail

LATEST_LOGS=$(ls "$RC/logs/" 2>/dev/null | grep -E '^[0-9]{14}$' | sort | tail -1)
COORD_HOST=$(tail -n 1 "$NODES")
CLIENT_LOG_REMOTE="$RC/logs/$LATEST_LOGS/client1.${COORD_HOST}.log"

echo
echo "=== client log ($COORD_HOST:$CLIENT_LOG_REMOTE) ==="
sudo ssh -o BatchMode=yes -o UserKnownHostsFile=/root/.ssh/known_hosts \
    "$COORD_HOST" "tail -n 120 $CLIENT_LOG_REMOTE 2>/dev/null"

# Smoke-test verdict: did the benchmark produce its summary lines?
if sudo ssh -o BatchMode=yes -o UserKnownHostsFile=/root/.ssh/known_hosts \
       "$COORD_HOST" \
       "grep -q 'basic.writeBw1M' $CLIENT_LOG_REMOTE 2>/dev/null"; then
    echo
    echo "=== SMOKE TEST PASSED ==="
    exit 0
else
    echo
    echo "=== SMOKE TEST FAILED (no basic.writeBw1M in $CLIENT_LOG_REMOTE) ==="
    exit 1
fi
