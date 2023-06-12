---
title: "使用 library 实现 K8s apiserver"
date: 2023-06-07T16:11:19+08:00
lastmod: 2023-06-11T16:11:19+08:00
draft: true
keywords: ["kubernetes", "rest", "go", "http", "openapi"]
description: ""
tags: ["kubernetes", "rest", "go", "http", "openapi"]
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

[实现一个极简 K8s apiserver] 展示了 apiserver 的极简实现方式。本文将使用 K8s apiserver 库实现 apiserver。

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

## apiserver supports hello.zeng.dev/v1 

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

[k8s.io/apiserver] 中枢纽就是 [GenericAPIServer](https://github.com/kubernetes/apiserver/blob/ed61fb1c78ab5dcf99235126eee4969c3ab5ca84/pkg/server/genericapiserver.go#LL105C6-L105C22)。
所有组件都会体现在这个结构体中。

_ 最核心的文件就 2 个 apiserver/apiserver.go 和 registry/foo.go，前者


[apiserver by lib: add etcd store] 做了更新，支持 etcd 存储


## apiserver supports hello.zeng.dev/v2
为支持 hello.zeng.dev/v2，新 apiserver 主要 commits 也是 2 个
- [apiserver-by-lib: add hello.zeng.dev/v2 internal] 定义了 API 类型到内部类型的默认值设定、类型转换、统一注册等
- [apiserver-by-lib: supports CRUD hello.zeng.dev/v2 foos] 升级 v1 增删改查逻辑为 v2，且同时支持


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

<!-- apiserver using library PRs -->
[build apiserver ontop library]: https://github.com/phosae/x-kubernetes/commit/4c0df0e726cb041451b09d1fb1be7a88c3c09169
[apiserver by lib: add etcd store]: https://github.com/phosae/x-kubernetes/commit/ea08ef93c375163aeb19c556ccfdd61ac8dca7eb
[apiserver-by-lib: add hello.zeng.dev/v2 internal]: https://github.com/phosae/x-kubernetes/commit/7f30c3df7fe46ca87597e7f0c4d71edb464c4532
[apiserver-by-lib: gen hello.zeng.dev/v2 internal codes]: https://github.com/phosae/x-kubernetes/commit/e9ab0750243bb7132074bc1e4afc14a8e9988c78
[apiserver-by-lib: supports CRUD hello.zeng.dev/v2 foos]: https://github.com/phosae/x-kubernetes/commit/b95522b123c95013cce4b4763a350adf0b40258e