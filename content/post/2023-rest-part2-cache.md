---
title: "REST: Part 2 - HTTP 缓存"
date: 2023-04-07T14:59:31+08:00
lastmod: 2023-04-12T14:59:31+08:00
draft: false
keywords: ["REST","HTTP","Cache"]
description: ""
tags: ["REST","HTTP","Cache"]
author: "Zeng Xu"
summary: "HTTP REST 缓存简述"

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

本文为 REST 系列第二篇
- [Part 1 - HTTP API 设计思路](../2023-rest-part1-api)
- Part 2 - 缓存（本文）

## Cache
在 REST 设计中使用缓存可以缩短响应时间、节约网络带宽。

> A "cache" is a local store of previous response messages and the
   subsystem that controls its message storage, retrieval, and deletion.
   A cache stores cacheable responses in order to reduce the response
   time and network bandwidth consumption on future, equivalent
   requests.  Any client or server MAY employ a cache, though a cache
   cannot be used while acting as a tunnel.
> —— [RFC9110#section-3.8](https://www.rfc-editor.org/rfc/rfc9110#section-3.8)

HTTP 缓存契合 REST Cacheability 原则。

> The effect of a cache is that the request/response chain is shortened
   if one of the participants along the chain has a cached response
   applicable to that request.  The following illustrates the resulting
   chain if B has a cached copy of an earlier response from O (via C)
   for a request that has not been cached by UA or A.
> —— [RFC9110#section-3.8](https://www.rfc-editor.org/rfc/rfc9110#section-3.8)

               >             >
          UA =========== A =========== B - - - - - - C - - - - - - O
                     <             <

                                  Figure 3

[RFC 9111: HTTP Caching] 提供了 HTTP 缓存标准，也可以翻阅文章快速了解控制原理 [MDN: HTTP caching]，[Increasing Application Performance with HTTP Cache Headers] 和 [Things Caches Do]。

以 Figure 3 为例，当 B 首次通过 C 访问 O 某资源时，O 在响应中包含 `Cache-Control` Header 时，触发 HTTP 中间服务器（如 Proxy、CDN）的缓存功能

```shell
HTTP/1.1 200 OK
Content-Type: text/html
Content-Length: 1024
Date: Tue, 22 Feb 2022 22:22:22 GMT
Cache-Control: max-age=604800
```
示例响应提示 HTTP 客户端缓存内容，假设 C 没有实现缓存功能，按照 [RFC 9111: HTTP Caching Section-5.2](https://www.rfc-editor.org/rfc/rfc9111#section-5.2#section-5.2) 要求，会将 `Cache-Control` Header 透传给 B。B 收到响应后，会缓存结果 1 星期（max-age 单位为秒）。

> A proxy, whether or not it implements a cache, 
> MUST pass cache directives through in forwarded messages, 
> regardless of their significance to that application, 
> since the directives might apply to all recipients along the request/response chain. 
> It is not possible to target a directive to a specific cache.

后续 A 访问 B 时，会收到这样的响应

```shell
HTTP/1.1 200 OK
Content-Type: text/html
Content-Length: 1024
Date: Tue, 22 Feb 2022 22:22:22 GMT
Cache-Control: max-age=604800
Age: 86400
```
多出的 `Age` Header 字段表示 B 已缓存资源对象 86400 秒，`604800 - 86400 = 518400` 表示在 518400 秒内对象为 `fresh`，即缓存状态有效、未过期。

老的 HTTP 1.0 缓存服务器可能使用 `Expires: Tue, 28 Feb 2022 22:22:22 GMT` 控制缓存有效期，原理和 `Cache-Control: max-age=604800` 类似，也表示缓存 1 星期，但会有更难解析和系统时钟不准确的问题。

从客户端到服务端方向，HTTP 同样提供了一套缓存检验机制和刷新机制，分别是 
- If-Modified-Since 和 Last-Modified
- ETag/If-None-Match

Cache 端实现在资源到期后收到请求，会向上游服务器发起校验，必要时会刷新缓存，具体查看 [MDN: HTTP caching]

缓存由资源对象和指向资源对象的 cache key 组成，cache key
- 最小限度 = Method + URI，但由于大部分缓存实现仅缓存 GET 响应，因此最短 cache key 也可能等同于 URI
- 单个 URI 可能有多种表现形式（如 json, yaml, text），Response 可以使用 Vary Header 声明应包含在 cache key 中的 Headers，如
  ```
  Vary: accept-encoding, accept-language
  ```
- 云服务如 [AWS API Gateway](https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-caching.html) 支持用户自由选择 custom headers, URL paths, or query strings 组成 cache key

> The "cache key" is the information a cache uses to choose a response
   and is composed from, at a minimum, the request method and target URI
   used to retrieve the stored response; the method determines under
   which circumstances that response can be used to satisfy a subsequent
   request.  However, many HTTP caches in common use today only cache
   GET responses and therefore only use the URI as the cache key.

> A cache might store multiple responses for a request target that is
   subject to content negotiation.  Caches differentiate these responses
   by incorporating some of the original request's header fields into
   the cache key as well, using information in the Vary response header
   field, as per [Section 4.1](https://www.rfc-editor.org/rfc/rfc9111#section-4.1).

[RFC9110#section-9.2.3](https://www.rfc-editor.org/rfc/rfc9110#section-9.2.3) 指出 GET，HEAD 和 POST 可支持缓存。

> This specification defines caching semantics for GET, HEAD, and POST, although the overwhelming majority of cache implementations only support GET and HEAD.

规范提及，被缓存的 POST 响应可以服务于接下来的 GET 或 HEAD 请求（但不一定所有的 HTTP 客户端都支持了该特性）。

> Responses to POST requests are only cacheable when they include explicit freshness information (see [Section 4.2.1 of RFC9111](https://www.rfc-editor.org/rfc/rfc9111#section-4.2.1)) 
   and a Content-Location header field that has the same value as the POST's target URI ([Section 8.7](https://www.rfc-editor.org/rfc/rfc9110#section-8.7)). 
   A cached POST response can be reused to satisfy a later GET or HEAD request. 
   In contrast, a POST request cannot be satisfied by a cached POST response because POST is potentially unsafe; 
   see [Section 4 of RFC9111](https://www.rfc-editor.org/rfc/rfc9111#section-4).

大多实现只缓存状态码为 200 (OK) 的 GET 请求响应。小部分实现也可能支持缓存 206 (Partial Content)、301 302（Redirects）、404 (Not Found)，也可能支持 POST 和 HEAD。
  
> Most commonly, caches store the successful result of a retrieval
   request: i.e., a 200 (OK) response to a GET request, which contains a
   representation of the target resource ([Section 9.3.1 of HTTP](https://www.rfc-editor.org/rfc/rfc9110#section-9.3.1)).
   However, it is also possible to store redirects, negative results
   (e.g., 404 (Not Found)), incomplete results (e.g., 206 (Partial
   Content)), and responses to methods other than GET if the method's
   definition allows such caching and defines something suitable for use
   as a cache key.

现今 Web 服务多采用前后端分离的架构。

这样静态文件，包括前端代码（HTML、CSS、JS 等）、图片、视频，可以使用 NGINX 等服务器托管并开启缓存控制。规模更大场景更复杂的情况，可以使用 [AWS S3](https://aws.amazon.com/s3/) 等 Object Storage 存放图片、视频，结合 CDN (content delivery networks)、大型 In-Memory Cache（如 [Redis]）做统一分发 [[1]][[2]][[3]]。

> There is a wide variety of architectures and configurations of caches
   deployed across the World Wide Web and inside large organizations.
   These include national hierarchies of proxy caches to save bandwidth
   and reduce latency, content delivery networks that use gateway
   caching to optimize regional and global distribution of popular
   sites, collaborative systems that broadcast or multicast cache
   entries, archives of pre-fetched cache entries for use in off-line or
   high-latency environments, and so on.
>
> —— [RFC9110#section-3.8](https://www.rfc-editor.org/rfc/rfc9110#section-3.8)

类似地，后端 REST JSON API 同样可以借鉴此原理，由统一网关集中控制缓存，类似 AWS API Gateway [[4]]。很多公司会使用 [Redis] 集群构建大型 In-Memory Cache，由源 Server 实现缓存控制逻辑，同时禁用 HTTP 缓存，它们的响应会集中采用此 HTTP Caching 语义（或部分）

    Cache-Control: no-cache, no-store, must-revalidate
    Pragma: no-cache
    Expires: 0

不是所有的服务都有低延迟高吞吐需求，使用分布式缓存会提高系统复杂度。很多情况下，仅使用服务进程内的 In-Memory Cache 或者 DiskCache，甚至乎利用好数据库实现的缓存功能，写出服务就已足够快速。


[1]: https://cloud.google.com/storage/docs/caching
[2]: https://learn.microsoft.com/en-us/azure/architecture/best-practices/caching
[3]: https://docs.aws.amazon.com/whitepapers/latest/s3-optimizing-performance-best-practices/using-caching-for-frequently-accessed-content.html
[4]: https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-caching.html
[RFC 9111: HTTP Caching]: https://www.rfc-editor.org/rfc/rfc9111
[MDN: HTTP caching]: https://developer.mozilla.org/en-US/docs/Web/HTTP/Caching
[Increasing Application Performance with HTTP Cache Headers]: https://devcenter.heroku.com/articles/increasing-application-performance-with-http-cache-headers
[Things Caches Do]: https://tomayko.com/blog/2008/things-caches-do
[Redis]: https://redis.io/

## 参考链接
- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110)
- [RFC 9111: HTTP Caching](https://www.rfc-editor.org/rfc/rfc9111)
- [MDN: HTTP caching](https://developer.mozilla.org/en-US/docs/Web/HTTP/Caching)
- [Increasing Application Performance with HTTP Cache Headers](https://devcenter.heroku.com/articles/increasing-application-performance-with-http-cache-headers)
- [Things Caches Do](https://tomayko.com/blog/2008/things-caches-do)
