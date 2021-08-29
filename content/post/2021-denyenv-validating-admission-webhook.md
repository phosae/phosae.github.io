---
title: "Kubernetes admission webhook server 开发教程"
date: 2021-08-08T21:11:28+08:00
lastmod: 2021-08-29T15:05:00+08:00
draft: false

keywords: ["kubernetes", "container"]
description: ""
tags: ["kubernetes", "container"]
author: "Zeng Xu"
summary: "how to implement a Kubernetes validating admission webhook"

comment: true
toc: true
autoCollapseToc: false
postMetaInFooter: true
hiddenFromHomePage: false
---

## 背景

Kubernetes 提供了非常多的拓展方式，比方说 Custom Resources 和 Operator 模式、CNI 和 Networking Plugin、CRI 和 container runtime。

在 apiserver 内部，常见的拓展方式是 [admission controller](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)，请求通过鉴权后，会被 controllers 拦截处理。而请求只有成功通过所有 controller 处理后，才能被持久到存储层。以创建操作为例，假设请求尝试在尚不存在的 namespace 中创建 Pod 资源，那么  NamespaceLifecycle admission controller 检查后便会拒绝并返回报错

```shell
$ kubectl -n ns-not-exist run nginx --image=nginx
Error from server (NotFound): namespaces "ns-not-exist" not found
```

类似地，LimitRange 的 Pod 资源使用控制功能也是以 admission controllers 方式实现。

除校验控制之外，admission controllers 的另外一大用途是修改请求资源，如 apiserver 会根据 Pod 指定的 ServiceAccountName，自动往 Pod 插入 Token Secret Volume 和 VolumeMount。

在 apiserver 内部，有两个特殊的 controllers：MutatingAdmissionWebhook 和 ValidatingAdmissionWebhook，通过它们提供的协议，用户能够将自定义 webhook 集成到 admission controller 控制流中。顾名思义，mutating admission webhook 可以拦截并修改请求资源，validating admission webhook 只能拦截并校验请求资源，但不能修改它们。分成两类的一个好处是，后者可以被 apiserver 并发执行，只要任一失败，即可快速结束请求。

实现自定义 admission webhook，可以灵活地修改或校验 Kubernetes 资源（尤其是 Custom Resources），满足各种定制化需求。

下文将以 validating admission webhook 为例，展示如何开发、部署和调试 admission webhook server，所有代码均出自我的项目 [denyenv-validating-admission-webhook](https://github.com/phosae/denyenv-validating-admission-webhook)。


## 思路及实现

灵感来自 Kelsey Hightower 项目 [denyenv-validating-admission-webhook](https://github.com/kelseyhightower/denyenv-validating-admission-webhook)，即在 webhook 中实现一套简单逻辑，校验 Pod 创建请求，如果 Pod 中的任意 Container 声明了环境变量，就拒绝它。Kelsey 使用 gcloud nodeJS function 实现、使用 gcloud GKE 测试，这里使用 Go 实现，可以在任何 Kubernetes 集群部署使用。

如果是本地开发测试，建议安装 [Kind](https://kind.sigs.k8s.io/)，只需一行命令即可创建 Kubernetes 测试环境

```
$ kind create cluster
Creating cluster "kind" ...
 ✓ Ensuring node image (kindest/node:v1.20.2) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-kind"
You can now use your cluster with:

kubectl cluster-info --context kind-kind

Have a nice day! 👋
```

首先，构建一个 HTTP/HTTPS 服务，监听 8000 端口，通过 path /validate 接收认证请求。

按照设想，我们的服务会在 Kubernetes 集群发生 Pod 创建时，收到 apiserver 发起的 HTTP POST 请求，其 Body 包含如下 JSON 数据，即序列化后的 [AdmissionReview](https://github.com/kubernetes/api/blob/499b6f90564cff48dc1fba56d974de2e5ec98bb4/admission/v1beta1/types.go#L34-L42)

```json
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  ...
  "request": {
    # Random uid uniquely identifying this admission call
    "uid": "705ab4f5-6393-11e8-b7cc-42010a800002",
    # object is the new object being admitted.
    "object": {"apiVersion":"v1","kind":"Pod", ...},
    ...
  }
}
```
接着，我们要做的就是反序列化 AdmissionReview，获得 request.object 中的 Pod，遍历 container 数组、循环遍历 Env 数组，校验之，最后将校验结果返回给 apiserver。

如果 Pod 中没有用到环境变量，返回如下 JSON，表示校验通过

```json
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "response": {
    "uid": "<value from request.uid>",
    "allowed": true,
  }
}
```

如果 Pod 中用到了环境变量，返回如下 JSON，表示校验未通过
```json
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "response": {
    "uid": "<value from request.uid>",
    "allowed": false,
    "status": {
      "code": 402,
      "status": "Failure",
      "message": "#ctr is using env vars",
      "reason": "#ctr is using env vars"
    }
  }
}
```
其决定作用的字段是 .response.uid 和 .response.allowed，前者唯一确定请求，后者表示通过或者不通过，status 字段主要供错误提示。

具体实现在这里 [代码传送门](https://github.com/phosae/denyenv-validating-admission-webhook/blob/dd28134f2884b1799e81135e37da43bca6bf337a/main.go#L33-L79)。


## 部署

### 使用 Kubernetes CertificateSigningRequest 签发 TLS 证书
由于 Kubernetes 只支持 HTTPS 协议的 admission webhook，所以关键在于 HTTPS 化我们的服务。Kubernetes 本身就有自己的 CA 证书体系，且支持 TLS 证书签发。我们要做的就是使用 openssl 生成服务私钥、服务证书请求并巧用 Kubernetes CA 签名服务证书
1. 使用 openssl 生成服务的私钥（server-key）
2. 结合 server-key，使用 openssl 生成证书请求 server.csr
3. 使用 Kubernetes CertificateSigningRequest 和 kubectl approve 签名服务证书
4. 将服务私钥和证书，存储到 Kubernetes Secret 中

[过程脚本传送门](https://github.com/phosae/denyenv-validating-admission-webhook/blob/master/webhook-create-signed-cert.sh)

### 使用 cert-manager 签发 TLS 证书

Kubernetes 证书有效期为 1 年，复杂的生产环境可以考虑使用 [cert-manager](https://github.com/jetstack/cert-manager) ，因为它具有证书自动更新、自动注入等一系列生命周期管理功能。
1. 安装 cert-manager 相关依赖，如 CRD/Controller、RABC、Webhook (`kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.5.3/cert-manager.yaml`)
2. 创建 cert-manager Issuer CR（这里用 selfSigned Issuer）
3. 创建 cert-manager Certificate CR，引用 Issuer 签发证书（可以在 .Spec.ipAddresses 指定机器 IP 方便本地调试）

[步骤 2、3 Yaml 声明传送门](https://github.com/phosae/denyenv-validating-admission-webhook/blob/master/k-cert-manager.yaml)

最终，签发的证书会持久到 Certificate CR 中声明的 Secret（这里是 denyenv-tls-secret）。接着，在 admission webhook 配置中，我们会利用 cert-manager ca-injector（ mutate webhook 实现）注入证书。

### 部署和暴露方式

denyenv webhook server 以 Deployment 形式部署到 Kubernetes 集群，将 Secret Volume 挂载到容器目录，通过 ENV 将证书、私钥所在目录传递给应用。

以 Service 方式向 apiserver 暴露服务接口，以 443 端口映射 denyenv 8000。

### admission webhook 协议配置

通过 ValidatingWebhookConfiguration 向 apiserver 中的 ValidatingAdmissionWebhook controller 声明我们的 webhook，注意以下两点：
1. clientConfig.caBundle 用于证书认证，如果使用 Kubernetes CertificateSigningRequest 签发证书，则进入任意 Pod，拷贝文件 /run/secrets/kubernetes.io/serviceaccount/ca.crt，base64 格式化再写入 `clientConfig.caBundle`; 如果使用 cert-manager 签发证书，cert-manager ca-injector 组件会自动帮忙注入证书。
2. 为防止自己拦截自己的情形，使用 objectSelector 将 server Pod 排除。

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: denyenv
  annotations:
    ## for cert-manager CA injection
    cert-manager.io/inject-ca-from: default/denyenv-tls-secret
webhooks:
  - admissionReviewVersions:
      - v1
    clientConfig:
      caBundle: "<Kubernetes CA> or <cert-manager CA>"
      service:
        name: denyenv
        namespace: default
        port: 443
        path: /validate
    failurePolicy: Fail
    matchPolicy: Exact
    name: denyenv.zeng.dev
    rules:
      - apiGroups:
          - ""
        apiVersions:
          - v1
        operations:
          - CREATE
        resources:
          - pods
        scope: '*'
    objectSelector:
      matchExpressions:
        - key: app
          operator: NotIn
          values:
            - denyenv
    sideEffects: None
    timeoutSeconds: 3
```

注: 

你可以 clone 我的 [代码]((https://github.com/phosae/denyenv-validating-admission-webhook))，使用 `make deploy` 一键自动化所有部署过程。

如果是本地开发，可以采用 `make linux` 构建镜像，使用 `kind load` 加载镜像，最后使用 `make clear && make deploy` 一键部署。

如果使用 cert-manager，用 `make deploy-cm`、`make clear-cm` 替代 `make deploy`、`make clear`。

## 测试结果

尝试创建不含环境变量的 Pod，成功
```
$ kubectl run nginx --image nginx
pod/nginx created

$ kubectl get pod nginx
NAME    READY   STATUS              RESTARTS   AGE
nginx   0/1     ContainerCreating   0          68s
```

尝试创建含环境变量的 Pod，失败并收到拒绝信息
```
$ kubectl run nginx --image nginx --env='FOO=BAR'
Error from server (nginx is using env vars): admission webhook "denyenv.zeng.dev" denied the request: nginx is using env vars
```

## 拓展阅读
* [TLS Certificates for Kubernetes Admission Webhooks made easy with Certificator and Helm Hook?](https://medium.com/trendyol-tech/tls-certificates-for-kubernetes-admission-webhooks-made-easy-with-certificator-and-helm-hook-89ece42fa193)
* [Dynamic Admission Control
](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)
* [Certificate Trust Chain](https://en.wikipedia.org/wiki/File:Chain_Of_Trust.svg)
* [TLS](https://en.wikipedia.org/wiki/Transport_Layer_Security)
* [cert-manager](https://cert-manager.io/docs/configuration/selfsigned/)