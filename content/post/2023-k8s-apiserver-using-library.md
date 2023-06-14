---
title: "使用 library 实现 K8s apiserver"
date: 2023-06-07T16:11:19+08:00
lastmod: 2023-06-11T16:11:19+08:00
draft: true
keywords: ["kubernetes", "rest", "go", "http", "openapi"]
description: "The best way to understand K8s apiserver is to implement one yourself"
tags: ["kubernetes", "rest", "go", "http", "openapi"]
author: "Zeng Xu"
summary: "理解 K8s apiserver 的最好方式就是自己动手实现同款"

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
---
<!-- 系列链接 -->
[K8s CustomResourceDefinitions (CRD) 原理]: ../2023-k8s-api-by-crd
[实现一个极简 K8s apiserver]: ../2023-k8s-apiserver-from-scratch
[搞懂 K8s apiserver aggregation]: ../2023-k8s-apiserver-aggregation-internals
[最不厌其烦的 K8s 代码生成教程]: ../2023-k8s-api-codegen
[使用 library 实现 K8s apiserver]: ../2023-k8s-apiserver-using-library

本文为 **K8s API 和控制器** 系列文章之一
- [K8s CustomResourceDefinitions (CRD) 原理]
- [实现一个极简 K8s apiserver]
- [搞懂 K8s apiserver aggregation]
- [最不厌其烦的 K8s 代码生成教程]
- [使用 library 实现 K8s apiserver] (本文)

## API 定义和代码生成

[实现一个极简 K8s apiserver] 展示了 apiserver 的极简实现方式。但它还欠缺一些 apiserver 功能，比如 watch 和数据持久。
而 library [k8s.io/apiserver] 补全了所有欠缺，包括配置即用的鉴权/授权、etcd 集成等。

本文将使用 [k8s.io/apiserver] 实现 apiserver。

首先， API 相关可以变得正式一些。仿照 [k8s.io/api](https://github.com/kubernetes/api) 风格 创建独立 API module [x-kubernetes/api]
- 目录结构为 {group}/{version}
- types.go 放置 API structs
- doc.go 存放代码生成定义
- register.go 提供 API 注册函数。类型被注册到 [runtime.Scheme] 之后，apiserver 库中持有 [runtime.Scheme] 的组件便会知道
  * 反序列化 /apis/hello.zeng.dev/{version}/namespaces/{ns}/foos requestBody ➡️ go struct object Foo/FooList
  * 序列化  go struct object Foo/FooList ➡️ /apis/hello.zeng.dev/{version}/namespaces/{ns}/foos responseBody
  * 如何设置 structs 默认值，如何处理 structs 外部版本与内部版本转换 🔄，等等

原先的 API structs 被放置在 hello.zeng.dev/v1。同时，目录 hello.zeng.dev/v2 增设了 v2 版本 api。 

```bash
~/x-kubernetes/api# tree hello.zeng.dev/
hello.zeng.dev/
├── v1
│   ├── doc.go
│   ├── register.go
│   └── types.go
└── v2
    ├── doc.go
    ├── register.go
    └── types.go
```
hello.zeng.dev/v1 types.go 与 [极简 K8s apiserver types] 保持了一致。
```go
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
```
hello.zeng.dev/v2 types.go 基于 v1 做了升级，spec 中引入了 image，并将 msg 和 msg1 移到了 spec.config。同时，引入了 spec 同级字段 status，用来描述实际状态。

v2 版本 API 变得非常符合 [Kubernetes-style API types]。

```go
type Foo struct {
    metav1.TypeMeta   `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty" protobuf:"bytes,1,opt,name=metadata"`

    Spec   FooSpec   `json:"spec" protobuf:"bytes,2,opt,name=spec"`
    Status FooStatus `json:"status,omitempty" protobuf:"bytes,3,opt,name=status"`
}

type FooSpec struct {
    // Container image that the container is running to do our foo work
    Image string `json:"image" protobuf:"bytes,1,opt,name=image"`
    // Config is the configuration used by foo container
    Config FooConfig `json:"config" protobuf:"bytes,2,opt,name=config"`
}

type FooConfig struct {
    // Msg says hello world!
    Msg string `json:"msg" protobuf:"bytes,1,opt,name=msg"`
    // Msg1 provides some verbose information
    // +optional
    Msg1 string `json:"msg1,omitempty" protobuf:"bytes,2,opt,name=msg1"`
}
```

按照 [最不厌其烦的 K8s 代码生成教程] 生成代码后，即可着手开始构建 apiserver。

## The hello.zeng.dev/v1's CRUD Implementation

支持 hello.zeng.dev/v1 的新 apiserver 主要看 2 个 commits 即可，[build apiserver ontop library] 和 [apiserver by lib: add etcd store]。

[build apiserver ontop library] 提供了 [实现一个极简 K8s apiserver] 的 [k8s.io/apiserver] 库实现版，数据存储在内存。
提交文件很少，且大部分代码都在和库打交道

      ├── main.go              # 入口，设置 signal handler，调用 package cmd 并运行之
      └── pkg
          ├── apiserver
          │   └── apiserver.go # 组合各模块：设置 Scheme，创建 rest.Storage，初始化并启动 apiserver
          ├── cmd
          │   └── start.go     # 解析框架和自定义命令行参数，补全并校验配置，创建并运行 custom apiserver
          └── registry
              └── foo.go       # 实现框架接口 rest.StandardStorage，实现 foo CRUD

pkg/apiserver/apiserver.go 作用就是构建 [k8s.io/apiserver] 枢纽 —— [GenericAPIServer]。
所有组件都会体现在这个结构体中。

```go
import(
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/apimachinery/pkg/runtime"
    "k8s.io/apimachinery/pkg/runtime/schema"
    "k8s.io/apimachinery/pkg/runtime/serializer"
    genericapiserver "k8s.io/apiserver/pkg/server"
)

var (
    // Scheme defines methods for serializing and deserializing API objects.
    Scheme = runtime.NewScheme()
    // Codecs provides methods for retrieving codecs and serializers for specific
    // versions and content types.
    Codecs = serializer.NewCodecFactory(Scheme)
)

func init() {
    hello.Install(Scheme)

    metav1.AddToGroupVersion(Scheme, schema.GroupVersion{Group: "", Version: "v1"})
    unversioned := schema.GroupVersion{Group: "", Version: "v1"}
    Scheme.AddUnversionedTypes(unversioned,
        &metav1.Status{},
        &metav1.APIVersions{},
        &metav1.APIGroupList{},
        &metav1.APIGroup{},
        &metav1.APIResourceList{},
    )
}

// New returns a new instance of WardleServer from the given config.
func (c completedConfig) New() (*HelloApiServer, error) {
    genericServer, err := c.GenericConfig.New("hello.zeng.dev-apiserver", genericapiserver.NewEmptyDelegate())
    s := &HelloApiServer{ GenericAPIServer: genericServer}

    apiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(hellov1.GroupName, Scheme, metav1.ParameterCodec, Codecs)

    apiGroupInfo.VersionedResourcesStorageMap["v1"] = map[string]rest.Storage{
        "foos": registry.NewFooApi(),
    }

    if err := s.GenericAPIServer.InstallAPIGroup(&apiGroupInfo); err != nil {
        return nil, err
    }

    return s, nil
}
```

pkg/registry/foo.go 实现了 interface rest.StandardStorage 除 rest.Watcher 之外所有接口

```go
"k8s.io/apiserver/pkg/registry/rest"

var _ rest.ShortNamesProvider = &fooApi{}
var _ rest.SingularNameProvider = &fooApi{}
var _ rest.Getter = &fooApi{}
var _ rest.Lister = &fooApi{}
var _ rest.CreaterUpdater = &fooApi{}
var _ rest.GracefulDeleter = &fooApi{}
var _ rest.CollectionDeleter = &fooApi{}

// var _ rest.StandardStorage = &fooApi{} // implements all interfaces of rest.StandardStorage except rest.Watcher
```
GenericAPIServer 接到 fooApi 和 Scheme 注册之后，便会按照框架协议将它们转化为对应 REST Handlers。

[apiserver by lib: add etcd store] 支持了 etcd 存储

    pkg
    ├── apiserver
    │   └── apiserver.go # --enable-etcd-storage=true 则加载 etcd 存储实现
    ├── cmd
    │   └── start.go     # --enable-etcd-storage=true 则加载 etcd 配置项们
    └── registry/hello.zeng.dev/foo
        ├── etcd.go      # 初始化框架 etcd 存储实现，加载各种策略（CRUD、
        ├── strategy.go  # 实现各种策略
        └── mem.go       # mv pkg/registry/foo.go ---> pkg/registry/hello.zeng.dev/foo/mem.go

pkg/apiserver/apiserver.go 改动很小，即支持根据配置调整存储实现，当 enable-etcd-storage 为 true 时使用 etcd 存储实现

```go
func (c completedConfig) New() (*HelloApiServer, error) {
    genericServer, _ := c.GenericConfig.New("hello.zeng.dev-apiserver", genericapiserver.NewEmptyDelegate())
    ...
    s := &HelloApiServer{GenericAPIServer: genericServer}

    apiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(
        hellov1.GroupName, Scheme, metav1.ParameterCodec, Codecs)

    apiGroupInfo.VersionedResourcesStorageMap["v1"] = map[string]rest.Storage{}
    if c.ExtraConfig.EnableEtcdStorage {
        etcdstorage, err := fooregistry.NewREST(Scheme, c.GenericConfig.RESTOptionsGetter)
        if err != nil {
            return nil, err
        }
        apiGroupInfo.VersionedResourcesStorageMap["v1"]["foos"] = etcdstorage
    } else {
        apiGroupInfo.VersionedResourcesStorageMap["v1"]["foos"] = fooregistry.NewMemStore()
    }

    if err := s.GenericAPIServer.InstallAPIGroup(&apiGroupInfo); err != nil {
        return nil, err
    }
    return s, nil
}
```

pkg/registry/hello.zeng.dev/foo/etcd.go 只有一个 func NewREST，它干的活是
- 接收 runtime.Scheme 和 RESTOptionsGetter（其返回的 RESTOptions 包含了 rest.StandStorage 接口的 etcd 实现
- 新建 foo 存储策略 fooStrategy
- 构建并返回 struct [k8s.io/apiserver pkg/registry/generic/registry.Store]

```go
package foo

import (
    "k8s.io/apimachinery/pkg/runtime"
    "k8s.io/apiserver/pkg/registry/generic"
    genericregistry "k8s.io/apiserver/pkg/registry/generic/registry"

    hellov1 "github.com/phosae/x-kubernetes/api/hello.zeng.dev/v1"
)

// NewREST returns a RESTStorage object that will work against API services.
func NewREST(scheme *runtime.Scheme, optsGetter generic.RESTOptionsGetter) (*genericregistry.Store, error) {
    strategy := NewStrategy(scheme)

    store := &genericregistry.Store{
        NewFunc:                   func() runtime.Object { return &hellov1.Foo{} },
        NewListFunc:               func() runtime.Object { return &hellov1.FooList{} },
        PredicateFunc:             MatchFoo,
        DefaultQualifiedResource:  hellov1.Resource("foos"),
        SingularQualifiedResource: hellov1.Resource("foos"),

        CreateStrategy: strategy,
        UpdateStrategy: strategy,
        DeleteStrategy: strategy,
        TableConvertor: strategy,
    }
    options := &generic.StoreOptions{RESTOptions: optsGetter, AttrFunc: GetAttrs}
    if err := store.CompleteWithOptions(options); err != nil {
        return nil, err
    }
    return store, nil
}
```
pkg/registry/hello.zeng.dev/foo/strategy.go 实现了 Create/Update/Delete 策略，但它们基本都是空函数，主要就写了个 TableConvertor...。部分策略由 nested runtime.ObjectType 和 names.NameGenerator 实现。

```go
type fooStrategy struct {
    runtime.ObjectTyper
    names.NameGenerator
}

func (fooStrategy) NamespaceScoped() bool {
    return true
}

func (fooStrategy) ConvertToTable(ctx context.Context, object runtime.Object, tableOptions runtime.Object) (
    *metav1.Table, error) {/*...*/}
```

由于 [k8s.io/apiserver pkg/registry/generic/registry.Store] 提供了 etcd 存储实现，因此项目需要做的就是在框架内涂鸦——提供策略。官方库 [kubernertes/pkg/registry](https://github.com/kubernetes/kubernetes/tree/master/pkg/registry) 也采用了这种方式。

## 主要组件梳理

回顾两次 commits，可以发现 [k8s.io/apiserver] 架构相对简单

<img src="/img/2023/k8s-apiserver-install-apis.png" width="700px"/>

每个 APIGroupInfo 中包含了
- 存储接口实现集 map[string/\*(version\*)/][string/\*(kind_plural\*)/]rest.Storage (rest.Storage 仅是支持注册 GroupVersion 级 API，类似 /apis/hello.zeng.dev/v1，所以实际实现一般为 rest.StandardStorage，这样就可以支持资源 kind 的 CRUD，类似 /apis/hello.zeng.dev/v1/foos)
- 包含资源 group kinds 的编解码、默认值、转化等信息的 runtime.Scheme
- Codecs
  - 支持将 URL Query Params 转化 metav1.CreateOptions，metav1.GetOptions，metav1.UpdateOptions 等的 metav1.ParameterCodec 
  - 负责 runtime.Scheme 中 Group Kinds 序列化和反序列化的 CodecFactory

APIGroupInfo install 到 [GenericAPIServer] 后，就转化为 
- Discovery API handlers（ supports `/apis/{group}` `/apis/{group}/{version}`
- Object/Resource API Handlers (supports CRUD `/apis/{group}/{version}/**/{kind_plural}`) 

[GenericAPIServer] 集成了通用的 HTTP REST Handlers 模块 [k8s.io/apiserver pkg/endpoints]。而 [interface rest.StandardStorage] 为 [k8s.io/apiserver pkg/endpoints] handlers 提供存储策略。

<img src="/img/2023/k8s-registry-store.png" width="700px"/>

实现方可以从 0 到 1 实现 [interface rest.StandardStorage]，类似这里的 mem.go fooApi。
[k8s.io/apiserver pkg/registry/generic/registry.Store] 实现了 [interface rest.StandardStorage]，
使用方只需要提供简单 CRUD、校验等策略即可集成到存储层，比如这里的 fooStratedy。

registry.Store 并不直接与 etcd 交互，而是持有了抽象接口 [sotrage.Interface]。storage 下一级 package etcd3 提供了 etcd3 实现，cacher 提供了缓存层。
[sotrage.Interface] 和 [interface rest.StandardStorage] 等抽象解耦了业务层和存储层，使得项目可以采纳非 etcd 存储，比如

- [Kubernetes Metrics Server](https://github.com/kubernetes-sigs/metrics-server) 使用了内存实现
- [acorn-io/mink](https://github.com/acorn-io/mink) 则提供了 SQLite、MySQL、PostgreSQL 等的实现

## Supports hello.zeng.dev/v2
为支持 hello.zeng.dev/v2，新 apiserver commits 如下
- [apiserver-by-lib: add hello.zeng.dev/v2 internal] 定义了 API 类型到内部类型的默认值设定、类型转换、统一注册等
- [apiserver-by-lib: gen hello.zeng.dev/v2 internal codes] 生成了 default, conversion, deepcopy 函数
- [apiserver-by-lib: supports CRUD hello.zeng.dev/v2 foos] 升级 v1 增删改查逻辑为 v2，且同时支持

[k8s.io/apiserver] 使用多版本 API 时 (这里是 [x-kubernetes/api])，需要转化为统一的内部类型

    ~/x-kubernetes/api-aggregation-lib# tree pkg/api/
    pkg/api/
    └── hello.zeng.dev
        ├── doc.go
        ├── install
        │   └── install.go
        ├── register.go
        ├── types.go
        ├── v1
        │   ├── conversion.go
        │   ├── defaults.go
        │   ├── doc.go
        │   └── register.go
        └── v2
            ├── defaults.go
            ├── doc.go
            └──  register.go

```go

```

## //todo 一个 Object 在 apiserver 中的声明流程 

## 总结
使用库代码，或引用、或简单配置，即解决了 [实现一个极简 K8s apiserver] 中遗留的问题
- [x] authentication 和 authorization，不区分请求来源，接收任意客户端请求，且没有权限控制，任意用户都拥有增删改查权限
- [x] watch，比如 `GET /apis/hello.zeng.dev/v1/watch/foos`，或者 `GET /apis/hello.zeng.dev/v1/foos?watch=true`
- [x] list 分页
- [x] 数据持久

且带来了附加好处
- ✅ 多版本 API 支持

[runtime.Scheme]: https://github.com/kubernetes/apimachinery/blob/6b1428efc73348cc1c33935f3a39ab0f2f01d23d/pkg/runtime/scheme.go#L46
[极简 K8s apiserver types]: https://github.com/phosae/x-kubernetes/blob/c59960982df64efee4b166e040d8031203173963/apiserver-from-scratch/main.go#L278-L300
[x-kubernetes/api]: https://github.com/phosae/x-kubernetes/tree/master/api

[Kubernetes-style API types]: https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md
[k8s.io/apiserver]: https://github.com/kubernetes/apiserver
[GenericAPIServer]: https://github.com/kubernetes/apiserver/blob/ed61fb1c78ab5dcf99235126eee4969c3ab5ca84/pkg/server/genericapiserver.go#L105
[k8s.io/apiserver pkg/registry/generic/registry.Store]: https://github.com/kubernetes/apiserver/blob/44fa6d28d5b3c41637871486ba3ffaf3a2407632/pkg/registry/generic/registry/store.go#L97
[k8s.io/apiserver pkg/endpoints]: https://github.com/kubernetes/apiserver/tree/master/pkg/endpoints
[interface rest.StandardStorage]: https://github.com/kubernetes/apiserver/blob/0d8046157b1b4d137b6d9f84d9f9edb332c72890/pkg/registry/rest/rest.go#L290-L305
[sotrage.Interface]: https://github.com/kubernetes/apiserver/blob/0d8046157b1b4d137b6d9f84d9f9edb332c72890/pkg/storage/interfaces.go#L159-L239

<!-- apiserver using library PRs -->
[build apiserver ontop library]: https://github.com/phosae/x-kubernetes/commit/4c0df0e726cb041451b09d1fb1be7a88c3c09169
[apiserver by lib: add etcd store]: https://github.com/phosae/x-kubernetes/commit/ea08ef93c375163aeb19c556ccfdd61ac8dca7eb
[apiserver-by-lib: add hello.zeng.dev/v2 internal]: https://github.com/phosae/x-kubernetes/commit/7f30c3df7fe46ca87597e7f0c4d71edb464c4532
[apiserver-by-lib: gen hello.zeng.dev/v2 internal codes]: https://github.com/phosae/x-kubernetes/commit/e9ab0750243bb7132074bc1e4afc14a8e9988c78
[apiserver-by-lib: gen hello.zeng.dev/v2 internal codes]: https://github.com/phosae/x-kubernetes/commit/e9ab0750243bb7132074bc1e4afc14a8e9988c78
[apiserver-by-lib: supports CRUD hello.zeng.dev/v2 foos]: https://github.com/phosae/x-kubernetes/commit/b95522b123c95013cce4b4763a350adf0b40258e