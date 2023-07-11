---
title: "Http Range Request and MP4 Video Play in Browser"
date: 2023-03-08T10:51:20+08:00
lastmod: 2023-03-08T10:51:20+08:00
draft: false
keywords: ["http","go","range request", "byte serving", "web"]
description: ""
tags: ["http","go","range request", "byte serving", "web", "en"]
author: "Zeng Xu"
summary: "HTTP range request is a widely used feature when it comes to file resource. Besides covering basic concept of range request, this blog show how HTTP range request works in browsers. Behaviors of Chrome, FireFox and Safari are coverd. several sample HTTP servers written in Golang are used to trick browsers."

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

## Basic Concept

Splitting large video file into parts, transfering it over network part by part, are vital for browser
displaying video to user. The network may losing packet. The user may want to play at any random time point. The parts way can avoid retransmission and improve user experience.

```
+----------------------------------------------------------------------------------------------------+
|                                           1000MB                                                   |  
+----------------------------------------------------------------------------------------------------+
                                              ↓                                             
+--------+   +-------------+             +-----------------------------+        +--------------------+
| 100MB  |   |    150MB    |    ......   |            300MB            |        |         200MB      |
+--------+   +-------------+             +-----------------------------+        +--------------------+
```
In HTTP protocol 1.1 to achieve this range request can be leveraged. More backgroun and details are at HTTP [RFC7233], Wiki [Byte_serving].

Briefly, the HTTP Client send a request with header `Range` that declare needed byte ranges in resource. The HTTP server reponse with status code `206` (Partial Content), with header `Content-Range` describing what range of the selected representation is enclosed, and a payload consisting of the range.

```
HTTP Client                             HTTP Server
+------------------------+              +-------------------------------------+           
| GET /a.mp4 HTTP/1.1    |              | HTTP/1.1 206 Partial Content        |
| Host: example.com      |    <----->   | Content-Range: bytes 0-1023/10240   |
| Range: bytes=0-1023    |              | Content-Length: 1024                |
+------------------------+              | ...                                 |
                                        | (body: 1024 bytes of a.mp4)         |
                                        +-------------------------------------+
```
If the request range is invalid or don't overlap the selected resource, the server reponse with status code `416` (Range Not Satisfiable).

```
HTTP Client                               HTTP Server
+--------------------------+              +-----------------------------------------------+           
| GET /a.mp4 HTTP/1.1      |              | HTTP/1.1 416 Requested Range Not Satisfiable  |
| Host: example.com        |    <----->   | Content-Range: bytes */10240                  |
| Range: bytes=10250-12000 |              | ...                                           |
+--------------------------+              +-----------------------------------------------+
```
Examples of valid byte ranges (assuming a resource of length 10240): 
- `bytes=0-499`, the first 500 bytes
- `bytes=1000-1999`, 1000 bytes start from offset 1000
- `bytes=-500`, the final 500 bytes (byte offsets 9739-10239, inclusive)
- `bytes=0-0,-1`, the first and last bytes only
- `bytes=0-`, `bytes=0-10250`, be interpreted as `bytes=0-10239`

As [RFC7233] pointed out


> If the last-byte-pos value is absent, or if the value is greater than or equal to the current length of the representation data, the byte range is interpreted as the remainder of the representation

## How Range Requests happen in Browsers

How could the browser/client knows whether to send a range request and not? The answer is HTTP header `Accept-Ranges: bytes`.

Below is a example from Chrome that request and play a video (791MB) from Golang HTTP file server. It start with a normal HTTP request. By reading the response header from stream, Chrome find the server side supports range, then abort the connection and start sending range requests.

```
1. send request, read the onflight reponse header, close connection when range support detected

Chrome                                            Server
+------------------------+    ------------>       +-------------------------------------+           
| GET /a.mp4 HTTP/1.1    |   close conn when      | HTTP/1.1 200 OK                     |
| Host: example.com      |    <----x-------       | Accept-Ranges: bytes                |
+------------------------+ range support detected | Content-Length: 828908177           |
                                                  | ...                                 |
                                                  | (body: some first bytes of a.mp4)   |
                                                  +-------------------------------------+

2. send trivial range request 1, fetch head parts, verify server's support, 

Chrome                                         Server
+------------------------+   ------------>     +---------------------------------------------+           
| GET /a.mp4 HTTP/1.1    |  close conn when    | HTTP/1.1 206 Partial Content                |
| Host: example.com      |   <----x-------     | Accept-Ranges: bytes                        |
| Range: [bytes=0-]      |   verify success    | Content-Range: bytes 0-828908176/828908177  |
+------------------------+                     | Content-Length: 828908177                   |
                                               | ...                                         |
                                               | (body: some first bytes of a.mp4)           |
                                               +---------------------------------------------+

3. send trivial range request 2, fetch tail parts, verify server's support 

Chrome                                          Server
+--------------------------+                    +-----------------------------------------------------+           
| GET /a.mp4 HTTP/1.1      |                    | HTTP/1.1 206 Partial Content                        |
| Host: example.com        |   ----------->     | Accept-Ranges: bytes                                |
| Range: bytes=828604416-  |                    | Content-Range: bytes 828604416-828908176/828908177  |
+--------------------------+                    | Content-Length: 303761                              |
                                                | ...                                                 |
                                                | (body: some end bytes of a.mp4)                     |
                                                +-----------------------------------------------------+

4. sending range request for remaining bytes 

Chrome                                           Server
+--------------------------+                     +-----------------------------------------------------+           
| GET /a.mp4 HTTP/1.1      |   ------------>     | HTTP/1.1 206 Partial Content                        |
| Host: example.com        |   <------------     | Accept-Ranges: bytes                                |
| Range: bytes=720896-     |                     | Content-Range: bytes 720896-828908176/828908177     |
+--------------------------+                     | Content-Length: 828187281                           |
                                                 | ...                                                 |
                                                 | (body: rest bytes of a.mp4)                         |
                                                 +-----------------------------------------------------+
```

FireFox's Behaviors are quite similar to Chrome, except that's only one trivial range request.
```
1. send request, read the onflight reponse header, close connection when range support detected

FireFox                                           Server
+------------------------+    ------------>       +-------------------------------------+           
| GET /a.mp4 HTTP/1.1    |   close conn when      | HTTP/1.1 200 OK                     |
| Host: example.com      |    <----x-------       | Accept-Ranges: bytes                |
+------------------------+ range support detected | Content-Length: 828908177           |
                                                  | ...                                 |
                                                  | (body: some first bytes of a.mp4)   |
                                                  +-------------------------------------+

2. send trivial range request, fetch tail parts, verify server's support 

FireFox                                          Server
+--------------------------+                    +-----------------------------------------------------+           
| GET /a.mp4 HTTP/1.1      |                    | HTTP/1.1 206 Partial Content                        |
| Host: example.com        |   <---------->     | Accept-Ranges: bytes                                |
| Range: bytes=828604416-  |                    | Content-Range: bytes 828604416-828908176/828908177  |
+--------------------------+                    | Content-Length: 303761                              |
                                                | ...                                                 |
                                                | (body: some end bytes of a.mp4)                     |
                                                +-----------------------------------------------------+

3. sending range request for remaining bytes 

FireFox                                         Server
+--------------------------+                  +-----------------------------------------------------+           
| GET /a.mp4 HTTP/1.1      |   <---------->   | HTTP/1.1 206 Partial Content                        |
| Host: example.com        |                  | Accept-Ranges: bytes                                |
| Range: bytes=1867776-    |                  | Content-Range: bytes 1867776-828908176/828908177    |
+--------------------------+                  | Content-Length: 827040401                           |
                                              | ...                                                 |
                                              | (body: rest bytes of a.mp4)                         |
                                              +-----------------------------------------------------+
```
Safari send first trivial range request with `bytes=0-1`, and other two trivial range requests like Chrome.

Both Chrome and FireFox send range request using byte range (i.e `bytes=1867776-`) with last-byte-pos value absent. But Safari always set the last-byte-pos.

```
1. send request 1, read the onflight reponse header, close connection when range support detected

Safari                                         Server
+------------------------+    ------------>       +-------------------------------------+           
| GET /a.mp4 HTTP/1.1    |   close conn when      | HTTP/1.1 200 OK                     |
| Host: example.com      |    <----x-------       | Accept-Ranges: bytes                |
+------------------------+ range support detected | Content-Length: 828908177           |
                                                  | ...                                 |
                                                  | (body: some first bytes of a.mp4)   |
                                                  +-------------------------------------+

2. send trivial range request 1, fetch first two bytes, verify server's support, 

Safari                                       Server
+------------------------+                   +---------------------------------------------+           
| GET /a.mp4 HTTP/1.1    |                   | HTTP/1.1 206 Partial Content                |
| Host: example.com      |   <----------->   | Accept-Ranges: bytes                        |
| Range: bytes=0-1       |                   | Content-Range: bytes 0-1/828908177          |
+------------------------+                   | Content-Length: 2                           |
                                             | ...                                         |
                                             | (body: first two bytes of a.mp4)            |
                                             +---------------------------------------------+

3. send trivial range request 2, fetch some first parts, verify server's support 

Safari                                            Server
+---------------------------+   ------------>     +---------------------------------------------+           
| GET /a.mp4 HTTP/1.1       |  close conn when    | HTTP/1.1 206 Partial Content                |
| Host: example.com         |   <----x-------     | Accept-Ranges: bytes                        |
| Range: bytes=0-828908176  |   verify success    | Content-Range: bytes 0-828908176/828908177  |
+---------------------------+                     | Content-Length: 828908177                   |
                                                  | ...                                         |
                                                  | (body: some first bytes of a.mp4)           |
                                                  +---------------------------------------------+

3. send trivial range request 3, fetch tail parts, verify server's support 

Safari                                                 Server
+-----------------------------------+                  +----------------------------------------------------+
| GET /a.mp4 HTTP/1.1               |                  | HTTP/1.1 206 Partial Content                       |
| Host: example.com                 |   <---------->   | Accept-Ranges: bytes                               |
| Range: bytes=828571648-828908176  |                  | Content-Range: bytes 828571648-828908176/828908177 |
+-----------------------------------+                  | Content-Length: 336529                             |
                                                       | ...                                                |
                                                       | (body: some end bytes of a.mp4)                    |
                                                       +----------------------------------------------------+

4. sending serial range requests for remaining bytes 

req bytes=30.5-30.9MB
req bytes=30.9-63.2MB
req bytes=31.0-63.3MB
req bytes=39.5-790MB (close conn when desired bytes from offset 39.5MB received)
req bytes=42.3-790MB (close conn when desired bytes from offset 42.3MB received)
req bytes=45.7-790MB (close conn when desired bytes from offset 45.7MB received)
...
req bytes=780.8-790MB (may close conn when desired bytes from offset 780.8MB received)
req bytes=784.2-790MB (may close conn when desired bytes from offset 784.2MB received)
req bytes=788.1-790MB (may close conn when desired bytes from offset 788.1MB received)
```
Whiles Chrome/FireFox try fetching the remaining bytes in one range request (with range without last-byte-pos i.e bytes=720896-), Safari sends many range request. It firstly request some small parts from the sever, wait for completion. In the next, Safari ask for all remaining bytes ranging from the bytes it holds to the end of file. But once every 4-5MB was transmitted from the server, Safari close the connection and start a new one.

So what happens when user drag the progress bar to any time point? The browser just mapping the desired the point of video to an offset from start,then it abort the inflight range request and start a new one like `byte=offset-total`.

## Can HTTP Server return 206 to Browser for the First Request?

Maybe yes, but meaningless.

The server return `206`(Partial Content) directly for browser's first request (the request without Range header). As sample code  show

```go
const sizePerRequst = 5*1000*1000

type httpRange struct {
	start, length int64
}

func rangeVideo(w http.ResponseWriter, req *http.Request) {
  ...
  rangeHeader := req.Header.Get("Range")
  if rangeHeader == "" {
    ra := httpRange{
      start:  0,
      length: sizePerRequst,
    }
    w.Header().Set("Accept-Ranges", "bytes")
    w.Header().Set("Content-Length", strconv.FormatInt(ra.length, 10))
    w.Header().Set("Content-Range", ra.contentRange(size))
    w.WriteHeader(http.StatusPartialContent)
    fmt.Printf("hint browser to send serial range requests, response 206, 0-%d/%d\n", sizePerRequst-1, size)
    if req.Method != "HEAD" {
      written, err := io.CopyN(w, f, ra.length)
      if written != ra.length {
        fmt.Printf("desired range size: %d, actual written: %d, err: %v\n\n", ra.length, written, err)
      }
    }
    return
  }
}
```
Browsers include Chrome, FireFox, Safari handle this condition well. Sample server can play with docker and visit [localhost:9100](http://localhost:9100) to see browser's behavior

```shell
docker run --rm -p 9100:9100 zengxu/go-http-range
```

Full sample code is [here](https://github.com/phosae/samples/tree/main/2023/go-http-range).

## Can Server Side Control the Size of Each Range Request?
Demands like [[how-to-make-browser-request-smaller-range-with-206-partial-content]] are exist in server side. 

Chrome and FireFox ask for ranges like `bytes=300-`,  can server side return a smaller-range part, other than part from offset 300 to end of file? The answer is yes.

Blow code sample shows that, when last-byte-pos is absent, set a position 5,000,000 bytes from the start position.

```go
type httpRange struct {
	start, length int64
}

func parseRange(s string, size int64) ([]httpRange, error) {
  const b = "bytes="
  for _, ra := range strings.Split(s[len(b):], ",") {
    start, end, ok := strings.Cut(ra, "-")
    var r httpRange
    ...
    i, err := strconv.ParseInt(start, 10, 64)
    if end == "" {
      r.length = 5 * 1000 * 1000
      if r.length > size-r.start {
        r.length = size - r.start
      }
    } else {
      i, err := strconv.ParseInt(end, 10, 64)
      if err != nil || r.start > i {
        return nil, errors.New("invalid range")
      }
      if i >= size {
        i = size - 1
      }
      r.length = i - r.start + 1
    }
  }
}
```

This works well with Chrome and FireFox. The browser will send serial range request, like `bytes=5_000_300-`, `bytes=10_000_300-`, `bytes=15_000_300-`, until the end of file reached.

The full sample code is [here](https://github.com/phosae/samples/tree/main/2023/go-http-range). You can run the server in Docker and visit [localhost:9100](http://localhost:9100/) in Chrome or FireFox to verify result

```shell
docker run --rm -p 9100:9100 zengxu/go-http-range

...
[::1]:58426 request range bytes=3244032-
response range bytes 3244032-8244031, 4882 KB


[::1]:58426 request range bytes=8244032-
response range bytes 8244032-13244031, 4882 KB


[::1]:58426 request range bytes=13244032-
response range bytes 13244032-18244031, 4882 KB
...
[::1]:58426 request range bytes=53244032-
response range bytes 53244032-53591653, 339 KB
```

As Safari always set the last-byte-pos, if the server response another last-byte-pos than desired position, the browser reject to play the video.

## How Can Server Side Handle Video Stream of Dynamic Size?

The sample server [go-http-range-dynamic](https://github.com/phosae/samples/tree/main/2023/go-http-range-dynamic) returns 5,000,000 bytes for each range request of Chrome or FireFox (For Safari it depends on). when the range start of request is close the end of file, replace file with a large one.

```go
func rangeVideo(w http.ResponseWriter, req *http.Request) {
  f, size, err := openfile(vpart1)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer f.Close()
  ...
  ranges, err := parseRange(rangeHeader, size)
  ...
  ra := ranges[0]
  if ra.start+sizePerRequst > size && ra.length 1024*1024 /* try escape the tail verify */ {
    f, size, err = openfile(vfull)
    if err != nil {
      http.Error(w, err.Error(), 500)
      return
    }
    defer f.Close()
	}
  ...
}
```

Last two range request looks like this, the server try to update the resource size from 43730385 to 95644582. All browser have same behavior, they reject to fetch more streams and finish play the video.

```
Browser                                 Server
+------------------------+              +--------------------------------------------------+           
| GET / HTTP/1.1         |              | HTTP/1.1 206 Partial Content                     |
| Host: localhost        |    <----->   | Content-Range: bytes 37359296-42359295/43730385  |
| Range: bytes=37359296- |              | Content-Length: 5000000                          |
+------------------------+              | ...                                              |
                                        | (body: 5000000 bytes of video)                   |
                                        +--------------------------------------------------+

Browser                                 Server
+------------------------+              +--------------------------------------------------+           
| GET / HTTP/1.1         |              | HTTP/1.1 206 Partial Content                     |
| Host: localhost        |    <----->   | Content-Range: bytes 42359296-43730384/95644582  |
| Range: bytes=42359296- |              | Content-Length: 1371089                          |
+------------------------+              | ...                                              |
                                        | (body: 1371089 bytes of video)                   |
                                        +--------------------------------------------------+
```

This sample server can run in Docker directly

```shell
docker run --rm -p 9100:9100 zengxu/go-http-range:dynamic
```

What if the server side return a size large enough (i.e 100GB) as `Content-Length` header value for the first time browser requesting resource? Would the browser continually send range requests util 100GB reached? Answer is no. The browser may have some way to detect the actual size of first video(during head/tail verification), when its end reached, they reject to fetch more streams and exit the video play. 

```
Range: bytes=0-          <--->   Content-Range: bytes 0-4999999/1000000000
Range: bytes=4999999-    <--->   Content-Range: bytes 4999999-9999999/1000000000
Range: bytes=9999999-    <--->   Content-Range: bytes 9999999-14999999/1000000000
...
Range: bytes=9999999-    <--->   Content-Range: bytes 994999999-999999999/1000000000
```

Try sample server with option `-dynamic true` to verify browser's behavior

```shell
docker run --rm -p 9100:9100 zengxu/go-http-range:dynamic -dynamic true
```
Bypassing browser's verification need knowledges in video encoding technology and is tricky. The best solution for serving dynamic stream is write a custom one, popular video platforms like [YouTube](https://www.youtube.com), [Twitch](https://www.twitch.tv) all use their own video player.

## Conclusion
HTTP range request is a widely used feature when it comes to file resource. File systems such as [S3](https://docs.aws.amazon.com/whitepapers/latest/s3-optimizing-performance-best-practices/use-byte-range-fetches.html) have good support for this. Learning internals about range request helps you building HTTP system with higher aggregate throughput, for both server side and client side.

Browsers are quite smart with range request. Tricks sometimes works, but sometimes not. Obeying [RFC7233] is the best practice guide. HTTP range request is not a good solution for serving dynamic content. If you are building a site for livestream, it's better to come up with custom player.

---
Further Reading
1. [MDN range request](https://developer.mozilla.org/en-US/docs/Web/HTTP/Range_requests)
2. [Wiki Byte_serving](https://en.wikipedia.org/wiki/Byte_serving)
3. [RFC7233](https://www.rfc-editor.org/rfc/rfc7233)

[RFC7233]: https://www.rfc-editor.org/rfc/rfc7233
[Byte_serving]: https://en.wikipedia.org/wiki/Byte_serving
[how-to-make-browser-request-smaller-range-with-206-partial-content]: https://stackoverflow.com/questions/36114598/how-to-make-browser-request-smaller-range-with-206-partial-content
