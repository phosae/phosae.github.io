---
title: "K8s Admission Control and Policy"
date: 2023-06-19T23:19:35+08:00
lastmod: 2023-06-19T23:19:35+08:00
draft: true
keywords: ["kubernetes", "policy", "webhook", "plugin", "go"]
description: ""
tags: ["kubernetes", "policy", "webhook", "plugin", "go"]
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
[K8s CustomResourceDefinitions (CRD) internals]: ../2023-k8s-api-by-crd
[best practice for K8s api multi-version conversion]: ../2023-k8s-api-multi-version-conversion-best-practice
[simple K8s apiserver from scratch]: ../2023-k8s-apiserver-from-scratch
[K8s apiserver aggregation internals]: ../2023-k8s-apiserver-aggregation-internals
[The most thorough K8s code generation tutorial]: ../2023-k8s-api-codegen
[Implement K8s apiserver using library]: ../2023-k8s-apiserver-using-library
[Why custom K8s apiserver should avoid runtime?]: ../2023-k8s-apiserver-avoid-using-runtime
[K8s Admission Control and Policy]: ../2023-k8s-api-admission

This post is one of the **K8s API and Controllers** series
- [K8s CustomResourceDefinitions (CRD) internals]
- [best practice for K8s api multi-version conversion]
- [simple K8s apiserver from scratch]
- [K8s apiserver aggregation internals]
- [The most thorough K8s code generation tutorial]
- [Implement K8s apiserver using library]
- [Why custom K8s apiserver should avoid runtime?]
- [K8s Admission Control and Policy] (this post)

## 🎟️ What is Admission Control in K8s

Any API request comming to kube-apiserver normmaly follow these steps
1. firstly pass filterchain, in which kube-apiserver do authn/authz to it
2. then dispatched by kube-aggregator to corresponding sub apiserver's HTTP mux
3. after decoding/conversion/defaulting with [runtime.Scheme]
4. **corresponding sub apiserver perform admission control on the request**
5. RESTStorage strategy will be executed and it finally be persisted to etcd

The admission control is performed by [Admission Controllers].

> An admission controller is a piece of code that intercepts requests to 
    the Kubernetes API server prior to persistence of the object, 
> but after the request is authenticated and authorized.


<img src="/img/2023/k8s-admission-and-policy.png" width="800px"/>

[Admission Controllers] are quite common in K8s, take Pod creation as an example.
In v1.27.3 (and most previous versions), during creation a Pod will be mutated by ServiceAccount, Priority, and DefaultTolerationSeconds Admission Controller as show below

```shell
cat << EOF | kubectl create --dry-run=server -o yaml -f -
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  containers:
  - image: nginx
    name: web
EOF
---
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: "2023-07-05T08:35:42Z"   # generic registry Store
  name: web
  namespace: default                          # populated by kubelet, required by apiserver
  uid: e8645a53-4676-4fb7-9441-a91b549f293c   # generic registry Store
spec:
  containers:
  - image: nginx
    imagePullPolicy: Always   # defaults, Always for tag latest, IfNotPresent for other tags
    name: web
    resources: {}
    terminationMessagePath: /dev/termination-log  # defaults
    terminationMessagePolicy: File                # defaults
    volumeMounts:                           
    - mountPath: /var/run/secrets/kubernetes.io/serviceaccount <---+ 
      name: kube-api-access-rbr96                                  |--> by ServiceAccount Admission Controller
      readOnly: true                                           <---+ 
  dnsPolicy: ClusterFirst    # defaults
  enableServiceLinks: true   # defaults
  preemptionPolicy: PreemptLowerPriority   <-----------------------+
  priority: 0                              <-----------------------+--> by Priority Admission Controller
  restartPolicy: Always            # defaults
  schedulerName: default-scheduler # defaults
  securityContext: {}         
  serviceAccount: default       # conversion from serviceAccountName
  serviceAccountName: default   <--------------------------------------> by ServiceAccount Admission Controller
  terminationGracePeriodSeconds: 30
  tolerations:
  - effect: NoExecute              <--------------------------------+
    key: node.kubernetes.io/not-ready                               |
    operator: Exists                                                |
    tolerationSeconds: 300                                          |--> by DefaultTolerationSeconds Admission Controller
  - effect: NoExecute                                               |
    key: node.kubernetes.io/unreachable                             |
    operator: Exists                                                |
    tolerationSeconds: 300         <--------------------------------+
  volumes: 
  - name: kube-api-access-rbr96    <--------------------------------+
    projected:                                                      |
      defaultMode: 420                                              |
      sources:                                                      |
      - serviceAccountToken:                                        |
          expirationSeconds: 3607                                   |
          path: token                                               |
      - configMap:                                                  |
          items:                                                    |
          - key: ca.crt                                             |--> by ServiceAccount Admission Controller
            path: ca.crt                                            |
          name: kube-root-ca.crt                                    |
      - downwardAPI:                                                |
          items:                                                    |
          - fieldRef:                                               |
              apiVersion: v1                                        |
              fieldPath: metadata.namespace                         |
            path: namespace      <----------------------------------+
status:
  phase: Pending        # podStrategy.PrepareForCreate
  qosClass: BestEffort  # podStrategy.PrepareForCreate
```

Creating a Pod with namespaces that not exist in cluster will got a 404 response, which was done by NamespaceLifecycle Admission Controller.

```shell
kubectl -n ns-not-exist run nginx --image=nginx
Error from server (NotFound): namespaces "ns-not-exist" not found
```

Admission controllers perform deep inspection of a given request (including content), some of them just validate it and determine whether its allowed (like NamespaceLifecycle Admission Controller), while the other may mutate the content (like ServiceAccount, Priority, and DefaultTolerationSeconds Admission Controller).

All of the [Admission Controllers] are built in kube-apiserver. You can take further raading for details.

## 🧿 Admission internals

Admission is a module in [k8s.io/apiserver pkg/admission]. In which these interfaces are exposed to apiserver developer 
- An admission controller must implement Interface.Handles to decide whether to handle the incoming operation (CREATE, UPDATE, DELETE, or CONNECT), and MutationInterface or ValidationInterface to make admission decision.
- The MutationInterface is also an admission Interface (by nesting). Its function `Admit` makes an admission decision, and is allowed mutate request object
- The ValidationInterface is quite similar to MutationInterface, but its function `Validate` is not allowed to mutate request object

All admission controllers are implementation of MutationInterface or ValidationInterface. MutationInterface implementation can mutate and validate request content, but ValidationInterface implementation can only validate request content.

```
package admission

// Interface is an abstract, pluggable interface for Admission Control decisions.
type Interface interface {
	// Handles returns true if this admission controller can handle the given operation
	// where operation can be one of CREATE, UPDATE, DELETE, or CONNECT
	Handles(operation Operation) bool
}

type MutationInterface interface {
	Interface

	// Admit makes an admission decision based on the request attributes.
	// Context is used only for timeout/deadline/cancellation and tracing information.
	Admit(ctx context.Context, a Attributes, o ObjectInterfaces) (err error)
}

// ValidationInterface is an abstract, pluggable interface for Admission Control decisions.
type ValidationInterface interface {
	Interface

	// Validate makes an admission decision based on the request attributes.  It is NOT allowed to mutate
	// Context is used only for timeout/deadline/cancellation and tracing information.
	Validate(ctx context.Context, a Attributes, o ObjectInterfaces) (err error)
}
```
The official kube-apiserver has many [built-in admission plugins] ontop of the admission package, 
and here's the detail of [built-in admission plugins register].
These built-in plugins are commonly known as [Admission Controllers]. 

## ✍️ Write an Admission Controller in apiserver

As admission control is performed after dispatch of kube-aggregator, custom apiserver should implement admission controllers by itself.

👻👻👻 If interested in K8s apiserver aggregation, you can read this post: [K8s apiserver aggregation internals].

Implementing the admission interfaces, then registering it to apiserver, that's all for writing an Admission Controller in apiserver.

As [x-kubernetes commit: add admission] shows

Firstly write the Admission Controller implements admission.ValidationInterface under pkg/admisssion

```go
package disallow

// Register registers a plugin
func Register(plugins *admission.Plugins) {
    plugins.Register("DisallowFoo", func(config io.Reader) (admission.Interface, error) {
        return &DisallowFoo{
            Handler: *admission.NewHandler(admission.Create),
        }, nil
    })
}

type DisallowFoo struct {
    admission.Handler // nested Handler implements admission.Interface
}

// Validate implements admission.ValidationInterface
func (d *DisallowFoo) Validate(ctx context.Context, a admission.Attributes, o admission.ObjectInterfaces) (err error) {
    // write admission code here
    return nil
}
```
Then register Admission Controller to Admission options and enactive admission module in apiserver

```go
func (o *Options) Complete() error {
    disallow.Register(o.Admission.Plugins) // register the Admission Controller
    o.Admission.RecommendedPluginOrder = append(o.Admission.RecommendedPluginOrder, "DisallowFoo")
    return nil
}

func (o Options) ApiserverConfig() {
    ... 
    // Apply Admission Options to apiserver config. 
    // If RecommendedOptions was used to configure apiserver, just call RecommendedOptions.ApplyTo.
    o.Admission.ApplyTo(&serverConfig.Config, serverConfig.SharedInformerFactory, serverConfig.ClientConfig, feature.DefaultFeatureGate)
    ...
}
```

Things happen in kube-apiserver are quite similar to it in custom apiserver
- [built-in admission plugins] are where the Admission Controller codes in
- [built-in admission plugins register] are codes about plugin register

[k8s.io/apiserver pkg/server/options.NewAdmissionOptions] provides a convinient way for admission module initialization, which register these necessary admission controllers for custom apiserver

- NamespaceLifecycle 
- MutatingAdmissionWebhook
- ValidatingAdmissionPolicy
- ValidatingAdmissionWebhook

NamespaceLifecycle mostly for custom object creation. The others for dynamic policy.

## 🔮 Webhook and Policy

All of the [Admission Controllers] are built in apiserver. Among them there're three special guys
1. MutatingAdmissionWebhook 
2. ValidatingAdmissionPolicy
3. ValidatingAdmissionWebhook

[k8s.io/apiserver pkg/admission]: https://github.com/kubernetes/apiserver/tree/master/pkg/admission
[built-in admission plugins]: https://github.com/kubernetes/kubernetes/tree/master/plugin/pkg/admission
[built-in admission plugins register]: https://github.com/kubernetes/kubernetes/blob/master/pkg/kubeapiserver/options/plugins.go
[Admission Controllers]: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
[runtime.Scheme]: https://github.com/kubernetes/apimachinery/blob/6b1428efc73348cc1c33935f3a39ab0f2f01d23d/pkg/runtime/scheme.go#L46
[k8s.io/apiserver pkg/server/options.NewAdmissionOptions]: https://github.com/kubernetes/apiserver/blob/0e613811b6d0e41341abffac5a2f423eeee0fbaf/pkg/server/options/admission.go#L81-L95

[OPA/Gatekeeper]: https://github.com/open-policy-agent/gatekeeper
[Kyverno]: https://github.com/kyverno/kyverno
[Validating Admission Policy]: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
[Kubernetes Documentation: Validating Admission Policy]: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
<!-- https://github.com/douglasmakey/k8s-validating-admission-policy -->

[x-kubernetes commit: add admission]: https://github.com/phosae/x-kubernetes/commit/c2bfa30485677249374dbb582e8a111c0b897f0c