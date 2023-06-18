---
title: "使用 library 实现 K8s apiserver"
date: 2023-06-07T16:11:19+08:00
lastmod: 2023-06-16T09:11:19+08:00
draft: false
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

看文章的同时，你可以

1. 拉取项目 [x-kubernetes] 设置测试环境（并顺手 star ⭐🤩🌈

        git clone https://github.com/phosae/x-kubernetes.git
        cd x-kubernetes
        make localenv

<img src="/img/2023/x-k8s-setup-localenv-1.27.1.gif" width="700px"/>

2. 一键部署本项目

        cd api-aggregation-lib
        make deploy

## 🔮 API 定义和代码生成

[实现一个极简 K8s apiserver] 展示了 apiserver 的极简实现方式。但它还欠缺一些 apiserver 功能，比如 watch 和数据持久。
而 library [k8s.io/apiserver] 补全了所有欠缺，包括配置即用的鉴权/授权、etcd 集成等。

本文将使用 libary [k8s.io/apiserver] 实现 apiserver 全部功能。

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

## 👋 The hello.zeng.dev/v1's CRUD Implementation

支持 hello.zeng.dev/v1 的新 apiserver 主要看 2 个 commits 即可，[commit: build apiserver ontop library] 和 [commit: add etcd store]。

[commit: build apiserver ontop library] 提供了 [实现一个极简 K8s apiserver] 的 [k8s.io/apiserver] 库实现版，数据存储在内存。
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

[commit: add etcd store] 支持了 etcd 存储

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

## ✍️ 主要组件梳理

回顾两次 commits，可以发现 [k8s.io/apiserver] 架构相对简单

<img src="/img/2023/k8s-apiserver-install-apis.png" width="700px"/>

每个 APIGroupInfo 中包含了
- 存储接口实现集 map[string/\*(version\*)/][string/\*(kind_plural\*)/]rest.Storage (rest.Storage 仅是支持注册 GroupVersion 级 API，类似 /apis/hello.zeng.dev/v1，所以实际实现一般为 rest.StandardStorage，这样就可以支持资源 kind 的 CRUD，类似 /apis/hello.zeng.dev/v1/foos)
- 包含资源 group kinds 的编解码、默认值、转化等信息的 [runtime.Scheme]
- Codecs
  - 支持将 URL Query Params 转化 metav1.CreateOptions，metav1.GetOptions，metav1.UpdateOptions 等的 metav1.ParameterCodec 
  - 负责 API structs（注册在 runtime.Scheme 中）序列化和反序列化的 [struct runtime/serializer.CodecFactory]

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

## 🔄 Supports multiversion GroupKind
为支持 hello.zeng.dev/v2，新 apiserver commits 如下
- [commit: add hello.zeng.dev/v2 internal] 定义了 API 类型到内部类型的默认值设定、类型转换、统一注册等
- [commit: gen hello.zeng.dev/v2 internal codes] 生成了 default, conversion, deepcopy 函数
- [commit: supports CRUD hello.zeng.dev/v2 foos] 升级 v1 增删改查逻辑为 v2，且同时支持

[k8s.io/apiserver] 使用多版本 API 时 (这里是 [x-kubernetes/api])，涉及一系列类型转换

1. 任意类型不论对外有多少个版本，其内存版本唯一。
   该内存版本一般称之为 Memory/Internal/Hub Version（以下称之为内存版本或者内部版本）
2. `func (s *Scheme) SetVersionPriority(versions ...schema.GroupVersion) error` --> 在多个版本之间，需要显式设置 preferredVersion。
  `kubectl {action} {kind}` 默认取 preferredVersion，写入存储的一般也是 preferredVersion。
  `GET /apis/{group}` 可以获取该 group 的 preferredVersion 信息
3. 由外而内经过计算写入存储，会经历这个转换 RequestVersion kind ➡️ MemoryVersion kind ➡️ StorageVersion kind
4. 从存储经过计算返回客户端，则经历这个转换 StorageVersion kind ➡️ MemoryVersion kind ➡️ RequestVersion kind
5. 普通版本🔄内存版本：核心在于版本之间的两两转换。
   因此需要向 [runtime.Scheme] 注册转换函数 `func (s *Scheme) AddConversionFunc(from, to interface{}, fn conversion.ConversionFunc) error`

<img src="/img/2023/k8s-api-multiversion-conv.png" width="700px"/>

[k8s.io/apiserver] 版本转换实现是 [struct runtime/serializer.CodecFactory]，实现了 [interface runtime.NegotiatedSerializer]（面向 HTTP 层）和 [interface runtime.StorageSerializer]（面向存储层）。核心使用方式
1. `func SupportedMediaTypes() []SerializerInfo` 返回最底层的 encode/decode 实现 (struct 🔄 binary)，使用方根据 mediaType 选择最佳 encoder/decoder
2. `func EncoderForVersion(serializer Encoder, gv GroupVersioner) Encoder` 和 `DecoderToVersion(serializer Decoder, gv GroupVersioner) Decoder` 接收 encoder/decoder 和 GroupVersioner，返回出支持将 struct encode/decode 到某个特定版本的包装实现（正是这个包装实现提供了 encode/decode 增强，支持版本转换、设置默认值等）

类似 [Kubernetes]，
对外 API 库 (k8s.io/api) 仅包含外部 API 定义，仅提供了注册、protobuf 定义和 deepcopy，
内部库（pkg/api 和 pkg/apis）则提供了类型默认值设置、类型字段校验、内外类型转换这些贴近业务的函数。

```bash
k8s.io/kubernetes $ tree vendor/k8s.io/api/storage

vendor/k8s.io/api/storage
├── OWNERS
├── v1
│   ├── doc.go
│   ├── generated.pb.go
│   ├── generated.proto
│   ├── register.go
│   ├── types.go
│   └── zz_generated.deepcopy.go
├── v1alpha1
│   ├── doc.go
│   ├── generated.pb.go
│   ├── generated.proto
│   ├── register.go
│   ├── types.go
│   ├── zz_generated.deepcopy.go
└── v1beta1
    ├── ...
    ├── ...

k8s.io/kubernetes $ tree pkg/apis/storage

pkg/apis/storage
├── install
│   └── install.go
├── v1
│   ├── defaults.go
│   ├── doc.go
│   ├── register.go
│   ├── zz_generated.conversion.go
│   └── zz_generated.defaults.go
├── v1alpha1
│   ├── doc.go
│   ├── register.go
│   ├── zz_generated.conversion.go
│   └── zz_generated.defaults.go
├── v1beta1
│   ├── ...
│   ├── ...
├── doc.go
├── register.go
├── types.go
└── zz_generated.deepcopy.go
```

回过头看 [commit: add hello.zeng.dev/v2 internal] 也采用了类似结构
- pkg/api/{group}/types.go 存放 internal version
- pkg/api/{group}/{version}/ 有外部 version 默认值函数 defaults.go，有 conversion.go 协助版本转换 external 🔄 internal，有 register.go 简单引用并包装 [x-kubernetes/api] 注册
- pkg/install/install.go 注册所有版本到 [runtime.Scheme]

⚠️⚠️⚠️ 实现上，在 {group}/types.go 文件中定义 internal struct 非必要。比如可以挑选最新的 API struct，同时将它注册为 external version 和 internal version，只要定义好版本之间的转换即可。

      ~/x-kubernetes/api-aggregation-lib# tree pkg/api/
      pkg/api/
      └── hello.zeng.dev
          ├── install
          │   └── install.go
          ├── v1
          │   ├── conversion.go
          │   ├── defaults.go
          │   ├── doc.go
          │   └── register.go
          ├── v2
          │   ├── defaults.go
          │   ├── doc.go
          │   └── register.go
          ├── doc.go
          ├── register.go
          └── types.go

大部分 default funcs, conversion funcs 全部由自动生成。执行 [./hack/update-codegen-docker.sh] 之后，由各目录 doc.go 生成声明产生这些生成文件 [commit: gen hello.zeng.dev/v2 internal codes] 

      pkg/api/
      └── hello.zeng.dev
          ├── v1
          │   └── zz_generated.conversion.go
          ├── v2
          │   ├── zz_generated.conversion.go
          │   └── zz_generated.defaults.go
          └── zz_generated.deepcopy.go

引入 API、定义好内部类型、默认值设置函数、转换函数，准备好它们的注册函数之后，实际的业务逻辑改动非常小 [commit: supports CRUD hello.zeng.dev/v2 foos]: 71 additions and 52 deletions (而 [commit: add hello.zeng.dev/v2 internal]: 261 additions and 4 deletions)。改动仅是保证 pkg/api 们都注册到 [runtime.Scheme]，全部引用外部类型改为只引用内部类型，在 APIGroupInfo 中设置好多版本而已。这说明 [k8s.io/apiserver] 包办了大部分事情。



## ⚙️ 按配置引入组件

[搞懂 K8s apiserver aggregation] 提到了官方 kube-apiserver 处理请求的一般流程

request ➡️ filterchain ➡️ kube-aggregator ➡️ apiservers

而使用 [k8s.io/apiserver] library，custom apiserver 也会按照配置加载  [通用 filters/middlewares](https://github.com/kubernetes/kubernetes/blob/039ae1edf5a71f48ced7c0258e13d769109933a0/staging/src/k8s.io/apiserver/pkg/server/config.go#L890-L960)。

[commit: add authn/authz] 通过少量代码即开启了 authn/authz。默认情况下，对应 middleware 会加载 InCluster kubeconfig
- 提供 authn：对于任何资源请求 `/apis/{group}/{version}/**`，校验 HTTPS 证书和 Headers，如果鉴别请求来自 kube-apiserver，authn 通过。否则发起 tokenreviews，委托 kube-apiserver 认证用户信息
- 提供 authz：对于任何资源请求 `/apis/{group}/{version}/**`，发起 subjectaccessreviews, 委托 kube-apiserver 给用户授权

具体原理和细节可以进一步查阅 [搞懂 K8s apiserver aggregation]。

[commit: add etcd store] 也是类似，引入 etcd 配置项，Complete 完善 etcd 配置之后，registry 层通过 GenericConfig.RESTOptionsGetter 即可集成 etcd 存储。

```go
func (o *Options) Flags() (fs cliflag.NamedFlagSets) {
    ......
    msfs.BoolVar(&o.EnableEtcdStorage, "enable-etcd-storage", false, "If true, store objects in etcd")
    o.Etcd.AddFlags(fs.FlagSet("Etcd"))
    return fs
}
---
func (o Options) ServerConfig() (*myapiserver.Config, error) {
    ......
    if o.EnableEtcdStorage {
        if err := o.Etcd.Complete(apiservercfg.Config.StorageObjectCountTracker, apiservercfg.Config.DrainedNotify(), apiservercfg.Config.AddPostStartHook); err != nil {
            return nil, err
        }
        if o.Etcd.ApplyWithStorageFactoryTo(serverstorage.NewDefaultStorageFactory(
            o.Etcd.StorageConfig,
            o.Etcd.DefaultStorageMediaType,
            myapiserver.Codecs,
            serverstorage.NewDefaultResourceEncodingConfig(myapiserver.Scheme),
            apiservercfg.MergedResourceConfig,
            nil), &apiservercfg.Config); err != nil {
            return nil, err
        }
        klog.Infof("etcd cfg: %v", o.Etcd)
        o.Etcd.StorageConfig.Paging = utilfeature.DefaultFeatureGate.Enabled(features.APIListChunking)
    }
    ......
}
---
func (c completedConfig) New() (*HelloApiServer, error) {
    ......
    if c.ExtraConfig.EnableEtcdStorage {
        etcdstorage, err := fooregistry.NewREST(Scheme, c.GenericConfig.RESTOptionsGetter)
        if err != nil {
            return nil, err
        }
        apiGroupInfo.VersionedResourcesStorageMap["v1"]["foos"] = etcdstorage
    }
    ......
}
```

## 🎮 Play

**Watch**

<img src="/img/2023/apiserver-lib-play-watch.gif" width="700px"/>

**分页**

```bash
# paging
kubectl get --raw '/apis/hello.zeng.dev/v2/foos?limit=1' \
| jq -r '.apiVersion,.kind,("item: " + .items[].metadata.namespace + "/" + .items[].metadata.name),("continue: "+ .metadata.continue)'

hello.zeng.dev/v2
FooList
item: default/myfoo
continue: eyJ2IjoibWV0YS5rOHMuaW8vdjEiLCJydiI6MTQ2LCJzdGFydCI6ImRlZmF1bHQvbXlmb29cdTAwMDAifQ

kubectl get --raw '/apis/hello.zeng.dev/v2/foos?limit=1&continue=eyJ2IjoibWV0YS5rOHMuaW8vdjEiLCJydiI6MTQ2LCJzdGFydCI6ImRlZmF1bHQvbXlmb29cdTAwMDAifQ' \
| jq -r '.apiVersion,.kind,("item: " + .items[].metadata.namespace + "/" + .items[].metadata.name),("continue: "+ .metadata.continue)'

hello.zeng.dev/v2
FooList
item: default/test
continue: eyJ2IjoibWV0YS5rOHMuaW8vdjEiLCJydiI6MTQ2LCJzdGFydCI6ImRlZmF1bHQvdGVzdFx1MDAwMCJ9

kubectl get --raw '/apis/hello.zeng.dev/v2/foos?limit=1&continue=eyJ2IjoibWV0YS5rOHMuaW8vdjEiLCJydiI6MTQ2LCJzdGFydCI6ImRlZmF1bHQvdGVzdFx1MDAwMCJ9' \
| jq '.apiVersion,.kind,("item: " + .items[].metadata.namespace + "/" + .items[].metadata.name),("continue: "+ .metadata.continue)'

hello.zeng.dev/v2
FooList
item: kube-public/myfoo
continue:
```

**custom apiserver authn/authz 集成 kube-apiserver RBAC**

创建 default/readuser，通过 kube-apiserver RBAC 授予官方资源读取权限

```bash
kubectl create -f << EOF -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: readuser
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: readuser::view
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - kind: ServiceAccount
    name: readuser
    namespace: default
EOF
```

利用 [x-kubernetes/gen-sa-kubeconfig.sh] 生成 readuser kubeconfig

```bash
root@dev:~/x-kubernetes# ./hack/gen-sa-kubeconfig.sh default readuser
Cluster "kind-kind" set.
User "default-readuser" set.
Context "default" modified.
Switched to context "default".

root@dev:~/x-kubernetes# ls default-readuser.kubeconfig 
default-readuser.kubeconfig
```

测试 custom apiserver authn/authz，因为 readuser 只能访问官方资源，所以访问 foos 会遭拒

```
# forward local 6443 to cluster custom apiserver service 443
kubectl -n hello port-forward svc/apiserver 6443:443
---

KUBECONFIG=default-readuser.kubeconfig k -s https://localhost:6443 --insecure-skip-tls-verify get fo
Error from server (Forbidden): foos.hello.zeng.dev is forbidden: 
User "system:serviceaccount:default:readuser" 
cannot list resource "foos" in API group "hello.zeng.dev" in the namespace "default"
```

通过 kube-apiserver RBAC 授予 readuser hello.zeng.dev group 读取权限

```bash
cat << EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hello-view
rules:
- apiGroups:
  - hello.zeng.dev
  resources:
  - '*'
  verbs:
  - get
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: readuser::hello-view
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: hello-view
subjects:
  - kind: ServiceAccount
    name: readuser
    namespace: default
EOF
```
再测试时 readuser 已经获得了读取权限
```
# forward local 6443 to cluster custom apiserver service 443
kubectl -n hello port-forward svc/apiserver 6443:443
---

KUBECONFIG=default-readuser.kubeconfig k -s https://localhost:6443 --insecure-skip-tls-verify get fo
NAME    STATUS   AGE
myfoo            13h
test             12h
```

## 🔢 总结
[k8s.io/apiserver] 主要 package 如下

```bash
$ tree k8s.io/apiserver/pkg -L 1
k8s.io/apiserver/pkg
├── admission           # admission 库，支持 Resource validation, mutation, conversion 等
├── apis                # library 内部 API，主要是配置定义
├── audit               # 审计 HTTP middleware
├── authentication      # authn HTTP middleware
├── authorization       # authz HTTP middleware
├── cel                 # Google Common Expression Language support，支持将处理逻辑内嵌到 Object field 中
├── endpoints           # HTTP 通用实现: filters, REST handlers 等
├── features            # APIServer 功能开关
├── quota               # resource quota 库
├── registry            # 通用 storage 层，支持注册各种类型如 Pod Foo 的 CRUD 实现和策略
├── server              # 聚合其他所有层，the plumbing to create kubernetes-like API server comman
├── storage             # 存储层抽象
├── ...      
```

使用库代码，或引用、或简单配置，即解决了 [实现一个极简 K8s apiserver] 中遗留问题
- ✅ authentication 和 authorization，不区分请求来源，接收任意客户端请求，且没有权限控制，任意用户都拥有增删改查权限
- ✅ watch，比如 `GET /apis/hello.zeng.dev/v1/watch/foos`，或者 `GET /apis/hello.zeng.dev/v1/foos?watch=true`
- ✅ list 分页
- ✅ 数据持久

且带来了附加好处
- 🍺🍖 官方 apiserver 同款类库，方便借鉴/集成社区成果
- 🍺🍖 多版本 API 支持
- 🍺🍖 依赖接口而非实现，等等

[k8s.io/apiserver] 是一个接近框架的类库，这意味着使用上有一定学习成本。
比如需要理解各模块配置项的集成、补全和校验，需要理解资源类型的内部版本和外部版本转换，需要学习代码生成。

高级类库是把双刃剑。引入抽象一方面实现了依赖解耦，另一方面增加了复杂性。
观察本文贴出的 commits 可以发现，custom apiserver 中很多代码只是在加载和适配类库。
随着项目扩大和定制化增加到一定程度，类库相关代码比例才会逐渐减少，起到纯辅助的作用。

总之，[k8s.io/apiserver] 许多功能均可通过配置插拔，灵活度较高。抽象也相对简单，枢纽是 [GenericAPIServer]，类型序列化/反序列化和转换在 [runtime.Scheme]，存储是 [interface rest.StandardStorage]（通用实现是 [k8s.io/apiserver pkg/registry/generic/registry.Store]），HTTP 层是 [k8s.io/apiserver pkg/endpoints]。

[Kubernetes]: https://github.com/kubernetes/kubernetes
[runtime.Scheme]: https://github.com/kubernetes/apimachinery/blob/6b1428efc73348cc1c33935f3a39ab0f2f01d23d/pkg/runtime/scheme.go#L46
[interface runtime.NegotiatedSerializer]: https://github.com/kubernetes/apimachinery/blob/6b1428efc73348cc1c33935f3a39ab0f2f01d23d/pkg/runtime/interfaces.go#L167-L177
[interface runtime.StorageSerializer]: https://github.com/kubernetes/apimachinery/blob/6b1428efc73348cc1c33935f3a39ab0f2f01d23d/pkg/runtime/interfaces.go#L204-L218
[struct runtime/serializer.CodecFactory]: https://github.com/kubernetes/apimachinery/blob/6b1428efc73348cc1c33935f3a39ab0f2f01d23d/pkg/runtime/serializer/codec_factory.go#L125
[极简 K8s apiserver types]: https://github.com/phosae/x-kubernetes/blob/c59960982df64efee4b166e040d8031203173963/apiserver-from-scratch/main.go#L278-L300
[x-kubernetes/api]: https://github.com/phosae/x-kubernetes/tree/master/api

[Kubernetes-style API types]: https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md
[k8s.io/apiserver]: https://github.com/kubernetes/apiserver
[GenericAPIServer]: https://github.com/kubernetes/apiserver/blob/ed61fb1c78ab5dcf99235126eee4969c3ab5ca84/pkg/server/genericapiserver.go#L105
[k8s.io/apiserver pkg/registry/generic/registry.Store]: https://github.com/kubernetes/apiserver/blob/44fa6d28d5b3c41637871486ba3ffaf3a2407632/pkg/registry/generic/registry/store.go#L97
[k8s.io/apiserver pkg/endpoints]: https://github.com/kubernetes/apiserver/tree/master/pkg/endpoints
[interface rest.StandardStorage]: https://github.com/kubernetes/apiserver/blob/0d8046157b1b4d137b6d9f84d9f9edb332c72890/pkg/registry/rest/rest.go#L290-L305
[sotrage.Interface]: https://github.com/kubernetes/apiserver/blob/0d8046157b1b4d137b6d9f84d9f9edb332c72890/pkg/storage/interfaces.go#L159-L239

[x-kubernetes]: https://github.com/phosae/x-kubernetes
[x-kubernetes/gen-sa-kubeconfig.sh]: https://github.com/phosae/x-kubernetes/blob/229ba83958f5e85b0c46d542b72c2775643e6371/hack/gen-sa-kubeconfig.sh

<!-- apiserver using library commits -->
[commit: build apiserver ontop library]: https://github.com/phosae/x-kubernetes/commit/4c0df0e726cb041451b09d1fb1be7a88c3c09169
[commit: add etcd store]: https://github.com/phosae/x-kubernetes/commit/ea08ef93c375163aeb19c556ccfdd61ac8dca7eb
[commit: add hello.zeng.dev/v2 internal]: https://github.com/phosae/x-kubernetes/commit/7f30c3df7fe46ca87597e7f0c4d71edb464c4532
[commit: gen hello.zeng.dev/v2 internal codes]: https://github.com/phosae/x-kubernetes/commit/e9ab0750243bb7132074bc1e4afc14a8e9988c78
[commit: supports CRUD hello.zeng.dev/v2 foos]: https://github.com/phosae/x-kubernetes/commit/b95522b123c95013cce4b4763a350adf0b40258e
[commit: add authn/authz]: https://github.com/phosae/x-kubernetes/commit/92db2b078c000af8d0e8929b874b7b5a75e1f1f9
[./hack/update-codegen-docker.sh]: https://github.com/phosae/x-kubernetes/blob/229ba83958f5e85b0c46d542b72c2775643e6371/api-aggregation-lib/hack/update-codegen-docker.sh