---
title: "各种容器运行时都解决了什么问题"
date: 2020-07-01T17:31:56+08:00
lastmod: 2020-07-20T08:31:56+08:00
draft: false
keywords: ["container","oci","kubernetes","containerd","docker","cri-o"]
description: ""
tags: ["container","oci","kubernetes","containerd","docker","cri-o"]
author: "Zeng Xu"
summary: "容器运行时原理小综述"

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

## 低级容器运行时
低级容器运行时 (Low level Container Runtime)，一般指按照 OCI 规范实现的、能够接收可运行文件系统（rootfs） 和 配置文件（config.json）并运行隔离进程的实现。

这种运行时只负责将进程运行在相对隔离的资源空间里，不提供存储实现和网络实现。但是其他实现可以在系统中预设好相关资源，低级容器运行时可通过 config.json 声明加载对应资源。我在文章 [理解 OCI](../20200510-container-oci/#runc) 详细介绍了 runC 的执行细节，并展示了如何使用 Linux namespace network 为容器添加可与宿主机通信的虚拟网卡。

低级运行时的特点是底层、轻量、灵活，限制也很明显：
* 只认识 rootfs 和 config.json，不认识镜像 (下文简称 image)，不具备镜像存储功能，也不能执行镜像的构建、推送、拉取等（我们无法使用 runC, kata-runtime 处理镜像）
* 不提供网络实现，所以真正使用时，往往需要利用 [CNI](https://github.com/containernetworking/cni) 之类的实现为容器添加网络
* 不提供持久实现，如果容器是有状态应用需要使用文件系统持久状态，单机环境可以挂载宿主机目录，分布式环境可以自搭 NFS，但多数会选择云平台提供的 [CSI](https://github.com/container-storage-interface/spec) 存储实现
* 与特定操作系统绑定无法跨平台，比如 runC 只能在 Linux 上使用；runhcs 只能在 Windows 上使用
 
解决了这些限制中一项或者多项的容器运行时，就叫做高级容器运行时 (High level Container Runtime)。

## 高级容器运行时第一要务

高级容器运行时首先要做的是打通 OCI image spec 和 runtime spec，直白来说就是高效处理 image 到 rootfs 和 config.json 的转换。config.json 的生成比较简单，运行时可以结合 image config 和请求方需求直接生成；较为复杂的部分是 image 到 rootfs 的转换，这涉及镜像拉取、镜像存储、镜像 layer 解压、解压 layer 文件系统（fs layer) 的存储、合并 fs layer 为 rootfs。

<img src="/img/2020567/img2rootfs.png" width="666px"/>

镜像拉取模块先从 image registry 获取清单（manifest）文件，处理过程不仅需要兼容 OCI image 规范，考虑到 Docker 生态，也需兼容 Docker image 规范（所幸两者区别并不大）。运行时实现先从 manifest 获取 layer list，先检查对应 layer 在本地是否存在，如果不存在则下载对应 layer。下载的 layer tar 或者 tar.gz 一般直接存储磁盘，为实现快速处理，需要建立索引，比如从 reference:tag （如 docker.io/library/redis:6.0.5-alpine) 到 manifest 存储路径的映射；当然，layer 的访问比 image 高频，layer sha256 值到对应存储路径也会被索引。因此 ，运行时一般会围绕 image 索引和 image layer 存储组织独立模块对其他模块提供服务。

如果要转换 image layers 到 rootfs，就要逐层解压 layers 为 filesystem layer（fs layer) 再做合并。这带来了几个问题，首先是 fs layer 同样需要存储磁盘多次复用，那么就需要有一个方式从 image 映射到对应 fs layers；接着类似 image layer，需要建立索引维系 fs layers 之间的父子关系，尽可能复用里层文件，避免重复工作；最后是层次复用带来的烦恼，隔离进程运行之后会发生 rootfs 写入，需要以某种方式避免更改发生到共享的 fs layers。
* 第一个问题一般使用 image config 文件中的 diffID 解决，每解压一层 layer，就使用上一层 fs layer id 和 本层 diffID 的拼接串做 sha256 hash，输出结果作为本层对应的 fs layer id（最里层 id 为其 diffID），接着建立 id 到磁盘路径索引。因此只要通过 image manifest 文件找到 image config 文件，即可找到所有 fs layers，详细实现方式见 [OCI image spec layer chain id](https://github.com/opencontainers/image-spec/blob/e562b04403929d582d449ae5386ff79dd7961a11/config.md#layer-chainid)。
* 第二个问题解决方式很简单，在每个 fs layer 索引存储上一层 fs layer id 即可。
* 第三个问题，一般通过 UnionFS 提供的 CopyOnWrite 技术解决，简单来说，就是使用空文件夹，在镜像对应 fs layer 最外层之上再生成一层 layer，使用 UnionFS 合并（准确来说是挂载 mount）时将其声明为 work 目录（或者说 upper 目录）。UnionFS 挂载出 rootfs 之后，隔离进程所做的任何写操作（包括删除）都只体现在 work layer，而不会影响其他 fs layer。（详细介绍可以参考 [陈皓的介绍文章](https://coolshell.cn/articles/17061.html))

最后，高级运行时需要充当隔离进程管理者角色，而一个低级运行时（如 runC ）可能同时被多个高级运行时使用。同时试想，如果隔离进程退出，如何以最快的方式恢复运行？高级运行时实现一般都会引入 container 抽象（或者说 container meta），meta 存储了 ID、 image 信息、低级运行时描述、OCI spec (json config）、 work layer id 以及 K-V 结构的 label 信息。因此只要创建出 container meta，后续所有与隔离进程相关操作，如进程运行、进程信息获取、进程 attach、进程日志获取，均可通过 container ID 进行。

## containerd

containerd 是一个高度模块化的高级运行时，所有模块均以 RPC service 形式加载（gRPC 或者 TTRPC），所有模块均可插拔。不同插件通过声明互相依赖，由 containerd 核心实现统一加载，使用方可以使用 Go 语言实现编写插件实现更丰富的功能。不过这种设计使得 containerd 拥有强大的跨平台能力，并能够作为一个组件轻松嵌入其他软件，也带来一个弊端，模块之间功能互调也从简单的函数调用，变成了更为昂贵的 RPC 调用。

注：[TTRPC](https://github.com/containerd/ttrpc) 是一种基于 gRPC 的改良通信协议。

<img src="/img/2020567/containerd-arch.png" width="600px"/>
{{%center%}}containerd 架构图{{%/center%}}

containerd 大多功能模块很容易与上文提到的「第一要务」相联系 ：
* Content，以 image layer 哈希值（一般使用 sha256 算法生成）为索引，支持快速 layer 快速查找和读取，并支持对 layer 添加 label。索引和 label 信息存储在 boltDB。 
* Images，在 boltDB 中存储了 reference 到  manifest layer 的映射，结合 Content 可以组织完整的 image 信息。
* Snapshot，存储、处理解压后的 fs layers 和容器 work layer，索引信息同样存储在 boltDB。Snapshot 内置支持多种 UnionFS（如 overlay，aufs，btrfs）。
* Containers，以 container ID 为索引，在 boltDB 中存储了低级运行时描述、 snapshot 文件系统类型、 snapshotKey（work layer id）、image reference 等信息。
* Diff，可用于比对 image layer tar 和 fs layers 差异输出 diffID，可以校验 image config 中的 diffID，同样也能比对 fs layers 之间的差异。

基于以上模块，containerd 提供了 namespace 隔离，实现上是在各模块的内容放置于不同目录树，达到资源隔离效果。比如，它可以一边服务于 Docker，一边服务 k8s kubelet，做到两不冲突。

还有重要模块是 Tasks (runtime.PlatformRuntime)，它负责容器进程管理和与低级运行时打交道，对上统一了容器进程运行接口。v1 版 Tasks 只支持 Linux，1.2.0 (2018/11) 后 containerd 正式支持 Windows，新引入的 v2 版 Tasks 核心逻辑使用平台无关代码实现，因此可以在 Go 语言支持的大部分平台运行（包括 macOS darwin/amd64)。

containerd 运行容器，一般先从 Images 模块触发，结合 Snapshot 模块建立新的容器 fs layer，加上低级运行时信息，组合成 container 结构体。containerd 利用 container 结构体，将之前的所有 Snapshots 转换为 Mounts 对象（声明了所有子文件夹的位置和挂载方式），结合低级运行时、OCI spec、镜像等信息在请求体中，向 Tasks 模块提交任务请求。Tasks 模块 Manager 根据任务低级运行时信息（如 io.containerd.runc.v1），组合出统一的 containerd-shim 进程运行命令，通过系统调用启动 shim 进程，并同步建立与 shim 进程的 TTRPC 通信。随后将任务交给 shim 进程管理。shim 进程接到请求后，判知 Mounts 长度大于 0，则会按照 Mounts 声明的挂载方式，使用 overlay、aufs 等联合文件系统将所有子文件夹组成容器运行需要的 rootfs，结合 OCI spec 调用低级运行时运行容器进程并将结果返回给 containerd 进程。

使用 shim 进程管理容器进程好处很多，containerd clash，containerd-shim 进程和容器进程不会受影响，containerd 恢复后只需读取运行目录的 socket 文件及 pid 恢复与 shim 进程通信即可快速还原 Tasks 信息（Unix 平台），同一容器进程出现问题，对于其他进程来说是隔离。最重要的是，通过统一的 shim 接口，同一套 containerd 代码可以同时兼容多个不同的运行时，也能同时兼容不同操作系统平台。

<img src="/img/2020567/ctrd-shim.png" width="450px"/>

containerd 不提供容器网络和容器应用状态存储解决方案，而是把它们留给了更高层的实现。

container 在其 [介绍](https://github.com/containerd/containerd) 中提到：其设计目的是成为大系统中的一个组件（如 Kubernetes, Docker)，而非直接供用户使用。
> containerd is designed to be embedded into a larger system, rather than being used directly by developers or end-users。

下文会展示这意味着什么。

## CRI-O
相比 containerd，CRI-O 的高级运行时功能基于若干开源库实现，不同模块之间为纯粹 Go 语言依赖，而非通信协议：
* containers/image 库用于 Image 下载，下载过程类似 2 阶段提交。不同来源的镜像（如 Docker, Openshift, OCI）先被统一为 ImageSource 通用抽象，接着被分为 3 部分进行处理：blob 被放置在系统临时文件夹，manifest 和 signature 缓存在内存（Put*）。之后，镜像内容 Commit 至 containers/storage 库。
* CRI-O 大部分业务逻辑集中在 containers/storage 之上
  * LayerStore 接口统一处理 image layer（不包括 config layer） 和 fs layer，镜像 Commit 存储时，LayerStore 先调用 fs 驱动实现（如 overlay）在磁盘创建 fs layer 目录并记录层次关系，接着调用 ApplyDiff 方法，解压内容被存放在 layer 目录（经驱动实现），未解压内容被存放在 image layer 目录，fs layer 层次关系存储在 json 文件。
  * ImageStore 接口处理 image meta，包括 manifest、config 和 signature，meta 与 layer 关联索引存储在 json 文件。
  * ContainerStore 接口管理 container meta，创建 container 的步骤和存储 image layer 代码路径近乎重合，只不过前者被限制为 read 模式，后者为 readWrite，且没有 ApplyDiff（diff 送空），meta 与 layer 关联索引也存储在 json 文件。

containers/storage 库 container meta 没有 namespace 概念，但提供一个 metadata 字段（string 类型）可以存储任意内容，CRI-O 便是将包括 namespace 在内的业务信息序列化为 json string 存储其中。

CRI-O 运行容器进程时，先确保对应 image 存在（不存在则尝试下载），随之基于 image top layer 创建 UnionFS，同时生成 OCI spec config.json，之后，根据请求方提供的低级运行时信息（RuntimeHandler），使用不同包装实现操作容器进程。
* 如果 RuntimeHandler 为非 VM 类型，创建并委托监视进程 [conmon](https://github.com/containers/conmon) 操作低级运行时创建容器。之后，conmon 在特定路径提供一个可与容器进程通信的 socket 文件，并负责持续监视容器进程并负责将其 stream 写入指定日志文件。容器进程创建成功之后，CRI-O 直接与低级运行时交互执行 start、delete、update 等操作，或者通过 socket 文件直接与容器进程交互。
* 如果 RuntimeHandler 为 VM，则创建并委托 containerd-shim 进程处理间接容器进程（请求包含完整 rootfs，Mounts 为 空）。与非 VM 类型不同，此后所有容器进程相关操作均通过 shim 完成。

<img src="/img/2020567/crio-arch.png" width="700px"/>
{{%center%}}CRI-O 架构图{{%/center%}}

CRI-O 依靠 CNI 插件（默认路径 /opt/cni/bin）为容器进程提供网络实现。其逻辑一般在低级运行时创建完隔离进程返回后，获取 pid 后将对应的 network namespace path（/proc/{pid}/ns/net）交给 CNI 处理，CNI 会根据配置会往对应 namespace 添加好网卡。一般地，容器进程会在 cni 网桥上获得一个独立 IP 地址，这个 IP 地址能与宿主机通信，如果 CNI 配置了  flannel 之类的 overlay 实现，容器甚至能够与其他主机的同一网段容器进程通信，具体视配置而定。细节方面可以参考 [这篇介绍](https://karampok.me/posts/container-networking-with-cni/)。

如果指定由其管理 network namespace 生命周期（配置 manage_ns_lifecycle），则会在创建 sandbox 容器时采用类似 [理解 OCI#给 runC 容器绑定虚拟网卡](../20200510-container-oci/#-runc-1) 的方式创建虚拟网卡，随后通过 OCI json config 传递对应路径给低级运行时。同样地，当 sandbox  容器销毁时，CRI-O 会自动回收对应 namespace 资源。这部分逻辑的网络相关代码使用 C 语言实现，在 CRI-O 中以名为 pinns 的二进制程序发行。

需要指出的是，CRI-O 使用文件挂载方式配置容器 hostname, dns server 等，而非 CNI 插件。

## Docker

Docker 是一个大而完备的高级运行时，其用户端核心叫做 [Docker Engine](https://docs.docker.com/engine/)，由 3 部分构成：Docker Server (docker daemon, 简称 dockerd)、REST API 和 Docker cli。借助 Docker Engine 既能便捷地运行容器进程进行集成开发、也能快速构建分发镜像。

<img src="/img/2020567/docker-arch.png" width="777px"/>

如上图所示，Docker Engine 的核心是 dockerd，既驱动镜像的构建分发，也为容器运行提供成熟的持久实现和网络实现。Docker cli 使用 REST API 与 dockerd 交互。

与上文其他运行时不同，dockerd 以 image config 为核心，使用 config layer 的 sha256 hash 值索引 image 抽象，而不是 manifest。实际上，dockerd 根本不存储 manifest。dockerd 也不存储 image layers（tar, tar.gz 等)，而只存储解压后的 layer fs 和一些必要的索引。
* 镜像下载时，dockerd 先自 registry 获取 manifest 文件，随后并行下载存储 image layers 和 config layer。与 containers/storag 类似，image layer 解压内容由 fs 驱动实现（如 overlay) 存储至新建的子目录中（如 /var/lib/docker/overlay2/{new-dir}），不同的是，随后 dockerd 只是以 layer chainID 为索引，存储 fs new-dir、diffID、parent chainID、size 等必要信息，并不存储未解压 tar 或 tar.gz。image layers 和 config layer 均存储完成后，再以 image reference 为索引，建立 reference 至 image ID 映射。作为镜像分发模块的一部分，dockerd 还会以 manifest layer digest 为索引，建立 digest 至 diffID 映射；以 diffID 为索引，建立 diffID 至 repository 和 digest 映射。
* 镜像推送不过是镜像下载的逆过程。dockerd 先使用 reference 获取 imageID（也即 image config），随后以 imageID 为中心组织出目标 manifest，对应的 layer fs 开始被压缩成目标格式（一般是 tar.gz）。layers 开始上传时，自分发模块获取 diffID 至 repository 和 digest 信息，发起远程请求确认对应 layer 是否已存在，存在则跳过上传，最终以 manifest 为中心的镜像被分发至对应 Registry 实现。

Docker Engine 配套了成熟的镜像构建技术，它使得开发者只需提供一个目录、一份 Dockerfile，外加一行 `docker build` 命令即可构建镜像。简单来看，镜像构建过程即是把应用依赖的文件系统和运行环境转化为 image layers 和 config 的过程，构建结果是能够索引到构建结果的 reference，即我们熟悉的 tag。但简单的接口后面隐藏着非常多的考量，比如怎样提高镜像构建速度，比如怎样检查构建期错误。我们已经知道一份镜像包含多份 layers，基于什么镜像构建新镜像就会在之前的 layers 上构建新 layers。实际上，dockerd 会将 Dockerfile 中的每一行命令转化为一个构建子步骤，每执行一步，都可能产生中间镜像和中间容器。`COPY`, `ADD` 等文件传输命令一般直接产生中间镜像，`RUN`、`ENV`、`EXPOSE` 等运行命令会产生中间容器。每成功一步，该步骤产生的中间镜像或者 config 就会成为下一步的基础，产生的中间容器随之被移除，产生的中间镜像会被保存供后续复用。构建结束时，最后一步产生的镜像会被关联到 tag（如果指定了）。dockerd 维护了镜像构建过程产生的 parent-child 关系，使用 `docker image  ls` 命令罗列镜像时，没有 tag 且存在 child 的镜像会被过滤，如此便过滤了中间镜像。此外，docker cli 会将中间结果输出到控制台，这样如果构建出错，用户可以利用间镜像和中间容器排查问题。

Docker 容器创建运行相较 containerd 和 CRI-O 有更多高层的存储和网络抽象，如使用 `-v,--volume` 命令即可声明运行时需挂载的文件系统，使用 `-p,--publish` 即可声明 host 网络至容器网络映射，这些声明信息会被持久在 docker 工作目录下的 containers 子目录。

执行运行命令之际，dockerd 首先生成容器读写层并通过 UnionFS 与 fs layers 一道转化为 rootfs。接着，image config 中的环境、启动参数等信息被转化为 OCI runtime spec 参数。同时类似 CRI-O，dockerd 会为容器生成一些特殊的文件，如 /etc/hosts, /etc/hostname, /etc/resolv.conf, /dev/shim 等，随之这些特殊文件与 volume 声明或者 mount 声明一起作为 dockerd Mount 抽象转化为 OCI runtime spec Mount 参数。最后，rootfs、OCI runtime spec 和低级运行时信息通过 RPC 请求传递给 containerd，剧情变得和 containerd 运行容器一致。

不难发现，虽然持久挂载驱动各异，但对运行时而言，本质都是将宿主机某类型的文件目录映射到容器文件系统中。因此对于低级运行时而言，挂载逻辑可以统一。dockerd 在此之上发展了丰富的持久业务层，以便于用户使用。mount 用于直接将宿主机目录挂载至容器文件系统；volume 相对 bind mounts 优势是对应文件持久在 dockerd 的工作目录，由 dockerd 管理，同时具有跨平台能力。tmpfs 则由操作系统提供容器读写层之外的临时存储能力。

dockerd 支持多种网络驱动，其基础抽象叫做 endpoint，可以简单将 endpoint 理解为网卡背后的网络资源。对于每一 endpoint，dockerd 都会通过 IPAM 实现在 docker0 网桥上分配 IP 地址，接着通过 bridge 等驱动为容器创建网卡，如果使用 `publish` 参数配置了容器至宿主机的 port 映射，dockerd 会往宿主机 iptable 添加对应网络规则，同时还可能会启动 docker proxy 服务 forward 流量到容器。容器的所有 endpoints 被放置在 sandbox 抽象中。准备好网络资源后，dockerd 调用 containerd 运行容器时，会在 OCI spec 中设置 Prestart Hook 命令，该命令包含了设置网络的必要信息（容器ID，容器进程ID，sandbox ID）。低级运行时实现如 runC 会在容器进程被创建但未被运行前调用该命令，该命令最终将容器ID，容器进程ID，sandbox ID 传递给 dockerd，dockerd 随即将 sandbox 中的所有 endpoint 资源绑定到容器网络 namespace 中（也是 /proc/{ctr-pid}/ns/net）。

## 总结
上文简述了 containerd, CRI-O 和 Docker 运行时的基本原理和其基于低级运行时提供的高级功能。Docker 作为提供功能最多最高层实现，放在最后是方便渐进式理解容器技术构成。

实际上，目前容器生态的技术和 OCI 标准，大都源自 Docker。Docker 抽离其容器管理逻辑发展出了 containerd 项目，并随后使用它作为自己的低层运行时。

[libnetwork 库](https://github.com/moby/libnetwork) 赋能了 docker (19.03) 网络实现，也演化自 Docker。

上文提到，Docker 镜像构建过程会产生中间镜像和中间容器，这类中间产物提升了构建速度，但是也带来了使用负担（看着莫名其妙，清理费劲）。同时，很多公司有持续、大规模构建镜像的需求，他们往往希望负责构建镜像系统能够以 HTTP 或者 gRPC 的方式对其他系统暴露服务，而 dockerd 在设计上只是一个本地服务。因此在 2017 后，dockerd 中的构建功能逐步发展成了 [buildkit 项目](https://github.com/moby/buildkit)，对应考量见 [docker issuse 32925](https://github.com/moby/moby/issues/32925)。Docker 在 18.06 版本后开始支持 buildkit，使用此种方式构建镜像有着相近的性能且不会产生中间镜像和中间容器。

从 Docker 业务层越变越薄的情况可以看出，随着社区对 OCI 规范的靠拢，容器技术模块朝着越来越精细化的方向发展，同时模块的复用程度变得越来越强。如果某家公司想要加强容器的隔离能力，只需关心如何结合操作系统技术实现低级运行并基于 containerd 提供 shim 实现即可迅速将自家技术集成进 Docker 或者 Kubernetes，这样就没有必要把高级运行时提供的能力再实现一遍。这种类比可以推广到网络、存储、镜像分发等方面。

CRI-O 项目初衷是嫌弃 Docker 功能太多，打算做一个 Kubernetes 专用运行时，不需要镜像构建、不需要镜像推送、不需要复杂的网络和存储。但它的业务层同样很薄，代码多复用社区的 containers/storage 库和 containers/image 库，同时会利用 containerd-shim 运行 vm container。运行 Linux  container 情况下，纯 C 的 conmon 守护进程实现相较 Go 实现的 containerd-shim 有更少的内存消耗。

另外两个运行时 [PouchContainer](https://github.com/alibaba/pouch) 和 [frakti](https://github.com/kubernetes/frakti) 社区的日趋死寂在另一面反映了这种演进趋势。PouchContainer 最近一次发布还在 2019 年 1 月，frakti 是 2018 年 11 月。随着 containerd 跨平台能力的加强和其对 Kubernetes 的直接支持（2018/11 1.2.0 引入 shim-v2、CRI 插件)，很多低级运行时，如 gvisor、kata-runtime，更趋向于直接提供 containerd-shim 实现以集成进容器生态，而不是再造一边轮子。PouchContainer 试图打造一个镜像分发速度更快（利用 P2P），强隔离（利用 vm container、lxcfs 等），随着 containerd 和 Docker 的演进，这些 feature 优势变得越来越小，开源社区对 PouchContainer 的兴趣越来越弱实属当然。frakti 目的是打造一个支持 runV（kata-runtime 前身）的 Kubernetes 运行时，随着 runV 和 Clear Containers 合而为 kata-containers 项目，而后者可利用 containerd-shim 直接集成进生态，frakti 便变得越来越无意义。

## Resources
* [理解 OCI](../20200510-container-oci/#runc)
* [containerd](https://containerd.io/), [containerd-CRI](https://github.com/containerd/cri)
* [CRI-O](https://cri-o.io/)
* [Docker](https://docs.docker.com/get-started/overview/), [Docker Networking overview](https://docs.docker.com/network/), [Docker Storage overview](https://docs.docker.com/storage/), [buildkit](https://github.com/moby/buildkit), [libnetwork](https://github.com/moby/libnetwork)