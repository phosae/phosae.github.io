---
title: "最不厌其烦的 K8s 代码生成教程"
date: 2023-06-05T18:08:17+08:00
lastmod: 2023-06-11T15:36:17+08:00
draft: false
keywords: ["kubernetes", "code-generation"]
description: "An exquisitely thorough K8s code generation tutorial"
tags: ["kubernetes", "code-generation"]
author: "Zeng Xu"
summary: "彻底而全面的梳理，甚至提供了复制即用的脚本和镜像..."

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
- [最不厌其烦的 K8s 代码生成教程] (本文)
- [使用 library 实现 K8s apiserver]
- [慎重选用 Runtime 类框架开发 K8s apiserver]
- [K8s API Admission Control and Policy]

## ☸️ Kubernetes code-generator

K8s 中大量使用了代码生成，尤其是 API、控制器和客户端。Generators 统一放置在子项目 [kubernetes/code-generator]

```bash
~/go/src/k8s.io/kubernetes $ tree staging/src/k8s.io/code-generator/cmd -L 1
staging/src/k8s.io/code-generator/cmd
├── applyconfiguration-gen
├── client-gen
├── conversion-gen
├── deepcopy-gen
├── defaulter-gen
├── go-to-protobuf
├── informer-gen
├── lister-gen
├── openapi-gen
├── register-gen
```

K8s 之上的三方项目，也可以（且通常）会利用这些 generators，生成控制器相关代码和客户端代码。

如果项目基于 CustomResourceDefinitions (CRD) 做开发，经常用到的是 `deepcopy-gen` 和 `register-gen`。

如果要开发 custom apiserver，则还会经常用到 `defaulter-gen`  `conversion-gen` `openapi-gen` `go-to-protobuf`

无论通过 CRD 还是 custom apiserver，都可能要为 API 生成 Go 客户端，也就会用到 `applyconfiguration-gen` `client-gen` `lister-gen` `informer-gen`。

多语言客户端，可以利用 `openapi-gen` 生成 OpenAPI Specification JSON 文件，再利用 OpenAPI Specification 生成任意语言客户端代码。

## ✍️ Prepare API Structs
K8s 相关项目对外 API 都会包含 3 文件：`types.go` `doc.go` 和 `register.go`

```
api                           # external APIs     
└── hello.zeng.dev
    ├── v1
    │   ├── defaults.go       # 提供用户默认函数 func SetDefaults_TYPE
    │   ├── doc.go            # packge 级别生成声明
    │   ├── register.go       # 注册 API Structs, generated funcs 到 K8s Schema，提供通用的序列化/反序列化能力
    │   ├── types.go          # 提供 API Structs
    └── v2
        ├── doc.go
        ├── register.go
        └── types.go
```

`doc.go` 在代码生成中最为重要。它声明了按照 package 维度，为所有 structs 提供生成声明

```
// +k8s:openapi-gen=true ➡️ 生成 OpenAPI 相关
// +k8s:deepcopy-gen=package ➡️ 生成 deepcopy funcs
// +k8s:protobuf-gen=package ➡️ 生成 protobuf 定义和并从 protobuf 定义生成 protobuf funcs
// +k8s:defaulter-gen=TypeMeta ➡️ 生成 default funcs，如果 package 下存在 defaults.go 且存在函数签名 `func SetDefaults_TYPE(obj *TYPE)`
// +groupName=hello.zeng.dev // API Group，可供 register-gen 读取并使用

package v1
```

`types.go` 包含了 [kubernetes/code-generator] 注释 tag


```go
// +genclient ➡️ 生成客户端相关 client informer lister 以及 applyconfiguration
// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object ➡️ 声明生成 
//   func (in *Foo) DeepCopyObject() runtime.Object (实现 interface k8s.io/apimachinery/pkg/runtime.Object

type Foo struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty" protobuf:"bytes,1,opt,name=metadata"`

	Spec FooSpec `json:"spec" protobuf:"bytes,2,opt,name=spec"`
}
...

// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object ➡️ 声明生成 func (in *FooList) DeepCopyObject() runtime.Object

type FooList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty" protobuf:"bytes,1,opt,name=metadata"`

	Items []Foo `json:"items" protobuf:"bytes,2,rep,name=items"`
}
```

`register.go` 提供注册到 [runtime.Scheme] 的函数

```go
package v2

const GroupName = "hello.zeng.dev"

// SchemeGroupVersion is group version used to register these objects
var SchemeGroupVersion = schema.GroupVersion{Group: GroupName, Version: "v2"}

var (
	SchemeBuilder      = runtime.NewSchemeBuilder(addKnownTypes)
	// AddToScheme adds this group to a scheme.
	AddToScheme = localSchemeBuilder.AddToScheme
)

// Adds the list of known types to the given scheme.
func addKnownTypes(scheme *runtime.Scheme) error {
	scheme.AddKnownTypes(SchemeGroupVersion,
		&Foo{},
		&FooList{},
	)
	// add common meta types (i.e WatchEvent, ListOptions, ...) to the SchemeGroupVersion
	metav1.AddToGroupVersion(scheme, SchemeGroupVersion)
	return nil
}
```

观察一下官方项目，可以注意到大部分 register.go 都是重复，因此也可以自动生成。[kubernetes/code-generator] 提供的 register-gen 可以读取 `doc.go // +groupName` 并生成 register 文件。[rancher/wrangler controller-gen](https://github.com/rancher/wrangler/tree/master/pkg/controller-gen) 是这样干的。[kubernetes-sigs/kubebuilder] 会生成一份 groupversion_info.go。

## 💪 Helper Generators

### register-gen
```bash
# pwd 
# github.com/phosae/x-kubernetes/api
inputs=("--input-dirs" "github.com/phosae/x-kubernetes/api/hello.zeng.dev/v1")
inputs+=("--input-dirs" "github.com/phosae/x-kubernetes/api/hello.zeng.dev/v2")

register-gen \
    -O zz_generated.register \
    --go-header-file /tmp/fake-boilerplate.txt \
    --output-base /go/src \
    "${inputs[@]}"

# generated outputs:
# - github.com/phosae/x-kubernetes/api/hello.zeng.dev/v1/zz_generated.register.go
# - github.com/phosae/x-kubernetes/api/hello.zeng.dev/v2/zz_generated.register.go
```

### deepcopy-gen

```bash
# pwd 
# github.com/phosae/x-kubernetes/api
inputs=("--input-dirs" "github.com/phosae/x-kubernetes/api/hello.zeng.dev/v1")
inputs+=("--input-dirs" "github.com/phosae/x-kubernetes/api/hello.zeng.dev/v2")

deepcopy-gen \
    -O zz_generated.deepcopy \
    --go-header-file /tmp/fake-boilerplate.txt \
    --output-base /go/src \
    "${inputs[@]}"

# generated outputs:
# - github.com/phosae/x-kubernetes/api/hello.zeng.dev/v1/zz_generated.deepcopy.go
# - github.com/phosae/x-kubernetes/api/hello.zeng.dev/v2/zz_generated.deepcopy.go
```

常见的两种注释式声明
- package level: // +k8s:deepcopy-gen=package
- struct level:  // +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object

凡要集成 API 到 K8s 编解码库，对应的 Go struct 都需要实现 [apimachinery/interface runtime.Object]

```go
// Object interface must be supported by all API types registered with Scheme. Since objects in a scheme are
// expected to be serialized to the wire, the interface an Object must provide to the Scheme allows
// serializers to set the kind, version, and group the object is represented as. An Object may choose
// to return a no-op ObjectKindAccessor in cases where it is not expected to be serialized.
type Object interface {
	GetObjectKind() schema.ObjectKind
	DeepCopyObject() Object
}
```
API struct 一般会直接内嵌 TypeMeta（这样就继承了 `func GetObjectKind() schema.ObjectKind`），所以通常还缺少 `func DeepCopyObject() Object`。

注释 `// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object` 就是告诉 deepcopy-gen，这个 struct 需要实现 [apimachinery/interface runtime.Object]。

```go
import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object
type Foo struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec FooSpec `json:"spec"`
}
```

生成文件一般和 types.go 同级，名字默认是 `zz_generated.deepcopy.go`

同时，注意到 `doc.go` 中有 package 级别声明

```
// +k8s:deepcopy-gen=package
package v1
```

这个声明告诉 deepcopy-gen 生成基础的深度拷贝函数，生成时按照结构体字段递归为所有复合 struct 生成 DeepCopyInto 和 DeepCopy

前面的 `func DeepCopyObject() Object` 就会调用到 `func (in *Foo) DeepCopy() *Foo`

在 controller、apiserver 编写中，也会经常用到 deepcopy funcs

```go
func (in *Foo) DeepCopyInto(out *Foo) 

func (in *Foo) DeepCopy() *Foo

func (in *FooSpec) DeepCopyInto(out *FooSpec)

func (in *FooSpec) DeepCopy() *FooSpec 
```

### defaulter-gen

```bash
# pwd 
# github.com/phosae/x-kubernetes/api
inputs=("--input-dirs" "github.com/phosae/x-kubernetes/api/hello.zeng.dev/v1")
inputs+=("--input-dirs" "github.com/phosae/x-kubernetes/api/hello.zeng.dev/v2")

defaulter-gen \
    -v "${v}" \
    -O zz_generated.defaults \
    --go-header-file /tmp/fake-boilerplate.txt \
    --output-base /go/src\
    "${inputs[@]}"

# generated outputs:
# - github.com/phosae/x-kubernetes/api/hello.zeng.dev/v1/zz_generated.defaults.go
#
# v2 没有提供 defaults 实现，所以没有生成相应文件
```

defaulter-gen 较为有意思，只要在 package 下存在函数 `func SetDefaults_TYPE(obj *TYPE)`，且提供了 packge 级声明

    // +k8s:defaulter-gen=TypeMeta

注：`// +k8s:defaulter-gen=TypeMeta` 表示只要 API structs 存在 `TypeMeta` 字段（也可以是 ObjectMeta、ListMeta），就帮它们生成 Defaults 函数

举例说明，我在 [hello.zeng.dev/v1 defaults.go] 中提供了符合规范命名的实现

    func SetDefaults_Foo(obj *Foo) {/*... defaulting codes */}

会生成文件 [hello.zeng.dev/v1 zz_generated.defaults.go]，包含这些内容

```go
// 生成的注册函数
func RegisterDefaults(scheme *runtime.Scheme) error {
	scheme.AddTypeDefaultingFunc(&Foo{}, func(obj interface{}) { SetObjectDefaults_Foo(obj.(*Foo)) })
	scheme.AddTypeDefaultingFunc(&FooList{}, func(obj interface{}) { SetObjectDefaults_FooList(obj.(*FooList)) })
	return nil
}

func SetObjectDefaults_Foo(in *Foo) {
	SetDefaults_Foo(in) // 调用 defaults.go 实现
}

func SetObjectDefaults_FooList(in *FooList) {
	for i := range in.Items {
		a := &in.Items[i]
		SetObjectDefaults_Foo(a)
	}
}
```

习惯性地，我们应该在 [hello.zeng.dev/v1 defaults.go] 包装 `func RegisterDefaults(scheme *runtime.Scheme) error` 暴露给其他函数调用，避免直接依赖生成函数

    func AddDefaultingFuncs(scheme *runtime.Scheme) error {
	    return RegisterDefaults(scheme)
    }

此外，也可以给外部 module 提供的 public API 生成 default func，只需在 `doc.go` 提供声明 `+k8s:defaulter-gen-input` 引入外部 package

    // +k8s:defaulter-gen=TypeMeta
    // +k8s:defaulter-gen-input=github.com/phosae/x-kubernetes/api/hello.zeng.dev/v1
    package v1

具体可以参考 [api-aggregation-lib pkg/api/hello.zeng.dev/v1]

使用时将外部 module 类型和生成的 default funcs 一起注册到 Schema 即可

### conversion-gen

```bash
# pwd 
# github.com/phosae/x-kubernetes/api
inputs=("--input-dirs" "github.com/phosae/x-kubernetes/api/hello.zeng.dev/v1")
inputs+=("--input-dirs" "github.com/phosae/x-kubernetes/api/hello.zeng.dev/v2")

conversion-gen \
    -O zz_generated.conversion \
    --go-header-file /tmp/fake-boilerplate.txt \
    --output-base /go/src \
    "${inputs[@]}"
```

三种注释声明
- struct level:  // +k8s:conversion-gen:explicit-from=url.Values
- package level: // +k8s:conversion-gen=k8s.io/kubernetes/pkg/apis/apps
- package level: // +k8s:conversion-gen-external-types=k8s.io/api/apps/v1

conversion-gen 作用是解决多版本 API 类型到统一内部类型转换，它会自动比对外部 struct 和内部 struct 字段，尝试自动生成转换函数。

以 1.16 之前的官方资源 Deployment 为例，对外存在两个版本 API v1beta1 (k8s.io/api/apps/v1beta1/types.go) 和 v1 (k8s.io/api/apps/v1/types.go)，但是在内存和 etcd 它们都表现为统一的内部 Deployment (k8s.io/kubernetes/pkg/apis/apps/types.go)

    k8s.io/api/apps/v1beta1/types.go Deployment  <---+
                                                     +---> internal version k8s.io/kubernetes/pkg/apis/apps/types.go Deployment
    k8s.io/api/apps/v1/types.go      Deployment  <---+

转换函数全部放置在 `zz_generated.conversion.go`。文件头提供一个注册函数 `func RegisterConversions`

```go 
// file: zz_generated.conversion.go


// Convert_v1_DeploymentSpec_To_apps_DeploymentSpec is an autogenerated conversion function.
func Convert_v1_DeploymentSpec_To_apps_DeploymentSpec(in *v1.DeploymentSpec, out *apps.DeploymentSpec, s conversion.Scope) error {...}

func autoConvert_apps_DeploymentSpec_To_v1_DeploymentSpec(in *apps.DeploymentSpec, out *v1.DeploymentSpec, s conversion.Scope) error {...}

func autoConvert_apps_DeploymentSpec_To_v1_DeploymentSpec(in *apps.DeploymentSpec, out *v1.DeploymentSpec, s conversion.Scope) error {...}
```

需要手动转换的部分，在同目录下 conversion.go 提供 `func Convert_<pkg1>_<type>_To_<pkg2>_<type>` 并调用 `autoConvert_<pkg1>_<type>_To_<pkg2>_<type>` 即可

```go
// file: conversion.go

func Convert_apps_DeploymentSpec_To_v1_DeploymentSpec(in *apps.DeploymentSpec, out *appsv1.DeploymentSpec, s conversion.Scope) error {
  if err := autoConvert_apps_DeploymentSpec_To_v1_DeploymentSpec(in, out, s); err != nil {
      return err
    }
    // conversion code here
    return nil
}
```

点击这里查看 [Deployment v1 conversion](https://github.com/kubernetes/kubernetes/blob/0330fd91f4f49505c34ca32558b2ddad2635eb68/pkg/apis/apps/v1/conversion.go)，[hello.zeng.dev/v1 conversion] 提供了易于理解的例子。

如果内部类型和某个外部类型表示完全一致，则不需要写任何手工代码，由 conversion-gen 生成所有转换代码即可，[hello.zeng.dev/v2 conversion] 就是一例。

`// +k8s:conversion-gen:explicit-from=<package.type, i.e url.Values>` 提供 structs 级别声明，支持指明 structs 一对一转换，Kubernetes 的一个典型场景是 [转换 URL 参数到各种 CRUD options struct](https://github.com/kubernetes/kubernetes/blob/7cd51541cdc1fab211e22011e76052b997f5ce16/staging/src/k8s.io/apimachinery/pkg/apis/meta/v1/types.go#L318)

### go-to-protobuf

```bash
# pwd 
# github.com/phosae/x-kubernetes/api

go-to-protobuf \
    --proto-import=/go/src \
    --proto-import=/go/src/k8s.io/kubernetes/third_party/protobuf \
    --packages github.com/phosae/x-kubernetes/api/hello.zeng.dev/v1,github.com/phosae/x-kubernetes/api/hello.zeng.dev/v2 \
    --output-base /go/src/ \
    --go-header-file /tmp/fake-boilerplate.txt
```

在 `doc.go` 提供 protobuf 生成声明

    // +k8s:protobuf-gen=package

执行 `go-to-protobuf` 即可生成两个文件: generated.proto 和 generated.pb.go

generated.proto 是根据 go package 和 go struct 生成的 protobuf (proto 2) 定义

示例 API structs 内容，注意 field tags protobuf 为自动生成

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
示例 generated.proto 内容

```proto
syntax = "proto2";

package github.com.phosae.x_kubernetes.api.hello.zeng.dev.v1;

import "k8s.io/apimachinery/pkg/apis/meta/v1/generated.proto";
import "k8s.io/apimachinery/pkg/runtime/generated.proto";
import "k8s.io/apimachinery/pkg/runtime/schema/generated.proto";

// Package-wide variables from generator "generated".
option go_package = "github.com/phosae/x-kubernetes/api/hello.zeng.dev/v1";

message Foo {
  optional k8s.io.apimachinery.pkg.apis.meta.v1.ObjectMeta metadata = 1;

  optional FooSpec spec = 2;
}

message FooList {
  optional k8s.io.apimachinery.pkg.apis.meta.v1.ListMeta metadata = 1;

  repeated Foo items = 2;
}

message FooSpec {
  // Msg says hello world!
  optional string msg = 1;

  // Msg1 provides some verbose information
  // +optional
  optional string msg1 = 2;
}
```

generated.pb.go 是根据 generated.proto 生成的 Go 函数集，不再赘述

有了这两份文件，自定义 apiserver 等实现即可使用 protobuf 与官方 kube-apiserver 传递数据，也可以在 etcd 以 protobuf 格式存储对象。


## 🔥 OpenAPI Generator

```bash
# project:        github.com/phosae/x-kubernetes
# API go module:  github.com/phosae/x-kubernetes/api
inputs=("--input-dirs" "github.com/phosae/x-kubernetes/api/hello.zeng.dev/v1")
inputs+=("--input-dirs" "github.com/phosae/x-kubernetes/api/hello.zeng.dev/v2")

openapi-gen" \
    -O zz_generated.openapi \
    --go-header-file ${PROJECT_ROOT}/hack/boilerplate.go.txt" \
    --output-package github.com/phosae/x-kubernetes/api/generated/openapi" \
    --report-filename "${PROJECT_ROOT}/api/api-rules/violation_exceptions.list" \
    --input-dirs "k8s.io/apimachinery/pkg/apis/meta/v1" \
    --input-dirs "k8s.io/apimachinery/pkg/runtime" \
    --input-dirs "k8s.io/apimachinery/pkg/version" \
    "${inputs[@]}"
```

result

    ./github.com/phosae/x-kubernetes/api/generated/openapi/zz_generated.openapi.go

zz_generated.openapi.go 可以被 `k8s.io/apiserver` 库使用，作为 /openapi/v2 和 /openapi/v3 来源

```go
package cmd

import(
	openapinamer "k8s.io/apiserver/pkg/endpoints/openapi"
	genericapiserver "k8s.io/apiserver/pkg/server"
	utilfeature "k8s.io/apiserver/pkg/util/feature"
)

func ApiserverConfig() *genericapiserver.RecommendedConfig {
	serverConfig := genericapiserver.NewRecommendedConfig(myapiserver.Codecs)
	// enable OpenAPI schemas
	namer := openapinamer.NewDefinitionNamer(myapiserver.Scheme)
	serverConfig.OpenAPIConfig = genericapiserver.DefaultOpenAPIConfig(generatedopenapi.GetOpenAPIDefinitions, namer)
	serverConfig.OpenAPIConfig.Info.Title = "hello.zeng.dev-server"
	serverConfig.OpenAPIConfig.Info.Version = "0.1"

	if utilfeature.DefaultFeatureGate.Enabled(features.OpenAPIV3) {
		serverConfig.OpenAPIV3Config = genericapiserver.DefaultOpenAPIV3Config(generatedopenapi.GetOpenAPIDefinitions, namer)
		serverConfig.OpenAPIV3Config.Info.Title = "hello.zeng.dev-server"
		serverConfig.OpenAPIV3Config.Info.Version = "0.1"
	}
}
```

## 🔮 Client Generators

[kubernetes/client-go] 即是根据 API structs 自动生成，摘录 [hack/update-codegen.sh](https://github.com/kubernetes/kubernetes/blob/7cd51541cdc1fab211e22011e76052b997f5ce16/hack/update-codegen.sh) 如下

```
applyconfiguration-gen \
    --openapi-schema <("${modelsschema}") \
    --go-header-file "hack/boilerplate/boilerplate.generatego.tx" \
    --output-base "${KUBE_ROOT}/vendor" \
    --output-package k8s.io/client-go/applyconfigurations \
    $(printf -- " --input-dirs %s" "${ext_apis[@]}")
---
client-gen \
    --go-header-file "hack/boilerplate/boilerplate.generatego.tx" \
    --output-base "${KUBE_ROOT}/vendor" \
    --output-package="k8s.io/client-go" \
    --clientset-name="kubernetes" \
    --input-base="k8s.io/api" \
    --apply-configuration-package k8s.io/client-go/applyconfigurations \
    $(printf -- " --input %s" "${gv_dirs[@]}")
---
lister-gen \
    --go-header-file "hack/boilerplate/boilerplate.generatego.tx" \
    --output-base "${KUBE_ROOT}/vendor" \
    --output-package "k8s.io/client-go/listers" \
    $(printf -- " --input-dirs %s" "${ext_apis[@]}")
---
informer-gen \
    --go-header-file "hack/boilerplate/boilerplate.generatego.tx" \
    --output-base "${KUBE_ROOT}/vendor" \
    --output-package "k8s.io/client-go/informers" \
    --single-directory \
    --versioned-clientset-package k8s.io/client-go/kubernetes \
    --listers-package k8s.io/client-go/listers \
    $(printf -- " --input-dirs %s" "${ext_apis[@]}")
```

注: applyconfiguration-gen 参数 --openapi-schema 为可选。送了会生成额外的 ExtractTYPE 函数。如

    func ExtractPod(pod *apicorev1.Pod, fieldManager string) (*PodApplyConfiguration, error)  ----------------+
                                                                                                              |
    func ExtractPodStatus(pod *apicorev1.Pod, fieldManager string) (*PodApplyConfiguration, error) -----------+
                                                                                                              ⬇️ 
    func extractPod(pod *apicorev1.Pod, fieldManager string, subresource string) (*PodApplyConfiguration, error)

生成结果即是 [kubernetes/client-go] 中的熟悉结构

    tree -L 1 client-go
    client-go
    ├── applyconfigurations  # by applyconfiguration-gen
    ├── informers            # by informer-gen
    ├── kubernetes           # by client-gen
    ├── listers              # by lister-gen

client-gen 注释参数较多，可以查阅 [K8s community generating-clientset.md](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-api-machinery/generating-clientset.md)

### client example

```go
package main

import (
	"context"
	"fmt"

	apiv1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	applyv1 "k8s.io/client-go/applyconfigurations/core/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/homedir"
)

func main() {
	config, _ := clientcmd.BuildConfigFromFlags("", homedir.HomeDir()+"/.kube/config")
	clientset, _ := kubernetes.NewForConfig(config)

	podClient := clientset.CoreV1().Pods(apiv1.NamespaceDefault)

	pod := &apiv1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "testpd", Labels: map[string]string{"app": "test"}},
		Spec: apiv1.PodSpec{
			Containers: []apiv1.Container{
				{Name: "busybox", Image: "busybox:1.36"},
			},
		},
	}

	result, err := podClient.Create(context.TODO(), pod, metav1.CreateOptions{})
	if err != nil {
		panic(err)
	}
	fmt.Printf("Created pod %q.\n", result.GetObjectMeta().GetName())
	defer func() { podClient.Delete(context.TODO(), pod.Name, metav1.DeleteOptions{}) }()

	// similar to: kubectl patch pod/testpd -p '{"metadata": {"labels": {"hello": "world"}}}'
	podApplyCfg := applyv1.Pod("testpd", apiv1.NamespaceDefault).WithLabels(map[string]string{"hello": "world"})
	applyRet, err := podClient.Apply(context.Background(), podApplyCfg, metav1.ApplyOptions{FieldManager: "example", Force: false})
	if err != nil {
		panic(err)
	}
	fmt.Printf("Pod/%s labels:\n", applyRet.Name)
	for ak, av := range applyRet.Labels {
		fmt.Printf("\t%s: %v\n", ak, av)
	}
} ///~ ouput:
/*
Created pod "testpd".
Pod/testpd labels:
        app: test
        hello: world
*/
```

### watch example
```go
package main

import (
	"context"
	"fmt"
	"time"

	apiv1 "k8s.io/api/core/v1"
	coreinformers "k8s.io/client-go/informers/core/v1"
	"k8s.io/client-go/kubernetes"
	corelisters "k8s.io/client-go/listers/core/v1"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/homedir"
)

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	config, _ := clientcmd.BuildConfigFromFlags("", homedir.HomeDir()+"/.kube/config")
	clientset, _ := kubernetes.NewForConfig(config)

	// normally K8s Objects are KV based
	// client cache+indexers address this limit to some extent
	// for example we can group pods by nodeName
	var podInformer = coreinformers.NewFilteredPodInformer(clientset, apiv1.NamespaceDefault, 0,
		cache.Indexers{"spec.NodeName": func(obj interface{}) ([]string, error) {
			return []string{obj.(*apiv1.Pod).Spec.NodeName}, nil
		}}, nil)
	// pods, _ := podInformer.GetIndexer().ByIndex("spec.NodeName", "node-1")

	podInformer.Run(ctx.Done())

	for !podInformer.HasSynced() {
	}

	var podLister = corelisters.NewPodLister(podInformer.GetIndexer())
	result, err := podLister.Pods(apiv1.NamespaceDefault).Get("testpd")
	if err != nil {
		panic(err)
	}
	fmt.Printf("Get pod/%q from cache .\n", result.GetObjectMeta().GetName())

	// using event handlers do business when Pod Object changes
	podInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc:    func(obj interface{}) { /**/ },
		UpdateFunc: func(oldObj, newObj interface{}) { /**/ },
		DeleteFunc: func(obj interface{}) { /**/ },
	})
}
```

## 🥷 All in One Script

上述 Generators 中许多参数存在重复，针对这个问题 [kubernetes/code-generator] 早先提供了 generate-groups.sh 和 /generate-internal-groups.sh 脚本批量生成。1.28 alpha 之后则提供了表述更清晰更好维护的脚本 kube_codegen.sh。

另外，上述 Generator 均假设项目放置在 GOPATH 下，如 github.com/phosae/x-kubernetes/api 路径应为 ${GOPATH}/github.com/phosae/x-kubernetes/api。
之后在对应项目路径下执行生成命令，Generator 才能正常工作，造成了一定不便。

所以最好的方式是在容器环境生成代码，事先准备好容器镜像，运行时将项目挂载到容器 GOPATH 下，一键生成即可。
[x-kubernetes/api] 和 [x-kubernetes/api-aggregation-lib] 即利用了这种方式生成代码。

Public API module: github.com/phosae/x-kubernetes/api 运行 [./hack/update-codegen-docker.sh](https://github.com/phosae/x-kubernetes/blob/65956d7aac13a804e35635de53ed9f8989351c26/api/hack/update-codegen-docker.sh) 结果如下

```
tree -L 2 hello.zeng.dev generated/
hello.zeng.dev
├── install.go
├── register.go
├── v1
│   ├── defaults.go
│   ├── doc.go
│   ├── generated.pb.go
│   ├── generated.proto
│   ├── register.go
│   ├── types.go
│   ├── zz_generated.deepcopy.go
│   └── zz_generated.defaults.go
└── v2
    ├── doc.go
    ├── generated.pb.go
    ├── generated.proto
    ├── register.go
    ├── types.go
    └── zz_generated.deepcopy.go

generated/
├── applyconfiguration
│   ├── hello.zeng.dev
│   ├── internal
│   └── utils.go
├── clientset
│   └── versioned
├── examples
│   ├── client
│   ├── README.md
│   └── watch
├── informers
│   └── externalversions
├── listers
│   └── hello.zeng.dev
└── openapi
    └── zz_generated.openapi.go
```

apiserver module: github.com/phosae/x-kubernetes/api-aggregation-lib 运行 [./hack/update-codegen-docker.sh](https://github.com/phosae/x-kubernetes/blob/65956d7aac13a804e35635de53ed9f8989351c26/api-aggregation-lib/hack/update-codegen-docker.sh) 结果如下

```
pkg                            # internal APIs   
├── api
│   └── hello.zeng.dev
│       ├── install                
│       │   └── install.go
│       ├── v1
│       │   ├── conversion.go  # conversion funcs v1 ---> internal type
│       │   ├── defaults.go    # default funcs v1
│       │   ├── doc.go         # packge 级别生成声明
│       │   ├── register.go    # 注册 API Structs
│       │   ├── zz_generated.conversion.go
│       │   └── zz_generated.defaults.go
│       ├── v2
│       │   ├── defaults.go    # default funcs v2
│       │   ├── doc.go         # packge 级别生成声明
│       │   ├── register.go    # 注册 API Structs     
│       │   ├── zz_generated.conversion.go
│       │   └── zz_generated.defaults.go
│       ├── doc.go
│       ├── register.go
│       ├── types.go           # internal type all api versions, include v1 and v2
│       └── zz_generated.deepcopy.go
├── apiserver
..
```

Public API 生成前后 PR 对比
- [PR api: add hello.zeng.dev/v2](https://github.com/phosae/x-kubernetes/commit/8cc7165a09ea4f01f3f4c132e20e5c060910f379)
- [PR api: gen v2 codes](https://github.com/phosae/x-kubernetes/commit/6ef463dc1d251f2f267de9598e98453cbad3fe57)

Internal API 生成前后 PR 对比
- [PR apiserver-by-lib: add hello.zeng.dev/v2 internal](https://github.com/phosae/x-kubernetes/commit/7f30c3df7fe46ca87597e7f0c4d71edb464c4532)
- [PR apiserver-by-lib: gen hello.zeng.dev/v2 internal codes](https://github.com/phosae/x-kubernetes/commit/e9ab0750243bb7132074bc1e4afc14a8e9988c78)

👋👋👋 容器一键生成镜像代码库在 [phosae/kube-code-generator](https://github.com/phosae/kube-code-generator)，欢迎 PR 

[x-kubernetes/api]: https://github.com/phosae/x-kubernetes/tree/master/api

[x-kubernetes/api-aggregation-lib]: https://github.com/phosae/x-kubernetes/tree/65956d7aac13a804e35635de53ed9f8989351c26/api-aggregation-lib

[api-aggregation-lib pkg/api/hello.zeng.dev/v1]: https://github.com/phosae/x-kubernetes/tree/v0.0.1/api-aggregation-lib/pkg/api/hello.zeng.dev/v1
[hello.zeng.dev/v1 defaults.go]: https://github.com/phosae/x-kubernetes/blob/v0.0.1/api/hello.zeng.dev/v1/defaults.go
[hello.zeng.dev/v1 zz_generated.defaults.go]: https://github.com/phosae/x-kubernetes/blob/v0.0.1/api/hello.zeng.dev/v1/zz_generated.defaults.go
[hello.zeng.dev/v1 conversion]: https://github.com/phosae/x-kubernetes/blob/7fdec41420e59b02112ae79652f9ccc409c9c228/api-aggregation-lib/pkg/api/hello.zeng.dev/v1/conversion.go
[hello.zeng.dev/v2 conversion]: https://github.com/phosae/x-kubernetes/blob/7fdec41420e59b02112ae79652f9ccc409c9c228/api-aggregation-lib/pkg/api/hello.zeng.dev/v2


[kubernetes/code-generator]: https://github.com/kubernetes/code-generator
[kubernetes/apimachinery]:  https://github.com/kubernetes/apimachinery
[apimachinery/interface runtime.Object]: https://github.com/kubernetes/kubernetes/blob/4c40d749006a8895f6718f2b624a3dbe975988ab/staging/src/k8s.io/apimachinery/pkg/runtime/interfaces.go#L319-L326
[kubernetes/client-go]: https://github.com/kubernetes/client-go
[runtime.Scheme]: https://github.com/kubernetes/apimachinery/blob/6b1428efc73348cc1c33935f3a39ab0f2f01d23d/pkg/runtime/scheme.go#L46
[kubernetes-sigs/kubebuilder]: https://github.com/kubernetes-sigs/kubebuilder