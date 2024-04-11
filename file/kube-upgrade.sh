#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function install-kube-binary() {
    mkdir -p /etc/kubernetes/upgrade
    for VERSION in v1.15.12 v1.16.15 v1.17.17 v1.18.20 v1.19.16 v1.20.15 v1.21.14; do
        if [ ! -f "/etc/kubernetes/upgrade/kubeadm-$VERSION" ]; then
            wget -O "/etc/kubernetes/upgrade/kubeadm-$VERSION" "https://files.m.daocloud.io/storage.googleapis.com/kubernetes-release/release/$VERSION/bin/linux/amd64/kubeadm"
            chmod +x "/etc/kubernetes/upgrade/kubeadm-$VERSION"
        fi

        if [ ! -f "/etc/kubernetes/upgrade/kubelet-$VERSION" ]; then
            wget -O "/etc/kubernetes/upgrade/kubelet-$VERSION" "https://files.m.daocloud.io/storage.googleapis.com/kubernetes-release/release/$VERSION/bin/linux/amd64/kubelet"
            chmod +x "/etc/kubernetes/upgrade/kubelet-$VERSION"
        fi

        if [ ! -f "/etc/kubernetes/upgrade/kubectl-$VERSION" ]; then
            wget -O "/etc/kubernetes/upgrade/kubectl-$VERSION" "https://files.m.daocloud.io/storage.googleapis.com/kubernetes-release/release/$VERSION/bin/linux/amd64/kubectl"
            chmod +x "/etc/kubernetes/upgrade/kubectl-$VERSION"
        fi
    done
}

function kubelet-1.15.12() {
    sed -i -e '/# Should this cluster be allowed to run privileged docker containers/d' -e '/KUBE_ALLOW_PRIV="--allow-privileged=true"/d' /etc/kubernetes/kubelet.env
    sed -i '/--feature-gates=VolumeSubpathEnvExpansion=true \\/d' /etc/kubernetes/kubelet.env
}

function cluster-1.20.15() {
    kubectl -n kube-system get configmap kubeadm-config -o yaml | sed '/insecure-port:/d; /insecure-bind-address:/d;' | kubectl replace -f -
    kubectl -n kube-system get cm kubeadm-config -o json | jq '.data.ClusterConfiguration |= sub("controllerManager: \\{}"; "controllerManager: {extraArgs: { port: 10252 }}")' | kubectl apply -f -
    kubectl -n kube-system get cm kubeadm-config -o json | jq '.data.ClusterConfiguration |= sub("scheduler: \\{}"; "scheduler: {extraArgs: { port: 10251 }}")' | kubectl apply -f -
}

function cluster-1.19.16() {
    kubectl -n kube-system get configmap kubeadm-config -o yaml | sed 's/feature-gates: VolumeSubpathEnvExpansion=true/feature-gates:/' | kubectl replace -f -
    kubectl -n kube-system get configmap kube-proxy --output yaml | sed '/VolumeSubpathEnvExpansion: true/d' | kubectl replace -f -
}

function master-1.20.15() {
    sed -i '/- --insecure-port=8080/d;/- --insecure-bind-address=127.0.0.1/d' /etc/kubernetes/manifests/kube-apiserver.yaml
    sed -i '/- --port=0/d' /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/manifests/kube-controller-manager.yaml
}

function master-1.19.16() {
    sed -i '/feature-gates=VolumeSubpathEnvExpansion=true/d' /etc/kubernetes/kubelet.env
    sed -i '/feature-gates=VolumeSubpathEnvExpansion=true/d' /etc/kubernetes/manifests/kube-apiserver.yaml
    sed -i '/feature-gates=VolumeSubpathEnvExpansion=true/d' /etc/kubernetes/manifests/kube-controller-manager.yaml
    sed -i '/feature-gates=VolumeSubpathEnvExpansion=true/d' /etc/kubernetes/manifests/kube-scheduler.yaml
}

function wait_control_plane_ready() {
    if [ -z "$1" ]; then
        echo "Please provide the node name the control plane runs on."
        exit 1
    fi
    if [ -z "$2" ]; then
        echo "Please provide the target version of the control plane"
        exit 1
    fi

    local master=$1
    local version=$2
    local retries=0
    local max_retries=60
    local interval=5

    echo "wait kube-apiserver, kube-scheduler and kube-controller-manager on $master ready"

    while true; do
        local apiserver_ready=$(kubectl get pods -n kube-system -l component=kube-apiserver --field-selector spec.nodeName=$master -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
        local scheduler_ready=$(kubectl get pods -n kube-system -l component=kube-scheduler --field-selector spec.nodeName=$master -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
        local controller_manager_ready=$(kubectl get pods -n kube-system -l component=kube-controller-manager --field-selector spec.nodeName=$master -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)

        local apiserver_version=$(kubectl get pods -n kube-system -l component=kube-apiserver --field-selector spec.nodeName=$master -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null)
        local scheduler_version=$(kubectl get pods -n kube-system -l component=kube-scheduler --field-selector spec.nodeName=$master -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null)
        local controller_manager_version=$(kubectl get pods -n kube-system -l component=kube-controller-manager --field-selector spec.nodeName=$master -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null)

        if [[ "$apiserver_ready" == "true" && "$scheduler_ready" == "true" && "$controller_manager_ready" == "true" ]]; then
            if [[ "$apiserver_version" =~ $version && "$scheduler_version" =~ $version && "$controller_manager_version" =~ $version ]]; then
                echo "Control plane components are ready and running version $version on the current node."
                break
            fi
        fi

        if [[ $retries -ge $max_retries ]]; then
            echo "Timed out waiting for control plane components to be ready and running version $version on the current node."
            exit 1
        fi

        retries=$((retries + 1))
        sleep "$interval"
    done
}

function wait_coredns_ready() {
    local namespace="$1"
    local version="$2"
    local retries=0
    local max_retries=60
    local interval=5

    while true; do
        local ready_pods=$(kubectl get pods -n "$namespace" -l k8s-app=kube-dns --output=jsonpath="{range .items[*]}{.metadata.name}:{.status.containerStatuses[0].image}{'\n'}{end}" 2>/dev/null)
        local num_ready_pods=$(echo "$ready_pods" | grep -c "coredns:$version")
        local total_pods=$(echo "$ready_pods" | wc -l)

        if [[ $num_ready_pods -eq $total_pods ]]; then
            echo "All CoreDNS pods in namespace $namespace with version $version are ready."
            break
        fi

        if [[ $retries -ge $max_retries ]]; then
            echo "Timed out waiting for CoreDNS pods to be ready."
            exit 1
        fi

        retries=$((retries + 1))
        sleep "$interval"
    done
}

function wait_kubeproxy_ready() {
    local namespace="$1"
    local version="$2"
    local retries=0
    local node_count=$(kubectl get nodes --no-headers | wc -l)
    local max_retries=$((node_count * 45))
    local interval=5

    while true; do
        local ready_pods=$(kubectl get pods -n "$namespace" -l k8s-app=kube-proxy --output=jsonpath="{range .items[*]}{.metadata.name}:{.status.containerStatuses[0].image}{'\n'}{end}" 2>/dev/null)
        local num_ready_pods=$(echo "$ready_pods" | grep -c "kube-proxy:$version")
        local total_pods=$(echo "$ready_pods" | wc -l)

        if [[ $num_ready_pods -eq $total_pods ]]; then
            echo "All kube-proxy pods in namespace $namespace with version $version are ready."
            break
        else
            echo "ready status $num_ready_pods/$total_pods"
        fi

        if [[ $retries -ge $max_retries ]]; then
            echo "Timed out waiting for kube-proxy pods to be ready."
            exit 1
        fi

        retries=$((retries + 1))
        sleep "$interval"
    done
}

function format-container-disk() {
    docker_device_name=/dev/$(lsblk --json | jq 'del(.blockdevices[] | select(.children != null) | .children[] | select(.children == null))' | jq -r '.blockdevices[] | select(.children != null) | select(.children[].children != null) | select(.children[].children[].name? == "docker-thinpool_tmeta") | .children[0].name')

    sudo rm -rf /var/lib/docker
    cp /etc/docker/daemon.json /etc/docker/daemon.json.bk
    jq 'del(.["storage-driver", "storage-opts"]) | . + { "storage-driver": "overlay2" }' /etc/docker/daemon.json | sudo tee /etc/docker/daemon.json >/dev/null

    if lvremove --force /dev/docker/thinpool; then echo "lvm thinpool removed"; fi
    if lvremove --force /dev/docker/thinpoolmeta; then echo "lvm thinpoolmeta removed"; fi

    mkfs -t ext4 -F $docker_device_name
    mkdir -p /var/lib/containerd
    uuid=$(sudo blkid -s UUID -o value $docker_device_name)
    cp /etc/fstab /etc/fstab.bak
    echo "UUID=${uuid}  /var/lib/containerd  ext4  defaults,noatime  0  2" | sudo tee -a /etc/fstab
    mount -a
}

function prepare-containerd() {
    wget https://files.m.daocloud.io/github.com/opencontainers/runc/releases/download/v1.1.12/runc.amd64
    install -m 755 runc.amd64 /usr/local/bin/runc
    rm runc.amd64

    CONTAINERD_FILE="containerd-1.6.28-linux-amd64.tar.gz"
    wget https://files.m.daocloud.io/github.com/containerd/containerd/releases/download/v1.6.28/$CONTAINERD_FILE
    tar Cxzvf /usr/local $CONTAINERD_FILE
    rm $CONTAINERD_FILE
    mkdir -p /etc/containerd

    cat <<EOF >/etc/containerd/config.toml
version = 2
root = "/var/lib/containerd" 
state = "/run/containerd"
oom_score = 0

[grpc]
  max_recv_message_size = 16777216
  max_send_message_size = 16777216

[debug]
  level = "info"

[metrics]
  address = ""
  grpc_histogram = false

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "registry.aliyuncs.com/google_containers/pause:3.9"
    max_container_log_line_size = -1
    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "runc"
      snapshotter = "overlayfs"
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          runtime_engine = ""
          runtime_root = ""
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            systemdCgroup = true
    [plugins."io.containerd.grpc.v1.cri".registry]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
          endpoint = ["https://registry-1.docker.io"]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker-registry.zeng.dev:32500"]
          endpoint = ["http://docker-registry.zeng.dev:32500"]
      [plugins."io.containerd.grpc.v1.cri".registry.configs]
        [plugins."io.containerd.grpc.v1.cri".registry.configs."docker-registry.zeng.dev:32500".tls]
          insecure_skip_verify = true
        [plugins."io.containerd.grpc.v1.cri".registry.configs."docker-registry.example.com:5000".tls]
          insecure_skip_verify = true
EOF
}

function start-containerd() {
    cat <<EOF | sudo tee /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
Environment="ENABLE_CRI_SANDBOXES=sandboxed"
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd

Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
# Comment TasksMax if your systemd version does not supports it.
# Only systemd 226 and above support this version.
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable containerd && systemctl start containerd
}

function switch-runtime() {
    echo "start switch runtime: docker => containerd"
    systemctl stop kubelet
    echo "kubelet stopped"
    docker stop $(docker ps -a -q)
    docker rm $(docker ps -a -q)
    systemctl stop docker
    format-container-disk
    echo "docker lvm disk formatted success"
    systemctl stop docker
    prepare-containerd
    start-containerd
    echo "containerd started"
    sed -i '/KUBELET_ARGS=/a \--container-runtime=remote \\\n--container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \\' /etc/kubernetes/kubelet.env
    sed -i 's/--cgroup-driver=cgroupfs/--cgroup-driver=systemd/' /etc/kubernetes/kubelet.env
    systemctl daemon-reload
    systemctl restart kubelet
    echo "end switch runtime: docker => containerd"
}

function update-worker-kubelet() {
    VERSION=v1.21.14
    UPGRADEDIR=/etc/kubernetes/upgrade
    mkdir -p $UPGRADEDIR

    wget -O $UPGRADEDIR/kubeadm-$VERSION https://storage.googleapis.com/kubernetes-release/release/$VERSION/bin/linux/amd64/kubeadm
    chmod +x $UPGRADEDIR/kubeadm-$VERSION
    wget -O $UPGRADEDIR/kubelet-$VERSION https://storage.googleapis.com/kubernetes-release/release/$VERSION/bin/linux/amd64/kubelet
    chmod +x $UPGRADEDIR/kubelet-$VERSION

    # start of updating args, it depends on your kubelet's status, don't use it
    sed -i '/# Should this cluster be allowed to run privileged docker containers/d; /KUBE_ALLOW_PRIV="--allow-privileged=true"/d' /etc/kubernetes/kubelet.env
    sed -i '/\$KUBE_ALLOW_PRIV \\/d' /etc/systemd/system/kubelet.service
    sed -i '/--feature-gates=VolumeSubpathEnvExpansion=true \\/d' /etc/kubernetes/kubelet.env
    sed -i 's|google-containers/pause-amd64:3.1|google-containers/pause:3.4.1|' /etc/kubernetes/kubelet.env
    # end of updating args, it depends on your kubelet's status, don't use it

    echo "kubelet stopped"
    systemctl stop kubelet
    $UPGRADEDIR/kubeadm-$VERSION upgrade node
    mv $UPGRADEDIR/kubelet-$VERSION /usr/local/bin/kubelet
    systemctl daemon-reload
    systemctl restart kubelet
}

function wait_node_ready() {
    if [[ -z $1 ]]; then
        echo "Please provide the name of the node."
        exit 1
    fi
    if [[ -z $2 ]]; then
        echo "Please provide the desired version of the node."
        exit 1
    fi
    node="$1"
    nodeversion="$2"

    local max_attempts=60
    local interval_seconds=5
    local counter=0

    echo "Waiting for node/$node to become ready..."

    while true; do
        local actual_version=$(kubectl get nodes $node -o=jsonpath='{.status.nodeInfo.kubeletVersion}')
        local node_status=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

        if [[ $actual_version == "$nodeversion" && $node_status == "True" ]]; then
            echo "Node/$node is ready!"
            break
        fi

        sleep $interval_seconds
        counter=$((counter + 1))
    done
}

function next-version() {
    case $1 in
    "1.14") echo "v1.15.12" ;;
    "1.15") echo "v1.16.15" ;;
    "1.16") echo "v1.17.17" ;;
    "1.17") echo "v1.18.20" ;;
    "1.18") echo "v1.19.16" ;;
    "1.19") echo "v1.20.15" ;;
    "1.20") echo "v1.21.14" ;;
    *) echo "" ;;
    esac
}

function upgrade-cluter() {
    local CLUSTER_VERSION=$(kubectl version -o json | jq -r '.serverVersion.major + "." + .serverVersion.minor')
    local TARGET_CLUSTER_VERSION=$(next-version $CLUSTER_VERSION)
    local FIRST_MASTER=$(hostname)
    echo "start do upgrade cluster on master/$FIRST_MASTER: $CLUSTER_VERSION => $TARGET_CLUSTER_VERSION"

    echo "backup etcd before upgrading cluster"
    local master_ips=$(kubectl get node -owide | grep master | awk '{print $6}')
    local master1=$(echo $master_ips | awk -F' ' '{print $1}')
    # local master2=$(echo $master_ips | awk -F' ' '{print $2}')
    # local master3=$(echo $master_ips | awk -F' ' '{print $3}')
    # ETCDCTL_API=3 etcdctl --endpoints ${master1}:2379,${master2}:2379,${master3}:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/node-$(hostname).pem --key=/etc/ssl/etcd/ssl/node-$(hostname)-key.pem snapshot save etcd-before-$CLUSTER_VERSION.backup
    ETCDCTL_API=3 etcdctl --endpoints ${master1}:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/node-$(hostname).pem --key=/etc/ssl/etcd/ssl/node-$(hostname)-key.pem snapshot save etcd-before-$CLUSTER_VERSION.backup
    echo "backup etcd finished"

    /etc/kubernetes/upgrade/kubeadm-$TARGET_CLUSTER_VERSION upgrade apply "$TARGET_CLUSTER_VERSION" -f

    case $TARGET_CLUSTER_VERSION in
    "v1.19.16")
        echo "prepare cluster config and manifests for the firt master $FIRST_MASTER"
        cluster-1.19.16
        master-1.19.16
        ;;
    "v1.20.15")
        echo "prepare cluster config and manifests for the firt master $FIRST_MASTER"
        cluster-1.20.15
        master-1.20.15
        ;;
    esac

    if [ -z "$TARGET_CLUSTER_VERSION" ]; then
        echo "unsupported version $CLUSTER_VERSION"
        exit 0
    fi

    wait_control_plane_ready $FIRST_MASTER $TARGET_CLUSTER_VERSION
    # Get CoreDNS version from the Deployment
    coredns_version=$(kubectl get deployment -n kube-system coredns -o jsonpath="{.spec.template.spec.containers[0].image}" | cut -d':' -f2)
    # Get kube-proxy version from the DaemonSet
    kube_proxy_version=$(kubectl get daemonset -n kube-system kube-proxy -o jsonpath="{.spec.template.spec.containers[0].image}" | cut -d':' -f2)
    echo "wait CoreDNS ready"
    wait_coredns_ready "kube-system" "$coredns_version"
    echo "wait kube-proxy ready"
    wait_kubeproxy_ready "kube-system" "$kube_proxy_version"

    echo "end do upgrade, current cluster version is $TARGET_CLUSTER_VERSION :)"
}

function upgrade-master() {
    CLUSTER_VERSION=$(kubectl -n kube-system get cm kubeadm-config -o yaml | awk -F ': ' '/kubernetesVersion/ {print $2;exit}')
    local MASTER=$(hostname)
    local MASTER_VERSION=$(kubectl get no $MASTER -o json | jq -r .status.nodeInfo.kubeletVersion)
    
    case $CLUSTER_VERSION in
    "v1.15.12")
        kubelet-1.15.12
        ;;
    "v1.19.16")
        echo "prepare manifests for the master $MASTER"
        master-1.19.16
        ;;
    "v1.20.15")
        echo "prepare manifests for the master $MASTER"
        master-1.20.15
        ;;
    esac

    echo "start do upgrade control plane on master/$MASTER: $MASTER_VERSION => $CLUSTER_VERSION"

    mv /etc/kubernetes/upgrade/kubelet-$CLUSTER_VERSION /usr/local/bin/kubelet
    /etc/kubernetes/upgrade/kubeadm-$CLUSTER_VERSION upgrade node
    systemctl daemon-reload
    systemctl restart kubelet
    wait_control_plane_ready $MASTER $CLUSTER_VERSION
    wait_node_ready $MASTER $CLUSTER_VERSION

    echo "end do upgrade control plane, current control plane version is $CLUSTER_VERSION :)"
}

case "$1" in
"prepare")
    master_nodes=$(kubectl get nodes --selector='node-role.kubernetes.io/master' -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')
    for node in $master_nodes; do
        echo "Download kubeadm, kubelet, kubectl binary for Master $node"
        ssh $node "$(typeset -f install-kube-binary); install-kube-binary"
    done
    ;;
"runtime")
    switch-runtime
    ;;
"kubelet")
    update-worker-kubelet
    ;;
"master-runtime")
    if [[ -z $2 ]]; then
        echo "Please provide the master node name."
        exit 1
    fi
    kubectl drain $2 --ignore-daemonsets --delete-local-data
    ssh $2 "bash -s" -- < $0 runtime
    kubectl uncordon $2
    ;;
"worker")
    if [[ -z $2 ]]; then
        echo "Please provide the node name."
        exit 1
    fi
    kubectl drain $2 --ignore-daemonsets --delete-local-data
    ssh $2 "bash -s" -- < $0 kubelet
    ssh $2 "bash -s" -- < $0 runtime
    kubectl uncordon $2
    ;;
"cluster")
    upgrade-cluter
    ;;
"master")
    upgrade-master
    ;;
*)
    echo "Usage: $0 {prepare|cluster|master|runtime|worker}"
    ;;
esac

