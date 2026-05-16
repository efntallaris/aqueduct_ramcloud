#!/usr/bin/env bash
# End-to-end driver: clone RAMCloud, install deps on every peer, build,
# fan out, and run a smoke-test cluster.
#
# Runs the clone/build steps as the invoking user; uses `sudo ssh` for
# all peer access (peer nodes have /root/.ssh/id_rsa provisioned by
# CloudLab; this user does not have a personal ssh key).
#
# Usage:  bash setup_ramcloud.sh
#         SKIP_DEPS=1   bash setup_ramcloud.sh
#         SKIP_BUILD=1  bash setup_ramcloud.sh
#         SKIP_RUN=1    bash setup_ramcloud.sh
set -euo pipefail

ROOT="/users/entall/ramcloud_aqueduct"
SCRIPTS="$ROOT/scripts"
RC="$ROOT/RAMCloud"
NODES="$ROOT/nodes.txt"
LOG_DIR="$ROOT/setup_logs"
mkdir -p "$LOG_DIR"

REPO_URL="https://github.com/PlatformLab/RAMCloud.git"

# `sudo ssh` options used for every peer hop.
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile=/root/.ssh/known_hosts)

log()  { printf '\n=== %s ===\n' "$*"; }
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

chmod +x "$SCRIPTS"/*.sh

# -- 1. detect peers --------------------------------------------------------
log "1/8 detecting peer nodes"
bash "$SCRIPTS/detect_nodes.sh" "$NODES"
cat "$NODES"
SELF="$(hostname | cut -d. -f1)"
mapfile -t ALL < "$NODES"
PEERS=()
for h in "${ALL[@]}"; do
    [[ "$h" == "$SELF" ]] && continue
    PEERS+=("$h")
done

# -- 2. install deps locally ------------------------------------------------
if [[ "${SKIP_DEPS:-0}" != "1" ]]; then
    log "2/8 installing deps on $SELF"
    sudo -E bash "$SCRIPTS/install_deps.sh" 2>&1 | tee "$LOG_DIR/deps-$SELF.log"

    # -- 3. install deps on every peer (root over sudo ssh) -----------------
    log "3/8 installing deps on peers: ${PEERS[*]:-<none>}"
    for h in "${PEERS[@]}"; do
        echo "--- $h ---"
        sudo ssh "${SSH_OPTS[@]}" "$h" "bash -s" \
            < "$SCRIPTS/install_deps.sh" 2>&1 | tee "$LOG_DIR/deps-$h.log"
    done
else
    log "2-3/8 SKIP_DEPS=1, skipping apt install"
fi

# -- 4. clone --------------------------------------------------------------
if [[ ! -d "$RC/.git" ]]; then
    log "4/8 cloning $REPO_URL"
    git clone "$REPO_URL" "$RC"
    git -C "$RC" submodule update --init --recursive
else
    log "4/8 RAMCloud already cloned; refreshing submodules"
    git -C "$RC" submodule update --init --recursive
fi

# Patch python2-only build scripts: their shebang says `python`, but on
# Ubuntu 22.04 `python` points to python3 and these use Py2-only modules
# like `commands` plus Py2-only print statements. Patch every .py in the
# RAMCloud source tree (excluding gtest/logcabin/gtest, those are vendored
# and their own scripts use `python` correctly via their own shebangs).
log "4b/8 patching python shebangs to python2"
find "$RC" -name '*.py' \
    -not -path "$RC/gtest/*" \
    -not -path "$RC/logcabin/gtest/*" \
    -print0 \
    | xargs -0 sed -i '1s|^#!/usr/bin/env python$|#!/usr/bin/env python2|'

# -- 5. build --------------------------------------------------------------
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    log "5/8 building (make -j$(nproc))"
    BUILD_LOG="$LOG_DIR/build.log"
    if ! ( cd "$RC" && make ZOOKEEPER_LIB='-lzookeeper_mt' -j"$(nproc)" ) \
            2>&1 | tee "$BUILD_LOG"; then
        echo
        echo "build failed, retrying with -Wno-error..."
        echo "--- last 50 lines of $BUILD_LOG ---"
        tail -50 "$BUILD_LOG"
        echo "---"
        if ! ( cd "$RC" && make ZOOKEEPER_LIB='-lzookeeper_mt' \
                    EXTRACXXFLAGS='-Wno-error -Wno-deprecated-declarations' \
                    -j"$(nproc)" ) 2>&1 | tee -a "$BUILD_LOG"; then
            fail "build failed; full log: $BUILD_LOG"
        fi
    fi
else
    log "5/8 SKIP_BUILD=1, skipping make"
fi

# -- 6. fan out binaries (sudo rsync, ssh as root) -------------------------
if (( ${#PEERS[@]} > 0 )); then
    log "6/8 rsyncing RAMCloud/ to ${#PEERS[@]} peer(s)"
    RSYNC_RSH="ssh ${SSH_OPTS[*]}"
    for h in "${PEERS[@]}"; do
        echo "--- $h ---"
        sudo ssh "${SSH_OPTS[@]}" "$h" "mkdir -p $RC"
        sudo rsync -a --delete -e "$RSYNC_RSH" "$RC/" "$h:$RC/"
    done
else
    log "6/8 no peers, skipping fan-out"
fi

# -- 7. localconfig.py -----------------------------------------------------
log "7/8 writing localconfig.py"
python3 "$SCRIPTS/make_localconfig.py" "$NODES" "$RC/scripts/localconfig.py"
for h in "${PEERS[@]}"; do
    sudo rsync -a -e "ssh ${SSH_OPTS[*]}" \
        "$RC/scripts/localconfig.py" "$h:$RC/scripts/localconfig.py"
done

# -- 8. run smoke test -----------------------------------------------------
if [[ "${SKIP_RUN:-0}" != "1" ]]; then
    log "8/8 launching cluster + smoke test"
    bash "$SCRIPTS/run_cluster.sh"
else
    log "8/8 SKIP_RUN=1, cluster not started"
fi

log "done"
