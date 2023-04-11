---
title: "REST API 设计备忘"
date: 2023-04-05T15:28:41+08:00
lastmod: 2023-04-05T15:28:41+08:00
draft: true
keywords: ["REST","HTTP"]
description: ""
tags: ["REST","HTTP"]
author: "Zeng Xu"
summary: "HTTP REST API 通用设计思路摘录"

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
  enable: true
  options: ""

sequenceDiagrams: 
  enable: true
  options: "{theme: 'hand'}"
---

## What is REST

REST, stands for **RE**presentational **S**tate **T**ransfer, proposed by Roy Fielding in his 2000 PhD dissertation[[1]], is an architectural approach to designing web services. APIs that follow the REST architectural style are called REST/RESTful APIs. Web services that implement REST architecture are called RESTful web services. The term RESTful API generally refers to RESTful web APIs[[2]].

Roy Fielding 为 REST 架构提出了 6 大设计准则/约束 (constraints):
1. Client-Server
2. Stateless
3. Cache
4. Uniform Interface
5. Layered System
6. Code on demand (optional)

按照重要程度调整顺序展开各项如下[[2]]

**Uniform Interface** is fundamental to the design of any RESTful webservice. It indicates that the server transfers information in a standard format. The formatted resource is called a **representation** in REST. This format can be different from the internal representation of the resource on the server application. For example, the server can store data as text but send it in an HTML representation format.Uniform interface helps to decouple the client and service implementations.

Uniform interface imposes four architectural constraints:

1. Requests should identify resources. They do so by using a uniform resource identifier.
2. Clients have enough information in the resource representation to modify or delete the resource if they want to. The server meets this condition by sending metadata that describes the resource further.
3. Clients receive information about how to process the representation further. The server achieves this by sending self-descriptive messages that contain metadata about how the client can best use them.
4. Clients receive information about all other related resources they need to complete a task. The server achieves this by sending hyperlinks in the representation so that clients can dynamically discover more resources.

**Stateless**ness refers to a communication method in which the server completes every client request independently of all previous requests. Clients can request resources in any order, and every request is stateless or isolated from other requests. This REST API design constraint implies that the server can completely understand and fulfill the request every time. 

In a **Layered System** architecture, the client can connect to other authorized intermediaries between the client and server, and it will still receive responses from the server. Servers can also pass on requests to other servers. You can design your RESTful web service to run on several servers with multiple layers such as security, application, and business logic, working together to fulfill client requests. These layers remain invisible to the client.

**Cacheability**: RESTful web services support caching, which is the process of storing some responses on the client or on an intermediary to improve server response time. For example, suppose that you visit a website that has common header and footer images on every page. Every time you visit a new website page, the server must resend the same images. To avoid this, the client caches or stores these images after the first response and then uses the images directly from the cache. RESTful web services control caching by using API responses that define themselves as cacheable or noncacheable.

**Code on demand (optional)**: In REST architectural style, servers can temporarily extend or customize client functionality by transferring software programming code to the client. For example, when you fill a registration form on any website, your browser immediately highlights any mistakes you make, such as incorrect phone numbers. It can do this because of the code sent by the server.


**Client-Server** 架构分离准则看似毫无必要提及，因为它在今日已被广泛采用。但 2000 可是一个 PHP 和 Java Server Pages(JSP) 主导网站开发的年代，提出这点很有前瞻性。如 Roy Fielding 所言
> By separating the user interface concerns from the data storage concerns, we improve the portability of the user interface across multiple platforms and improve scalability by simplifying the server components. Perhaps most significant to the Web, however, is that the separation allows the components to evolve independently, thus supporting the Internet-scale requirement of multiple organizational domains.

## REST over HTTP

REST 架构并不依赖于任何底层协议，目前大部分 REST API 实现的应用层协议为 HTTP。在此，**Uniform Interface** 首先意味着
- 不论 Server 以何种格式存储数据，Client 端以何种方式应用或展现数据，它们之间按固定格式传输数据，如 HTML, JSON，XML，JPEG，MP4

应用与之相随的 `four architectural constraints` 就产生了一些基本设计准则
1. 围绕资源设计 API，比如 URI `example.com/orders` 表示订单集合 (collection of orders), URI `example.com/orders/1` 表示 id 为 1 的某特定订单 (particular order with `id=1`)
2. 使用标准的 HTTP verbs 操作资源，如 GET, POST, PUT, PATCH, and DELETE

应用 1,2 之后，客户端拿到 URL `example.com/orders`，几乎不需要额外信息就可以这样操作资源
- `GET example.com/orders`，获取所有订单列表
- `GET example.com/orders/{orderId}`，进一步获取订单详情
- `DELETE example.com/orders or example.com/orders/{orderId}`，删除订单资源

假设获取到 id=1 的订单信息为如下 JSON
```json
{"orderId":1,"orderValue":99.90,"productId":1,"quantity":1}
```
便可以推断出如何创建订单
- `POST example.com/orders -d '{"orderValue":9.9,"productId":2,"quantity":3}'`

以及如何更新订单
- `PUT example.com/orders/1 -d '{"orderValue":100,"productId":1,"quantity":1}'`

REST 中 URI + HTTP verbs 的方式约定化了资源定位及资源操作，基于这种风格设计的 API 自表达，易理解，沿着 GET 操作可以推断出所有资源的操作方式。这也是 `POST example.com/orders` 好过 `POST example.com/create-order` 的原因，创建操作约定化到了 HTTP POST 中，减少了记忆负担。而大部分资源只需 POST(C) GET(R) PUT/PATCH(U) DELETE(D) 就够了。

2008 年, Leonard Richardson 提出了有关 Web API 的[成熟度模型](https://martinfowler.com/articles/richardsonMaturityModel.html)
- Level 0: Define one URI, and all operations are POST requests to this URI.
- Level 1: Create separate URIs for individual resources.
- Level 2: Use HTTP methods to define operations on resources.
- Level 3: Use hypermedia (HATEOAS, described below).

大部分 REST Web API 都只达到了 Level 2。

达到 Level 3 HATEOAS(**H**ypertext **a**s **t**he **E**ngine **o**f **A**pplication **S**tate) 的 API 有更强的自我表达能力，比如订单详情可以再包含 links 数组，指向关键的客户资源及操作方式

```json
{
    "orderID":3,
    "productID":2,
    "quantity":4,
    "orderValue":16.60,
    "links": [
        {"rel":"product","href":"https://example.com/customers/3", "action":"GET" },
        {"rel":"product","href":"https://example.com/customers/3", "action":"PUT" }
    ]
}
```
一套达到 Level 3 的 REST API，只需对某几 URI 执行 GET 操作，而无需要任何文档，即可以探索出所有 URIs 及其所有操作方式。

## URL 设计

Google API 格式
```
https://<service>.googleapis.com/(<service>/)<version>/{resource/path}
```

Gmail API 示例 [[3]]
- users/{userId}/profile --> `https://gmail.googleapis.com/gmail/v1/users/{userId}/profile`
- users/{userId}/messages/{id} --> `https://gmail.googleapis.com/gmail/v1/users/{userId}/messages/{id}`
- users/{userId}/labels/{id} --> `https://gmail.googleapis.com/gmail/v1/users/{userId}/labels/{id}`

Cloud Pub/Sub API 示例 [[4]]
- projects/{project}/topics/{topic}/ --> `https://pubsub.googleapis.com/v1/projects/{project}/topics/{topic}`
- projects/{project}/subscriptions/{sub} --> `https://pubsub.googleapis.com/v1/projects/{project}/subscriptions/{sub}`
- projects/{project}/topics/{topic}/subscriptions --> `https://pubsub.googleapis.com/v1/projects/{project}/topics/{topic}/subscriptions`

Gmail API 既在域名包含了服务名，又在 path 中包含了服务名。相比之下我更推崇 Cloud Pub/Sub API，它格式更为简洁。

[Microsoft Azure REST API Guidelines] 推荐这样定义 URL
```
https://<tenant>.<region>.<service>.<cloud>/<service-root>/<resource-collection>/<resource-id>?api-version=YYYY-MM-DD(-preview)
```
把 users 信息和 regions 信息放到了域名。对于 Azure 这类全球各地部署的云服务，这样做比较合理。实践中可以根据业务自行设计
- 如果服务会部署到每个机房，且只暴露给开发者，那么 `cn-huadong.myservice.example.com` 这种合理。但如果 API 面向用户，最好封装成 `myservice.example.com` 这类统一格式，由中间层路由到各区域域名。
- 如果服务只是单机房部署，则无此必要
- 用户信息可以放置在 Header 中，采用 Bearer Token, API keys, OAuth 之类的方式

Google 选择用 URL Path 存放 API Version，具有强制性，对代码来说路由友好。Microsoft Azure 则将 API Version 放到了 URL Query，变为可选参数，类似地还可放到 HTTP Header，如 [Github](https://docs.github.com/en/rest/overview/api-versions) `X-GitHub-Api-Version: 2022-11-28`。

看起来，URL Path 方式简单好实践一些。切记 URL Path 方式和 URL Query 方式更加缓存友好（同一 URL 指向同一资源），尤其在使用了缓存代理的大型系统中。

再谈 Resources 层级，[Azure/Architecture/Best Practices: RESTful web API design] 提倡
> Avoid requiring resource URIs more complex than collection/item/collection.

但 [Azure API](https://learn.microsoft.com/en-us/rest/api/azure/) 看起来就很长，比如虚拟机接口

```
GET https://management.azure.com/subscriptions/{subscriptionId} \
/resourceGroups/{resourceGroupName}/providers/Microsoft.Compute \
/virtualMachines/{vmName}?api-version=2022-11-01
```

应该说，只要资源从属明确，URL 长点也没关系，比如 Gmail 中大多资源都归属某用户（如 `users/*/messages/*`），Azure 中大部分资源归属在 `subscriptions/*/resourceGroups/*/providers/*`
- Gmail API 除去约定的 User，每一资源都很短，如 `profile`，`labels/*`，`messages/*`
- Azure 去除约定 subscriptions，resourceGroups，providers 后，每一资源也很短，如 `/virtualMachines/{vmName}` `/disks/{diskName}`

总之，把前缀当成约定俗成即可，关键要便于记忆和理解。

再举例说明，用 /customers/* 表示用户，用户拥有订单，订单含有产品，容易产生这样的 URIs
- /customers/1
- /customers/1/orders/99
- /customers/1/orders/99/products

仔细想想，如果订单并不严格属于用户，那么 /customers/1/orders/99 就很费解；而 products 只是关联于 orders，并无严格从属。拆散为这些 URLs 会更灵活一些
- /customers/1
- /customers/1/orders（支持查询用户的所有订单，列表返回
- /orders/99（但是订单详情走独立 Path
- /products (产品也走独立 Path

若资源从属不明确，一律采用短 URI 设计，这样资源之间关系简单，架构演进方便。

对于 orders has products 的场景，可以按照 HATEOAS 原则，在 JSON 对象中添加 links 数组提供对应链接。此外 [Kubernetes] 实现的 API 发现机制也有借鉴意义 —— 沿着服务根目录触发，可以遍历出所有的资源。

```shell
$ kubectl proxy
Starting to serve on 127.0.0.1:8001

$ curl 127.0.0.1:8001 # in another window/panel

{
  "paths": 
    "/api",
    "/api/v1",
    "/apis",
    "/apis/apps",
    "/apis/apps/v1",
    "/apis/authentication.k8s.io",
    "/apis/authentication.k8s.io/v1",
    "/apis/autoscaling",
    "/apis/autoscaling/v1",
    "/apis/autoscaling/v2",
    "/apis/batch",
    "/apis/batch/v1",
    "/apis/node.k8s.io",
    "/apis/node.k8s.io/v1",
    "/logs",
    "/metrics",
    "/version"
  ]
}

$ curl 127.0.0.1:8001/apis/autoscaling/v2

{
  "kind": "APIResourceList",
  "apiVersion": "v1",
  "groupVersion": "autoscaling/v2",
  "resources": [
    {
      "name": "horizontalpodautoscalers",
      "singularName": "",
      "namespaced": true,
      "kind": "HorizontalPodAutoscaler",
      "verbs": [
        "create",
        "delete",
        "deletecollection",
        "get",
        "list",
        "patch",
        "update",
        "watch"
      ],
      "shortNames": [
        "hpa"
      ],
      "categories": [
        "all"
      ],
      "storageVersionHash": "oQlkt7f5j/A="
    },
    {
      "name": "horizontalpodautoscalers/status",
      "singularName": "",
      "namespaced": true,
      "kind": "HorizontalPodAutoscaler",
      "verbs": [
        "get",
        "patch",
        "update"
      ]
    }
  ]
}
```
注: [Kubernetes] 所用 REST library 是 [emicklei/go-restful](https://github.com/emicklei/go-restful)。

## Methods
[Microsoft REST API Guidelines] 总结了各 HTTP Method 的语义描述和幂等性，对应 [RFC 9110]/(POST, GET, PUT, DELETE, HEAD, OPTIONS) 和 [RFC 5789]/PATCH

| Method  | Description                                                         | Success Status Code                                         | Is Idempotent |
| ------- | ------------------------------------------------------------------- | ----------------------------------------------------------- | ------------- |
| GET     | Get the resource or List a resource collection                      | 200-OK                                                      | True          |
| HEAD    | Return metadata of an object for a GET response.                    | 200-OK                                                      | True          |
| OPTIONS | Get information about a request                                     | 200-OK                                                      | True          |
| POST    | Create a new object based on the data provided, or submit a command | 201-Created with URL of created resource, 200-OK for Action | False         |
| PUT     | Replace an object, or create a named object, when applicable        | 200-OK, 201-Created, 204-No Content                         | True          |
| PATCH   | Apply a partial update to an object                                 | 200-OK, 204-No Content                                      | False         |
| DELETE  | Delete an object                                                    | 200-OK, 204-No Content                                      | True          |

对于 POST/PUT/DELETE，如果处理时间过长需异步处理，可以返回 202 (Accepted)

对于 PUT/PATCH/DELETE，如果响应 Body 为空，建议返回 204 (No Content)。 [Azure/Architecture/Best Practices: RESTful web API design] 则建议即便是 GET，只要结果为 empty sets (如应用过滤条件之后结果为空集)，也应返回 204 (No Content)，而不是 200 (OK)。

### Get/List <---> HTTP GET/HEAD/OPTIONS
获取某一资源
```shell
GET /resources/{name}?p1=v1&p2=v2&p3=v3
```
获取资源集合
```shell
GET /resources?p1=v1&p2=v2&p3=v3
```
注意: URL Path 之外请求字段应通过 URL query parameters 传输，而不是存储于 Body

>  A payload within a GET request message has no defined semantics;
   sending a payload body on a GET request might cause some existing
   implementations to reject the request.

[Google Cloud API design guide] 提供了 List Sub-Collections 的思路（使用 `-` 匹配所有资源名），如获取所有书架下的书籍

```shell
GET https://library.googleapis.com/v1/shelves/-/books?filter=xxx
```
或者获取所有书架下的单本书籍
```shell
GET https://library.googleapis.com/v1/shelves/-/books/{id}
```

如果 List 结果条数过多，按照复杂度可以添加分页、过滤、排序功能

**分页**

典型的客户端驱动分页如下，limit 表示返回单页条数，offset 表示 starting offset。服务端应返回包含集合总条数 (total number) 的 Metadata。

```shell
GET /orders?limit=25&offset=50
```

Google 引入 page token 并移除了 offset，改由服务端驱动分页。[Google Calendar](https://developers.google.com/calendar/api/guides/pagination) 示例: 客户端通过 maxResults 声明单次响应条数，服务端返回 nextPageToken 字段声明还有下一页可供获取

```shell
GET /calendars/primary/events?maxResults=10

//Result contains

"nextPageToken": "CiAKGjBpNDd2Nmp2Zml2cXRwYjBpOXA"
```

客户端下一请求中送入 pageToken 参数，对应上一响应中返回的 nextPageToken

```shell
GET /calendars/primary/events?maxResults=10&pageToken=CiAKGjBpNDd2Nmp2Zml2cXRwYjBpOXA
```

Google 主导的 [Kubernetes] apiserver 使用 limit（对应 maxResults） 和 continue（对应 pageToken) 语义分页

客户端申请分页，单页数量 5。apiserver 返回第 1 页 5 条内容，返回 continue 并提示剩余 15 条
```shell
kubectl get --raw '/api/v1/configmaps?limit=5'

{
  "kind": "ConfigMapList",
  "apiVersion": "v1",
  "metadata": {
    "resourceVersion": "21796695",
    "continue": "eyJ2IjoibWV0YS5rOHMuaW8vdjEiLCJydiI6MjE3OTI1ODEsInN0YXJ0IjoiZGVmYXVsdC9teS1kYXByLWRiLXJlZGlzLWhlYWx0aFx1MDAwMCJ9",
    "remainingItemCount": 15
  },
  "items": [...]
}
```
调整 limit 为 10，送入 continue 参数获取下一页。apiserver 返回第 2 页 10 条内容，返回 continue 并提示剩余 5 条

```shell
kubectl get --raw '/api/v1/configmaps?limit=10&continue=eyJ2IjoibWV0YS5rOHMuaW8vdjEiLCJydiI6MjE3OTI1ODEsInN0YXJ0IjoiZGVmYXVsdC9teS1kYXByLWRiLXJlZGlzLWhlYWx0aFx1MDAwMCJ9'

{
  "kind": "ConfigMapList",
  "apiVersion": "v1",
  "metadata": {
    "resourceVersion": "21796695",
    "continue": "eyJ2IjoibWV0YS5rOHMuaW8vdjEiLCJydiI6MjE3OTY2OTUsInN0YXJ0Ijoia3ViZS1zeXN0ZW0va3ViZS1wcm94eVx1MDAwMCJ9",
    "remainingItemCount":5
  },
  "items": [...]
}
```
客户端获取最后 5 条。服务端返回不再返回 continue 和 remainingItemCount。

```shell
kubectl get --raw '/api/v1/configmaps?limit=10&continue=eyJ2IjoibWV0YS5rOHMuaW8vdjEiLCJydiI6MjE3OTY2OTUsInN0YXJ0Ijoia3ViZS1zeXN0ZW0va3ViZS1wcm94eVx1MDAwMCJ9'

{
  "kind": "ConfigMapList",
  "apiVersion": "v1",
  "metadata": {
    "resourceVersion": "21796695"
  },
  "items": [...]
}
```

类似地，[Google Cloud API design guide] design_patterns/List Pagination 将 maxResults 换成了 page_size，其他没有变化。

**过滤**

[Microsoft REST API Guidelines] 提供了非常好的过滤规范

| Operator             | Description           | Example                                               |
| -------------------- | --------------------- | ----------------------------------------------------- |
| Comparison Operators |                       |
| eq                   | Equal                 | city eq 'Redmond'                                     |
| ne                   | Not equal             | city ne 'London'                                      |
| gt                   | Greater than          | price gt 20                                           |
| ge                   | Greater than or equal | price ge 10                                           |
| lt                   | Less than             | price lt 20                                           |
| le                   | Less than or equal    | price le 100                                          |
| Logical Operators    |                       |
| and                  | Logical and           | price le 200 and price gt 3.5                         |
| or                   | Logical or            | price le 3.5 or price gt 200                          |
| not                  | Logical negation      | not price le 3.5                                      |
| Grouping Operators   |                       |
| ( )                  | Precedence grouping   | (priority eq 1 or city eq 'Redmond') and price gt 100 |

注：MS 推荐用 `$` 前缀表示操作，实践中可以去除

Example: all products with a name equal to 'Milk'

```http
GET https://api.contoso.com/v1.0/products?$filter=name eq 'Milk'
```

Example: all products with a name not equal to 'Milk'

```http
GET https://api.contoso.com/v1.0/products?$filter=name ne 'Milk'
```

Example: all products with the name 'Milk' that also have a price less than 2.55:

```http
GET https://api.contoso.com/v1.0/products?$filter=name eq 'Milk' and price lt 2.55
```

Example: all products that either have the name 'Milk' or have a price less than 2.55:

```http
GET https://api.contoso.com/v1.0/products?$filter=name eq 'Milk' or price lt 2.55
```

Example: all products that have the name 'Milk' or 'Eggs' and have a price less than 2.55:

```http
GET https://api.contoso.com/v1.0/products?$filter=(name eq 'Milk' or name eq 'Eggs') and price lt 2.55
```

filter 优先级

| Group           | Operator | Description           |
| :-------------- | :------- | :-------------------- |
| Grouping        | ( )      | Precedence grouping   |
| Unary           | not      | Logical Negation      |
| Relational      | gt       | Greater Than          |
|                 | ge       | Greater than or Equal |
|                 | lt       | Less Than             |
|                 | le       | Less than or Equal    |
| Equality        | eq       | Equal                 |
|                 | ne       | Not Equal             |
| Conditional AND | and      | Logical And           |
| Conditional OR  | or       | Logical Or            |

**排序**

[Microsoft REST API Guidelines] 提供了非常好的排序规范，即使用 orderBy 字段

注：MS 推荐用 `$` 前缀表示操作，实践中可以去除

示例：返回 people list，按照 name 升序排列
```shell
GET https://api.contoso.com/v1.0/people?$orderBy=name
```

示例：返回 people list，按照 name 降序排列
```shell
GET https://api.contoso.com/v1.0/people?$orderBy=name desc
```

示例：返回 people list，先按照 name 降序排列，再按照 hireDate 降序排列

```shell
GET https://api.contoso.com/v1.0/people?$orderBy=name desc,hireDate
```

示例：filter 与 orderBy 联合使用
```shell
GET https://api.contoso.com/v1.0/people?$filter=name eq 'david'&$orderBy=hireDate
```

**Range-分段返回大对象**

如果资源过大，如视频大文件，服务端可引入 Range 支持 [[5]]。

HEAD 请求专门用于获取资源元信息（Headers），除了 Body 为空外，其响应内容和 GET 请求相同。

> The HEAD method is identical to GET except that the server MUST NOT send content in the response. 
> HEAD is used to obtain metadata about the [selected representation](https://www.rfc-editor.org/rfc/rfc9110#selected.representation) without transferring its representation data, often for the sake of testing hypertext links or finding recent modifications.
> --- RFC 9110

客户端可先发起 HEAD 请求，发现资源对象过大后再发起 Range

```shell
HEAD https://adventure-works.com/products/10?fields=productImage HTTP/1.1
```
使用 HEAD 获取元数据

```shell
HTTP/1.1 200 OK

Accept-Ranges: bytes
Content-Type: image/jpeg
Content-Length: 4580
```

客户端根据响应结果使用 Range 获取部分数据

```shell
GET https://adventure-works.com/products/10?fields=productImage HTTP/1.1
Range: bytes=0-2499
```
服务端根据声明，返回字节流 0-2499/4580

```shell
HTTP/1.1 206 Partial Content

Accept-Ranges: bytes
Content-Type: image/jpeg
Content-Length: 2500
Content-Range: bytes 0-2499/4580

[...]

```

### Create <---> HTTP POST/PUT

规范建议使用 POST 或 PUT 表达创建语义。它们之间区别见 [RFC 9110 4.3.4](https://www.rfc-editor.org/rfc/rfc9110#section-4.3.4)

> The fundamental difference between the POST and PUT methods is 
   highlighted by the different intent for the enclosed representation. 
   The target resource in a POST request is intended to handle the 
   enclosed representation according to the resource's own semantics, 
   whereas the enclosed representation in a PUT request is defined as 
   replacing the state of the target resource. Hence, the intent of PUT 
   is idempotent and visible to intermediaries, even though the exact 
   effect is only known by the origin server.

对于如下 POST 请求
```shell
POST https://example.com/resources

{"msg": "hello"}
```
服务端实现在解析到 Body `{"msg": "hello"}` 之后，可以自行生成资源 `https://example.com/resources/027bdb6a-4deb-4906-9060-28cc0b1a35f3`，体现在 Response Header Location，响应如下内容
```shell
201 CREATED
Location: https://example.com/resources/027bdb6a-4deb-4906-9060-28cc0b1a35f3
```
对应内容表现为
```json
{"resource_id":"027bdb6a-4deb-4906-9060-28cc0b1a35f3", "msg": "hello", "extra": "world"}
```

对于如下 PUT 请求
```shell
PUT https://example.com/resources/hellomsg

{"resource_id":"hellomsg", "msg": "hello"}
```
服务端解析完 Body 之后，发现资源 `resources/hellomsg` 不存在，尊重 PUT 请求创建如下内容
```
{"resource_id":"hellomsg", "msg": "hello"}
```
返回响应如下（无需包含 Location Header
```shell
201 CREATED
```

通过对比可以看出
- POST 倾向于表达不确定的创建，服务端收到请求后，可以自行生成资源 URI，自行添加字段，且多次请求可能创建多个资源对象。最终资源属性不必与请求属性一致
- PUT 倾向于表达确定的创建或者替换，客户端知道资源 URI，知道资源的全部表现内容，且多次请求结果幂等。最终资源属性必须与请求属性一致

规范建议 POST 返回 201 CREATED 和 Location Header，建议 PUT 返回 201 CREATED。

这也解释了 POST Path 应该不包含，而 PUT Path 应包含 name/id 的原因
- POST /resources
- PUT /resources/{name}

### Update <---> HTTP PUT/PATCH

对于资源全局更新，使用 HTTP PUT。对于资源部分更新，使用 HTTP PATCH (see [RFC 5789])。

按照 [RFC 9110] 定义，PUT 可执行创建或者整体更新操作
> The PUT method requests that the state of the [target resource](https://www.rfc-editor.org/rfc/rfc9110#target.resource) be created or replaced with the state defined by the representation enclosed in the request message content.

- 如果创建了资源，返回 201 (Created)
- 如果更新成功且响应 Body 包含资源对象，返回 200 (OK)
- 如果更新成功但响应 Body 不包含资源对象，返回 204 (No Content)

PATCH 适合更新大对象（上百字段，一堆字节）的场景，比如设置 K8s Node 为不可调度时，使用 PATCH 可避免传输整个 Node 对象
```shell
PATCH https://myapiserver.myk8s.io/api/v1/nodes/node-test
Content-Type: application/strategic-merge-patch+json

{"spec":{"unschedulable":true}}
```
类似 PUT，更新成功后，可返回 200 (OK) 并在 Body 包含更新后的对象，也可返回 204 (No Content) 同时 Body 置空

对于异常情况，Update 操作通常可以返回
- 400 (Bad Request)（请求参数非法
- 404 (Not Found)（仅限 PATCH
- 409 (Conflict)（请求字段不存在-PATCH、并发冲突

### Delete <---> HTTP DELETE

HTTP DELETE 用于删除资源。

服务端实现可以视情况返回如下响应
- 202 (Accepted)，表异步删除
- 204 (No Content)，删除完成且 Response Body 为空
- 200 (OK)，删除完成且在 Response Body 包含删除状态描述

关于 200 (OK) 返回的删除状态描述，最简单实现是给原先的资源对象带上删除时间戳，复杂场景可以添加状态字段展现更多细节。

注，DELETE 不要使用 Request Body [RFC 9110 section-9.3.5](https://www.rfc-editor.org/rfc/rfc9110#section-9.3.5) 指出
>  Although request message framing is independent of the method used, 
  content received in a DELETE request has no generally defined semantics, 
  cannot alter the meaning or target of the request, and might lead some implementations to reject the request and close the connection because of its potential as a request smuggling attack ([Section 11.2 of HTTP/1.1](https://www.rfc-editor.org/rfc/rfc9112.html#section-11.2)). 

### custom methods/actions

## Caches
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

老的 HTTP 缓存服务器可能使用 `Expires: Tue, 28 Feb 2022 22:22:22 GMT` 控制缓存有效期，原理和 `Cache-Control: max-age` 类似，也表示缓存 1 星期，但会有更难解析和系统时钟不准确的问题。

从客户端到服务端方向，HTTP 同样提供了一套缓存检验机制，分别是 
- If-Modified-Since 和 Last-Modified
- ETag/If-None-Match

> A proxy, whether or not it implements a cache, 
> MUST pass cache directives through in forwarded messages, 
> regardless of their significance to that application, 
> since the directives might apply to all recipients along the request/response chain. 
> It is not possible to target a directive to a specific cache.

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

大多实现只缓存状态码为 200 (OK) 的 GET 请求响应。小部分实现也可能支持缓存 206 (Partial Content)、3xx（redirects）、404 (Not Found)，也可能支持 POST 和 HEAD。
  
> Most commonly, caches store the successful result of a retrieval
   request: i.e., a 200 (OK) response to a GET request, which contains a
   representation of the target resource ([Section 9.3.1 of HTTP](https://www.rfc-editor.org/rfc/rfc9110#section-9.3.1)).
   However, it is also possible to store redirects, negative results
   (e.g., 404 (Not Found)), incomplete results (e.g., 206 (Partial
   Content)), and responses to methods other than GET if the method's
   definition allows such caching and defines something suitable for use
   as a cache key.

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

## 错误处理
//todo dapr handling pr
- 409 Conflicting state
- 409 Conflicting modification
- 409 Concurrent modification

| Standard Method | HTTP Mapping                | HTTP Request Body | HTTP Response Body      |
| --------------- | --------------------------- | ----------------- | ----------------------- |
| List            | GET <collection URL>        | N/A               | Resource* list          |
| GET             | GET <resource URL>          | N/A               | Resource*               |
| Create          | POST <collection URL>       | Resource          | Resource*               |
| Update          | PUT or PATCH <resource URL> | Resource          | Resource*               |
| Delete          | DELETE <resource URL>       | N/A               | google.protobuf.Empty** |

**The response returned from a Delete method that doesn't immediately remove the resource (such as updating a flag or creating a long-running delete operation) should contain either the long-running operation or the modified resource.


[1]: https://www.ics.uci.edu/~fielding/pubs/dissertation/rest_arch_style.htm
[2]: https://aws.amazon.com/what-is/restful-api/
[3]: https://developers.google.com/gmail/api
[4]: https://cloud.google.com/pubsub/docs/reference/rest
[5]: https://developer.mozilla.org/en-US/docs/Web/HTTP/Range_requests
[RFC 5789]: https://www.rfc-editor.org/rfc/rfc5789
[RFC 9110]: https://www.rfc-editor.org/rfc/rfc9110
[RFC 9111: HTTP Caching]: https://www.rfc-editor.org/rfc/rfc9111
[MDN: HTTP caching]: https://developer.mozilla.org/en-US/docs/Web/HTTP/Caching
[Increasing Application Performance with HTTP Cache Headers]: https://devcenter.heroku.com/articles/increasing-application-performance-with-http-cache-headers
[Things Caches Do]: https://tomayko.com/blog/2008/things-caches-do
[Google Cloud API design guide]: https://cloud.google.com/apis/design
[Microsoft Azure REST API Guidelines]: https://github.com/microsoft/api-guidelines/blob/vNext/azure/Guidelines.md
[Microsoft REST API Guidelines]: https://github.com/microsoft/api-guidelines/blob/vNext/Guidelines.md#74-supported-methods
[Azure/Architecture/Best Practices: RESTful web API design]: https://learn.microsoft.com/en-us/azure/architecture/best-practices/api-design
[Kubernetes]: https://kubernetes.io/docs/home/

## 参考链接
- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110)
- [RFC 9112: HTTP/1.1](https://www.rfc-editor.org/rfc/rfc9112.html)
- [RFC 5789: PATCH Method for HTTP](https://www.rfc-editor.org/rfc/rfc5789)
- [RFC 9111: HTTP Caching](https://www.rfc-editor.org/rfc/rfc9111)
- [REST on Wikipedia](https://en.wikipedia.org/wiki/Representational_state_transfer)
- [Codecademy: What is REST?](https://www.codecademy.com/article/what-is-rest)
- [Roy Fielding's REST Dissertation](https://www.ics.uci.edu/~fielding/pubs/dissertation/rest_arch_style.htm)
- [AWS: What Is A RESTful API?](https://aws.amazon.com/what-is/restful-api/)
- [Microsoft REST API Guidelines](https://github.com/microsoft/api-guidelines/blob/vNext/Guidelines.md#74-supported-methods)
- [Google Cloud API design guide](https://cloud.google.com/apis/design)
- [Joshua Bloch: How to Design a Good API and Why it Matters](https://static.googleusercontent.com/media/research.google.com/zh-CN//pubs/archive/32713.pdf)
- [MDN: HTTP caching](https://developer.mozilla.org/en-US/docs/Web/HTTP/Caching)
- [Increasing Application Performance with HTTP Cache Headers](https://devcenter.heroku.com/articles/increasing-application-performance-with-http-cache-headers)
- [Things Caches Do](https://tomayko.com/blog/2008/things-caches-do)