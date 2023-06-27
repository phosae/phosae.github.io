---
title: "K8s CustomResourceDefinitions (CRD) 原理"
date: 2023-05-19T10:09:09+08:00
lastmod: 2023-05-27T17:29:00+08:00
draft: false
keywords: ["kubernetes", "rest"]
description: "K8s CustomResourceDefinition internals"
tags: ["kubernetes", "rest"]
author: "Zeng Xu"
summary: "K8s CustomResourceDefinition (CRD) 为使用者提供了开箱即用的 REST API 拓展能力。使用方只需创建一份 CRD 声明，kube-apiserver 就会自动提供一套成熟的 HTTP REST API，并直接将 Custom Resources 存储到背后存储（通常是 etcd）中。本文由浅入深，先展示了 CRD 的基本使用方式、kubectl 与对应 Custom API 模块的交互原理，再深入探究 CRD 在 kube-apiserver 内部的实现原理，最后对其特性的利弊做了总结"

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

<!-- 系列链接 -->
[CustomResourceDefinitions (CRD) 原理]: ../2023-k8s-api-by-crd
[K8s 多版本 API 转换最佳实践]: ../2023-k8s-api-multi-version-conversion-best-practice
[实现一个极简 apiserver]: ../2023-k8s-apiserver-from-scratch
[搞懂 apiserver aggregation]: ../2023-k8s-apiserver-aggregation-internals
[最不厌其烦的 K8s 代码生成教程]: ../2023-k8s-api-codegen
[使用 library 实现 K8s apiserver]: ../2023-k8s-apiserver-using-library
[慎重选用 Runtime 类框架开发 K8s apiserver]: ../2023-k8s-apiserver-avoid-using-runtime

本文为 **K8s API 和控制器** 系列文章之一
- [CustomResourceDefinitions (CRD) 原理] (本文)
- [K8s 多版本 API 转换最佳实践]
- [实现一个极简 apiserver]
- [搞懂 apiserver aggregation]
- [最不厌其烦的 K8s 代码生成教程]
- [使用 library 实现 K8s apiserver]
- [慎重选用 Runtime 类框架开发 K8s apiserver]

## 🎯 Goals
这里假定你已经熟悉 Kubernetes 的基本组件，尤其是 Control Plane 之核心 kube-apiserver，如不然，可以移步[这里](https://kubernetes.io/docs/concepts/overview/components/)。

kube-apiserver 的所有资源都归属于不同组，以 API Group 方式对外暴露 [[1]](https://kubernetes.io/docs/reference/using-api/#api-groups)
- 核心/默认组 (core/legacy group) 比较特殊，它的组名为空字符串，前缀为 `/api`，可以通过 REST HTTP 路径 `/api/v1` 访问，如 `/api/v1/pods`, `/api/v1/namespaces/default/configmaps`
- 其他资源 REST HTTP 路径前缀为 `/apis`，格式一律为 `/apis/{group}/{version}`，如 `/apis/apps/v1`，`/apis/autoscaling/v2`

用户可以使用 kubectl 操作这些资源 (CRUD)

| Pod                               | Deployment                              | Action           |
| --------------------------------- | --------------------------------------- | ---------------- |
| kubectl run foo --image nginx     | kubectl create deploy/foo --image nginx | create           |
| kubectl create -f ./pod-nginx.yml | kubectl create -f ./deploy-nginx.yml    | create           |
| kubectl get pod foo               | kubectl get  deploy foo                 | get              |
| kubectl apply -f ./pod-foo.yml    | kubectl apply -f ./deploy-foo.yml       | update or create |
| kubectl delete pod foo            | kubectl delete deploy foo               | delete           |

注意到不需要指明 Deployment 对应 Group apps 也可操作成功，因为 kube-apiserver 中并无其他名称复数为 deploys/deployments 的资源。如果多个 Group 存在相同名字资源，则需要通过 `{kind_plural}.{group}` 唯一标识资源，类似这样 `kubectl get deployments.apps foo`。

我们现在开始拓展 kube-apiserver API，目标是在其中增设一个资源组 `hello.zeng.dev`，HTTP REST Path 为 `/apis/hello.zeng.dev/`。且资源 `foos.hello.zeng.dev` 可被 kubectl CRUD

| by KindName                 | by GroupKindName                         | Action           |
| --------------------------- | ---------------------------------------- | ---------------- |
| kubectl create -f ./foo.yml | kubectl create -f ./foo.yml              | create           |
| kubectl get foo myfoo       | kubectl get hello.zeng.dev.foos myfoo    | get              |
| kubectl apply -f ./foos.yml | kubectl apply -f ./foos.yml              | update or create |
| kubectl delete foo myfoo    | kubectl delete hello.zeng.dev.foos myfoo | delete           |

## 🎮 Hands on API by CRD

最简单的方式是在集群中创建 CustomResourceDefinition 对象

```yaml
cat << EOF | kubectl apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  # 固定格式 {kind_plural}.{group}，其中 foos 对应 spec.names.plural，hello.zeng.dev 对应 spec.group
  name: foos.hello.zeng.dev 
spec:
  group: hello.zeng.dev # 资源组，用在 URL 标识资源所属 Group，如 /apis/hello.zeng.dev/v1/foos 之 hello.zeng.dev
  names:
    kind: Foo
    listKind: FooList
    plural: foos  # 资源名复数，用在 URL 标识资源类型，如 /apis/hello.zeng.dev/v1/foos 之 foos
    singular: foo # 资源名单数，可用于 kubectl 匹配资源
    shortNames:   # 资源简称，可用于 kubectl 匹配资源
    - fo
  scope: Namespaced # Namespaced/Cluster
  versions:
  - name: v1
    served: true # 是否启用该版本，可使用该标识启动/禁用该版本 API
    storage: true # 唯一落存储版本，如果 CRD 含有多个版本，只能有一个版本被标识为 true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              msg:
                type: string
    additionalPrinterColumns: # 声明 kubectl get 输出列，默认在 name 列之外额外输出 age 列，改为额外输出 age 列，message 列
    - name: age
      jsonPath: .metadata.creationTimestamp
      type: date
    - name: message
      jsonPath: .spec.msg
      type: string
EOF
```

创建 crd/foos.hello.zeng.dev 之后，即可用 kubectl 直接操作 foo 资源。操作体验和官方资源 Pod，Service 等相比并无二致。

<img src="/img/2023/api-crd-crudfoo.gif" width="700px"/>

## 🔍 API Discovery

kubectl 如何知道 kube-apiserver 存在某项资源 fo？如何知道 fo 是资源 foos 的简称？如何知道 foos 属于哪个资源 Group？如何知道 foos 支持什么操作？这就涉及到 Kubernetes 的 API Discovery 机制。

调整日志级别可以发现：kubectl 在向 kube-apiserver 发起 `GET /apis/hello.zeng.dev/v1/namespaces/default/foos` 之前。会先查询 /api 和 /apis

```bash
kubectl get fo --cache-dir $(mktemp -d) -v 6

I0524 02:24:45.787217 1446906 loader.go:373] Config loaded from file:  /root/.kube/config
I0524 02:24:45.806835 1446906 round_trippers.go:553] GET https://127.0.0.1:41485/api?timeout=32s 200 OK in 17 milliseconds
I0524 02:25:36.529247 1446951 round_trippers.go:463] GET https://127.0.0.1:41485/apis?timeout=32s
I0524 02:24:45.829483 1446906 round_trippers.go:553] GET https://127.0.0.1:41485/apis/hello.zeng.dev/v1/namespaces/default/foos?limit=500 200 OK in 5 milliseconds
No resources found in default namespace.
```

调整 kubectl 日志级别为 8 拿到 Accept Header 更改输出 application/json -> application/yaml，curl kube-apiserver /apis

```bash
# on top terminal
kubectl proxy
Starting to serve on 127.0.0.1:8001

---
# on bottom terminal, Kubernetes 1.27.2
curl -H 'Accept: application/yaml;g=apidiscovery.k8s.io;v=v2beta1;as=APIGroupDiscoveryList' localhost:8001/apis

apiVersion: apidiscovery.k8s.io/v2beta1
kind: APIGroupDiscoveryList
metadata: {}
items:
- metadata:
    creationTimestamp: null
    name: hello.zeng.dev
  versions:
  - version: v1
    resources:
    - resource: foos
      responseKind:
        group: hello.zeng.dev
        kind: Foo
        version: v1
      scope: Namespaced
      shortNames:
      - fo
      singularResource: foo
      verbs:
      - delete
      - deletecollection
      - get
      - list
      - patch
      - create
      - update
      - watch
```
可以看到如下 REST API 信息
- kube-apiserver 有一个 API Group `hello.zeng.dev`
- Group `hello.zeng.dev` 含有许多 `versions`
- 版本 `v1` 内含资源 `foos`，scope 级别为 `Namespaced`
- `foos` 资源简称为 `fo`
- `foos` 资源支持操作动词为 `delete`, `deletecollection`, `get`, `list`, `patch`, `create`, `update`, `watch`

获取对应 REST API 信息后，kubectl 发现 fo 是资源复数为 `foos` 的简称，其对应 group 为 `hello.zeng.dev`，其默认版本为 `v1`，于是发起请求 `GET/POST/PATCH/DELETE /apis/hello.zeng.dev/v1/namespaces/default/foos`，而抛出错误 `error: the server doesn't have a resource type "fo"`

⚠️😵 注意 😵⚠️ 

返回类型 `application/yaml;g=apidiscovery.k8s.io;v=v2beta1;as=APIGroupDiscoveryList` 由 [Feature Aggregated Discovery](https://github.com/kubernetes/enhancements/issues/3352) 实现，支持一次调用获取所有 API Group/Resource 信息，于 1.26 进入 alpha 状态（默认关闭），1.27 进入 beta（默认开启）

一般地，kube-apiserver 中所有 REST API resouces 均可按照如下层次发现（核心/默认组放在特殊路径 `/api`，它没有 Group（或者说 Group 是空字符串）
1. GET `/api` ➡️ APIVersions or APIGroupDiscoveryList (1.27+)
2. GET `/apis` ➡️ APIGroupList or APIGroupDiscoveryList (1.27+)
3. GET `/apis/{group}` ➡️ APIGroup (optional, contained in `/apis`)
4. GET `/apis/{group}/{version}` or `/api/v1` ➡️ APIResourceList

kubectl api-resources 包含了整个发现过程

```bash
# Kubernetes 1.26.4 (1.27-
kubectl api-resources --cache-dir $(mktemp -d) -v 6 | awk 'NR==1 || /pods|fo|deploy/'

I0524 08:05:12.629151 1472208 loader.go:373] Config loaded from file:  /root/.kube/config
I0524 08:05:12.645780 1472208 round_trippers.go:553] GET https://127.0.0.1:34779/api?timeout=32s 200 OK in 14 milliseconds
I0524 08:05:12.650105 1472208 round_trippers.go:553] GET https://127.0.0.1:34779/apis?timeout=32s 200 OK in 2 milliseconds
I0524 08:05:12.655089 1472208 round_trippers.go:553] GET https://127.0.0.1:34779/apis/authorization.k8s.io/v1?timeout=32s 200 OK in 3 milliseconds
I0524 08:05:12.655874 1472208 round_trippers.go:553] GET https://127.0.0.1:34779/api/v1?timeout=32s 200 OK in 4 milliseconds
I0524 08:05:12.655935 1472208 round_trippers.go:553] GET https://127.0.0.1:34779/apis/authentication.k8s.io/v1?timeout=32s 200 OK in 4 milliseconds
...
I0524 08:05:12.659065 1472208 round_trippers.go:553] GET https://127.0.0.1:34779/apis/hello.zeng.dev/v1?timeout=32s 200 OK in 6 milliseconds
I0524 08:05:12.721295 1472208 round_trippers.go:553] GET https://127.0.0.1:34779/apis/hello.zeng.dev/v1/namespaces/default/foos?limit=500 200 OK in 43 milliseconds
NAME                              SHORTNAMES   APIVERSION                             NAMESPACED   KIND
pods                              po           v1                                     true         Pod
deployments                       deploy       apps/v1                                true         Deployment
foos                              fo           hello.zeng.dev/v1                      true         Foo
```

默认情况下 kube-apiverser `GET /apis` 返回 APIGroupList (包含所有 API Groups 信息），再逐个访问 `/apis/{group}/{version}` 得到 APIResourceList。最终汇聚出 kube-apiserver 支持的所有 Resource 信息

```bash
# on top terminal
kubectl proxy
Starting to serve on 127.0.0.1:8001
---
curl -H 'Accept: application/yaml' localhost:8001/apis 

kind: APIGroupList
apiVersion: v1
groups:
- name: autoscaling
  versions:
  - groupVersion: autoscaling/v2
    version: v2
  - groupVersion: autoscaling/v1
    version: v1
  preferredVersion:
    groupVersion: autoscaling/v2
    version: v2
- name: hello.zeng.dev
  versions:
  - groupVersion: hello.zeng.dev/v1
    version: v1
  preferredVersion:
    groupVersion: hello.zeng.dev/v1
    version: v1
...
---
curl -H 'Accept: application/yaml' localhost:8001/apis/hello.zeng.dev/v1

apiVersion: v1
groupVersion: hello.zeng.dev/v1
kind: APIResourceList
resources:
- kind: Foo
  name: foos
  namespaced: true
  shortNames:
  - fo
  singularName: foo
  storageVersionHash: YAqgrOjs43I=
  verbs:
  - delete
  - deletecollection
  - get
  - list
  - patch
  - create
  - update
  - watch
```

可以看出，APIGroupDiscoveryList 其实是 APIGroupList 加上所有 APIResourceList，作用是减少 API Discovery 的请求次数 (n -> 1)。

## 🤔 API by CRD internals

kube-apiserver 包含两个模块：kube-apiserver 模块和 [apiextensions-apiserver 模块]，前者负责官方核心组 core/legacy (Pod, ConfigMap, Service 等) 和官方普通 Groups (apps, autoscaling, batch) 资源的处理，后者负责 CRD 及对应 Custom Resources 处理。

> 🤣🤣🤣 
> 「kube-apiserver 包含 kube-apiserver 模块」 —— 听着很奇怪。Kubernetes 起初只有 kube-apiserver 模块提供官方 API，并不支持 Custom Resources。1.6 之后相继引入 CustomResourceDefinitions（也即 [apiextensions-apiserver 模块]，见 [issue 95]）和 kube-aggregator 模块（支持 API Aggregation 功能，见 [issue 263]）支持 Custom Resources。

[apiextensions-apiserver 模块] 功能，由多个内置 controllers 驱动。比较重要的控制器是 controllers 是 [DiscoveryController]（负责 API Discovery）、OpenAPI 控制器（OpenAPI Spec），和 [customresource_handler]（负责资源的增删改查）。其他的还有 CRD 状态字段更新、对应 custom resource 名称检查、CRD 删除清理等，代码集中在 [这个 package](https://github.com/kubernetes/apiextensions-apiserver/tree/master/pkg/controller)。

[DiscoveryController] 实现了之前展示的 API Discovery。它不断监听 CRD 变化，负责将 CRD 声明同步转化为以下内存对象 

- [APIGroupDiscovery](https://github.com/kubernetes/kubernetes/blob/master/staging/src/k8s.io/api/apidiscovery/v2beta1/types.go#L33-L66) (1.26+)
- [APIGroup](https://github.com/kubernetes/kubernetes/blob/0bff705acd8982e34b937116eb2016c9d6e4c4a6/staging/src/k8s.io/apimachinery/pkg/apis/meta/v1/types.go#L1045-L1076)
- [APIResourceList](https://github.com/kubernetes/kubernetes/blob/0bff705acd8982e34b937116eb2016c9d6e4c4a6/staging/src/k8s.io/apimachinery/pkg/apis/meta/v1/types.go#L1098-L1155)
 
并动态注册以下 API 返回对应资源

- `/apis/{group}` ➡️ APIGroup
- `/apis/{group}/{version}` ➡️ APIResourceList

在本文例子中，动态注册的路由是 `/apis/hello.zeng.dev` 和 `/apis/hello.zeng.dev/v1`。

在 1.26+ APIGroupDiscovery 则会提供给 kube-apiserver 中的全局 [AggregatedDiscoveryGroupManager](https://github.com/kubernetes/kubernetes/blob/b374404825125f5ea8c46313ccaf3717e6ba46fb/staging/src/k8s.io/apiserver/pkg/server/config.go#L278)，最终统一聚合在 `/apis`。1.26 之前，`/apis` 路径只返回 APIGroupList。

得益于 OpenAPI 控制器，CRD 创建后，自 kube-apiserver /openapi/v3 或者 /openapi/v2 查询 hello.zeng.dev/v1 的 OpenAPISpec，即可得到如下结果（只展示了 3 层 JSON，完整内容在 [这里](/file/hello.zeng.dev_v1_openapi_v3.json) 

```bash
# on top terminal
kubectl proxy
Starting to serve on 127.0.0.1:8001

---
# on bottom terminal, or curl -s http://localhost:8001/openapi/v3/apis/hello.zeng.dev/v1 | jq 'del(.[]?[]?[]?[]?)'
curl -s http://localhost:8001/openapi/v3/apis/hello.zeng.dev/v1 | jq 'delpaths([path(.), path(..) | select(length >3)])'
{
  "openapi": "3.0.0",
  "info": {
    "title": "Kubernetes CRD Swagger",
    "version": "v0.1.0"
  },
  "paths": {
    "/apis/hello.zeng.dev/v1/foos": {
      "get": {},
      "parameters": []
    },
    "/apis/hello.zeng.dev/v1/namespaces/{namespace}/foos": {
      "get": {},
      "post": {},
      "delete": {},
      "parameters": []
    },
    "/apis/hello.zeng.dev/v1/namespaces/{namespace}/foos/{name}": {
      "get": {},
      "put": {},
      "delete": {},
      "patch": {},
      "parameters": []
    }
  },
  "components": {
    "schemas": {
      "dev.zeng.hello.v1.Foo": {},
      "dev.zeng.hello.v1.FooList": {},
      "io.k8s.apimachinery.pkg.apis.meta.v1.DeleteOptions": {},
      "io.k8s.apimachinery.pkg.apis.meta.v1.FieldsV1": {},
      "io.k8s.apimachinery.pkg.apis.meta.v1.ListMeta": {},
      "io.k8s.apimachinery.pkg.apis.meta.v1.ManagedFieldsEntry": {},
      "io.k8s.apimachinery.pkg.apis.meta.v1.ObjectMeta": {},
      "io.k8s.apimachinery.pkg.apis.meta.v1.OwnerReference": {},
      "io.k8s.apimachinery.pkg.apis.meta.v1.Patch": {},
      "io.k8s.apimachinery.pkg.apis.meta.v1.Preconditions": {},
      "io.k8s.apimachinery.pkg.apis.meta.v1.Status": {},
      "io.k8s.apimachinery.pkg.apis.meta.v1.StatusCause": {},
      "io.k8s.apimachinery.pkg.apis.meta.v1.StatusDetails": {},
      "io.k8s.apimachinery.pkg.apis.meta.v1.Time": {}
    }
  }
}
```

OpenAPI 控制器有两个：[OpenAPIController v2] 和 [OpenAPIController v3]，分别支持 [OpenAPI Specification v2](https://swagger.io/specification/v2/) 和 [OpenAPI Specification v3](https://spec.openapis.org/oas/v3.1.0)。**接口响应体字段** schemas 对应 CRD 对象字段 `.spec.versions[].schema`， [OpenAPIController v2] 和 [OpenAPIController v3] 会监听 CRD 变化、自动生成 OpenAPISpec 并将其写入 kube-apiserver 模块 OpenAPI Spec，由 kube-apiserver 路由 /openapi/v2 和 /openapi/v3 对外暴露。

OpenAPISpec 则类似使用说明书，它提供了使用 API 的规范：包括接收参数、数据格式约束、操作动词、返回数据类型等。稍微修改 CRD OpenAPI 定义，要求 `spec.msg` 为必输，且长度不超过 15

```yaml
schema:
  openAPIV3Schema:
    type: object
    properties:
      spec:
        type: object
        required: ["msg"] # 新增字段必输校验
        properties:
          msg:
            type: string
          maxLength: 15 # 新增长度上限校验
```

可校验效果如下

```bash
cat << EOF | k apply -f -
apiVersion: hello.zeng.dev/v1
kind: Foo
metadata:
  name: invalid
spec: {}
EOF

The Foo "invalid" is invalid: spec.msg: Required value
---

cat << EOF | k apply -f -
apiVersion: hello.zeng.dev/v1
kind: Foo
metadata:
  name: invalid
spec:
  msg: "hello world, hello world"
EOF
The Foo "invalid" is invalid: spec.msg: Too long: may not be longer than 15
```

<img src="/img/2023/crd-custom-resource-validation.gif" width="600px"/>

此外可以看到，创建 Foo 不遵从如下结构会报错

```
apiVersion: hello.zeng.dev/v1 | apiVersion: v1  <--- 使用何种 API 版本创建资源
kind: Foo                     | kind: Pod       <--- 欲创建资源类型
metadata:                     | metadata:       <--- 唯一标识资源的元数据，包括 name
  name: myfoo                 |   name: web              namespace（默认值为 default）, UID（省略则在服务端自动生成) 等
spec:                         | spec:           <--- 所期望的资源状态（What state you desire for the object
  msg: hi                     |   containers:            通常搭配 status 使用，当前阶段的 Foo 还不涉及，后续文章会做介绍
                              |   - name: nginx  
                              |     image: nginx
```

它们是 [Kubernetes objects 必须字段](https://kubernetes.io/docs/concepts/overview/working-with-objects/#required-fields) 。尽管 CRD OpenAPIV3 Schema 并不包含 apiVersion, kind 和 metadata 字段， [apiextensions-apiserver 模块] 会 [强制保证这些字段](https://github.com/kubernetes/apiextensions-apiserver/blob/e0b0416bf23396ad7fb7007b264f5c04062590bc/pkg/registry/customresource/validator.go)。

🪬🪬🪬 Kubernetes 1.25+ [CRD validation rules](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules) 进入 beta，可在 OpenAPI Spec 基础上设置更强大的字段约束。

🪬🪬🪬 kubectl apply 会利用 OpenAPI Spec 确定资源支持的 Patch 类型，kubectl explain 输出的资源字段来自于 OpenAPI Spec。kubectl 插件 [kubernetes-sigs/kubectl-validate](https://github.com/kubernetes-sigs/kubectl-validate) 支持在客户端使用 OpenAPI Spec 校验资源对象（接近 `--dry-run=server`）。

解释了 API Discovery 如何可能和如何使用 API 之后，到达了最后一个问题：**API 资源处理和持久如何可能?**

这得从路由层说起，kube-apiserver [通过委托模式串联 apiextensions-apiserver 模块](https://github.com/kubernetes/kubernetes/blob/e11c5284ad01554b60c29b8d3f6337f2c735e7fb/cmd/kube-apiserver/app/server.go#L192-L208) 获得了 CRD 处理能力

```
kube-apiserver ---> {core/legacy group /api/**}, {official groups /apis/apps/**, /apis/batch/**, ...}
    │
 delegate
    │
    └── apiextensions-apiserver ---> {CRD groups /apis/apiextensions.k8s.io/**, /apis/<crd.group.io>/**}
                      │
                   delegate
                      │
                      └── notfoundhandler ---> 404 NotFound
```

HTTP 请求路由流程如下
- 先从 kube-apiserver 模块开始路由匹配，如果匹配核心组路由 `/api/**` 或者[官方 API Groups](https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.27/#-strong-api-groups-strong-) 如 `/apis/apps/**`，`/apis/batch/**`，直接在本模块处理。如果不匹配，委托给 apiextensions-apiserver 处理
- [apiextensions-apiserver 模块] 先看请求是否匹配路由 `/apis/apiextensions.k8s.io/**`，如果是则为 customresourcedefinitions 变更，直接在本模块处理；如果不匹配，再看是否匹配任意 CRD 对应的 Custom 路由 `/apis/{crd_group}/**`，如果任一匹配，直接在本模块处理。否则委托给 notfoundhandler 处理
- notfoundhandler 返回 HTTP 404

回顾之前的 OpenAPI Spec，可以发现 [apiextensions-apiserver 模块] 自动为 CRD 生成了这些 REST API

- /apis/hello.zeng.dev/v1/foos
- /apis/hello.zeng.dev/v1/namespaces/{namespace}/foos
- /apis/hello.zeng.dev/v1/namespaces/{namespace}/foos/{name}

原理是模块内 [customresource_handler] 提供了 `/apis/{group}/{version}/({kind_plural} | namespaces/{namespace}/{kind_plural} | namespaces/{namespace}/{kind_plural}/{name})` 通配。[customresource_handler] 实时读取所有 CRD 信息，负责 custom resources 的 CRUD 操作，并持有一个 [RESTStorage](https://github.com/kubernetes/apiextensions-apiserver/tree/master/pkg/registry/customresource) (实现通常为 etcd)。在 API 层业务（通用校验、解码转换、admission 等）成功后，[customresource_handler] 调用 RESTStorage 实施对象持久化。


路由 `/apis` 实际是 `/apis/{group}/{version}` 和 `/apis/{group}` 的聚合，由 kube-apiserver 的 kube-aggregator 模块提供，将在后面章节介绍。

总结上述内容如下

<img src="/img/2023/crd-2discovery-2resource.png" width="888px"/>

```
                      +--- DiscoveryController sync ---> HTTP Endpoints /apis/{group},/apis/{group}/{version}
                      |
CRD <---listwatch---> +--- OpenApiController sync ---> OpenAPI Spec in kube-apiserver module
                      |
                      +--- customresource_handler CRUDs
                           +---> /apis/{group}/{version}/foos
                           +---> /apis/{group}/{version}/namespaces/{namespace}/{kind_plural}
                           +---> /apis/{group}/{version}/namespaces/{namespace}/{kind_plural}/{name}
```

## 🧰 Generate CRD from Go Structs
手动维护 CRD 对象是笨办法，更好的方式是从 Go Struct 生成 CRD 声明。[controller-tools](https://github.com/kubernetes-sigs/controller-tools) 项目的一个工具 [controller-gen](https://github.com/kubernetes-sigs/controller-tools/tree/master/cmd/controller-gen) 提供了这种能力。

我的项目 [x-kubernetes] 统一将 API 相关 Go Structs 放置在目录 /api 中，按照 /api/{group} 罗列

```
~/x-kubernetes# tree api -L 3
api
└── hello.zeng.dev
    └── v1
        ├── types.go
        └── ...
```

types.go 内容如下
```go
package v1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

type Foo struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty" protobuf:"bytes,1,opt,name=metadata"`

	Spec FooSpec `json:"spec" protobuf:"bytes,2,opt,name=spec"`
}

type FooSpec struct {
	// Msg says hello world!
	Msg string `json:"msg" protobuf:"bytes,1,opt,name=msg"`
	// Msg1 provides some verbose information
	// +optional
	Msg1 string `json:"msg1" protobuf:"bytes,2,opt,name=msg1"`
}

type FooList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty" protobuf:"bytes,1,opt,name=metadata"`

	Items []Foo `json:"items" protobuf:"bytes,2,rep,name=items"`
}
```

在项目 /api 目录，执行 crd 生成脚本 update-crd-docker.sh

```bash
~/x-kubernetes/api# ./hack/update-crd-docker.sh 
```
或者在 /api 目录直接跑 controller-gen

```bash
controller-gen schemapatch:manifests=./artifacts/crd paths=./... output:dir=./artifacts/crd
```

即可动态生成 OpenAPI schemas (changes trace: git diff a5469c0 38dcc40 \-\- artifacts/crd/hello.zeng.dev_foos.yaml)

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: foos.hello.zeng.dev
spec:
  group: hello.zeng.dev
  names:
    kind: Foo
    listKind: FooList
    plural: foos
    singular: foo
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      additionalPrinterColumns:
        - name: age
          jsonPath: .metadata.creationTimestamp
          type: date
        - name: message
          jsonPath: .spec.msg
          type: string
        - name: message1
          jsonPath: .spec.msg1
          type: string
      schema:
-        openAPIV3Schema: {}
+        openAPIV3Schema:
+          type: object
+          required:
+            - spec
+          properties:
+            apiVersion:
+              description: 'APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources'
+              type: string
+            kind:
+              description: 'Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
+              type: string
+            metadata:
+              type: object
+            spec:
+              type: object
+              required:
+                - msg
+              properties:
+                msg:
+                  description: Msg says hello world!
+                  type: string
+                msg1:
+                  description: Msg1 provides some verbose information
+                  type: string
```

可以发现 Go Structs 中含有 JSON Tags 的字段均被映射到了 OpenAPI Spec Properties，字段注释映射到了 description，字段类型映射到了 type。

⚠️⚠️⚠️ 注意：这里的 `controller-gen schemapatch`，作用使用 patch 仅更新文件 hello.zeng.dev_foos.yaml 中的 openAPIV3Schema。如果使用 `controller-gen crd`，则会重新生成整个文件。
- `controller-gen crd:crdVersions=v1 paths=./... output:dir=./artifacts/crd` 生成完整CRD定义 ➡️ [hello.zeng.dev_foos_full.yaml]
- `controller-gen crd:crdVersions=v1,maxDescLen=0 paths=./... output:dir=./artifacts/crd` 生成不含注释的CRD定义 ➡️ [hello.zeng.dev_foos_nodesc.yaml]

这里没有引入需要学习成本的 [generation markers](https://book.kubebuilder.io/reference/markers/crd.html)，故没法生成 additionalPrinterColumns 定义。也没有引入 [validation markers](https://book.kubebuilder.io/reference/markers/crd-validation.html)，故没法生成字段校验 schema。

⚠️⚠️⚠️ 注意：CRD OpenAPI Schema 之 `properties/apiVersion, kind, metadata` ，虽然工具生成了这些字段定义，实际非必需（如之前展示）。apiextensions-apiserver 的 [openapi builder](https://github.com/kubernetes/apiextensions-apiserver/blob/37c0f7d353bee5630da4b697c410b00acec91f11/pkg/controller/openapi/builder/builder.go#L381-L413) 会自动注入这些定义。

## 📝 Summarize

CustomResourceDefinition 是拓展 K8s API 最便捷方式，没有之一。[apiextensions-apiserver 模块] 有如下好处
- 开箱即用，只需提供 CRD 声明，不需要自行实现 REST API（包括 OpenAPI Spec 转换、API Discovery、Custom Resource CRUD），也不需要与存储层交互
- 本身集成在 kube-apiserver 中，不需要处理鉴权（authentication）和授权（authorization）
- [kubebuilder], [controller-tools] 等社区工具，可以一键生成 CRD 定义和对应的控制器脚手架

而它的缺点也正是它的优点的反面（但对于规模不大的集群和大部分场景通常可以忍受
- 存储限制较大，只能以 JSON 存储 etcd，其他存储需求无法满足，比如存储为 protobuf 以节约磁盘空间，比如 Custom Resource 仅存储在内存，仅存储在普通文件，需要存储在 MySQL, SQLite, PostgreSQL 等关系型数据库
- API 绑定在 kube-apiserver 进程，无法单独对外提供服务，无法实施 API 分流，定制性低

后续篇章会基于同样的 API 库，展示各种 custom apiserver 集成方式，方便比较优劣。

如果对 CRD 的多版本 API 转换有兴趣，可以移步查阅 [K8s 多版本 API 转换最佳实践]。

Custom API 往往需要配合控制器，才能发挥其强大能力。本文仅介绍了 CustomResourceDefinition 的使用姿势和实现原理。控制器相关将在后续篇章介绍。

<!-- apiextensions-apiserver timeline -->
[issue 95]: https://github.com/kubernetes/enhancements/issues/95
<!-- API Aggregation timeline -->
[issue 263]: https://github.com/kubernetes/enhancements/issues/263
[customresource_handler]: https://github.com/kubernetes/apiextensions-apiserver/blob/master/pkg/apiserver/customresource_handler.go
[DiscoveryController]: https://github.com/kubernetes/apiextensions-apiserver/blob/501bf5ec6db2f5e9171a8ed822380f71911b1b8f/pkg/apiserver/customresource_discovery_controller.go#L59
[OpenAPIController v2]: https://github.com/kubernetes/apiextensions-apiserver/blob/master/pkg/controller/openapi/controller.go
[OpenAPIController v3]: https://github.com/kubernetes/apiextensions-apiserver/blob/master/pkg/controller/openapiv3/controller.go
[apiextensions-apiserver 模块]: https://github.com/kubernetes/apiextensions-apiserver
[x-kubernetes]: https://github.com/phosae/x-kubernetes
[hello.zeng.dev_foos_full.yaml]: https://github.com/phosae/x-kubernetes/blob/38dcc4056984705ffbf9dbeaa570e875857a6042/api/artifacts/crd/hello.zeng.dev_foos_full.yaml
[hello.zeng.dev_foos_nodesc.yaml]: https://github.com/phosae/x-kubernetes/blob/38dcc4056984705ffbf9dbeaa570e875857a6042/api/artifacts/crd/hello.zeng.dev_foos_nodesc.yaml
[kubebuilder]: https://github.com/kubernetes-sigs/kubebuilder
[controller-tools]: https://github.com/kubernetes-sigs/controller-tools