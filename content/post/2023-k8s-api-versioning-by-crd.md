---
title: "CRD API 多版本"
date: 2023-06-19T23:19:19+08:00
lastmod: 2023-06-19T23:19:19+08:00
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
---


<!-- 系列链接 -->
[CustomResourceDefinitions (CRD) 原理]: ../2023-k8s-api-by-crd
[CRD API 多版本]: ../2023-k8s-api-versioning-by-crd
[实现一个极简 apiserver]: ../2023-k8s-apiserver-from-scratch
[搞懂 apiserver aggregation]: ../2023-k8s-apiserver-aggregation-internals
[最不厌其烦的 K8s 代码生成教程]: ../2023-k8s-api-codegen
[使用 library 实现 K8s apiserver]: ../2023-k8s-apiserver-using-library
[慎重选用 Runtime 类框架开发 K8s apiserver]: ../2023-k8s-apiserver-avoid-using-runtime

本文为 **K8s API 和控制器** 系列文章之一
- [CustomResourceDefinitions (CRD) 原理]
- [CRD API 多版本] (本文)
- [实现一个极简 apiserver]
- [搞懂 apiserver aggregation]
- [最不厌其烦的 K8s 代码生成教程]
- [使用 library 实现 K8s apiserver]
- [慎重选用 Runtime 类框架开发 K8s apiserver]

[CustomResourceDefinitions (CRD) 原理] 以 `hello.zeng.dev/v1 Foo` 为例，剖析了 K8s CRD 原理。

[使用 library 实现 K8s apiserver] 则讲到了 apiserver 中的多版本 API 转换
<img src="/img/2023/k8s-api-multiversion-conv.png" width="700px">

与 apiserver 类似，基于 CRD 也可以支持 API 多版本。那么

[Kubernetes Documentation: Versions in CustomResourceDefinitions]: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning