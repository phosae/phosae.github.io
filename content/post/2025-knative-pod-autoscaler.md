---
title: "Dive into Knative Pod Autoscaler"
date: 2025-04-09T20:25:29+08:00
lastmod: 2025-04-09T23:25:29+08:00
draft: false
keywords: ["serverless", "autoscaler", "container"]
description: "Understanding the Knative Pod Autoscaler (KPA) and its scaling mechanisms"
tags: ["en", "serverless", "autoscaler", "container"]
author: "Zeng Xu"
summary: "Understanding the Knative Pod Autoscaler (KPA) and its scaling mechanisms"

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

The Knative Pod Autoscaler (KPA) acts on metrics, concurrency or requests per second (RPS), which are aggregated over time-based windows.

There're two types of buckets used to gather metrics: stable bucket and panic bucket.
- The stable bucket has a configurable window size, with a default of 60 seconds.
- The panic bucket has a smaller window size, which can be 1-100% of the stable window size, with a default of 10%.

In each scaling loop, the autoscaler first calculates the `observedStableValue` from the stable bucket and the `observedPanicValue` from the panic bucket by calling the `WindowAverage` function. 
The `WindowAverage` function returns an exponential weighted average, where more recent items have a greater impact on the average than older ones.

In the example below, the concurrency of the target service over the last 10 seconds is [1, 3, 5, 4, 6, 7, 2, 8, 10, 20] (newest last):

    now := time.Now()
    stableBucket := NewWeightedFloat64Buckets(10*time.Second, time.Second)
    panicBucket := NewWeightedFloat64Buckets(3*time.Second, time.Second)
    for i, conc := range []float64{1, 3, 5, 4, 6, 7, 2, 8, 10, 20} { // record concurrency
        stableBucket.Record(now.Add(time.Duration(i+1)*time.Second), conc)
        panicBucket.Record(now.Add(time.Duration(i+1)*time.Second), conc)
    }
    fmt.Println("stableBuckt.WindowAverage = ", stableBucket.WindowAverage(now.Add(10*time.Second)))
    fmt.Println("panicBucket.WindowAverage = ", panicBucket.WindowAverage(now.Add(10*time.Second)))
    // stableBuckt.WindowAverage =  15.430728028666296
    // panicBucket.WindowAverage =  19.530732247258655

windowAverage of stableBucket is 15.43, windowAverage of panicBucket is 9.53.
As we can see, the panic bucket is more sensitive to burst traffic.

The autoscaler then calculates two desired pod counts: `desiredStablePodCount` and `desiredPanicPodCount` using the formula:

    desiredPodCount = observedValue/TargetValue

where `TargetValue` is the concurrency per pod that we aim to maintain (typically 70% of the maximum value).

When `desiredPanicPodCount/currentReadyPodsCount >= PanicThreshold` (e.g., 21/10 >= 2.0), the autoscaler enters panic mode for a stable window time. During this period, the `desiredPodCount` is based on `desiredPanicPodCount`.

In panic mode, the service can only be scaled up, not down.

Under normal conditions, the `desiredPodCount` is based on `desiredStablePodCount`, and the target service can be scaled both up and down. 

For scale-down operations, there is a `delayWindow` that defers scale-down decisions until a window has passed at the reduced concurrency.

In summary, KPA is designed to be:
- Aggressive for scaling up (panic mode)
- Conservative for scaling down (delayWindow)

Additional scaling bounds include:
- Minimum and maximum replicas (`minReplica`/`maxReplica`)
- Maximum scale-up rate (`maxScaleUpRate`)
- Maximum scale-down rate (`maxScaleDownRate`)

For more information about scale-to-zero functionality, refer to the [Knative Serving Autoscaling System](https://github.com/knative/serving/blob/main/docs/scaling/SYSTEM.md) documentation.
