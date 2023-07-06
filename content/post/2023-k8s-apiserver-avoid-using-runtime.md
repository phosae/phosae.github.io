---
title: "慎重选用 Runtime 类框架开发 K8s apiserver"
date: 2023-06-18T16:09:27+08:00
lastmod: 2023-06-18T18:42:27+08:00
draft: false
keywords: ["kubernetes"]
description: "Be cautious in choosing the Runtime type framework for developing K8s apiserver"
tags: ["kubernetes"]
author: "Zeng Xu"
summary: "apiserver-runtime 本身也是基于 k8s.io/apiserver 提供增强。当项目需要灵活定制策略时，就不可避免需要直接使用底层库。结果是，开发者除了要熟悉 k8s.io 库，还需要再学一套框架。那为什么不从一开始直接使用 k8s.io/apiserver？"

comment: true
toc: false
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
[K8s 多版本 API 转换最佳实践]: ../2023-k8s-api-multi-version-conversion-best-practice
[实现一个极简 K8s apiserver]: ../2023-k8s-apiserver-from-scratch
[搞懂 K8s apiserver aggregation]: ../2023-k8s-apiserver-aggregation-internals
[最不厌其烦的 K8s 代码生成教程]: ../2023-k8s-api-codegen
[使用 library 实现 K8s apiserver]: ../2023-k8s-apiserver-using-library
[慎重选用 Runtime 类框架开发 K8s apiserver]: ../2023-k8s-apiserver-avoid-using-runtime
[K8s API Admission Control and Policy]: ../2023-k8s-api-admission

本文为 **K8s API 和控制器** 系列文章之一
- [K8s CustomResourceDefinitions (CRD) 原理]
- [K8s 多版本 API 转换最佳实践]
- [实现一个极简 K8s apiserver]
- [搞懂 K8s apiserver aggregation]
- [最不厌其烦的 K8s 代码生成教程]
- [使用 library 实现 K8s apiserver]
- [慎重选用 Runtime 类框架开发 K8s apiserver]（本文）
- [K8s API Admission Control and Policy]

[sigs.k8s.io/apiserver-runtime] 试图用 [kubebuilder] 构建控制器的理念提供一套快速构建 apiserver 框架，它做了如下事情

引入了 [resource.Object interface] [resourcestrategy interfaces] 等各种接口集合
1. 尝试聚合存储层策略到 API 层：鼓励将 [k8s.io/apiserver] 各种 [REST storage interfaces] 直接放到 API structs 中实现
2. 抛弃 Kubernetes 官方项目中较为复杂的 conversion 和 default funcs 代码生成，提供新协议 Defaulter interface 和 Converter interface，以及它们之上的 [runtime.Scheme] 注册实现
3. 基于 [k8s.io/apiserver] [RESTOptionsGetter interface] 提供各种存储实现

有了以上三种抽象，[sigs.k8s.io/apiserver-runtime] 就支持一行代码创建 k8s apiserver

```go
package main

import (
	_ "k8s.io/client-go/plugin/pkg/client/auth" // register auth plugins
	"k8s.io/component-base/logs"
	"k8s.io/klog/v2"
	"sigs.k8s.io/apiserver-runtime/pkg/builder"
	"sigs.k8s.io/apiserver-runtime/sample/pkg/apis/sample/v1alpha1"
	"sigs.k8s.io/apiserver-runtime/sample/pkg/generated/openapi"
)

func main() {
	logs.InitLogs()
	defer logs.FlushLogs()

	err := builder.APIServer.
		WithOpenAPIDefinitions("sample", "v0.0.0", openapi.GetOpenAPIDefinitions).
		WithResource(&v1alpha1.Flunder{}). // namespaced resource
		WithResource(&v1alpha1.Fischer{}). // non-namespaced resource
		WithResource(&v1alpha1.Fortune{}). // resource with custom rest.Storage implementation
		WithLocalDebugExtension().
		Execute()
	if err != nil {
		klog.Fatal(err)
	}
}
```

框架内部会根据 API structs 所实现接口，自动完成 [runtime.Scheme] 注册，而且会照顾好 [k8s.io/apiserver] 各层
1. 生成 [APIGroupInfo struct]，完成 HTTP API 层 install
2. 完成 [pkg/registry/generic/registry.Store] 初始化，设置好存储层

一切看着很美好，但在使用时有各种各样的弊端。

首先是存储层策略到 API 层之后，有耦合过紧的问题
- API package/module 必须依赖 [sigs.k8s.io/apiserver-runtime] 接口（显式/隐式均可）。如果使用者打算对外公开 API，那么会造成语义不清晰
- 如果想在 apiserver 中引入其他项目的 Public API 呢？由于 Golang 只支持在 struct package 提供 interface 实现，而其他 API 不可能会实现框架接口。

[x-kubernetes apiserver-using-runtime] 只能通过 nested struct 方式，包装外部 API 实现 [sigs.k8s.io/apiserver-runtime] 接口们

    var _ resource.Object = &Foo{}
    var _ resource.MultiVersionObject = &Foo{}
    var _ resource.ObjectList = &FooList{}

    type Foo struct {
	    hellov1.Foo
    }

然后遇到了第二个问题，[sigs.k8s.io/apiserver-runtime] 社区不活跃，上次更新还是 2022 年底，只适配到 Kubernetes v1.26，且框架本身有一些 bug
- 没有支持 shortname
- 多版本 conversion, default 问题
- ...

所以变成需要这样就 bypass 框架

```go
func main() {
    defer logs.FlushLogs()

    logOpts := logs.NewOptions()

    err := builder.APIServer.
        WithAdditionalSchemeInstallers(func(s *runtime.Scheme) error {
            return hellov1.AddDefaultingFuncs(s)
        }).
        WithOpenAPIDefinitions("hello.zeng.dev-server", "v0.1.0", openapi.GetOpenAPIDefinitions).
        // customize backed storage (can be replace with any implemention instead of etcd
        // normally use WithResourceAndStorage is ok
        // we choose WithResourceAndHandler only because WithResourceAndStorage don't support shortNames
        WithResourceAndHandler(&resource.Foo{}, func(scheme *runtime.Scheme, optsGetter generic.RESTOptionsGetter) (rest.Storage, error) {
            obj := &resource.Foo{}
            gvr := obj.GetGroupVersionResource()
            s := &restbuilder.DefaultStrategy{
                Object:         obj,
                ObjectTyper:    scheme,
                TableConvertor: rest.NewDefaultTableConvertor(gvr.GroupResource()),
            }
            store := &genericregistry.Store{
                NewFunc:                   obj.New,
                NewListFunc:               obj.NewList,
                PredicateFunc:             s.Match,
                DefaultQualifiedResource:  gvr.GroupResource(),
                CreateStrategy:            s,
                UpdateStrategy:            s,
                DeleteStrategy:            s,
                StorageVersioner:          gvr.GroupVersion(),
                SingularQualifiedResource: (resource.Foo{}).GetSingularQualifiedResource(),
                TableConvertor:            (resource.Foo{}),
            }

            options := &generic.StoreOptions{RESTOptions: optsGetter, AttrFunc: func(obj runtime.Object) (labels.Set, fields.Set, error) {
                accessor, ok := obj.(metav1.ObjectMetaAccessor)
                if !ok {
                    return nil, nil, fmt.Errorf("given object of type %T does implements metav1.ObjectMetaAccessor", obj)
                }
                om := accessor.GetObjectMeta()
                return om.GetLabels(), fields.Set{
                    "metadata.name":      om.GetName(),
                    "metadata.namespace": om.GetNamespace(),
                }, nil
            }}

            if err := store.CompleteWithOptions(options); err != nil {
                return nil, err
            }
            return &fooStorage{store}, nil
        }).
        WithOptionsFns(func(so *builder.ServerOptions) *builder.ServerOptions {
            // do log opts trick
            logs.InitLogs()
            logsapi.ValidateAndApply(logOpts, utilfeature.DefaultFeatureGate)
            return so
        }).
        WithFlagFns(func(ss *pflag.FlagSet) *pflag.FlagSet {
            logsapi.AddFlags(logOpts, ss)
            return ss
        }).
        Execute()
        ...
}
```

所以显而易见的问题来了：[sigs.k8s.io/apiserver-runtime] 本身也是基于 [k8s.io/apiserver] 提供增强。当项目需要灵活定制策略时，就不可避免需要直接使用底层库。结果是，开发者除了要熟悉 [k8s.io/apiserver]，还需要再学一套框架。

那为什么不从一开始直接使用 [k8s.io/apiserver] 呢？

而且随着 [k8s.io/apiserver] 提供的功能越来越多，框架更新便必然滞后。这也会增加维护成本。

使用框架时需要格外警惕，除非你确定项目的生命周期不长，只打算做一锤子买卖。
欢迎 clone [x-kubernetes apiserver-using-runtime] 代码查看崩溃过程。

最后 [sigs.k8s.io/apiserver-runtime] 的一些设计思路，比如降低 default conversion 复杂度，比如简化策略配置，非常适合实现为辅助 library，而非框架。

[REST storage interfaces]: https://github.com/kubernetes/apiserver/blob/0d8046157b1b4d137b6d9f84d9f9edb332c72890/pkg/registry/rest/rest.go
[pkg/registry/generic/registry.Store]: https://github.com/kubernetes/apiserver/blob/44fa6d28d5b3c41637871486ba3ffaf3a2407632/pkg/registry/generic/registry/store.go#L97
[APIGroupInfo struct]: https://github.com/kubernetes/apiserver/blob/1bf7d4daedf7f3a9c31f4922a41a76d1dfa16436/pkg/server/genericapiserver.go#L67-L95
[resource.Object interface]: https://github.com/kubernetes-sigs/apiserver-runtime/blob/33c90185692756252ad3e36c5a940167d0de8f41/pkg/builder/resource/types.go#L30
[resourcestrategy interfaces]: https://github.com/kubernetes-sigs/apiserver-runtime/blob/main/pkg/builder/resource/resourcestrategy/interface.go
[RESTOptionsGetter interface]: https://github.com/kubernetes/apiserver/blob/1bf7d4daedf7f3a9c31f4922a41a76d1dfa16436/pkg/registry/generic/options.go#L46

[k8s.io/apiserver]: https://github.com/kubernetes/apiserver
[runtime.Scheme]: https://github.com/kubernetes/apimachinery/blob/6b1428efc73348cc1c33935f3a39ab0f2f01d23d/pkg/runtime/scheme.go#L46
[sigs.k8s.io/apiserver-runtime]: https://github.com/kubernetes-sigs/apiserver-runtime
[kubebuilder]: https://github.com/kubernetes-sigs/kubebuilder


[x-kubernetes]: https://github.com/phosae/x-kubernetes
[x-kubernetes apiserver-using-runtime]: https://github.com/phosae/x-kubernetes/tree/9ef420db82a406039aa944d2504a41e5525b1ec0/api-aggregation-runtime