# aqueduct_ramcloud

Ansible playbooks that clone, patch, build, and smoke-test
[PlatformLab/RAMCloud](https://github.com/PlatformLab/RAMCloud) on a
CloudLab `redisN` cluster running Ubuntu 22.04.

The upstream repo is archived and last targeted Ubuntu Trusty / gcc-4.x;
these playbooks apply the patches needed for gcc-11, Python 3, and
RoCE-mode Mellanox NICs, then run `ClusterPerf basic` across the cluster.

## Requirements

- Ansible 2.10+ on the control node (`apt install ansible`).
- 5 Ubuntu 22.04 nodes named `redis0..redis4` reachable over an internal
  network (default CloudLab profile is fine).
- `/root/.ssh/id_rsa` provisioned on the control node and `authorized_keys`
  set up on every peer (the CloudLab default does this automatically).
- Passwordless `sudo` on the control node.

## Layout

```
.
├── ansible.cfg
├── inventory.ini                 # static, redis0..redis4 grouped
├── site.yml                      # full pipeline (imports all 5 plays)
├── playbooks/
│   ├── 10-deps.yml               # apt deps on every host
│   ├── 20-clone-patch-build.yml  # clone + in-tree patches + make
│   ├── 30-fanout.yml             # rsync built tree to peers
│   ├── 40-config.yml             # render localconfig.py from inventory
│   └── 50-smoke-test.yml         # cleanup + cluster.py + assert
├── templates/
│   └── localconfig.py.j2
├── patches/
│   ├── 02-runtime-options-access.patch
│   ├── 03-remoteexec-stdin.patch
│   └── 04-cluster-logdir-fanout.patch
└── README.md
```

## Running

```bash
# Full pipeline (deps -> clone -> build -> rsync -> config -> smoke test).
sudo ansible-playbook site.yml

# Any single phase, standalone:
sudo ansible-playbook playbooks/10-deps.yml
sudo ansible-playbook playbooks/20-clone-patch-build.yml
sudo ansible-playbook playbooks/50-smoke-test.yml

# Override defaults (transport, backup file, branch) inline.
sudo ansible-playbook site.yml -e ramcloud_transport=basic+udp
```

`ansible-playbook` must be invoked with `sudo` because it reads
`/root/.ssh/id_rsa` to ssh to peers as root. The user's own account is
not expected to have an ssh key.

A successful run ends with the `=== SMOKE TEST PASSED ===` assertion and
prints the last 60 lines of the `ClusterPerf basic` output (per-object-size
read/write latency and bandwidth).

## What the playbooks patch in RAMCloud

| Patch | Why |
| --- | --- |
| `02-runtime-options-access.patch` | gcc-11 enforces nested-type access; promotes `RuntimeOptions::Parseable` to PUBLIC. |
| `03-remoteexec-stdin.patch` | Removes kill-on-stdin-EOF, which fires immediately in non-interactive ssh and kills short commands like `ensureServers`. |
| `04-cluster-logdir-fanout.patch` | `cluster.py` creates `logs/<ts>/` only locally; this fans it out to peers (the filesystem isn't NFS-shared on CloudLab). |
| shebang fix (in playbook) | `#!/usr/bin/env python` → `python2` across the tree; Ubuntu 22.04's `python` is python3, and these scripts use `import commands` / py2 print. |

## Defaults & overrides

The transport defaults to `tcp`. The cluster's ConnectX-4 Lx cards are in
Ethernet/RoCE mode with no subnet manager, so `basic+infud` won't work
here (results in `lid=0` failures). Override via
`-e ramcloud_transport=...` if you've got native IB.
