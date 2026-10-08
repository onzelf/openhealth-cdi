#!/usr/bin/env bash
# Run once on the L0 host, after `tofu apply -var flower_placement=ecs ...`.
# Moves /vault onto the shared EFS volume so the hub (here) and the Flower
# server (on ECS) keep reading and writing the same files.
#
#   ./mount-vault.sh <efs-id>
set -euo pipefail

FS=${1:?usage: mount-vault.sh <efs-id>}
VAULT=${VAULT:-$HOME/openhealth-cdi/src/vfp-governance/verifier/vault}
EFS_DNS="$FS.efs.eu-west-2.amazonaws.com"

sudo apt-get install -y -q nfs-common >/dev/null

# 1. copy what L0 already has into the volume (models, runs, holder keys)
sudo mkdir -p /mnt/efs-root
sudo mount -t nfs4 -o nfsvers=4.1 "$EFS_DNS:/" /mnt/efs-root
sudo mkdir -p /mnt/efs-root/vault
sudo rsync -a "$VAULT"/ /mnt/efs-root/vault/
sudo umount /mnt/efs-root

# 2. mount the volume where the containers expect /vault, and keep it across reboots
sudo mount -t nfs4 -o nfsvers=4.1 "$EFS_DNS:/vault" "$VAULT"
grep -q "$EFS_DNS:/vault" /etc/fstab || \
  echo "$EFS_DNS:/vault $VAULT nfs4 nfsvers=4.1,_netdev 0 0" | sudo tee -a /etc/fstab >/dev/null

# 3. containers bound to the old directory must be restarted to see the mount;
#    the frontend's nginx caches the hub's address, so it restarts too
docker restart fc-hub holder-signer issuer-hospitala issuer-hospitalb fcac-frontend >/dev/null
echo "vault on EFS: $(df -h "$VAULT" | tail -1 | awk '{print $1}')"
