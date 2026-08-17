#!/usr/bin/env bash

set -euo pipefail

# Quick and dirty script to create a working Dirac-style SMS from a
# freshly-installed Rocky 9 x86_64 system.

# Assumes there are two NICs, one already set up for Internet access,
# and the other will be internal to the HPC network.

# Some of this is adapted from https://github.com/mikerenfro/rcsi-howto-openhpc/blob/main/Vagrantfile

TZ=America/Chicago
# Set timezone to avoid chrony issue
timedatectl set-timezone $TZ
date
# Configure default network interface
DEFAULT_NETDEV=$(ip route show default | awk '{print $5}')
FALLBACK_DNS=8.8.8.8
nmcli con mod ${DEFAULT_NETDEV} ipv4.dns "${FALLBACK_DNS}" ipv4.ignore-auto-dns yes ; nmcli dev reapply ${DEFAULT_NETDEV}
# Configure internal network interface
INTERNAL_NETDEV=$(ip link | grep BROADCAST | grep -v ${DEFAULT_NETDEV} | awk '{print $2}' | sed 's/://g') # only works correctly when there are exactly 2 normal (broadcast-style) interfaces
nmcli con add type ethernet ifname ${INTERNAL_NETDEV} con-name "ohpc" ip4 172.16.0.1/16
nmcli con up ohpc
systemctl disable --now firewalld

# Prepare OpenHPC installation
dnf -y install http://repos.openhpc.community/OpenHPC/3/EL_9/$(arch)/ohpc-release-3-1.el9.$(arch).rpm
crb enable
dnf -y install docs-ohpc
for p in input.local $(arch)/warewulf/slurm/recipe.sh; do
    cp -p /opt/ohpc/pub/doc/recipes/rocky9/${p} ~
done

# provide defaults for input.local: network interface, default gateway, node count, node config, IPMI
cat > ~/overrides.local <<EOD
export sms_eth_internal=${INTERNAL_NETDEV}
export ipv4_gateway=172.16.0.1
export provision_wait=1
export update_slurm_nodeconfig=1
export compute_prefix=c
export num_computes=4

# https://stackoverflow.com/a/49971213
c_mac=("e8:6a:64:f6:7c:f7" "e8:6a:64:f6:7c:cd" "e8:6a:64:f6:7c:cf" "e8:6a:64:f6:7d:e7")
export AR_DATA=$(declare -p c_mac)
eval "$AR_DATA"
# don't forget to escape interal variables nested in values
export slurm_node_config="NodeName=\\${compute_prefix}[1-\\${num_computes}] CPUs=4 State=UNKNOWN"
export has_ipmi=0
export enable_nhc=0
EOD

# Fix recipe.sh: fix node time sync, remove extra sleep at end
perl -pi.bak -e \
    "s#systemctl restart chronyd#systemctl restart chronyd ; dnf -y install examples-ohpc ; echo 'makestep 1.0 3' >> /opt/ohpc/pub/examples/chrony.conf.ww#g;" \
    ~/recipe.sh

# Run installation recipe
. ~/overrides.local
OHPC_INPUT_LOCAL=~/input.local ~/recipe.sh
