---
title: "Enable Kubelet Serving Certificates in Kubernetes Setup by Kubeadmin"
date: 2023-04-22T10:01:25+08:00
lastmod: 2023-04-23T17:53:00+08:00
draft: false
keywords: ["Kubernetes","mTLS","metrics-server"]
description: "Setting up a Kubernetes cluster with a newly deployed metrics server often results in the following error message: `Failed to scrape node, err=Get https://172.18.0.3:10250/metrics/resource: x509: cannot validate certificate for 172.18.0.3 because it doesn't contain any IP SANs node=kind-worker`. This can be frustrating. In this post, I will demonstrate how to solve this problem in KinD."
tags: ["Kubernetes","mTLS","metrics-server"]
author: "Zeng Xu"
summary: "Setting up a Kubernetes cluster with a newly deployed metrics server often results in the following error message: `Failed to scrape node, err=Get https://172.18.0.3:10250/metrics/resource: x509: cannot validate certificate for 172.18.0.3 because it doesn't contain any IP SANs node=kind-worker`. This can be frustrating. In this post, I will demonstrate how to solve this problem in KinD."

comment: true
toc: true
autoCollapseToc: false
postMetaInFooter: true
hiddenFromHomePage: false
contentCopyright:  '本作品采用 <a rel="license noopener" href="https://creativecommons.org/licenses/by-nc-nd/4.0/" target="_blank">知识共享署名-非商业性使用-禁止演绎 4.0 国际许可协议</a> 进行许可，转载时请注明原文链接。'    
reward: false
mathjax: false
mathjaxEnableSingleDollar: false
mathjaxEnableAutoNumber: false

# You unlisted posts you might want not want the header or footer to show
hideHeaderAndFooter: false

# You can enable or disable out-of-date content warning for individual post.
# Comment this out to use the global config.
#enableOutdatedInfoWarning: false

flowchartDiagrams:
  enable: false
  options: ""

sequenceDiagrams: 
  enable: false
  options: ""
---
As highlighted in [the official Kubernetes documentation](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/#kubelet-serving-certs)

> By default the kubelet serving certificate deployed by kubeadm is self-signed. This means a connection from external services like the metrics-server to a kubelet cannot be secured with TLS.

Setting up a testing cluster with a newly deployed metrics server often results in the following error message: "Failed to scrape node, err=Get https://172.18.0.3:10250/metrics/resource: x509: cannot validate certificate for 172.18.0.3 because it doesn't contain any IP SANs node=kind-worker". This can be frustrating. In this post, I will demonstrate how to solve this problem in KinD. The solution I present is applicable to any Kubernetes cluster set up using Kubeadmin.

## Reproduce
<img src="/img/2023/kubelet-selfsigned-cert-reproduce.gif" width="700px"/>

Setup Kubernetes without additional Kubeadm init configuration.

```shell
cat << EOF | kind create cluster --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    image: kindest/node-amd64:v1.26.2
  - role: worker
    image: kindest/node-amd64:v1.26.2
  - role: worker
    image: kindest/node-amd64:v1.26.2
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
EOF
```
Deploy metrics server 
```
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.3/components.yaml
```
and errors occour
```
E0423 08:43:11.181966       1 scraper.go:140] "Failed to scrape node" err="Get \"https://172.18.0.2:10250/metrics/resource\": x509: cannot validate certificate for 172.18.0.2 because it doesn't contain any IP SANs" node="kind-worker"
E0423 08:43:11.193158       1 scraper.go:140] "Failed to scrape node" err="Get \"https://172.18.0.3:10250/metrics/resource\": x509: cannot validate certificate for 172.18.0.3 because it doesn't contain any IP SANs" node="kind-worker2"
```
The metrics server won't be ready
```
# k -n kube-system get po -l k8s-app=metrics-server
NAME                             READY   STATUS    RESTARTS   AGE
metrics-server-6757d65f8-dk94t   0/1     Running   0          4m33s
# k top no
Error from server (ServiceUnavailable): the server is currently unable to handle the request (get nodes.metrics.k8s.io)
# k top po
Error from server (ServiceUnavailable): the server is currently unable to handle the request (get pods.metrics.k8s.io)
```
## Temporarily Solution
It can be solved by adding args `--kubelet-insecure-tls`, but is not a ideal solution

```shell
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metrics-server
  namespace: kube-system
# ......
spec:
  template:
    spec:
      containers:
      - args:
        - --cert-dir=/tmp
        - --secure-port=4443
        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
        - --kubelet-use-node-status-port
        - --metric-resolution=15s
        -- --kubelet-insecure-tls ## append this arg
        image: zengxu/metrics-server:v0.6.3
```
It goes Ready.
```
# 
# k -n kube-system get po -l k8s-app=metrics-server
NAME                              READY   STATUS    RESTARTS   AGE
metrics-server-7499c765d9-bw8rv   1/1     Running   0          103s

# k  top no
NAME                 CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
kind-control-plane   191m         1%     582Mi           0%
kind-worker          43m          0%     145Mi           0%
kind-worker2         30m          0%     126Mi           0%
```

## Ideal Solution
<img src="/img/2023/kubelet-serving-cert-kubeadm-solution.gif" width="700px"/>

```shell
cat << EOF | kind create cluster --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    image: kindest/node-amd64:v1.26.2
    kubeadmConfigPatches:         # -----+
    - |                           #      |   (setup cluster with
      kind: KubeletConfiguration  #      |    patches)
      serverTLSBootstrap: true    # -----+
  - role: worker
    image: kindest/node-amd64:v1.26.2
  - role: worker
    image: kindest/node-amd64:v1.26.2
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
EOF
```

When it comes ready, apply metrics-server manifests
```shell
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.3/components.yaml
```

Errors throw when connected to kubectl
```shell
# k -n kube-system logs metrics-server-6757d65f8-tfwb5
Error from server: Get "https://172.18.0.3:10250/containerLogs/kube-system/metrics-server-6757d65f8-tfwb5/metrics-server": remote error: tls: internal error
```
Because Kubelet's certificate requests aren't approved.
```shell
# k -n kube-system get csr
NAME        AGE   SIGNERNAME                                    REQUESTOR                        REQUESTEDDURATION   CONDITION
csr-brvcz   85s   kubernetes.io/kubelet-serving                 system:node:kind-control-plane   <none>              Pending
csr-c24zs   91s   kubernetes.io/kubelet-serving                 system:node:kind-control-plane   <none>              Pending
csr-k4ggc   67s   kubernetes.io/kube-apiserver-client-kubelet   system:bootstrap:abcdef          <none>              Approved,Issued
csr-pbbxh   65s   kubernetes.io/kubelet-serving                 system:node:kind-worker2         <none>              Pending
csr-r8gk7   67s   kubernetes.io/kube-apiserver-client-kubelet   system:bootstrap:abcdef          <none>              Approved,Issued
csr-srh22   65s   kubernetes.io/kubelet-serving                 system:node:kind-worker          <none>              Pending
```
Approve kubelet certificate requests
```shell
for kubeletcsr in `kubectl -n kube-system get csr | grep kubernetes.io/kubelet-serving | awk '{ print $1 }'`; do kubectl certificate approve $kubeletcsr; done
```

Everything works as expected
```shell
# k -n kube-system get po -l k8s-app=metrics-server
NAME                             READY   STATUS    RESTARTS   AGE
metrics-server-6757d65f8-tfwb5   1/1     Running   0          3m42s

# k -n kube-system top po
NAME                                         CPU(cores)   MEMORY(bytes)
coredns-787d4945fb-2dwn9                     4m           13Mi
coredns-787d4945fb-cl288                     2m           12Mi
etcd-kind-control-plane                      34m          30Mi
kindnet-hql7g                                1m           8Mi
kindnet-jdxl6                                1m           7Mi
kindnet-xrdkl                                1m           8Mi
kube-apiserver-kind-control-plane            67m          263Mi
kube-controller-manager-kind-control-plane   26m          43Mi
kube-proxy-4fc8z                             1m           11Mi
kube-proxy-hpckv                             2m           11Mi
kube-proxy-t275x                             2m           11Mi
kube-scheduler-kind-control-plane            6m           18Mi
metrics-server-6757d65f8-tfwb5               5m           15Mi

# k  top no
NAME                 CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
kind-control-plane   164m         1%     577Mi           0%
kind-worker          33m          0%     147Mi           0%
kind-worker2         24m          0%     119Mi           0%
```