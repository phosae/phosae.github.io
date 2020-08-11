---
title: "搭建树莓派 k8s 集群"
date: 2020-04-05T10:00:00+08:00
lastmod: 2020-04-15T21:30:00
draft: false

tags: ["树莓派","Kubernetes"]

summary: 自己动手，丰衣足食，利用开发板搭建本地 k8s 集群
---

最近正在捣鼓一套本地 k8s 集群，于是想到了树莓派和各种开发板。说干就干，本文记录一些搭建细节。

## 器件清单
| 器件名                |  数量 |
| ---------------------| ------------- |
| 树莓派 3 Model B+     | 3  |
| 树莓派 4 Model B      | 1  |
| microSD(TF) 卡       | 4  |
| NETGEAR GS308P 交换机 | 1  |
| Type-C 千兆有线网卡    | 1 |
| 0.3米网线             | 5  |
| microUSB 供电线或树莓派 PoE HAT 模块  | 3  |
| usb-c 供电线或树莓派 PoE HAT 模块  | 1  |
| 亚克力外壳             | 若干 |

供电方面要注意的是，树莓派 3 Model B+ 和树莓派 4 Model B 支持 PoE 供电（802.3af标准），需要额外购买 PoE HAT 模块，同时使用的交换机也必须支持 PoE 供电。使用 PoE 的好处是省去了 USB 电源，观感比较整洁，坏处是贵（PoE HAT 售价 140+）。

## Ubuntu 系统烧录

下载 [Ubuntu Server 18.04 LTS](https://ubuntu.com/download/raspberry-pi) Pi image 64-bit 版，安装并使用 [Etcher](https://www.balena.io/etcher/) 进行系统烧录。注意千万不用使用树莓派官方的 *Raspberry Pi Imager*, 那玩意在 TF 卡格式化方面是噩梦，且貌似只支持烧录 Raspbian 系统。

选择好 img 镜像和对应 SD 卡之后，点击 Flash 开始烧录。
<img src="/img/2020-04/etcher.jpg" alt="drawing" width="500px"/>
打开烧录完成后的 TF 卡，在根目录中新建一个空白 ssh 文件，以便 Ubuntu 在启动自动开启远程登陆，这样一来就不需要连接显示器之类的外设操作开发板。
<img src="/img/2020-04/ubuntu-ssh.jpg" width="500px"/>

## 启动并配置网络
网络配置参考了 [交换机组建通信子网并通过macOS共享网络](https://www.ancii.com/asnvx7pqp/)，即 Mac 通过外置网卡充当交换机上集群的路由器，让每一块板子都能直接联网。

<img src="/img/2020-04/cluster-hardware.JPG" width="500px"/>
{{% center %}}
注: 左边 4 根为开发板网线，最右为 Mac 网线
{{% /center %}}

### Mac 网络配置
插入 type-c 网卡之后，安装好网卡驱动（重要！！!)，然后打开系统偏好设置 -> 网络，看到 AX8817...thernet 已出现在列表。注意要保证 Wi-Fi 网卡在其之前（通过设定服务顺序调整），因为 Mac 操作系统会选择第一张网卡发起对外网络连接，如果连接交换机的网卡在第一栏，设备将无法上网。

<img src="/img/2020-04/mac-net-config.jpg" width="500px">

在这里我们设置 Mac 在有线网卡侧的 IP 为 192.168.2.10，并把它作为路由器。

### 开发板网络配置
通过 arp -a 获取开发板硬件地址并使用 ssh 操作进入开发板系统 (默认用户名名字均为 ubuntu)，依次按照如下指令依次操作所有开发板

```shell
$ arp -a 
? (192.168.2.2) at b8:27:eb:51:6e:d7 on bridge100 ifscope [bridge]
$ ssh ubuntu@192.168.2.2
Welcome to Ubuntu 18.04.4 LTS (GNU/Linux 5.3.0-1017-raspi2 aarch64)
  ...
  System information as of Sun Apr  5 05:09:55 UTC 2020

  System load:  0.08               Processes:           113
  Usage of /:   11.7% of 14.30GB   Users logged in:     0
  Memory usage: 25%                IP address for eth0: 192.168.2.2
  Swap usage:   0%
...
Last login: Sun Apr  5 01:25:28 2020 from 192.168.2.1
ubuntu@ubuntu:~$
```

使用 root 权限在 /etc/netplan/ 目录下新建 99_config.yaml 文件，配置开发板地址为 192.168.2.2(其他板依此类推为 192.168.2.3, 192.168.2.4, ...)，配置静态 IP 地址并设置网关地址为 192.168.2.10(即你的 Mac)，之后使用 netplan apply 更改网络配置。

```yaml
{
cat <<EOF | sudo tee /etc/netplan/99_config.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: no
      addresses:
        - 192.168.2.2/24
      gateway4: 192.168.2.10
      nameservers:
        addresses: [8.8.8.8,114.114.114.114]
EOF
sudo netplan apply 99_config.yaml
}
```

4 月 15 拾遗: NetworkManager 也可以使用 netplan 更改网络，只需将 **renderer: networkd** 换成 **renderer: NetworkManager** 即可 

### 测试网络连通
完成上述步骤后，在任意开发板中或者 Mac 中进行 ping 操作，确认所有主机 192.168.2.2, 192.168.2.3, 192.168.2.4, 192.168.2.5, 192.168.2.10 互通。

## 4-10 更新, 加入 x86 开发板 Up Board
型号 4 cores @ 1.44 GHz, 4 GB RAM(DDR3/1600MHZ), 2 GbE, 32 GB eMMc 

安装系统 Ubuntu Desktop 18.04 LTS，Desktop 版不带 open SSH，安装 OpenSSH 并开启以便远程登陆
```text
$ sudo apt update
$ sudo apt install --assume-yes openssh-server 
$ sudo systemctl enable ssh
$ sudo systemctl start ssh
# 防火墙配置
$ sudo ufw allow ssh 
```

Ubuntu Desktop 网络配置和树莓派 Ubuntu Server 不一样，它使用的是 network-manager, 先通过 **ip a** 获取网卡名 (这里是 enp1s0，很多是 eth0)，在  /etc/network/interfaces 文件设置静态 IP 
```text
auto lo
iface lo inet loopback

auto enp1s0
  iface enp1s0 inet static
  address 192.168.2.7
  netmask 255.255.255.0
  gateway 192.168.2.10
```
重启 network-manager
```text
$ sudo service network-manager restart
$ ps aux | grep -i -E "(networkmanager|nm)"
root      2175  0.0  0.5 502676 18436 ?  Ssl  21:23   0:00 /usr/sbin/NetworkManager --no-daemon
```

Ubuntu Desktop 使用 systemd-resolved 解析 DNS，打开 /etc/systemd/resolved.conf，加入 DNS 服务地址
```text
[Resolve]
DNS=8.8.8.8 114.114.114.114 192.168.2.10
FallbackDNS=8.8.4.4
```
重启服务 
```
$ systemctl restart systemd-resolved
```

最后，切记链接文件
```
$ sudo ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
```
测试 DNS 解析
```
$ nslookup google.com nslookup google.com
Server:		8.8.8.8
Address:	8.8.8.8#53

Name:	google.com
Address: 93.46.8.90
Name:	google.com
Address: 59.24.3.174
```

## 4-13，加入 ODYSSEY-X86 开发板

型号 4 cores @ 1.5-2.5 GHz, 8 GB RAM(LPDDR4), 64 GB eMMc 

配置方式基本同上，不过在网络配置中我更改了默认的网卡名

```
network:
  version: 2
  renderer: networkd
  ethernets:
    eth_lan:
      dhcp4: no
      dhcp6: no
      addresses: [192.168.2.8/24]
      gateway4: 192.168.2.10
      nameservers:
        addresses: [8.8.8.8,114.114.114.114,192.168.2.10]
      match:
        macaddress: 00:e0:4c:01:0f:6f
      set-name: eth_lan
    enp2s0:
      dhcp4: true
      dhcp6: true
```

目前集群长这样

<img src="/img/2020-04/pi-cluster-0415.jpg" width="500px"/>

感慨一下，上回装系统还是 5 年前，那会用 UtraISO 做 Window7 启动盘。这回树莓派用的是 sd 卡烧录系统，很快折腾完事了。面对 Ubuntu x86 时自己犯难了，怎么用 U 盘引导装系统完全没概念，网上也没找到啥教程。后来发现和 Windows 一样的，关键在于主板是否支持 UEFI 引导安装，用 Etcher 往 U 盘刷系统，启动主板时找下显示器键盘鼠标，开机时狂按 F2 或者 F7 进开机选项，选 U 盘装系统即可。