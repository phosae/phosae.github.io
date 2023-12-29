---
title: "Notes on Retriable HTTP Client (with Golang/Rust example"
date: 2023-12-22T17:46:10+08:00
lastmod: 2023-12-29T17:36:10+08:00
draft: false
keywords: ["http", "retry", "fault-tolerance", "go", "rust"]
description: "Notes on Retriable HTTP Client"
tags: ["en", "go", "rust", "http"]
author: "Zeng Xu"
summary: "Notes on Retriable Http Client (with Golang/Rust example"

comment: true
toc: false
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

A fault-tolerance HTTP client needs to retry on recoverable errors.

When the server is able to send a response, the client can retry on `429 Too Many Requests` or any status code equal to or greater than 500.

When the client is unable to receive a response from the server, it will encounter an error or exception from the underlying network libraries. There are various cases that can lead to these errors:
- The connection cannot be established. The URL schema may be invalid, DNS resolution could fail for the hostname, or the server may temporarily be down for an upgrade and not listening on the socket
- The connection is established but is aborted before the server sends a response back

When a reverse proxy is placed behind the application server, a client error in the proxy will be translated into a response with a `502 Bad Gateway` status code.

Some errors are recoverable, while others are not.

A client can retry on certain recoverable errors.

Here's a Go example.

```go
func shouldRetry(resp *http.Response, err error) bool {
	if err == nil {
		statusCode := resp.StatusCode
		return statusCode >= 500 || statusCode == http.StatusTooManyRequests
	}

	var uerr *url.Error
	if !errors.As(err, &uerr) {
		return false
	}

	if uerr.Timeout() {
		return true
	}

	err = uerr.Err
	msg := err.Error()
	switch {
	case err == io.EOF:
		return true
	case err == io.ErrUnexpectedEOF:
		return true
	case msg == "http: can't write HTTP request on broken connection":
		return true
	case strings.Contains(msg, "http2: server sent GOAWAY and closed the connection"):
		return true
	case strings.Contains(msg, "connection reset by peer"):
		return true
	case strings.Contains(msg, "connection refused"):
		return true
	case strings.Contains(strings.ToLower(msg), "use of closed network connection"):
		return true
	}
	return false
}
```

Here's a Rust example based on [reqwest]. It's a simplified version ported from [TrueLayer/reqwest-middleware].

```rust
fn should_retry(ret: &Result<reqwest::blocking::Response, reqwest::Error>) -> bool {
    match ret {
        Ok(resp) => {
            return resp.status().as_u16() >= 500
                || resp.status() == http::StatusCode::TOO_MANY_REQUESTS
        }
        Err(err) => {
            if err.is_connect() || err.is_timeout() {
                return true;
            }
            if let Some(err) = get_source_error_type::<hyper::Error>(&err) {
                if err.is_incomplete_message() || err.is_canceled() {
                    return true;
                } else {
                    if let Some(err) = get_source_error_type::<io::Error>(err) {
                        return err.kind() == std::io::ErrorKind::ConnectionReset
                            || err.kind() == std::io::ErrorKind::ConnectionAborted;
                    }
                }
            }
            return false;
        }
    }
}
```

Clients can also retry any error except for certain unrecoverable errors, as demonstrated by [hashicorp/go-retryablehttp].

As the examples show, retrying based on status codes is quite similar, but retrying based on library errors is highly language-specific.

The full code for all the samples in this post is [available on GitHub](https://github.com/phosae/samples/tree/main/2023/http-client-retry).

Writing your own retry code from nothing is not recommended; it is better to use or learn from mature libraries.

- Golang: [hashicorp/go-retryablehttp]
- Rust: [TrueLayer/reqwest-middleware]

In Java, HTTP client implementations such as [Apache HttpClient] and [OkHttp] have retry policies based on Java's Exception mechanism.

[reqwest]: https://github.com/seanmonstar/reqwest
[TrueLayer/reqwest-middleware]: https://github.com/TrueLayer/reqwest-middleware/blob/main/reqwest-retry/src/retryable_strategy.rs
[hashicorp/go-retryablehttp]: https://github.com/hashicorp/go-retryablehttp
[Apache HttpClient]: https://github.com/apache/httpcomponents-client
[OkHttp]: https://github.com/square/okhttp