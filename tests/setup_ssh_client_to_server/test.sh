#!/bin/bash
set -x

mkdir -p /root/.ssh
chmod 700 /root/.ssh
cat "$TMT_TREE/tests/ssh_keys/id_ecdsa.pub" >>/root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
