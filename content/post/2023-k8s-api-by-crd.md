---
title: "拓展 K8s API: CustomResourceDefinitions (CRD)"
date: 2023-05-19T10:09:09+08:00
lastmod: 2023-05-19T10:09:09+08:00
draft: true
keywords: ["kubernetes", "rest"]
description: ""
tags: []
author: "Zeng Xu"
summary: "文章摘要"

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
  enable: true
  options: ""
---

本文为 **拓展 K8s API** 系列文章之一
- K8s API 拓展: CustomResourceDefinitions (CRD) (本文)
 <!-- - [Part 2 - 缓存](../2023-rest-part2-cache) -->

## Goals
这里假定你已经熟悉 Kubernetes 的基本组件，尤其是 Control Plane 之核心 kube-apiserver，如不然，可以移步[这里](https://kubernetes.io/docs/concepts/overview/components/)。

kube-apiserver 的所有资源都归属于不同组，以 API Group 方式对外暴露 [[1]](https://kubernetes.io/docs/reference/using-api/#api-groups)
- 核心/默认组 (core/legacy group) 比较特殊，它的组名为空字符串，前缀为 `/api`，可以通过 REST HTTP 路径 `/api/v1` 访问，如 `/api/v1/pods`, `/api/v1/namespaces/default/configmaps`
- 其他资源 REST HTTP 路径前缀为 `/apis`，格式一律为 `/apis/$GROUP_NAME/$VERSION`，如 `/apis/apps/v1`，`/apis/autoscaling/v2`

用户可以使用 kubectl 操作这些资源 (CRUD)

| Pod                               | Deployment                              | Action           |
| --------------------------------- | --------------------------------------- | ---------------- |
| kubectl run foo --image nginx     | kubectl create deploy/foo --image nginx | create           |
| kubectl create -f ./pod-nginx.yml | kubectl create -f ./deploy-nginx.yml    | create           |
| kubectl get pod foo               | kubectl get  deploy foo                 | get              |
| kubectl apply -f ./pod-foo.yml    | kubectl apply -f ./deploy-foo.yml       | update or create |
| kubectl delete pod foo            | kubectl delete deploy foo               | delete           |

注意到不需要指明 Deployment 对应 Group apps 也可操作成功，因为 kube-apiserver 中并无其他名称复数为 deploys/deployments 的资源。如果多个 Group 存在相同名字资源，则需要通过 `$RESOURCE_NAME.$GROUP_NAME` 唯一标识资源，类似这样 `kubectl get deployments.apps foo`。

我们现在开始拓展 kube-apiserver API，目标是在其中增设一个资源组 `hello.zeng.dev`，HTTP REST Path 为 `/apis/hello.zeng.dev/`。且资源 `foos.hello.zeng.dev` 可被 kubectl CRUD

| by KindName                 | by GroupKindName                         | Action           |
| --------------------------- | ---------------------------------------- | ---------------- |
| kubectl create -f ./foo.yml | kubectl create -f ./foo.yml              | create           |
| kubectl get foo myfoo       | kubectl get hello.zeng.dev.foos myfoo    | get              |
| kubectl apply -f ./foos.yml | kubectl apply -f ./foos.yml              | update or create |
| kubectl delete foo myfoo    | kubectl delete hello.zeng.dev.foos myfoo | delete           |

## Hands on API by CRD

最简单的方式是在集群中创建 CustomResourceDefinition 对象

```yaml
cat << EOF | kubectl apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  # 固定格式 <kind_plural>.<group>，其中 foos 对应 spec.names.plural，hello.zeng.dev 对应 spec.group
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

创建 crd/foos.hello.zeng.dev 之后，即可用 kubectl 直接操作 foo 资源。操作体验和官方资源 Pod，Service 并无二致。

<img src="/img/2023/api-crd-crudfoo.gif" width="700px"/>

这是如何做到的呢？调整日志级别可以看到， kubectl 在向 apiserver 发起 `GET /apis/hello.zeng.dev/v1/namespaces/default/foos` 之前，先 `GET /api` 和 `GET /apis` 进行 API Discovery

```bash
kubectl get fo --cache-dir $(mktemp -d) -v 6

I0524 02:24:45.787217 1446906 loader.go:373] Config loaded from file:  /root/.kube/config
I0524 02:24:45.806835 1446906 round_trippers.go:553] GET https://127.0.0.1:41485/api?timeout=32s 200 OK in 17 milliseconds
I0524 02:25:36.529247 1446951 round_trippers.go:463] GET https://127.0.0.1:41485/apis?timeout=32s
I0524 02:24:45.829483 1446906 round_trippers.go:553] GET https://127.0.0.1:41485/apis/hello.zeng.dev/v1/namespaces/default/foos?limit=500 200 OK in 5 milliseconds
No resources found in default namespace.
```

调整日志级别为 kubectl level 8 拿到 Accept Header 更改输出 application/json -> application/yaml，curl kube-apiserver /apis

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
- Group `hello.zeng.dev` 有一个版本列表 `versions`
- 版本 `v1` 内含资源 `foos`，scope 级别为 `Namespaced`
- `foos` 资源简称为 `fo`
- `foos` 资源支持动词为 `delete`, `deletecollection`, `get`, `list`, `patch`, `create`, `update`, `watch`

获取对应 REST API 信息后，kubectl 才会接着发起请求 `GET /apis/hello.zeng.dev/v1/namespaces/default/foos` 并输出 `No resources found in default namespace.` 而非直接报错 `error: the server doesn't have a resource type "fo"`

⚠️😵 注意 😵⚠️ 

返回类型 `application/yaml;g=apidiscovery.k8s.io;v=v2beta1;as=APIGroupDiscoveryList` 由 [Feature Aggregated Discovery](https://github.com/kubernetes/enhancements/issues/3352) 实现，提供聚合性的 API Discovery，于 1.26 进入 alpha 状态（默认关闭），1.27 进入 beta（默认开启）

1.27 之前 kubectl API Discovery 需要遍历所有 groups 接口

```bash
# Kubernetes 1.26.4 or below
kubectl get fo --cache-dir $(mktemp -d) -v 6

I0524 08:05:12.629151 1472208 loader.go:373] Config loaded from file:  /root/.kube/config
I0524 08:05:12.645780 1472208 round_trippers.go:553] GET https://127.0.0.1:34779/api?timeout=32s 200 OK in 14 milliseconds
I0524 08:05:12.650105 1472208 round_trippers.go:553] GET https://127.0.0.1:34779/apis?timeout=32s 200 OK in 2 milliseconds
I0524 08:05:12.655089 1472208 round_trippers.go:553] GET https://127.0.0.1:34779/apis/authorization.k8s.io/v1?timeout=32s 200 OK in 3 milliseconds
I0524 08:05:12.655874 1472208 round_trippers.go:553] GET https://127.0.0.1:34779/api/v1?timeout=32s 200 OK in 4 milliseconds
I0524 08:05:12.655935 1472208 round_trippers.go:553] GET https://127.0.0.1:34779/apis/authentication.k8s.io/v1?timeout=32s 200 OK in 4 milliseconds
...
I0524 08:05:12.659065 1472208 round_trippers.go:553] GET https://127.0.0.1:34779/apis/hello.zeng.dev/v1?timeout=32s 200 OK in 6 milliseconds
I0524 08:05:12.721295 1472208 round_trippers.go:553] GET https://127.0.0.1:34779/apis/hello.zeng.dev/v1/namespaces/default/foos?limit=500 200 OK in 43 milliseconds
No resources found in default namespace.
```

## API by CRD internals

不难发现，无论 Kubernetes 1.27 或更低版本，kube-apiserver 中所有 REST API resouces 均可按照如下层次发现

1. GET /apis ➡️ APIGroupList or APIGroupDiscoveryList (1.26+)
2. GET /apis/$GROUP_NAME ➡️ APIGroup (optional)
3. GET /apis/$GROUP_NAME/$VERSION or /api/v1 ➡️ APIResourceList

kubectl 子命令 api-resources 包含了整个发现过程（也可以结合 kubectl proxy + localhost:8001 走纯 HTTP 研究

```bash
kubectl api-resources | awk 'NR==1 || /pods|fo|deploy/'
NAME                              SHORTNAMES   APIVERSION                             NAMESPACED   KIND
pods                              po           v1                                     true         Pod
deployments                       deploy       apps/v1                                true         Deployment
foos                              fo           hello.zeng.dev/v1                      true         Foo
```

上节只是在 kube-apiserver 创建了 CRD/foos.hello.zeng.dev，对应的 REST endpoints /apis/hello.zeng.dev，/apis/hello.zeng.dev/v1 如何安装？返回的  [APIGroup](https://github.com/kubernetes/kubernetes/blob/0bff705acd8982e34b937116eb2016c9d6e4c4a6/staging/src/k8s.io/apimachinery/pkg/apis/meta/v1/types.go#L1045-L1076) 和 [APIResource](https://github.com/kubernetes/kubernetes/blob/0bff705acd8982e34b937116eb2016c9d6e4c4a6/staging/src/k8s.io/apimachinery/pkg/apis/meta/v1/types.go#L1098-L1155) 从何而来？

kube-apiserver 包含两个服务模块: kube-apiserver 和 apiextensions-apiserver，采用委托模式串联，HTTP 请求进来时
- 先从模块 kube-apiserver 开始路由匹配，如果匹配核心组路由 `/api/**` 或者[官方 API Groups](https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.27/#-strong-api-groups-strong-) 如 `/apis/apps/**`，`/apis/batch/**`，直接使用本地 Handler 处理并返回 APIGroup 或 APIResourceList 或 Resources。如果不匹配，委托给 apiextensions-apiserver 处理
- 模块 apiextensions-apiserver 先看请求是否匹配路由 `/apis/apiextensions.k8s.io/**`（customresourcedefinitions 属于该 group）或是 CRD 定义的 Custom 路由 `/apis/<crd.group.io>/**`，如果任一匹配，返回并返回 Custom APIGroup 或 Custom APIResourceList 或 Custom Resources。否则委托给 notfoundhandler 处理
- notfoundhandler 返回 HTTP 404

```
kube-apiserver (own paths: core/legacy group /api/**, official groups /apis/apps/**, /apis/batch/**...)
    |
 delegate
    |
    +--- apiextensions-apiserver (own paths: /apis/apiextensions.k8s.io/**, /apis/<crd.group.io>/**
                      |
                   delegate
                      |
                      +--- notfoundhandler -> 404Not Found
```

> 🤣🤣🤣 「kube-apiserver 包含 kube-apiserver 模块」 听着很奇怪。Kubernetes 起初只有 kube-apiserver 模块提供官方 API，并不支持 Custom Resources。之后 在 1.6 引入了 kube-aggregator 模块。在 1.7 引入了 CustomResourceDefinitions 支持 ([timeline issue](https://github.com/kubernetes/enhancements/issues/95))，也就是模块 apiextensions-apiserver。

apiextensions-apiserver 模块代码在 [这里](https://github.com/kubernetes/apiextensions-apiserver)，kube-apiserver [集成了该模块](https://github.com/kubernetes/kubernetes/blob/e11c5284ad01554b60c29b8d3f6337f2c735e7fb/cmd/kube-apiserver/app/server) 并对外提供 CRD 能力。

以上并没有解释仅创建 CRD
1. 如何自动产生 HTTP 路由
2. 如何自动创建 APIGroup/APIResourceList
3. 如何可以支持存储 custom resource 到 kube-apiserver(etcd)

这些功能主要由 apiextensions-apiserver 模块的[控制器](https://github.com/kubernetes/apiextensions-apiserver/blob/501bf5ec6db2f5e9171a8ed822380f71911b1b8f/pkg/apiserver/apiserver.go#L231-L266)实现。起主要作用的是
- [DiscoveryController](https://github.com/kubernetes/apiextensions-apiserver/blob/501bf5ec6db2f5e9171a8ed822380f71911b1b8f/pkg/apiserver/customresource_discovery_controller.go#L59)
- OpenapiController

感知到 CRD 创建后，OpenapiController 负责将所有 CRD 转换为 OpenAPISpec，将其写入 kube-apiserver 模块 OpenAPISpec，最终由 kube-apiserver /openapi/v3 或者 /openapi/v2 对外暴露。

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

通过获取 hello.zeng.dev/v1 的 openapi 信息（这里只保留了 3 层 JSON），可以发现 apiextensions-apiserver 模块自动为 CRD 生成了这些路由

- /apis/hello.zeng.dev/v1/foos
- /apis/hello.zeng.dev/v1/namespaces/{namespace}/foos
- /apis/hello.zeng.dev/v1/namespaces/{namespace}/foos/{name}

它们全部由 apiextensions-apiserver 模块的 [customresource_handler] 提供 `/apis/<group>/<version>/(foos | namespaces/{namespace}/<kind_plural> | namespaces/{namespace}/<kind_plural>/{name})` 通配。[customresource_handler] 实时读取所有 CRD 信息，负责 custom resources 的 CRUD 操作，持有一个 [RESTStorage](https://github.com/kubernetes/apiextensions-apiserver/tree/master/pkg/registry/customresource) (实现通常为 etcd)。在 API 层业务（通用校验、解码转换、admission 等）成功后，[customresource_handler] 调用 RESTStorage 实施对象持久化。

DiscoveryController 则负责实将 CRD 声明同步成 APIGroup 和 APIResource，并动态注册以下路由
- `/apis/<group>/<version>`
- `/apis/<group>`

```bash
# on top terminal
kubectl proxy
Starting to serve on 127.0.0.1:8001

---
# on middle terminal
curl -H 'Accept: application/yaml' 127.1:8001/apis/hello.zeng.dev
apiVersion: v1
kind: APIGroup
name: hello.zeng.dev
preferredVersion:
  groupVersion: hello.zeng.dev/v1
  version: v1
versions:
- groupVersion: hello.zeng.dev/v1
  version: v1
---
# on bottom terminal
curl -H 'Accept: application/yaml' 127.1:8001/apis/hello.zeng.dev/v1
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
路由 `/apis` 实际是 `/apis/<group>/<version>` 和 `/apis/<group>` 的聚合，由 kube-apiserver 的 kube-aggregator 模块提供，将在后面章节介绍。

// todo 提供图
```
CRD +---> CR
    |
    |
    +---> /apis/<group>
    |
    |
    +---> /apis/<group>
    ｜
    ｜
    +---> openapi (optional)
```
## Generate CRD from Go Structs


[customresource_handler]: https://github.com/kubernetes/apiextensions-apiserver/blob/master/pkg/apiserver/customresource_handler.go