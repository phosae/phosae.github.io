---
title: "Terminate Container in Responsive and Gracefule Way"
date: 2023-02-27T08:00:59+08:00
lastmod: 2023-02-27T08:00:59+08:00
draft: false
keywords: ["container", "init", "pid1", "docker", "kubernetes", "rust"]
description: ""
tags: ["container", "init", "pid1", "docker", "kubernetes", "rust"]
author: "Zeng Xu"
summary: "Running application in container as PID 1 is quite common today, shutdown application responsively and gracefully is hard. This article show how PID 1 behave in container and provides serveral ways to make container shutdown as we want."

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
## Container Context and PID 1
In container context, when it comes to teardown
- `docker stop` send a `SIGTERM` to the main process inside the container, and after a grace period (default 10s), `SIGKILL` 
- Kubernetes send a `SIGTERM` signal to the main process of containers in the Pod, and after a grace period (default 30s), `SIGKILL`
- Under interactive mode, pressing Ctrl+C causes the system to send a `SIGINT` signal to the main process

For Terminating in graceful and responsive way, processes inside container should handle `SIGTERM` and `SIGINT`. Many annoying issues/complains about container exit can be found in network[[1]][[2]]. Let's dig out why.

Applications shipped in minimal container image, such as [Distroless Container Images](https://github.com/GoogleContainerTools/distroless), or `FROM scratch` static binary, usually have with entrypoint like `/app`, run directly as PID 1 in container's pid namespace.

But `PID 1` is treated specially by Linux[[3]][[4]][[5]]: 
- The process will not terminate on SIGINT or SIGTERM unless it is coded to do so.
- Indeed, it is unkillable, meaning that it doesn't get killed by signals which would terminate regular processes.
- When the process with pid 1 die for any reason, all other processes are killed with `KILL` signal
- When any process having children dies for any reason, its children are reparented to process with PID 1

The following Rust code build a basic application that print its PID and lives for 60 seconds.

```rust
// sleep.rs
use std::{thread, time, process};

fn main() {
    let pid = process::id();
    println!("pid {}", pid);

    let delay = time::Duration::from_secs(1);

    for i in 1..=60 {
        thread::sleep(delay);
        println!(". {}", i);
    }
}
```
Let's build and run it in container, then send `SIGTERM` or `SIGINT` to sleep process. Our process with PID 41 is child of /bin/sh, it will exit immediately with code `143 (SIGTERM)` or `130 (SIGINT)`. 

This much like the case we run program in terminal, test it, and press CTRL-C to stop it. 

```shell
docker run --rm --name sleep -w /src  -it -v $PWD:/src rust:alpine   # $ docker exec sleep ps
/src # rustc sleep.rs                                                # PID   USER     TIME  COMMAND
/src # ./sleep                                                       #     1 root      0:00 /bin/sh
pid 41                                                               #    41 root      0:00 ./sleep
. 1                                                                  #
. 2                                                                  # $ docker exec sleep kill -s -SIGTERM 41
. 3                                                                  #       
. 4                                                                  #          
. 5                                                                  #                                                                  # 
Terminated
/src # echo $?
143

/src # ./sleep
pid 96
^C
/src # echo $?
130
``` 

## PID 1 Behavior

When run as PID 1, it is unstoppable in its PID namespace. None of `SIGINT`, `SIGTERM` or `SIGKILL` will work.

```shell
docker run --rm --entrypoint /src/sleep -it -v $PWD:/src rust:alpine   # $ docker exec sleep ps
pid 1                                                                  # PID   USER     TIME  COMMAND
. 1                                                                    #     1 root      0:00 ./sleep
. 2                                                                    #    
^C^C. 3                                                                # $ docker exec sleep kill -s SIGINT 1
^C^C^C^C^C. 4                                                          # $ docker exec sleep kill -s SIGTERM 1
...                                                                    # $ docker exec sleep kill -s SIGKILL 1
. 60                                                                   # 
``` 
As container processes are just normal processes in host PID namespace, sending `SIGKILL` in host work as expected. Docker or Kubelet send signals to PID 1 in every container by this way.

The process won't repond to `SIGTERM` or `SIGINT` because it is not coded to do it.

```shell
# docker run --rm --name sleep --entrypoint /src/sleep -it -v $PWD:/src alpine       
pid 1                                                                 # $ docker exec sleep ps
. 1                                                                   # PID   USER     TIME  COMMAND
. 2                                                                   #     1 root      0:00 ./sleep
. 3                                                                   # 
. 4                                                                   # $ ps -ef | grep sleep
. 5                                                                   # root      9521  9374  0 15:49 pts/0    00:00:00 /src/sleep 
. 6                                                                   # $ kill -s SIGINT  9521 // not work
. 7                                                                   # $ kill -s SIGTERM 9521 // not work
. 8                                                                   # $ kill -s SIGKILL 9521 // worked
#                                                                     #
``` 
## Solution for entrypoint is application binary

Solutions to this problem depends on what the behavior is expected. If reponsive to `SIGINT(CTRL-C)` or `SIGTERM` is the only demand, for languages have default behavior, such as Golang, it abort directly when receive `SIGTERM` or `SIGINT`. Nothing need to be done.

For language don't have default behavior, like Rust, using [tini] or [dumb-init] to wrap container entrypoint are the fast way.

[tini] or [dumb-init] will act as PID 1 in container and immediately spawns command as a child process, taking care to properly handle and forward signals as they are received

```shell
# docker run --rm --name sleep --entrypoint /dumb-init -v $PWD:/src zengxu/alpine:init /src/sleep
pid 8                                                         # 
. 1                                                           # $ docker exec sleep ps
. 2                                                           # PID   USER     TIME  COMMAND
. 3                                                           #     1 root      0:00 /dumb-init /src/sleep
. 4                                                           #     8 root      0:00 /src/sleep
. 5                                                           #
. 6                                                           # docker exec sleep kill 1
. 7                                                           #
# 
```

Note `zengxu/alpine:init` is build by this Dockerfile:
```
FROM alpine

ENV TINI_VERSION v0.19.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static /tini
RUN chmod +x /tini

RUN wget -O /dumb-init https://github.com/Yelp/dumb-init/releases/download/v1.2.5/dumb-init_1.2.5_x86_64
RUN chmod +x /dumb-init
```

Above solution can work in any runtime context, including Containerd, Docker, Podman, or Kubernetes.

In runtime context is Docker, [tini] is included in it. Adding arg `--init` in run command will ovveride target's entrypoint as `/sbin/docker-init -- /src/sleep`.

```shell
# docker run --rm --name sleep --init -v $PWD:/src zengxu/alpine:init /src/sleep
pid 8                                                         # 
. 1                                                           # $ docker exec sleep ps
. 2                                                           # PID   USER     TIME  COMMAND
. 3                                                           #     1 root      0:00 /sbin/docker-init -- /src/sleep
. 4                                                           #     8 root      0:00 /src/sleep
. 5                                                           #
. 6                                                           # docker exec sleep kill 1
. 7                                                           #
# 
``` 
## Solution for entrypoint script

What about application that must be start from a shell script? Bash or shell don't forward signals like SIGTERM to processes it is currently waiting on[[6]]. 

```shell
# cat start.sh                                  
#!/bin/sh                                                                         
/src/sleep

# docker run --rm --name sleep -v $PWD:/src --entrypoint /src/start.sh alpine
pid 7
. 1
^C^C. 2
^C^C^C. 3
...
. 60
```
This is why the annoying scene happens[[1]], the container can't kill by `Ctrl-C`.
```text
              + ------------------ Contianer PID namespace ------------------
              |                                                           
SIG_INT/SIG_TERM ---> PID 1, /bin/sh /src/start.sh  (won't forward signals to child 
              |
              |      |                     
              |      |
              |      +----> PID 8, /src/sleep
              |                                                           
              +--------------------------------------------------------------
```
As point out by answers in [[6]], exec process and let it replace shell process solve this problem. Writing signal handler in script do the best, but can be a litte complex.
```
# cat exec.sh 
#!/bin/sh                                                                         
exec /tini -- /src/sleep

# docker run --rm --name sleep -v $PWD:/src --entrypoint /src/exec.sh zengxu/alpine:init
pid 7
. 1
. 2
^C
# 
```
What happen here is 
```text
              + ------------------ Contianer PID namespace ------------------
              |                                                           
SIG_INT/SIG_TERM ---> PID 1, /tini -- /src/sleep   (/tini replace /bin/sh as PID 1, will forward signals to child
              |
              |      |                     
              |      |
              |      +----> PID 8, /src/sleep
              |                                                           
              +--------------------------------------------------------------
```
## graceful shutdown guides
For application should shutdown gracefully, it should be coded to catch `SIGTERM` or `SIGINT`, do cleanup such as closing connections, and finally exit with 0. For Rust this guide ([handling-unix-kill-signals-in-rust]) can be followed. For Golang this ([how-to-stop-http-listenandserve]) can be followed. Other languages are your own, but solution are quite common.

[1]: https://github.com/moby/moby/issues/2838
[2]: https://github.com/rustdesk/rustdesk-server/issues/36
[3]: https://docs.docker.com/engine/reference/run/#foreground
[4]: https://github.com/tailhook/vagga/blob/275b540cec12a1c721c121be58cf5a6d63fa8863/docs/pid1mode.rst?plain=1#L8-L20
[5]: https://github.com/torvalds/linux/blob/49697335e0b441b0553598c1b48ee9ebb053d2f1/include/linux/sched/signal.h#L262
[6]: https://unix.stackexchange.com/questions/146756/forward-sigterm-to-child-in-bash
[tini]: https://github.com/krallin/tini
[dumb-init]: https://github.com/Yelp/dumb-init
[handling-unix-kill-signals-in-rust]: https://dev.to/talzvon/handling-unix-kill-signals-in-rust-55g6
[how-to-stop-http-listenandserve]: https://stackoverflow.com/questions/39320025/how-to-stop-http-listenandserve