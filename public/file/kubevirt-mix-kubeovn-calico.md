# Calico ➕ KubeOVN - providing restricted underlay network access for KubeVirt VMs

Create a cluster with KinD

```bash
{
IMAGE=${IMAGE:-kindest/node:v1.27.3}

cat << EOF | kind create cluster --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kind
nodes:
  - role: control-plane
    image: $IMAGE
  - role: worker
    image: $IMAGE
  - role: worker
    image: $IMAGE
networking:
  podSubnet: "10.199.0.0/16"
  serviceSubnet: "172.20.0.0/16"
  disableDefaultCNI: true
EOF

kubectl taint node kind-control-plane node-role.kubernetes.io/control-plane:NoSchedule-
}
```

Install Calico CNI

```bash
{
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml

cat << EOF |  kubectl create -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    bgp: Enabled
    ipPools:
    - blockSize: 26
      cidr: 10.199.0.0/16
      encapsulation: VXLAN
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
}
```

Install KubeOVN

```bash
{
wget https://raw.githubusercontent.com/kubeovn/kube-ovn/v1.12.0/dist/images/install.sh
sed -i 's/CNI_CONFIG_PRIORITY=${CNI_CONFIG_PRIORITY:-01}/CNI_CONFIG_PRIORITY=${CNI_CONFIG_PRIORITY:-20}/' install.sh
chmod +x install.sh
./install.sh
}
```

Prepare namespace, VPC, Subnet/Switch

```bash
{
kubectl create ns test
cat << EOF | kubectl apply -f -
apiVersion: kubeovn.io/v1
kind: Vpc
metadata:
  name: test
---
apiVersion: kubeovn.io/v1
kind: Subnet
metadata:
  name: test
spec:
  cidrBlock: 10.0.1.0/24
  excludeIps:
  - 10.0.1.1
  gateway: 10.0.1.1
  namespaces:
  - zenx
  protocol: IPv4
  provider: ovn
  vpc: test
EOF
}
```

Deploy KubeVirt

```bash
{
export RELEASE=$(curl https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)

echo "Deploy the KubeVirt operator"
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${RELEASE}/kubevirt-operator.yaml

echo "Create the KubeVirt CR (instance deployment request) which triggers the actual installation"
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${RELEASE}/kubevirt-cr.yaml

echo "wait until all KubeVirt components are up"
kubectl -n kubevirt wait kv kubevirt --for condition=Available
}
```

Install virtctl

```bash
{
echo "install virtctl"
export VERSION=v0.41.0
wget https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/virtctl-${VERSION}-linux-amd64
chmod +x virtctl-${VERSION}-linux-amd64
mv virtctl-${VERSION}-linux-amd64 /usr/local/bin/virtctl
}
```

Install Multus

```bash
{
wget https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/v4.0.2/deployments/multus-daemonset-thick.yml
kubectl apply -f multus-daemonset-thick.yml
}
```

Install x-calico-route CNI plugin

```bash
{
cat << 'EOF' | tee x-calico-route
#!/usr/bin/env bash

### CNI x-calico-route
### Remove calicos default route and add specific routes for node/internal-service access

set -eEuo pipefail
shopt -s inherit_errexit

inputData=$(cat)

cniVersion=$(echo "$inputData" | jq -r .cniVersion)
if [[ $cniVersion != "0.3.0" ]] && [[ $cniVersion != "0.3.1" ]]
then
    exit 1
fi

case $CNI_COMMAND in
    VERSION)
        echo "{\"cniVersion\": \"$cniVersion\", \"supportedVersions\": [\"0.3.0\", \"0.3.1\"]}"
        exit 0
        ;;
    ADD)
        nsenter --net="${CNI_NETNS}" bash -euxc "ip route del default; ip route add 10.199.0.0/16 via 169.254.1.1; ip route add 172.18.0.0/16 via 169.254.1.1"
        # Pass through previous result
        echo "$inputData" | jq -r .prevResult
        exit 0
        ;;
    DEL)
        exit 0
        ;;
    *)
        exit 4
        ;;
esac
EOF

chmod +x x-calico-route 

docker cp x-calico-route kind-control-plane:/opt/cni/bin/
docker cp x-calico-route kind-worker:/opt/cni/bin/
docker cp x-calico-route kind-worker2:/opt/cni/bin/
}
```

Prepare NetworkAttachmentDefinitions

```bash
{
docker cp kind-control-plane:/etc/cni/net.d/ ./net.d

CNI_CONF=$(cat ./net.d/10-calico.conflist  | jq '.plugins[.plugins | length] |=.+ {"type": "x-calico-route"}')

cat << EOF | kubectl apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: calico
spec:
  config: '$CNI_CONF'
EOF

CNI_CONF=$(cat ./net.d/20-kube-ovn.conflist  | jq '.plugins[.plugins | 0] |=.+{"provider": "kubeovn.default.ovn"}')

cat << EOF | kubectl apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: kubeovn
spec:
  config: '$CNI_CONF'
EOF
}
```

Create VM with Calico ➕ KubeOVN

```bash
{
cat << EOF | kubectl apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: testvm
  namespace: test
spec:
  running: true
  template:
    metadata:
      annotations:
        cni.projectcalico.org/ipAddrs: '["10.199.3.153"]'
      labels:
        kubevirt.io/domain: ubuntu
        kubevirt.io/size: normal
    spec:
      architecture: amd64
      dnsConfig:
        nameservers:
        - 1.1.1.1
        - 8.8.8.8
      dnsPolicy: None
      domain:
        devices:
          disks:
          - disk:
              bus: virtio
            name: osdisk
          interfaces:
          - bridge: {}
            name: default
          - bridge: {}
            name: second
          networkInterfaceMultiqueue: true
        machine:
          type: q35
        resources:
          limits:
            cpu: "4"
            memory: 4Gi
          requests:
            cpu: "2"
            memory: 4Gi
      hostname: testvm
      networks:
      - multus:
          default: true
          networkName: default/calico
        name: default
      - multus:
          networkName: default/kubeovn
        name: second
      volumes:
      - containerDisk:
          image: zengxu/ubuntu-kubevirt:22.04
        name: osdisk
      - cloudInitNoCloud:
          networkDataBase64: bmV0d29yazoKICB2ZXJzaW9uOiAyCiAgZXRoZXJuZXRzOgogICAgZW5wMXMwOgogICAgICBkaGNwNDogdHJ1ZQogICAgZW5wMnMwOgogICAgICBkaGNwNDogdHJ1ZQogICAgICByb3V0ZXM6CiAgICAgIC0gdG86IDAuMC4wLjAvMAogICAgICAgIHZpYTogMTAuMC4xLjEK
          # mkpasswd --method=SHA-512 zengdev -S "hello123"
          userDataBase64: I2Nsb3VkLWNvbmZpZwp1c2VyczoKICAtIG5hbWU6IHJvb3QKICAgIGhhc2hlZF9wYXNzd2Q6ICIkNiRoZWxsbzEyMyRrYjRpV0M4LzRCYnNwZTdUOGFFeTRYWmtaWHhRS0d4TFptcDZBbXhwTEJvREpoWlEvN3A0R1BVNlg2QldKdGVLZVNLSFk2enhPcFc5aURjd25vS0dKLyIKICAgIHNoZWxsOiAvYmluL2Jhc2gKICAgIGxvY2tfcGFzc3dkOiBGYWxzZQpydW5jbWQ6CiAgLSBbIGJhc2gsIC1jLCAic2VkIC1pICdzLyNQZXJtaXRSb290TG9naW4gcHJvaGliaXQtcGFzc3dvcmQvUGVybWl0Um9vdExvZ2luIHllcy8nIC9ldGMvc3NoL3NzaGRfY29uZmlnIl0KICAtIFsgYmFzaCwgLWMsICJzZWQgLWkgJ3MvI1Blcm1pdFJvb3RMb2dpbiB5ZXMvUGVybWl0Um9vdExvZ2luIHllcy8nIC9ldGMvc3NoL3NzaGRfY29uZmlnIl0KICAtIFsgYmFzaCwgLWMsICJzZWQgLWkgJ3MvUGFzc3dvcmRBdXRoZW50aWNhdGlvbiBuby9QYXNzd29yZEF1dGhlbnRpY2F0aW9uIHllcy8nIC9ldGMvc3NoL3NzaGRfY29uZmlnIl0KICAtIFsgYmFzaCwgLWMsICJzeXN0ZW1jdGwgcmVzdGFydCBzc2hkIl0K
        name: cloudinitdisk
EOF
}
```

Verify underlay access

```
# user/passwd root/zengdev
virtctl -n test console testvm

ip a && ip r

# 1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
#     link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
#     inet 127.0.0.1/8 scope host lo
#        valid_lft forever preferred_lft forever
#     inet6 ::1/128 scope host
#        valid_lft forever preferred_lft forever
# 2: enp1s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc mq state UP group default qlen 1000
#     link/ether 36:a7:cb:a9:c6:a6 brd ff:ff:ff:ff:ff:ff
#     inet 10.199.3.153/32 metric 100 scope global dynamic enp1s0
#        valid_lft 86313402sec preferred_lft 86313402sec
#     inet6 fe80::34a7:cbff:fea9:c6a6/64 scope link
#        valid_lft forever preferred_lft forever
# 3: enp2s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc mq state UP group default qlen 1000
#     link/ether 00:00:00:b4:f2:57 brd ff:ff:ff:ff:ff:ff
#     inet 10.16.0.42/16 metric 100 brd 10.16.255.255 scope global dynamic enp2s0
#        valid_lft 86313402sec preferred_lft 86313402sec
#     inet6 fe80::200:ff:feb4:f257/64 scope link
#        valid_lft forever preferred_lft forever
# default via 10.0.1.1 dev enp2s0 proto static onlink
# 10.16.0.0/16 dev enp2s0 proto kernel scope link src 10.16.0.42 metric 100
# 10.199.0.0/16 via 169.254.1.1 dev enp1s0 proto dhcp src 10.199.3.153 metric 100
# 169.254.1.1 dev enp1s0 proto dhcp scope link src 10.199.3.153 metric 100
# 172.18.0.0/16 via 169.254.1.1 dev enp1s0 proto dhcp src 10.199.3.153 metric 100

ping 172.18.0.2
# PING 172.18.0.2 (172.18.0.2) 56(84) bytes of data.
# 64 bytes from 172.18.0.2: icmp_seq=1 ttl=64 time=0.156 ms
# 64 bytes from 172.18.0.2: icmp_seq=2 ttl=64 time=0.151 ms
# 64 bytes from 172.18.0.2: icmp_seq=3 ttl=64 time=0.140 ms

ping 172.18.0.3
# PING 172.18.0.3 (172.18.0.3) 56(84) bytes of data.
# 64 bytes from 172.18.0.3: icmp_seq=1 ttl=64 time=0.182 ms
# 64 bytes from 172.18.0.3: icmp_seq=2 ttl=64 time=0.111 ms
# 64 bytes from 172.18.0.3: icmp_seq=3 ttl=64 time=0.137 ms
```

Apply NetworkPolicy to limit underly access

```bash
{
ECHO_SERVER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(docker run --rm --network kind -d zengxu/echo-server))

echo "limit access to $ECHO_SERVER_IP"

cat << EOF | kubectl apply -f -
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: vm-egress
  namespace: test
spec:
  selector: vm.kubevirt.io/name == 'testvm'
  types:
  - Egress
  egress:
  - action: Allow
    protocol: TCP
    destination:
      nets:
      - $ECHO_SERVER_IP/32
      ports: [80, 8080, 443]
EOF
} # limit access to 172.18.0.6
```


Verify underlay limited access

```bash
# user/passwd root/zengdev
virtctl -n test console testvm

ping 172.18.0.2 # failure 
# PING 172.18.0.2 (172.18.0.2) 56(84) bytes of data.

ping 172.18.0.3 # failure 
# PING 172.18.0.3 (172.18.0.3) 56(84) bytes of data.

curl -i 172.18.0.6:8080 # access 172.18.0.6 ok
# HTTP/1.1 200 OK 
# Date: Mon, 14 Aug 2023 15:35:03 GMT
# Content-Length: 79
# Content-Type: text/plain; charset=utf-8

# GET / HTTP/1.1
# Host: 172.18.0.6:8080
# Accept: */*
# User-Agent: curl/7.81.0
```