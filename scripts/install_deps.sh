#!/usr/bin/env bash
# Install RAMCloud build/runtime dependencies on Ubuntu 22.04.
# Idempotent: re-running is a no-op if everything is already installed.
# Designed to be piped over ssh as well as run locally.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: install_deps.sh must run as root (use sudo)" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

PKGS=(
    build-essential
    git
    make
    ccache
    pkg-config
    python2
    python2-dev
    libboost-all-dev
    libprotobuf-dev
    protobuf-compiler
    libzookeeper-mt-dev
    libpcrecpp0v5
    libpcre3-dev
    libibverbs-dev
    librdmacm-dev
    rdma-core
    ibverbs-providers
    ibverbs-utils
    cmake
    libssl-dev
    doxygen
    rsync
)

apt-get update -qq
apt-get install -y --no-install-recommends "${PKGS[@]}"

# Ensure /usr/bin/python points somewhere (cluster.py shebang is "python").
if ! command -v python >/dev/null 2>&1; then
    if command -v python2 >/dev/null 2>&1; then
        update-alternatives --install /usr/bin/python python /usr/bin/python2 1 >/dev/null
    fi
fi

# Verify Infiniband HCA is visible. Don't fail here — detect_nodes runs this
# on every host and a single bad node should be surfaced clearly, but the
# decision to abort belongs to the driver.
if command -v ibv_devinfo >/dev/null 2>&1; then
    if ibv_devinfo 2>/dev/null | grep -q '^hca_id:'; then
        echo "IB: HCA detected on $(hostname -s)"
    else
        echo "IB: WARNING no HCA on $(hostname -s) (basic+infud will not work here)" >&2
    fi
else
    echo "IB: WARNING ibv_devinfo missing on $(hostname -s)" >&2
fi

echo "deps installed on $(hostname -s)"
