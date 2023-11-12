#!/usr/bin/env bash

# The master script that performs full setup of the entire cluster, starting from absolute zero.
# It is run on the host machine and aggregates all other scripts.

set -xe
dir=$(dirname "$0")
source "$dir/variables.sh"
sudo -v

export USE_CILIUM

case $(uname -s) in
  Darwin)
    brew install \
      qemu wget curl cdrtools dnsmasq tmux cfssl kubernetes-cli helm
    ;;

  Linux)
    sudo apt install -y \
      apt-transport-https ca-certificates qemu-system-x86 curl genisoimage dnsmasq tmux golang-cfssl nfs-kernel-server

    if [[ -z "$(which kubectl)" ]]; then
      curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key \
        | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' \
        | sudo tee /etc/apt/sources.list.d/kubernetes.list
      sudo apt-get update
      sudo apt-get install -y kubectl
    fi

    if [[ -z "$(which helm)" ]]; then
      curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" \
        | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
      sudo apt-get update
      sudo apt-get install -y helm
    fi
    ;;
esac

cd "$dir/auth"
./genauth.sh
./genenckey.sh
./setuplocalkubeconfig.sh
cd ..

wget -P "$dir" -q --show-progress --https-only --timestamping \
  https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-${arch}.img

"$dir/vmsetupall.sh"
sudo -E "$dir/setuphost.sh"
sudo "$dir/vmlaunchall.sh" kubenet-qemu

for vmid in $(seq 0 6); do
  "$dir/vmsshsetup.sh" $vmid
done

"$dir/deploysetup.sh"
"$dir/auth/deployauth.sh"
"$dir/deploybinaries.sh"

pids=()
for i in $(seq 0 2); do
  ssh ubuntu@control$i "sudo ./setupcontrol.sh" &
  pids+=($!)
done
wait ${pids[@]}

ssh ubuntu@gateway "sudo ./setupgateway.sh"

pids=()
for i in $(seq 0 2); do
  ssh ubuntu@control$i "sudo USE_CILIUM=$USE_CILIUM ./setupnode.sh" &
  pids+=($!)
done
for i in $(seq 0 2); do
  ssh ubuntu@worker$i "sudo USE_CILIUM=$USE_CILIUM ./setupnode.sh" &
  pids+=($!)
done
wait ${pids[@]}

if [[ -z $USE_CILIUM ]]; then
  sudo "$dir/setuproutes.sh"
fi

"$dir/setupkubeletaccess.sh"
"$dir/addhelmrepos.sh"
"$dir/setupcluster.sh"

echo "Your Kubernetes cluster is now fully functional!"
