---
title: "如何迁移 Spring Cloud Eureka 注册体系至 k8s"
date: 2020-04-28T20:32:51+08:00
lastmod: 2020-05-07T01:00:00+08:00
draft: false
keywords: ["Spring Cloud","Eureka","k8s","Spring","Java"]
tags: ["Spring Cloud","Eureka","k8s","Spring","Java"]

summary: 优雅处理 Eureka 跨集群同步

comment: true
toc: true
autoCollapseToc: false
postMetaInFooter: true
hiddenFromHomePage: false
# You can also define another contentCopyright. e.g. contentCopyright: "This is another copyright."
contentCopyright: '本作品采用 <a rel="license noopener" href="https://creativecommons.org/licenses/by-nc-nd/4.0/" target="_blank">知识共享署名-非商业性使用-禁止演绎 4.0 国际许可协议</a> 进行许可，转载时请注明原文链接。' 
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
## 背景
最近负责着手把公司跑在阿里云 ECS 上的 Spring Cloud 微服务迁移到 k8s，为保证平滑顺畅，仍需 k8s 中保留 Eureka 体系，直到所有服务都跑在 k8s 后，才会着手考虑去 Eureka。根据迁移情况，云主机会处于如下两个阶段:
1. 阶段一，部分主机受 k8s 管理，部分不受 k8s 管理。默认情况下，k8s 网络到 ECS 网络为单向畅通，不受管理部分的 ECS 无法通过 ip 直接访问 k8s Pod 网段和Service 网段。
2. 阶段二，所有主机均受 k8s 管理，k8s 网络到 ECS 网络双通。

该如何处理 k8s 服务实例与 ECS 服务实例互通互调，有如下方案：
1. 迁移到 k8s 的服务实例仍旧注册到 ECS Eureka 集群，对于不受 k8s 管理的实例，采用手工配置 ip table 的方式，保证不受管理部分的 ECS 可以通过 ip 直接访问 k8s Pod 网段和Service 网段；这种方案可以使用到全部迁移完成
2. 在 k8s 中新部署 Eureka 集群，迁移到 k8s 的实例通过切换配置注册到 k8s Eureka 集群；阶段一，将 ECS Eureka 集群单向注册到 k8s Eureka 集群，保证 k8s 实例可以访问 ECS 实例即可(容忍 ECS 实例不能访问 k8s 实例)；阶段二，ECS Eureka 集群与 k8s Eureka 集群双向注册，直到迁移完成。

注: 如果迁移开始前即可保证所有 ECS 均可成为 Worker 节点 K8S 管理，则自由选择持续使用外部 Eureka 集群或者一致维持 ECS Eureka 集群与 k8s Eureka 集群双向注册即可。

方案 1 的好处是简单轻松，坏处是需要手工配置 ip table，比较适合 ECS 节点不多的情况。方案 2 的好处是不用手动配置网络，坏处是阶段一区域网络不通。

结合具体情况，我选择了方案 2，对于网络不通的情况，迁移时可先选择较为独立的周边服务，等这部分迁移完，差不多所有节点也能纳入 k8s 管理了。

<img src="/img/2020-04/migrate-simple-schema.jpg" width="700px">
{{% center %}}
概要图，省略服务层级和 k8s  Service、Pod 等细节
{{% /center %}}

下文接着讲述 ECS 集群单向注册 k8s 集群的配置设计以及如何解决遇到问题。

# Eureka 配置设计
首先在 /etc/hosts 文件增加如下 DNS 解析规则
```shell
127.0.0.1 ecs-peer1
127.0.0.1 ecs-peer2
127.0.0.1 k8s-peer1
127.0.0.1 k8s-peer2
```

下面的 yaml 配置展示了如何模拟将 ECS Eureka 集群单向注册到 k8s 集群，有几个配置需要说明
* *eureka.server.enable-self-preservation=false*，关闭了 k8s Eureka 集群的自我保护功能（原因将在下文说明）
* *eureka.client.fetch-registry=false*, 关闭了 ECS Eureka 启动的应用列表获取，如果开启，ECS Eureka 启动时将从 k8s Eureka server 中获取应用列表， k8s 实例会注册到 ECS Eureka，由于网络不通，会导致 ECS 实例访问出错

```yaml
---
server:
  port: 8761
spring:
  profiles: k8s-peer1
eureka:
  instance:
    hostname: k8s-peer1
    appname: k8s-eureka
  client:
    serviceUrl:
      k8s-zone: http://k8s-peer1:8761/eureka/,http://k8s-peer2:8762/eureka/
    availability-zones:
      shanghai: k8s-zone
    region: shanghai
  server:
    enable-self-preservation: false
---
server:
  port: 8762
spring:
  profiles: k8s-peer2
eureka:
  instance:
    hostname: k8s-peer2
    appname: k8s-eureka
  client:
    serviceUrl:
      k8s-zone: http://k8s-peer1:8761/eureka/,http://k8s-peer2:8762/eureka/
    availability-zones:
      shanghai: k8s-zone
    region: shanghai
  server:
    enable-self-preservation: false
---
server:
  port: 8763
spring:
  profiles: ecs-peer1
eureka:
  instance:
    hostname: ecs-peer1
    appname: ecs-eureka
  client:
    fetch-registry: false
    serviceUrl:
      ecs-zone: http://ecs-peer1:8763/eureka/,http://ecs-peer2:8764/eureka/
      k8s-zone: http://k8s-peer1:8761/eureka/,http://k8s-peer2:8762/eureka/
    availability-zones:
      shanghai: ecs-zone,k8s-zone
    region: shanghai
---
server:
  port: 8764
spring:
  profiles: ecs-peer2
eureka:
  instance:
    hostname: ecs-peer2
    appname: ecs-eureka
  client:
    fetch-registry: false
    serviceUrl:
      ecs-zone: http://ecs-peer1:8763/eureka/,http://ecs-peer2:8764/eureka/
      k8s-zone: http://k8s-peer1:8761/eureka/,http://k8s-peer2:8762/eureka/
    availability-zones:
      shanghai: ecs-zone,k8s-zone
    region: shanghai
```
确认你已经在 Eureka server 项目目录，开 4 个控制台依次使用如下命令启动所有 Eureka
```shell
mvn spring-boot:run -Dspring-boot.run.arguments=--spring.profiles.active=k8s-peer1
mvn spring-boot:run -Dspring-boot.run.arguments=--spring.profiles.active=k8s-peer2
mvn spring-boot:run -Dspring-boot.run.arguments=--spring.profiles.active=ecs-peer1
mvn spring-boot:run -Dspring-boot.run.arguments=--spring.profiles.active=ecs-peer2
```

访问 k8s-peer1:8761 或者 k8s-peer2:8762，可以看到 Eureka 实例 ecs-peer1:8763 和 ecs-peer2:8764 注册到了 k8s-zone
<img src="/img/2020-04/k8s-peer.jpg" width="600px">

访问 ecs-peer1:8763 或者 ecs-peer2:8764，k8s-zone 但 Eureka 并未注册到 ecs-zone
<img src="/img/2020-04/ecs-peer.jpg" width="600px">

再通过 ecs-peer1:8763 注册应用 ecs-to-k8s-app，再通过 k8s-peer1:8761 注册应用 k8s-only-app，发现 ecs-to-k8s-app 注册信息已被同步至 k8s-zone，但 k8s-only-app 注册信息并未被同步至 ecs-zone
<img src="/img/2020-04/k8s-only-app.jpg" width="600px">
{{% center %}}
k8s-peer1:8761 注册信息
{{% /center %}}
<img src="/img/2020-04/ecs2k8s-app.jpg" width="600px">
{{% center %}}
ecs-peer1:8763 注册信息
{{% /center %}}

如进入阶段二，打算切为双向注册，类似地，只需将 k8s Eureka 实例配置改为如下即可
```yaml
port: 8761
spring:
  profiles: k8s-peer1
eureka:
  instance:
    hostname: k8s-peer1
    appname: k8s-eureka
  client:
    serviceUrl:
      ecs-zone: http://ecs-peer1:8763/eureka/,http://ecs-peer2:8764/eureka/
      k8s-zone: http://k8s-peer1:8761/eureka/,http://k8s-peer2:8762/eureka/
    availability-zones:
      shanghai: k8s-zone, ecs-zone
    region: shanghai
  server:
    enable-self-preservation: false
```

## 理解 Eureka 集群复制原理
Eureka 会选取 eureka.client.availability-zones 声明的所有节点作为同步节点列表（在上面，我通过这种方式实现了单向注册）。

Eureka 集群复制代码在 package com.netflix.eureka.registry, class PeerAwareInstanceRegistryImpl，以实例注册为例
```java
public void register(final InstanceInfo info, final boolean isReplication) {
    int leaseDuration = Lease.DEFAULT_DURATION_IN_SECS;
    if (info.getLeaseInfo() != null && info.getLeaseInfo().getDurationInSecs() > 0) {
      leaseDuration = info.getLeaseInfo().getDurationInSecs();
    }
    super.register(info, leaseDuration, isReplication);
    replicateToPeers(Action.Register, info.getAppName(), info.getId(), info, null, isReplication);
}

private void replicateToPeers(Action action, String appName, String id,
                                  InstanceInfo info /* optional */,
                                  InstanceStatus newStatus /* optional */, boolean isReplication) {
    Stopwatch tracer = action.getTimer().start();
    try {
        if (isReplication) {
            numberOfReplicationsLastMin.increment();
        }
        // If it is a replication already, do not replicate again as this will create a poison replication
        // 如果是其他节点信息同步，处理结束
        if (peerEurekaNodes == Collections.EMPTY_LIST || isReplication) {
            return;
        }
        // 如果是应用信息更新，同步注册信息至其他节点
        for (final PeerEurekaNode node : peerEurekaNodes.getPeerEurekaNodes()) {
            // If the url represents this host, do not replicate to yourself.
            if (peerEurekaNodes.isThisMyUrl(node.getServiceUrl())) {
                continue;
            }
            replicateInstanceActionsToPeers(action, appName, id, info, newStatus, node);
        }
    } finally {
        tracer.stop();
    }
}
```
Eureka server 实例通过 register 同时处理应用注册 (isReplication=false) 和 peer 注册同步 (isReplication=true)。如果是应用注册，在本地注册成功后，PeerAwareInstanceRegistryImpl 会将注册信息同步到集群其他节点；如果是其他节点的注册同步，那么在本地注册成功之后，即结束流程。

这样设计的考量是：如果允许 replication 信息反复传递，那么只要任意注册一个应用，稍过一段时间，所有 Eureka 节点的网卡都会被打爆。

因此，在跨集群复制中，不要使用将多节点放置在同一域名，再通过域名传递注册信息实现最终一致的方式实现复制，而必须配置中声明每一个需要同步的节点。

<img src="/img/2020-04/eureka-chain-replica.jpg" width="300px">

在上图中，app 信息更新到 ecs-zone 的 eureka-1 中，随之会被复制到 ecs-zone 的 eureka-2 和 k8s-zone 的 eureka-1，但不会被复制到 k8s-zone 的 eureka-2，最终会导致 k8s-zone 中的某个 Eureka 实例缺少大量注册应用。

同理，其他操作，如续租 (renew), 下线 (cancel) 都是类似的。值得一提的是，Eureka 的设计思想是 AP，所以过期服务淘汰(evict) 并不会同步至其他节点。

## Eureka cluster in k8s
任意 Eureka 节点均需知道其他节点的地址，切需要通过固定地址维续通信，于是 Eureka 集群在 k8s 中的适宜部署为 StatefuleSet。在 StatefulSet yaml 中，只需要将节点信息替换称固定域名即可，这里省去该部分配置。

值得注意的是，这里使用了多个 Service 暴露底层的 Eureka 实例，原因都写在注释中，StatefulSet 需要根据 Service 声明生成节点域名，如果 StatefulSet 名为 eureka，那么节点固定域名就是 eureka-0.eureka-svc, eureka-1.eureka-svc,..., eureka-n.eureka-svc。

上文提到，Eureka 节点之间的信息同步不能统一域名负载，因此不能简单在 eureka-svc 上层放一个 Ingress 暴露给 ECS Eureka 注册，而是需要通过单独的 Service 逐个挑选 Eureka 实例（结合 StatefulSet label)，再通过 NodePort 或者 Ingress 逐个暴露。

```yaml
---
# headless Service, 绑定到 StatefulSet 使用
apiVersion: v1
kind: Service
metadata:
  name: eureka-svc
spec:
  clusterIP: None
  ports:
    - port: 8761
      targetPort: 8761
  selector:
    app: eureka
---
# 与 Pod 一一对应，供 ECS eureka 注册
apiVersion: v1
kind: Service
metadata:
  name: eureka-0-svc
spec:
  type: NodePort
  ports:
    - nodePort: 30761
      port: 8761
      targetPort: 8761
      protocol: TCP
  selector:
    app: eureka
    "statefulset.kubernetes.io/pod-name": eureka-0
---
# 与 Pod 一一对应，供 ECS eureka 注册
apiVersion: v1
kind: Service
metadata:
  name: eureka-1-svc
spec:
  type: NodePort
  ports:
    - nodePort: 30762
      port: 8761
      targetPort: 8761
      protocol: TCP
  selector:
    app: eureka
    "statefulset.kubernetes.io/pod-name": eureka-1
```

看到这里，你应该已经明白如何实现 k8s Eureka 与外部 Eureka 信息同步了。

## 为什么关闭 Eureka 自我保护
Eureka 自我保护 (eureka-self-preservation-renewal) 功能，旨在出现 network partition 时，禁用 evict 机制，不再淘汰服务实例，这里有很好的[介绍文章](https://www.baeldung.com/eureka-self-preservation-renewal)。

默认情况下，如果 Eureka 没收到超过 85% 实例的续租信息，自我保护就会开启。

迁移早期，k8s Eureka 集群中的大部分实例均来自 ECS 集群。但凡发生点网络抖动，或者 ECS Eureka 重启，就会触发 k8s Eureka 自我保护。结果就是 k8s Eureka 存在大量过期实例，一致性特差，服务调用失败频发。因此笔者在实践中关闭了自我保护。