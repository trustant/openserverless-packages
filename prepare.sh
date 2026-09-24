#!/bin/bash
set -euo pipefail
cd "$(dirname $0)"

echo "=== PREPARE ==="

echo "=== install k3s ==="

if which k3s-killall.sh
then sudo k3s-killall.sh &&  sudo k3s-uninstall.sh
fi

curl -sfL https://get.k3s.io | sudo sh -s - --node-name trustant

while ! sudo k3s kubectl get storageclass | grep default
do sleep 1
done

mkdir -p ~/.ops/tmp
sudo cat /etc/rancher/k3s/k3s.yaml >~/.ops/tmp/kubeconfig
ops debug kube nodes

echo "=== install openserverless ==="

ops config slim
ops config apihost miniops.me --protocol=http

ops setup kubernetes create

ops setup openserverless streamer deploy
ops setup openserverless system-api deploy
ops setup openserverless tika deploy

echo "=== test ==="

sudo k3s kubectl -n openserveress get ingress
sudo k3s kubectl -n openserverless get sts
sudo k3s kubectl -n openserverless get po

echo "=== trim down openserverless ==="

# cleanup
sudo du -sh /var/lib/rancher
# Cleanup is best-effort: missing runtime images or busy artifacts should not
# abort payload preparation.
runtime_images="$(sudo k3s ctr images list -q | grep -E 'openserverless-runtime-(go|php|java)' || true)"
printf '%s\n' "${runtime_images}" | xargs -r -L1 sudo k3s crictl rmi || true

sudo k3s crictl rmp -a || true
sudo k3s crictl rmi --prune || true
sudo k3s ctr -n k8s.io content prune references || true
sudo du -sh /var/lib/rancher

echo "=== stopping openserverless ==="

sudo systemctl stop k3s
/usr/local/bin/k3s-killall.sh

sync
sleep 2

echo "=== ready to package ==="
