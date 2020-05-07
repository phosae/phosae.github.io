---
title: "从定时任务理解 Eureka 架构设计"
date: 2020-04-25T20:40:29+08:00
lastmod: 2020-05-08T00:22:00+08:00
draft: false
keywords: ["Spring Cloud","Eureka","Spring","Java"]
description: ""
tags: ["Spring Cloud","Eureka","Spring","Java"]
author: "Zeng Xu"
summary: "扒一扒 Eureka 中的定时任务"

comment: true
toc: true
autoCollapseToc: false
postMetaInFooter: true
hiddenFromHomePage: false
# You can also define another contentCopyright. e.g. contentCopyright: "This is another copyright."
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

## 写在前面
Eureka 功能是服务注册发现，核心实现在 package com.netflix.eureka.registry，其他几万行代码都绕着这 2000 来行代码展开。

接口 LookupService 声明了服务发现功能，接口 LeaseManager 声明租期管理功能，接口 InstanceRegistry 继承前两者并额外声明了实例信息覆盖、实例列表增量获取、响应缓存、自我保护等功能。最高抽象类 AbstractInstanceRegistry 实现了 InstanceRegistry，实际上就是在一个 ConcurrentHashMap 中维护注册信息，然后围绕该 Map 处理服务发现、服务注册、服务续租、服务下线、服务淘汰。

接口 PeerAwareInstanceRegistry 在 InstanceRegistry 之上提供 Eureka 集群实例之间的信息同步功能，而 PeerAwareInstanceRegistryImpl 继承抽象 AbstractInstanceRegistry 并实现了 PeerAwareInstanceRegistry 接口，所以 Eureka 中使用的实现类为 PeerAwareInstanceRegistryImpl。

<img src="/img/2020-04/eureka-regsitry-class.jpg" width="500px">

在 registry 包基础上，Eureka 为实现高并发低延迟、配置动态更新、故障自动检测和监控等目标，大量使用了缓存、异步、批处理等技术，而这些在实现时多依赖定时任务。所以顺着定时任务扒，很容易弄懂 Eureka 的设计架构和高性能原理。

Eureka 在架构上主要围绕以下几点方面做文章：
1. 围绕 Get 类请求，如获取应用列表和详情，Eureka 支持增量（delta） 获取，同时设置 2 级服务端缓存和客户端缓存，大幅度减少了核心 Registry 的并发度，带来了更少的带宽消耗和更低的延迟。
2. 针对集群 Peer replication，每个 Peer Node 启用独立异步线程组，其一是异步处理，快速响应客户端请求，其二是实例信息批量同步，可以有效提高吞吐；最后则是使用舱壁模式隔离 Peer Node，这样即使某个 Peer Node 出现响应过慢或者无响应，并不会因线程耗尽而影响其他 Peer Node 接收信息同步。
3. 围绕定时淘汰未续租过期实例功能，设计实现了灵活可配置的自我保护模式，可以解决网络分区问题，提高集群可用性

<img src="/img/2020-04/eureka-draft.jpg" width="500px">

## let's go
启动 Eureka server，将其注册到某个集群，启动后，可通过 jstack <pid> 得到如下线程列表：

```text
// Eureka Server 任务线程
Eureka-CacheFillTimer
Eureka-DeltaRetentionTimer
Eureka-EvictionTimer
ReplicaAwareInstanceRegistry - RenewalThresholdUpdater
Eureka-MeasureRateTime
--- Peers ---
Eureka-PeerNodesUpdater
TaskAcceptor-peer1,TaskNonBatchingWorker-peer1-0 // AWS ASG
TaskAcceptor-peer2,TaskNonBatchingWorker-peer2-0 // AWS ASG
TaskAcceptor-target_peer1
TaskBatchingWorker-target_peer1-0
... 省略 1-18
TaskBatchingWorker-target_peer1-19
TaskAcceptor-target_peer2
TaskBatchingWorker-target_peer2-0
... 省略 1-18
TaskBatchingWorker-target_peer2-19

// Eureka Client 任务线程
DiscoveryClient-0
DiscoveryClient-1
DiscoveryClient-InstanceInfoReplicator-0
DiscoveryClient-HeartbeatExecutor-0
DiscoveryClient-CacheRefreshExecutor-0
AsyncResolver-bootstrap-0

// Eureka HTTP Transport 任务线程
Eureka-JerseyClient-Conn-Cleaner
```

## Server
以下定时任务处理 Get 请求 2 级缓存和增量 delta 队列
* Eureka-CacheFillTimer
* Eureka-DeltaRetentionTimer

以下定时任务处理 Peer Replication
* TaskAcceptor-target_peer*
* TaskBatchingWorker-target_peer*-0 至 TaskBatchingWorker-target_peer*-19
* TaskAcceptor-peer*,TaskNonBatchingWorker-peer*-0

以下定时任务处理过期实例淘汰及自我保护
* Eureka-EvictionTimer
* ReplicaAwareInstanceRegistry - RenewalThresholdUpdater
* Eureka-MeasureRateTime

注：以下标题中的 task 名均省去了 `Eureka-` 前缀 (如果有) 。
### CacheFillTimer
CacheFillTimer 定时任务的作用就是每 30s 从 readWriteCache 同步一次实例信息至 readOnlyCache，
实现细节见 com.netflix.eureka.registry.ResponseCacheImpl。
<img src="/img/2020-04/eureka-response-cache.jpg" width="700px">
{{% center %}}
请求——2 级响应缓存——Registry 流转逻辑
{{% /center %}}

默认情况下 Eureka， 开启使用 2 级缓存提高实例获取性能，只有当 2 层缓存均不存在实例信息时，才会从 InstanceRegistry 获取注册信息，路径 /{version}/apps/ 下的 GET 请求均会被缓存。

```java
// 使用 java.util.Timer 定时执行
// 每 30s 从 readWriteCacheMap 同步
if (shouldUseReadOnlyResponseCache) {
  timer.schedule(getCacheUpdateTask(),
          new Date(((System.currentTimeMillis() / responseCacheUpdateIntervalMs) * responseCacheUpdateIntervalMs)
                  + responseCacheUpdateIntervalMs),
          responseCacheUpdateIntervalMs);
}
```
根据 2 级响应缓存时效，结合后文会提到的客户端缓存时长 30s，可以量化 Eureka 的弱一致性。

假设某个实例在退出前取消注册，server 会 invalidate readWriteCache，因此最长存在 60s(readOnlyCache 30s + clientCache 30s) 延迟；假设某个实例在发送完 heart-beat 后立刻退出且没取消注册，那么可能存在 120s 延迟(readOnlyCache 30s + evict every 60s + clientCache 30s)。即使禁用 readOnlyCache，最大也会存在 90s 延迟。

该定时任务对应配置如下，readOnlyCache 可以通过 `eureka.server.use-read-only-response-cache` 禁用（CacheFillTimer定时任务也随之被禁用），readwriteCache 无法被禁用。

```yaml
eureka:
  server:    
    use-read-only-response-cache: true
    response-cache-auto-expiration-in-seconds: 180 # readWriteCache 180s 过期
    response-cache-update-interval-ms: 30000 # 30s readOnlyCache 30s 同步
    initial-capacity-of-response-cache: 1000 # readWriteCache 容量
```


### DeltaRetentionTimer
Eureka client 向 server 获取实例列表时，一般会使用增量获取而非全量，这样做可以减少传输数据量、并降低响应时间。

com.netflix.eureka.registry.AbstractInstanceRegistry 使用 recentlyChangedQueue（ConcurrentLinkedQueue<RecentlyChangedItem>) 保存了最近变更的应用信息，支持 EurekaClient 获取增量注册信息。

注：delta 层注册、续租、下线等状态与核心 Map 存储同步更新，不存在滞后性。

默认情况下，定时任务每 30s 执行一次，超过 180s 未更新的实例将被清理，可通过 `eureka.server.retention-time-in-m-s-in-delta-queue` 控制保存时长。

如果 `eureka.server.disable-delta=true`，定时任务仍旧照常执行，只不过，Eureka server 在接到  get delta 请求时，会把它重定向到 get all。

```java
// 任务随 AbstractInstanceRegistry 构造函数启动调度
this.deltaRetentionTimer.schedule(getDeltaRetentionTask(),
      serverConfig.getDeltaRetentionTimerIntervalInMs(),
      serverConfig.getDeltaRetentionTimerIntervalInMs());
// timer task
public void run() {
  Iterator<RecentlyChangedItem> it = recentlyChangedQueue.iterator();
  while (it.hasNext()) {
      if (it.next().getLastUpdateTime() <
              System.currentTimeMillis() - serverConfig.getRetentionTimeInMSInDeltaQueue()) {
          it.remove();
      } else {
          break;
      }
  }
}
```
相关配置如下
```yaml
eureka:
  server:
    disable-delta: false
    # 废弃功能配置，早期实现会在本地获取不到 delta 时，会向所有远程实例获取 delta
    # 现在 Eureka server 会客户端声明远程 Region 列表决定是否向远程实例获取 delta
    # disable-delta-for-remote-regions: false 
    delta-retention-timer-interval-in-ms: 30000 # 定时任务每 30s 执行一次
    retention-time-in-m-s-in-delta-queue: 180000 # 清理超过 3 分钟未更新的实例
```

### TaskAcceptor & TaskBatchingWorker

Eureka server 针对每个集群节点(Peer Node)，都会启动 1 组线程批量处理集群实例信息同步，同步范围包括实例 register、cancel、heartbeat、statusUpdate 和 deleteStatusOverride，这部分逻辑集中在 com.netflix.eureka.cluster.PeerEurekaNode。

线程组包含 1 个 Acceptor 线程加上若干 Worker 线程（默认 20，通过 `eureka.server.max-threads-for-peer-replication` 设置）
```yaml
eureka:
  server:
    max-elements-in-peer-replication-pool: 10000 # pending task queue 最大容量
    max-threads-for-peer-replication: 20 # batch 线程数量
```

Acceptor 在设计上使用了 3 级队列，第 1 级包括了最新的实例变更信息，没有显式设置容量限制。

- Eureka server PeerAwareInstanceRegistry 实现在接到客户端请求后，先写本地 registry，随之将变更提交到 Acceptor 对象的 accept queue (通过 PeerEurekaNode 实现），请求即立刻返回客户端，实际同步采用批处理方式完成。
- Acceptor daemon 线程不断尝试从 accept queue 获取任务并转至第 2 级的 pending task queue（实现上是 LinkedList + HashMap），pending task queue 容量默认 10,000，由 `eureka.server.max-elements-in-peer-replication-pool` 设置，超过容量后，使用 FIFO 方式丢弃任务。
- 同时，每当 pending queue 任务数量到达容量阈值 (10,000)，或者每隔 500ms，Acceptor daemon 线程会将任务成批打包成 List（容量上限 250，写死无法配置），放置到 3 级队列 batch work queue 中。所有 Worker 线程共享该 3 级队列， JDK BlockQueue 为线程安全实现。Worker 线程不断尝试从 batch work queue  获取到 batch List 后，使用封装好的 HTTP Transport 实现将状态传递给集群其他节点。

<img src="/img/2020-04/eureka-batch-replica-internal.jpg" width="500px">

每个 Peer Node 使用 20 线程处理信息同步，对于小集群来说可能比较浪费，可根据实际情况调整线程数量。

### TaskAcceptor & TaskNonBatchingWorker
TaskNonBatchingWorker 其实就是 TaskBatchingWorker batch size 为 1 的特殊情况，netflix 专门用于处理 AWS Autoscaling group(ASG）变更同步，不使用 ASG 就用不到。

其对应配置如下

```yaml
eureka:
  server:
    max-threads-for-status-replication: 1 # batch 线程数量
    max-elements-in-status-replication-pool: 10000 # pending task queue 最大容量
```

### Evict 任务 

1. 主任务 EvictionTimer
---
对于未能在租期（默认 90s）通过心跳请求续租的实例，Eureka 使用定时任务，执行清理工作，实现在 com.netflix.eureka.registry。AbstractInstanceRegistry$EvictionTask。

租期淘汰任务执行频率由 `eureka.server.eviction-interval-timer-in-ms` 控制，默认 60s 一次。

Eureka 实现了名为「自我保护」的功能，用来检测网络分裂（[network partition](https://en.wikipedia.org/wiki/Network_partition))这类问题。如果关闭了自我保护，直接执行清理；如果开启了自我保护，会使用结合辅助任务 RenewalThresholdUpdater 和 MeasureRateTimer → renewsLastMin 判断是否停止清理注册实例。

```yaml
eureka:
  sever:
    eviction-interval-timer-in-ms: 60000 # 默认 60s 一次
```

2. 辅助任务 RenewalThresholdUpdater
---
用来更新自我保护开启阈值，实现见 com.netflix.eureka.registry.ReplicaAwareInstanceRegistry。

自我保护开启时(`enable-self-preservation=true`)，默认每 15 分钟更新一次续约刷新阈值，如果 eureka 每分钟收到的心跳数量小于阈值 **注册instances数量x2x0.85**，便会开启自我保护，不再淘汰实例。

相关配置如下，值得注意的是，即使关闭自我保护，该任务仍旧会定时执行。
```yaml
eureka:
  server:
     enable-self-preservation: true # 是否开启自我保护
     renewal-percent-threshold: 0.85 # renew-interval 注册实例预期心跳比例
     expected-client-renewal-interval-seconds: 30 # 实例心跳间隔
     renewal-threshold-update-interval-ms: 900000 # 15 分钟
```

3. 辅助任务 MeasureRateTimer → renewsLastMin
---
默认记录并定期更新当前 60s 和上一 60s 注册实例的续租次数，见 com.netflix.eureka.registry.AbstractInstanceRegistry 属性 renewsLastMin，使用实现类 MeasuredRate 存储注册实例租约刷新次数，每 60s 更新上一分钟的租约刷新次数，供 Registry 实现判断是否需开启自我保护之用。

### PeerNodesUpdater
实现见 com.netflix.eureka.cluster.PeerEurekaNodes#start。

作用是动态更新 Peer 节点列表，当配置 `eureka.client.serviceUrl` 和 `eureka.client.availability-zones` 发生变化时，动态更新通信集群节点，对应配置如下
```yaml
eureka:
  server:
    peer-eureka-nodes-update-interval-ms: 600000 # 10*60*1000，默认 10 分钟执行一次，启动延迟 10 分钟
eureka:
  client:
    serviceUrl: 
      defaultZone: http://peer1:8761/eureka/,http://peer2:8762/eureka/
  availability-zones:
    shanghai: defaultZone
  region: shanghai
```

### MeasureRateTimer → numberOfReplicationsLastMin

com.netflix.eureka.registry.PeerAwareInstanceRegistryImpl  定时任务，属性 numberOfReplicationsLastMin。
使用实现类 MeasuredRate 存储 peer 节点同步实例数量，每 60s 更新上一分钟的同步次数，供监控使用。

## Client
以下线程任务处理客户端缓存更新
* DiscoveryClient-0
* DiscoveryClient-CacheRefreshExecutor-0

以下线程任务处理实例续租
* DiscoveryClient-1
* DiscoveryClient-HeartbeatExecutor-0

DiscoveryClient-InstanceInfoReplicator-0 处理服务状态更新，AsyncResolver-bootstrap-0 处理 Eureka Server 节点更新。

Eureka Client 在处理缓存定时更新和定时心跳续租时，采用双级线程池模式，里层线程池定时执行业务逻辑，外层线程池处理超时（超时时间等于执行间隔，实现见 com.netflix.discovery.TimedSupervisorTask)，所以各需要 2 个线程。如果频繁超时导致任务积压，可能会启动临时业务线程 DiscoveryClient-CacheRefreshExecutor-1 和 DiscoveryClient-HeartbeatExecutor-1。

Eureka client 核心类为 **com.netflix.discovery.DiscoveryClient**，它在构造时会根据配置启动一系列定时任务。

```yaml
eureka:
  client:
    registerWithEureka: true # 是否注册到 Eureka server
    fetchRegistry: true # 是否向 Eureka server 获取注册实例
    heartbeat-executor-thread-pool-size: 2
    cache-refresh-executor-thread-pool-size: 2
```

### CacheRefresh

集群应用列表获取任务，，一般由 scheduler DiscoveryClient-0 线程管理，由 DiscoveryClient-CacheRefreshExecutor-0 或 DiscoveryClient-CacheRefreshExecutor-1 执行，默认 30s 一次。

当 `eureka.client.registerWithEureka=false` 时，不会启动该任务。

可以通过 `eureka.client.registry-fetch-interval-seconds` 设置执行频率，默认 30s 一次。

### heartbeat

心跳续租任务，一般由 scheduler DiscoveryClient-1 线程管理，由 DiscoveryClient-HeartbeatExecutor-0 或 DiscoveryClient-HeartbeatExecutor-1 执行，默认 30s 一次。

当 `eureka.client.registerWithEureka=false` 时，不会启动该任务。

可以通过 `eureka.instance.lease-expiration-duration-in-seconds` 调整租期，默认 90s。

可以通过 `eureka.instance.lease-renewal-interval-in-seconds` 调整心跳频率，默认 30s/次。

### InstanceInfoReplicator

处理实例状态变更（通过  ApplicationInfoManager#setInstanceStatus），如从 UP 变为其状态 {DOWN，STARTING，OUT_OF_SERVICE，UNKNOWN}，ApplicationInfoManager 的StatusChangeListener 会向 InstanceInfoReplicator 提交变更任务。

也就是说，实例状态变更和 heartbeat 续租分属不同逻辑分支。

InstanceInfoReplicator 经过一些 RateLimiter 策略判断后，会调用 DiscoveryClient#register 向 Eureka 重新注册应用状态。

主要用于实例上下线

```java
public synchronized void setInstanceStatus(InstanceStatus status) {
    InstanceStatus next = instanceStatusMapper.map(status);
    if (next == null) {
        return;
    }

    InstanceStatus prev = instanceInfo.setStatus(next);
    if (prev != null) {
        for (StatusChangeListener listener : listeners.values()) {
            try {
                listener.notify(new StatusChangeEvent(prev, next));
            } catch (Exception e) {
                logger.warn("failed to notify listener: {}", listener.getId(), e);
            }
        }
    }
}

statusChangeListener = new ApplicationInfoManager.StatusChangeListener() {
    @Override
    public String getId() {
        return "statusChangeListener";
    }

    @Override
    public void notify(StatusChangeEvent statusChangeEvent) {
        if (InstanceStatus.DOWN == statusChangeEvent.getStatus() ||
                InstanceStatus.DOWN == statusChangeEvent.getPreviousStatus()) {
            // log at warn level if DOWN was involved
            logger.warn("Saw local status change event {}", statusChangeEvent);
        } else {
            logger.info("Saw local status change event {}", statusChangeEvent);
        }
        instanceInfoReplicator.onDemandUpdate();
    }
};
```

### AsyncResolver-bootstrap-0

逻辑入口 scheduleServerEndpointTask#scheduleServerEndpointTask

任务位置 AsyncResolver#updateTask

Client 端 Eureka Service 列表定时更新任务，不断读取内存配置并尝试更新 Eureka Service 列表，默认 5 分钟执行一次，无法禁止，可以使用 `eureka-service-url-poll-interval-seconds` (默认 300s) 控制执行间隔。

## Transport

Eureka Server 或 Eureka Client 部分均使用 JerseyClient HTTP Transport 抽象（实现为 Apache HttpClient）处理实例信息复制或实例信息注册，每个 Eureka 相关实例（包括自己）均对应一个独立的 Transport Client。

对每个 Transport Client，Eureka 均会启动 Eureka-JerseyClient-Conn-Cleaner 线程清理空闲 HTTP 连接，任务位置 com.netflix.discovery.shared.transport.jersey.ApacheHttpClientConnectionCleaner#cleanIdle(long  delayMs)。

定时任务每 30s 执行一次，无法修改频率，无法被关闭。默认情况下，超过 30s 未活动连接将被关闭。可以通过 `eureka.client.eureka-connection-idle-timeout-seconds` 调整闲置时间阈值。