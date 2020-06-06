---
title: "理解 OCI"
date: 2020-05-10T22:43:15+08:00
lastmod: 2020-06-03T22:43:15+08:00
draft: false
keywords: ["container","oci","docker"]
description: ""
tags: ["container","oci","docker"]
author: "Zeng Xu"
summary: "Dive into Open Container Initiative"

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

## Docker 的味道

写一个 Java HTTP 应用，启动后监听 8000 端口，执行 `curl localhost:8000/hello` 后返回 hello world。将其打包成可执行 jar 后，可通过如下 Dockerfile 将其镜像化：

```
FROM openjdk:8-jdk-alpine
WORKDIR /
COPY app.jar .
ENTRYPOINT ["java","-jar","app.jar"]
```

在独立文件夹中放置 app.jar 和 Dockerfile 并执行 docker 镜像构建命令

```
$ docker build -t oci-demo-app:v0 .
Step 1/4 : FROM openjdk:8-jdk-alpine3.9
 ---> a3562aa0b991
Step 2/4 : WORKDIR /
 ---> Using cache
 ---> 6cbcc0fdd452
Step 3/4 : COPY app.jar .
 ---> 60bf11322039
Step 4/4 : ENTRYPOINT ["java","-jar","app.jar"]
 ---> Running in 9ff5a344724b
Removing intermediate container 9ff5a344724b
 ---> 73330cad5c12
Successfully built 73330cad5c12
Successfully tagged oci-demo-app:v0
```

我已经将 oci-demo-app:v0 推送到了 Dockerhub，你可以通过 `docker pull zengxu/oci-demo-app:v0` Pull 镜像并在自己的电脑上复现本文中贴出的结果。

使用 docker run 运行容器，随之就可以通过 HTTP 请求访问服务
```
$ docker run -p 8000:8000 oci-demo-app:v0
...
[main] o.z.o.OciImageDemoApplication : Starting OciImageDemoApplication v0.0.1-SNAPSHOT on c7b8e0f373bc with PID 1 (/app.jar started by root in /)
[main] o.s.b.w.embedded.tomcat.TomcatWebServer  : Tomcat initialized with port(s): 8000 (http)
...
---
# 另起一个控制台访问服务
$ curl localhost:8000/hello
hello world
```

上面使用的 Docker 命令展示了如下功能：
1. `docker build`，镜像构建功能
2. `docker push/pull`，镜像存储功能
3. `docker run -p`，镜像解压功能、容器运行功能以及容器网络设置功能（根据镜像文件运行容器，并将容器网络端口 8000 映射到 host 网络端口 8000）

## OCI 的出现

尤其随着 Kubernetes 成熟并成为容器编排的事实标准，Docker 对于 Kubernetes 来说功能太多了
* Kubernetes 不需要镜像构建功能
* Kubernetes 只需要镜像拉取功能
* Kubernetes 有自己的 CNI 网络插件，所以也不需要 Docker 的网络功能
* ......

于是 2015 年，在 Linux 基金会的支持下有了 [Open Container Initiative (OCI)](https://opencontainers.org/about/overview/)（功能上来说就是负责制定开放社区容器标准的组织）：
>The Open Container Initiative (OCI) is a lightweight, open governance structure (project), formed under the auspices of the Linux Foundation, for the express purpose of creating open industry standards around container formats and runtime. The OCI was launched on June 22nd 2015 by Docker, CoreOS and other leaders in the container industry.

Docker 将自己容器格式和运行时 [runC](https://github.com/opencontainers/runc) 捐给了 OCI。OCI 在此基础上制定了 2 个标准：运行时标准 Runtime Specification (runtime-spec) 和 镜像标准 Image Specification (image-spec) :

`runtime-spec` 很简单，就是规范了拿到文件夹和配置文件之后，如何把容器跑起来（下文将展示它有多简单！）：
> The Runtime Specification outlines how to run a “filesystem bundle” that is unpacked on disk. 

`image-spec` 则比较啰嗦，以至于 OCI 在首页介绍中没贴出它是干嘛的。它其实规范了镜像应按照何种格式组织文件层、镜像配置文件该怎么写。你可以先忽略它，下文会展示 OCI 镜像到底是什么玩意。

> This specification defines how to create an OCI Image, which will generally be done by a build system, and output an [image manifest](https://github.com/opencontainers/image-spec/blob/master/manifest.md), a [filesystem (layer) serialization](https://github.com/opencontainers/image-spec/blob/master/layer.md), and an [image configuration](https://github.com/opencontainers/image-spec/blob/master/config.md). At a high level the image manifest contains metadata about the contents and dependencies of the image including the content-addressable identity of one or more filesystem serialization archives that will be unpacked to make up the final runnable filesystem. The image configuration includes information such as application arguments, environments, etc. The combination of the image manifest, image configuration, and one or more filesystem serializations is called the OCI Image.

## 镜像是什么
为什么讲明白规范，有必要先弄明白镜像是什么。

### Docker 镜像里有什么

通过 docker image save 命令导出镜像，并使用 tar 命令解压，使用 tree 命令即可得到镜像文件结构。没错，镜像就是 tar 格式压缩包，而且压缩包中还包含着多个 layer.tar 压缩包。

```
{
docker pull zengxu/oci-demo-app:v0
docker image save zengxu/oci-demo-app:v0 -o oci-demo-app.tar
mkdir oci-demo-app-docker-image
tar -C oci-demo-app-docker-image -xvf oci-demo-app.tar
tree oci-demo-app-docker-image
}

oci-demo-app-docker-image
├── 1a58e6937db044ef6f2e2962a0dc7bef16a6c33fdfc5a0318c39092612a1bd1a # (amd64/alpine:3.9.4)
│   ├── json
│   ├── layer.tar
│   └── VERSION
├── 98867178f60349f16652222772d086159a6d087fcd50bc32b9d75c23cd01ed8d # (openjdk8)
│   ├── json
│   ├── layer.tar
│   └── VERSION
├── c12f86d2a60fc27a1d93d555944262fda4ed66e3a3172ac45cd861151a0dc6c1 # (java_home)
│   ├── json
│   ├── layer.tar
│   └── VERSION
├── d39aa2f569c9d3100f9f2f2ddbe9133bc1688ba332d445409112952ada1fffbb #(app.jar)
│   ├── json
│   ├── layer.tar
│   └── VERSION
├── fa903e5799bb733ed874b5161bfaf6ec363b54ac9020541735305b5d515d6335.json
├── manifest.json
└── repositories
```

manifest.json 声明了镜像的配置、tag 和包含的层级，同时每个 layer 文件夹包含了一个 json 文件，声明了当前层的配置和自己的 parent layer。其实每个 layer 都是一镜像，然后组合起来成了新的镜像。通过镜像分层，存储实现在处理 Push 和 Pull 只需传输不存在的层即可。`oci-demo-app:v0` 层次关系如下：
```
amd64/alpine:3.9.4
      |
      v 
   java_home
      |
      v
   openjdk8
      |
      v
   app.jar
```

```
$ cat manifest.json  | jq
[
  {
    "Config": "fa903e5799bb733ed874b5161bfaf6ec363b54ac9020541735305b5d515d6335.json",
    "RepoTags": [
      "zengxu/oci-demo-app:v0"
    ],
    "Layers": [
      "1a58e6937db044ef6f2e2962a0dc7bef16a6c33fdfc5a0318c39092612a1bd1a/layer.tar",
      "c12f86d2a60fc27a1d93d555944262fda4ed66e3a3172ac45cd861151a0dc6c1/layer.tar",
      "98867178f60349f16652222772d086159a6d087fcd50bc32b9d75c23cd01ed8d/layer.tar",
      "d39aa2f569c9d3100f9f2f2ddbe9133bc1688ba332d445409112952ada1fffbb/layer.tar"
    ]
  }
]
```
如果查看 json config 文件，就会找到之前在 Dockerfile 中声明的 EntryPoint，同时也包含了 Linux std、tty 以及熟悉的 Java 环境变量。

```json
{
  "architecture": "amd64",
  "config": {
    "Hostname": "",
    "Domainname": "",
    "User": "",
    "AttachStdin": false,
    "AttachStdout": false,
    "AttachStderr": false,
    "Tty": false,
    "OpenStdin": false,
    "StdinOnce": false,
    "Env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/lib/jvm/java-1.8-openjdk/jre/bin:/usr/lib/jvm/java-1.8-openjdk/bin",
      "LANG=C.UTF-8",
      "JAVA_HOME=/usr/lib/jvm/java-1.8-openjdk",
      "JAVA_VERSION=8u212",
      "JAVA_ALPINE_VERSION=8.212.04-r0"
    ],
    "Cmd": null,
    "Image": "sha256:9fbacfbc982e07b153f6f23f0857a33765bc48d3c935a051dd16ad132f749ef7",
    "Volumes": null,
    "WorkingDir": "/",
    "Entrypoint": [
      "java",
      "-jar",
      "app.jar"
    ],
    "OnBuild": null,
    "Labels": null
  },
  ...
}
```
如果我们按照压缩包中 layer 的关系，从顶层开始，逐级解压文件再合并组织到一个目录树，得到的就是容器运行时文件系统。
```
app.jar	 bin  dev  etc  home  lib  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var
```

实际上，如果通过 `docker export` 命令将容器文件系统导出，也会得到该文件结构
```
$ docker pull zengxu/oci-demo-app:v0
$ docker export $(docker create zengxu/oci-demo-app:v0) > oci-demo-app-container.tar
$ mkdir oci-demo-app-container
$ tar -C oci-demo-app-container -xvf oci-demo-app-container.tar
$ ls ./oci-demo-app-container
app.jar  bin  dev  etc  home  lib  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var
```

### 转换 Docker 镜像为 OCI 镜像

使用 [skopeo](https://github.com/containers/skopeo) 将远程镜像拷贝以 OCI 格式拷贝到本地
```
$ skopeo copy docker://zengxu/oci-demo-app:v0 oci:oci-demo-app:v0
Getting image source signatures
Copying blob e7c96db7181b done
Copying blob f910a506b6cb done
Copying blob c2274a1a0e27 done
Copying blob e4d6c83503a9 done
Copying config d4a44c93e6 done
Writing manifest to image destination
Storing signatures
```

得到的 OCI 格式镜像由如下部分组成
* index.json，故名思义，索引文件，指向了镜像 manifest 文件列表，如果镜像包含多个不同版本软件包，那么每个版本各对应一个 manifest 项
* oci-layout, json 格式文件，只有一个字段 `imageLayoutVersion`，指明了目前镜像组织形式的版本，当前为 `1.0.0`
* blobs/sha256，sh256 表示每个文件签名（也即文件名）所用的算法，包含了镜像 mafifest 文件、镜像 config 文件和一系列 layer 压缩文件，和 docker client 导出的不同，这里的 layer 压缩文件是 .tar.gz 格式

```
$ sudo tree oci-demo-app
oci-demo-app
├── blobs
│   └── sha256
│       ├── c2274a1a0e2786ee9101b08f76111f9ab8019e368dce1e325d3c284a0ca33397
│       ├── d45802acb2a6c862e2d5576bd9bb90d7a2a57cfcbc160b81cf44322c8e20ab73   <----------------|
│       ├── d4a44c93e6326fd854b559a254310ba3e8861e7e35d062607f0a32e7562e9deb                    |
│       ├── e4d6c83503a9bf0b4922dd67e42b92eb8c3d5a59322585570c6c6f91b1cbd924                    |
│       ├── e7c96db7181be991f19a9fb6975cdbbd73c65f4a2681348e63a141a2192a5f10                    |
│       └── f910a506b6cb1dbec766725d70356f695ae2bf2bea6224dbe8c7c6ad4f3664a2                    |
├── index.json                                                                                  |
└── oci-layout                                                                                  |
                                                                                                |
$ cat oci-demo-app/index.json | jq                                                              |
{                                                                                               |
  "schemaVersion": 2,                                                                           |
  "manifests": [                                                                                |
    {                                                                                           |
      "mediaType": "application/vnd.oci.image.manifest.v1+json",                                |
      "digest": "sha256:d45802acb2a6c862e2d5576bd9bb90d7a2a57cfcbc160b81cf44322c8e20ab73", <----|
      "size": 821,
      "annotations": {
        "org.opencontainers.image.ref.name": "v0"
      }
    }
  ]
}
```

根据 index.json，可以立马找到镜像 manifest 文件， OCI 格式比 docker 直接导出更有描述性
* application/vnd.oci.image.config.v1+json，json 格式的配置文件，和上面 docker 导出的一样
* application/vnd.oci.image.layer.v1.tar+gzip，镜像 layer 层，和 docker 直接导出一样是 4 个

```
$ cat oci-demo-app/blobs/sha256/d45802acb2a6c862e2d5576bd9bb90d7a2a57cfcbc160b81cf44322c8e20ab73 | jq
{
  "schemaVersion": 2,
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:d4a44c93e6326fd854b559a254310ba3e8861e7e35d062607f0a32e7562e9deb",
    "size": 2698
  },
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:e7c96db7181be991f19a9fb6975cdbbd73c65f4a2681348e63a141a2192a5f10",
      "size": 2757034
    },
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:f910a506b6cb1dbec766725d70356f695ae2bf2bea6224dbe8c7c6ad4f3664a2",
      "size": 238
    },
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:c2274a1a0e2786ee9101b08f76111f9ab8019e368dce1e325d3c284a0ca33397",
      "size": 70732768
    },
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:e4d6c83503a9bf0b4922dd67e42b92eb8c3d5a59322585570c6c6f91b1cbd924",
      "size": 14737188
    }
  ]
}
```

### OCI V1 和 Docker Image Manifest V2
使用如下命令从 docker registry 获取镜像 zengxu/oci-demo-app:v0 的 Docker Image manifest V2，两边对比可以发现，OCI V1 Image manifest 的 layer 压缩文件与 Docker Image manifest V2 sha256 值完全一致，只是 OCI V1 Image config 文件小一些（因为 docker Image Config 会额外包含容器配置和 Docker 相关信息）。
{{<highlight text "linenos=table,hl_lines=12-17,linenostart=0">}}
{
TOKEN="Bearer $(curl -s \
    "https://auth.docker.io/token?scope=repository%3Azengxu%2Foci-demo-app%3Apull&service=registry.docker.io" \
    | jq -r '.token')"
curl -s https://registry-1.docker.io/v2/zengxu/oci-demo-app/manifests/v0 \
    -H "Authorization:$TOKEN" -H "Accept:application/vnd.docker.distribution.manifest.v2+json" \
    | jq
}
---
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
  "config": {
    "mediaType": "application/vnd.docker.container.image.v1+json",
    "size": 3792,
    "digest": "sha256:fa903e5799bb733ed874b5161bfaf6ec363b54ac9020541735305b5d515d6335"
  },
  "layers": [
    {
      "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
      "size": 2757034,
      "digest": "sha256:e7c96db7181be991f19a9fb6975cdbbd73c65f4a2681348e63a141a2192a5f10"
    },
    {
      "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
      "size": 238,
      "digest": "sha256:f910a506b6cb1dbec766725d70356f695ae2bf2bea6224dbe8c7c6ad4f3664a2"
    },
    {
      "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
      "size": 70732768,
      "digest": "sha256:c2274a1a0e2786ee9101b08f76111f9ab8019e368dce1e325d3c284a0ca33397"
    },
    {
      "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
      "size": 14737188,
      "digest": "sha256:e4d6c83503a9bf0b4922dd67e42b92eb8c3d5a59322585570c6c6f91b1cbd924"
    }
  ]
}
{{</highlight>}}

事实上，OCI Image Spec V1 就是基于 Docker Image Manifest V2 而来，两者的几乎一致。 MediaType 的对应关系可以在 [这里](https://github.com/opencontainers/image-spec/blob/master/manifest.md) 找到。

<img src="/img/2020567/oci-image-spec.png" width="600px">
{{% center %}}
图来自 github opencontainers/image-spec
{{% /center %}}


如果我们使用 Docker Registry V2 api `GET /v2/<name>/blobs/<digest>` (如 https://registry-1.docker.io/v2/zengxu/oci-demo-app/blobs/sha256:e4d6c83503a9bf0b4922dd67e42b92eb8c3d5a59322585570c6c6f91b1cbd924) 逐个下载 blob，并按照 OCI layout 组织，得到的结果和 [skopeo](https://github.com/containers/skopeo) copy 是一致的。

这里直接使用工具 [oci-image-tool](https://github.com/opencontainers/image-tools) 将下载压缩包转化为文件系统，结果也是同样

```
$ mkdir oci-demo-app-bundle
$ oci-image-tool unpack --ref name=v0 oci-demo-app oci-demo-app-bundle
$ ls oci-demo-app-bundle
app.jar  bin  dev  etc  home lib  media mnt  opt  proc root run sbin srv sys tmp  usr  var
```

### 镜像是什么
经过上面的实操折腾，再来理解这段英文

> At a high level the **image manifest** contains metadata about the contents and dependencies of the image including the content-addressable identity of **one or more filesystem serialization archives** that will be unpacked to make up the final runnable filesystem. The **image configuration** includes information such as application arguments, environments, etc. 
> 
> **The combination of the image manifest, image configuration, and one or more filesystem serializations is called the OCI Image.**

直白来说

{{% admonition%}}
镜像 = 一份文件清单 (manifest) + 一个或多个文件压缩包 (layer) + 一份配置文件 (config)

**文件清单**列明了镜像所需的文件压缩包，同时指明了每种压缩包使用的压缩算法、哈希值和文件大小 (字节数)

**配置文件**包含了程序运行所需的硬件架构、操作系统、系统环境变量、启动命令、启动参数、工作目录等。
{{%/ admonition %}}

利用文件压缩包 hash 值的唯一性，镜像存储设施在交互时，只需根据文件清单检查本地存储，相同的压缩包只需存储一份即可，大幅提高了镜像分发的效率。在一个预热良好的机器上，传输镜像相当于只传输程序包。

用户只需提供程序包、程序配置，并声明程序依赖，即可通过构建工具组织出镜像。

<img src="/img/2020567/oci-build-diagram.png" width="800px">
{{% center %}}
图来自 github opencontainers/image-spec
{{% /center %}}

按照 OCI 规范组合并解压这些压缩包，便组成了一个包含程序包包和程序依赖库的可运行文件系统。只要把该文件系统 (在 OCI 规范中叫做 rootfs) 和 json 配置文件交给 OCI 容器运行时，容器运行时便能够按照用户期望运行目标应用程序。

## runC

runC 是 OCI 提供的 `runtime-spec` 标准实现，使用它可以直接运行容器。

### 简单 runC 容器
经过上面铺垫，接着使用 OCI runC 从 bundle 文件夹创建容器。首先新建 rootfs 目录，把文件都拷贝到 rootfs 目录
```
{
cd oci-demo-app-bundle
mkdir rootfs
mv -r * ./rootfs/
}
```

使用 runC spec 生成 OCI 容器运行配置文件 config.json，稍做修改以与镜像配置保持一致

```
{
runc spec
sed -i 's;"sh";"java","-jar","app.jar";' config.json
sed -i 's;"terminal": true;"terminal": false;' config.json
sed -i 's;"readonly": true;"readonly": false;' config.json
chmod -R 777 ./rootfs/tmp/
}
```

修改后的 config.json 如下
```
{
  "ociVersion": "1.0.1-dev",
  "process": {
    "terminal": false,
    ...
    "args": [
      "java","-jar","app.jar"
    ],
    ...
  }
  "root": { 
    "path": "rootfs",
    "readonly": false
  },
  ...  
}
```

使用 runc run 以 detach 模式运行容器，并通过 runc list 查看容器运行情况
```
# runc run -d oci-demo-app > oci-demo-app.out 2>&1
# runc list
ID             PID         STATUS     ...   OWNER
oci-demo-app   3054        running    ...   root
# ps -ef | grep 3054
root  3054  1  0 ...  00:01:18 java -jar app.jar

cat oci-demo-app.out
...
[main] o.z.o.OciImageDemoApplication: Starting OciImageDemoApplication v0.0.1-SNAPSHOT with PID 1 (/app.jar started by root in /)
...
[main] o.s.b.w.embedded.tomcat.TomcatWebServer  : Tomcat started on port(s): 8000 (http) with context path ''
```

通过 runC  exec 进入容器 shell 控制台，运行 ifconfig 会发现，默认情况下 runC 容器只有一张 loop 网卡，只有 127.0.0.1 一个地址
```
runc exec -t oci-demo-app sh

/ # ifconfig
lo  Link encap:Local Loopback
    inet addr:127.0.0.1  Mask:255.0.0.0
    inet6 addr: ::1/128 Scope:Host
    UP LOOPBACK RUNNING  MTU:65536  Metric:1
    RX packets:24 errors:0 dropped:0 overruns:0 frame:0
    TX packets:24 errors:0 dropped:0 overruns:0 carrier:0
    collisions:0 txqueuelen:1000
    RX bytes:1536 (1.5 KiB)  TX bytes:1536 (1.5 KiB)
```

也即，通过这种方式运行的容器，被隔离在独立 cgroup 的 network namespace 中，无法直接从宿主机访问容器。

### 给 runC 容器绑定虚拟网卡
先停止并移除容器
```
# runc kill oci-demo-app
# runc delete oci-demo-app
```
注: brctl 可能需自行安装，CentOS 可以通过如下命令
```
sudo yum install bridge-utils -y
```

使用 brctl 生成在宿主机生成网桥 runc0 并往 runc0 上挂一张虚拟网卡，网卡的一端 veth-host 绑定在宿主机，网卡的另外一端 veth-guest 将绑定到容器（即容器里的 eth0）。

同时使用 ip netns 针对 namespace 进行操作，我们赋予容器网卡（地址在 /var/run/netns/runc-demo-contaienr），同时给予它一个 IP 地址 10.200.0.2，如此一来即可访问容器。
```
{
brctl addbr runc0
ip link set runc0 up
ip addr add 10.200.0.1/24 dev runc0
ip link add name veth-host type veth peer name veth-guest
ip link set veth-host up
brctl addif runc0 veth-host
ip netns add runc-demo-contaienr
ip link set veth-guest netns runc-demo-contaienr
ip netns exec runc-demo-contaienr ip link set veth-guest name eth0
ip netns exec runc-demo-contaienr ip addr add 10.200.0.2/24 dev eth0
ip netns exec runc-demo-contaienr ip link set eth0 up
ip netns exec runc-demo-contaienr ip addr add 127.0.0.1 dev lo
ip netns exec runc-demo-contaienr ip link set lo up
ip netns exec runc-demo-contaienr ip route add default via 10.200.0.1
}
```

修改 config.json .linux.namespaces 的网络部分
{{<highlight text "linenos=table,hl_lines=8-9,linenostart=1">}}
{
  ...
  "linux": {
    ...
    "namespaces": [
      ...
      {
        "type": "network",
        "path": "/var/run/netns/runc-demo-contaienr"
      },
      ...
    ],
    ...
  }
}
{{</highlight>}}

运行容器，并使用 curl 访问容器服务，网络通了
```
# runc run -d oci-demo-app > oci-demo-app.out 2>&1
# curl 10.200.0.2:8000/hello
hello world
```
如果进入容器，可以发现多了一张 eth0 网卡
```
runc exec -t oci-demo-app sh
/ # ifconfig
eth0      Link encap:Ethernet  HWaddr 66:25:83:FA:3D:27
          inet addr:10.200.0.2  Bcast:0.0.0.0  Mask:255.255.255.0
          inet6 addr: fe80::6425:83ff:fefa:3d27/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:55 errors:0 dropped:0 overruns:0 frame:0
          TX packets:57 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:4426 (4.3 KiB)  TX bytes:4080 (3.9 KiB)

lo        Link encap:Local Loopback
          inet addr:127.0.0.1  Mask:255.255.255.255
          inet6 addr: ::1/128 Scope:Host
          UP LOOPBACK RUNNING  MTU:65536  Metric:1
          RX packets:24 errors:0 dropped:0 overruns:0 frame:0
          TX packets:24 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:1536 (1.5 KiB)  TX bytes:1536 (1.5 KiB)
```
同样，在宿主机可以看到 runc0 网桥和  veth-host 网卡，这里不再展示。Docker 网络原理也是类似的，你会在自己机器上发现名为 docker0 的网桥和若干名为 veth-xxxx 的虚拟网卡。

值得一提的是，如果多个容器可以共享同一张 namespace 网卡，同一空间内的容器之间网络也是通的，这就是 k8s Pod 的网络原理。

## OCI 标准的意义
在 OCI 之前，容器生态发展百花齐放，Docker 一骑绝尘瞩目，但大小社区各自为政，开发人员兼容疲惫，用户使用痛苦。

有了 OCI 镜像标准之后，不同平台在沿着各自方向优化镜像的存储和传输，同时也能够使用同一套标准下实现互通，用户因此得以在不同平台自由迁移。

借助 OCI Runtime 标准，客户端只需提供 rootfs 和 config.json 声明，便可借助不用的 OCI Runtime 实现，将应用跑到不同操作系统上，且达到不同的隔离效果。如只需达到 namespace 级别隔离，Linux 使用 runC，Windows 使用 runhcs，这也是传统容器的隔离级别，隔离资源但并不隔离内核。如果需要达到 VM 级的强隔离，可以使用 gVisor runsc 实现用户态内核隔离，也可以借助 hyper runV 实现 hypervisor VM 级别隔离。

<img src="/img/2020567/oci2containers.jpg" width="666px">

OCI 既没有定下网络标准，也没有定下存储标准，因为这都与平台实现关联。但如 runC 小结展示，使用方只要使用平台相关技术（示例是 Linux namespace network)，就能挂载好网络和存储。OCI Runtime 实现支持使用 create 和 start 2 阶段启动容器，使用方可以在 create 和 start 间隔准备网络、存储等资源。

如今比较流行容器网络接口标准是 [CNCF CNI](https://github.com/containernetworking/cni)，比较流行的容器存储标准是 [container-storage-interface-community CSI](https://github.com/container-storage-interface/spec/blob/master/spec.md)。

事实上，正是 OCI 将标准定在足够低级的通用范围，才取得了巨大的成功。

现如今，它跨云平台、跨操作系统、跨硬件平台、支持各种隔离......

## Reference
* [runtime-spec](https://github.com/opencontainers/runtime-spec/blob/master/spec.md)
* [image-spec](https://github.com/opencontainers/image-spec/blob/master/spec.md)
* [Docker Registry Api](https://docs.docker.com/registry/spec/api/)
* [runC](https://github.com/opencontainers/runc)
* [runV](https://github.com/hyperhq/runv), [kata-containers](https://katacontainers.io/)
* [gVisor](https://gvisor.dev/), [runsc](https://github.com/google/gvisor/tree/master/runsc)
* [Container platform tools on Windows](https://docs.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/containerd)
* [CNI](https://github.com/containernetworking/cni), [CSI](https://github.com/container-storage-interface)