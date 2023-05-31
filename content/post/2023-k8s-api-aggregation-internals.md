---
title: "K8s API 和控制器: API 聚合原理剖析"
date: 2023-05-31T18:46:31+08:00
lastmod: 2023-05-31T18:46:31+08:00
draft: true
keywords: []
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
  enable: false
  options: ""
---

<!-- 系列链接 -->
[K8s API 和控制器: CustomResourceDefinitions (CRD)]: ../2023-k8s-api-by-crd
[K8s API 和控制器: 实现一个极简 apiserver]: ../2023-k8s-api-from-scratch
[K8s API 和控制器: API 聚合原理剖析]: ../2023-k8s-api-aggregation-internals

本文为 **K8s API 和控制器** 系列文章之一
- [K8s API 和控制器: CustomResourceDefinitions (CRD)]
- [K8s API 和控制器: 实现一个极简 apiserver]
- [K8s API 和控制器: API 聚合原理剖析]（本文）

## kube-apiserver API 请求流程？？

[拓展 K8s API: CustomResourceDefinitions (CRD)] 谈到了 kube-apiserver 引入 CustomResourceDefinitions 时的做法：采用委托模式组合核心 kube-apiserver 模块和 apiextensions-apiserver 模块，收到客户端服务请求时，先到核心模块寻找支持，再到拓展模块寻找支持，最后再返回 404。

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

查看同时期 (v1.7.0 前后) [proposal: Aggregated API Servers]，可以发现社区当时面临的问题
1. 自身业务有拆单体 kube-apiserver 为多个 aggregated servers 的需求 
2. 用户/三方机构有自己实现 custom apiserver 并暴露 custom API 的需求

社区提供的解决方案经历了许多个 PR 迭代。第一次提交发生在2016 年 5 月 [kubernetes PR20358]，增加了一个名为第独立进程 kube-discovery，功能非常原始，仅提供 API disovery 信息聚合。具体来说就是读取配置文件提供的 apiserver 列表，逐个访问，将 kube-apiserver 核心 API Group 信息聚合到 /api，将其他 API Groups（官方、三方）一起组合到 /apis。

2016 年 12 月 v1.6.0-alpha.1 版本 [kubernetes PR37561] 引入服务发现 GroupVersionKind `apiregistration.k8s.io/v1alpha1 apiservices`，[kubernetes PR38289] 提供了 proxy。


也谈到 apiextensions-apiserver 模块实现了 REST API Discovery Endpoints /apis/{group},/apis/{group}/{version}，kube-aggregator 模块的 /apis 则会聚合它们。

[deads2k PRs]: https://github.com/kubernetes/kubernetes/pulls?page=29&q=is%3Apr+is%3Aclosed+author%3Adeads2k

<!-- v1.7.0-alpha.1: kubernetes PR42911 combine kube-apiserver and kube-aggregator -->
[kubernetes PR42911]: https://github.com/kubernetes/kubernetes/pull/42911
<!-- add summarizing discovery controller and handlers -->
[kubernetes PR38319]: https://github.com/kubernetes/kubernetes/pull/38319
<!-- kubernetes-discovery proxy -->
[kubernetes PR38289]: https://github.com/kubernetes/kubernetes/pull/38624
<!-- v1.6.0-alpha.1: api federation types apiregistration.k8s.io/v1alpha1 apiservices -->
[kubernetes PR37561]: https://github.com/kubernetes/kubernetes/pull/37561
<!-- 1st federated api servers, named kube-discovery -->
[kubernetes PR20358]: https://github.com/kubernetes/kubernetes/pull/20358

[proposal: Aggregated API Servers]: https://github.com/kubernetes/design-proposals-archive/blob/acc25e14ca83dfda4f66d8cb1f1b491f26e78ffe/api-machinery/aggregated-api-servers.md
<!-- API Aggregation timeline -->
[issue 263]: https://github.com/kubernetes/enhancements/issues/263