#!/usr/bin/env bash
# Parse /etc/hosts for redisN short hostnames (CloudLab populates these),
# probe each via `sudo ssh` (root uses /root/.ssh/id_rsa), and emit the
# surviving list to $1. Self is forced to be the first entry (coordinator).
set -euo pipefail

OUT="${1:-/users/entall/ramcloud_aqueduct/nodes.txt}"

self_short="$(hostname | cut -d. -f1)"
echo "self: $self_short" >&2

mapfile -t candidates < <(
    awk '{ for (i=2; i<=NF; i++) print $i }' /etc/hosts \
      | grep -E '^redis[0-9]+$' \
      | sort -u -V
)

if (( ${#candidates[@]} == 0 )); then
    echo "ERROR: no redisN entries in /etc/hosts" >&2
    exit 1
fi

probe() {
    local host="$1"
    [[ "$host" == "$self_short" ]] && return 0
    sudo ssh -o BatchMode=yes -o ConnectTimeout=3 \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/.ssh/known_hosts \
        "$host" true </dev/null >/dev/null 2>&1
}

found=()
for h in "${candidates[@]}"; do
    if probe "$h"; then
        found+=("$h")
        echo "  $h: ok" >&2
    else
        echo "  $h: unreachable, skipping" >&2
    fi
done

if (( ${#found[@]} == 0 )); then
    echo "ERROR: no reachable redisN hosts" >&2
    exit 1
fi

ordered=()
if printf '%s\n' "${found[@]}" | grep -qx "$self_short"; then
    ordered+=("$self_short")
fi
for h in "${found[@]}"; do
    [[ "$h" == "$self_short" ]] && continue
    ordered+=("$h")
done

printf '%s\n' "${ordered[@]}" > "$OUT"
echo "wrote ${#ordered[@]} hosts to $OUT" >&2
