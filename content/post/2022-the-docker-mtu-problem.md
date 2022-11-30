---
title: "虚拟网络环境中 Docker MTU 问题及解决方式"
date: 2022-11-18T18:11:28+08:00
lastmod: 2022-11-30T23:35:00+08:00
draft: false

keywords: ["docker", "container"]
description: ""
tags: ["docker", "container"]
author: "Zeng Xu"
summary: "在 SDN 网络环境中，如果 docker0 bridge MTU 大于 Host MTU 时，会出现「即小包可通，大包不通」的情况，直观来说就是能简单 ping 通，但是网站打不开、文件下载失败。本文将复现并教你如何解决该问题"

comment: true
toc: true
autoCollapseToc: false
postMetaInFooter: true
hiddenFromHomePage: false
---

## 问题背景

K8s 网络，OpenStack 网络或者其他 SDN 网络会使用各种各样的封包技术，结果便是 Host Pod 或者 Host VM 网卡 MTU 会小于 1500。

而 docker0 bridge 默认 MTU 为 1500，当 docker0 bridge MTU 大于 Host MTU 时，会出现「即小包可通，大包不通」的情况，直观来说就是能简单 ping 通，但是网站打不开、文件下载失败

如
```
2: enp1s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc fq_codel state UP group default qlen 1000
    link/ether 00:00:00:5b:ee:a4 brd ff:ff:ff:ff:ff:ff
    inet 10.1.1.7/24 brd 10.1.1.255 scope global dynamic enp1s0
       valid_lft 86313322sec preferred_lft 86313322sec
    inet6 fe80::200:ff:fe5b:eea4/64 scope link
       valid_lft forever preferred_lft forever
3: docker0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state DOWN group default
    link/ether 02:42:db:19:c6:d1 brd ff:ff:ff:ff:ff:ff
    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0
       valid_lft forever preferred_lft forever
```

在默认 docker 网络启动容器，观察到里面网卡的 MTU 也是 1500

```
docker run --rm -d --name net alpine sleep 3600

$ docker exec net ip a
12: eth0@if13: <BROADCAST,MULTICAST,UP,LOWER_UP,M-DOWN> mtu 1500 qdisc noqueue state UP
    link/ether 02:42:ac:11:00:02 brd ff:ff:ff:ff:ff:ff
    inet 172.17.0.2/16 brd 172.17.255.255 scope global eth0
       valid_lft forever preferred_lft forever
```

使用不同 packet size ping 可证明问题存在

```
$ docker exec net ping -s 1360 -c 3 baidu.com
PING baidu.com (110.242.68.66): 1360 data bytes
1368 bytes from 110.242.68.66: seq=0 ttl=45 time=37.994 ms
1368 bytes from 110.242.68.66: seq=1 ttl=45 time=37.829 ms
1368 bytes from 110.242.68.66: seq=2 ttl=45 time=38.122 ms

--- baidu.com ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
---
$ docker exec net ping -s 1400 -c 3 baidu.com
PING baidu.com (39.156.66.10): 1400 data bytes

--- baidu.com ping statistics ---
3 packets transmitted, 0 packets received, 100% packet loss
```

## 直接解决 —— 修改docker0 MTU 配置后重启 docker

方式一、修改 `daemon.json` 文件

```yaml
$ vim /etc/docker/daemon.json
{
  "mtu": 1400
}

$ systemctl restart docker
```

方式二、修改 systemd unit file 指明启动参数 `--mtu` （不同系统位置可能不同

```yaml
$ vim /lib/systemd/system/docker.service 

ExecStart=/usr/bin/dockerd --mtu 1400 -H fd:// --containerd=/run/containerd/containerd.sock

$ systemctl daemon-reload

$ systemctl restart docker
```

注意，修改重启后，如果 docker0 上当前没有容器运行。使用 ifconfig/ip 命令会看到处于 `DOWN` 状态的 docker0  MTU 仍然会显示为 1500，创建容器后即会变成 1400


## 间接解决 —— 不使用 docker0 网桥

即不使用默认网络，指定 opt `com.docker.network.driver.mtu` 

```bash
$ docker network create \
  --opt com.docker.network.bridge.name=mtu0 \
  --opt com.docker.network.driver.mtu=1400 \
  --driver=bridge \
  --subnet=172.28.0.0/16 \
  --gateway=172.28.0.1 \
  mybridge
```

注意，如果 mybridge 上没有容器运行。使用 ifconfig/ip 命令会看到处于 `DOWN` 状态的 mybridge  MTU 显示为 1500，创建容器后，状态转为 `UP` 时即会正确显示为 1400

```bash
$ docker run --rm -it --name test --network mybridge alpine 

# ip a
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
25: eth0@if26: <BROADCAST,MULTICAST,UP,LOWER_UP,M-DOWN> mtu 1400 qdisc noqueue state UP
    link/ether 02:42:ac:1c:00:02 brd ff:ff:ff:ff:ff:ff
    inet 172.28.0.2/16 brd 172.28.255.255 scope global eth0
       valid_lft forever preferred_lft forever
```

## 参考

1. [https://www.civo.com/learn/fixing-networking-for-docker](https://www.civo.com/learn/fixing-networking-for-docker)
2. [https://mlohr.com/docker-mtu/](https://mlohr.com/docker-mtu/)
3. [https://sylwit.medium.com/how-we-spent-a-full-day-figuring-out-a-mtu-issue-with-docker-4d81fdfe2caf](https://sylwit.medium.com/how-we-spent-a-full-day-figuring-out-a-mtu-issue-with-docker-4d81fdfe2caf)
4. [https://github.com/moby/moby/pull/18108](https://github.com/moby/moby/pull/18108)
5. [https://github.com/moby/moby/issues/34981](https://github.com/moby/moby/issues/34981)
6. [https://www.digitalocean.com/community/tutorials/understanding-systemd-units-and-unit-files](https://www.digitalocean.com/community/tutorials/understanding-systemd-units-and-unit-files)