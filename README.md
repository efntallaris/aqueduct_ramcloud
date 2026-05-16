# ramcloud-cloudlab

End-to-end driver for cloning, building, and smoke-testing
[PlatformLab/RAMCloud](https://github.com/PlatformLab/RAMCloud) on a
CloudLab `redisN` cluster running Ubuntu 22.04.

The upstream RAMCloud repo is archived and was last tested on Ubuntu Trusty
with gcc-4.x. This driver applies the patches needed to build it on a modern
toolchain (gcc-11, Python 3) and runs the bundled `ClusterPerf basic`
benchmark across all detected peer nodes.

## What it does

```
setup_ramcloud.sh
├── 1. detect_nodes.sh     parse /etc/hosts for redisN, probe via `sudo ssh`
├── 2. install_deps.sh     apt deps on this node
├── 3. install_deps.sh     apt deps on every peer (over sudo ssh)
├── 4. git clone RAMCloud + submodules
├── 4b.patch python shebangs (python -> python2) across the tree
├── 5. make ZOOKEEPER_LIB=-lzookeeper_mt -j$(nproc)
│         (retries with -Wno-error if first pass fails)
├── 6. sudo rsync RAMCloud/ to every peer at the same absolute path
├── 7. write RAMCloud/scripts/localconfig.py with the detected host list
└── 8. run_cluster.sh: cluster.py + obj.master/apps/ClusterPerf basic
```

## Assumptions

- Ubuntu 22.04 on every node.
- Hostnames `redis0..redisN` resolvable via `/etc/hosts` (CloudLab default).
- Passwordless `sudo` locally.
- `/root/.ssh/id_rsa` provisioned on every node by the CloudLab profile, so
  `sudo ssh redisX` works root-to-root. The invoking user's account does
  *not* need an ssh key.
- The cluster's NICs are ConnectX-4 Lx in Ethernet/RoCE mode (no native
  Infiniband subnet manager). The default transport is therefore `tcp`,
  not `basic+infud`.
- Filesystem is **not** NFS-shared; the driver fans the built tree out to
  every peer via `sudo rsync`.

## Running

```bash
# Full pipeline (deps + clone + build + run smoke test).
bash setup_ramcloud.sh

# Skip phases that have already succeeded.
SKIP_DEPS=1                bash setup_ramcloud.sh
SKIP_DEPS=1 SKIP_BUILD=1   bash setup_ramcloud.sh
SKIP_RUN=1                 bash setup_ramcloud.sh   # build only

# Override the cluster step.
TRANSPORT=basic+udp        bash scripts/run_cluster.sh
CLIENT='obj.master/apps/ClusterPerf readDist'  bash scripts/run_cluster.sh
```

A successful run ends with `=== SMOKE TEST PASSED ===` and the
`ClusterPerf basic` summary (read/write latency and bandwidth per object
size) is in `RAMCloud/logs/latest/client1.<coordinator-host>.log` on the
coordinator node.

## Patches applied to RAMCloud at clone time

The cloned tree gets four small in-place patches before it builds:

| File | Patch |
| --- | --- |
| `scripts/*.py`, `pragmas.py`, `bindings/`, `systemtests/`, `benchmarks/` | Shebang `python` → `python2`; on Ubuntu 22.04 `python` is Python 3 and these scripts use `import commands` / Py2 print statements. |
| `src/RuntimeOptions.h` | Move the nested `Parseable` struct from `PRIVATE:` to `PUBLIC:`; gcc-11 enforces nested-type access where older gccs let it slide. |
| `scripts/remoteexec.py` | Remove the kill-on-stdin-EOF behavior, which fires immediately when the cluster driver runs non-interactively and kills short commands like `ensureServers` before they finish. |
| `scripts/cluster.py` | Fan-out `mkdir -p logs/<timestamp>/perfcounters` to every peer over ssh, because the filesystem isn't NFS-shared. |

The shebang patch is re-applied automatically on every run; the other
three are applied once after the initial `git clone`.

## Layout

```
.
├── setup_ramcloud.sh                  # top-level driver
├── scripts/
│   ├── detect_nodes.sh                # writes nodes.txt
│   ├── install_deps.sh                # idempotent apt install (root)
│   ├── make_localconfig.py            # writes RAMCloud/scripts/localconfig.py
│   └── run_cluster.sh                 # cleans up stale procs, runs cluster.py
├── RAMCloud/                          # cloned source tree (gitignored)
├── nodes.txt                          # detected host list (gitignored)
└── setup_logs/                        # build + driver logs (gitignored)
```
