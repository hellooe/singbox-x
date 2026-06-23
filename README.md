# Sing-box 全能节点管理脚本 (xsb.sh)

语言：[English](README_en.md) | 简体中文

> 一站式 Sing-box 代理节点管理工具，集成了证书管理、入站/出站配置、路由分流、Brutal安装、端口跳跃、TCP 智能调优、Cloudflare DNS管理、端口回源与 Argo 隧道配置等功能，并支持 Alpine Linux。

---

## 📋 简介

`xsb.sh` 是一个 Bash 脚本，专为快速部署和管理 **Sing-box** 代理节点而设计。它采用模块化架构，所有配置文件统一存放在 `~/xsb/` 目录下，并提供交互式菜单，让您轻松完成以下任务：

- 安装 / 更新 / 卸载 Sing-box
- 多域名 ACME 证书管理（HTTP-01 / DNS-01）
- 多种入站协议（VLESS+Reality、AnyTLS+Reality、AnyTLS+TLS、Hysteria2、VMess+WS+TLS、 SS2022）
- 出站代理（SOCKS5、WARP）
- Hysteria2 端口跳跃（基于 iptables）
- TCP 内核参数智能调优（基于测速结果）
- Cloudflare DNS 记录管理、Origin Rule、Argo 固定隧道配置
- 自动构建 Sing-box 配置文件并启动服务
- 获取节点链接（支持 IPv4 / IPv6）

---

## 🚀 系统要求

- **操作系统**：Debian / Ubuntu / CentOS / Alpine Linux
- **架构**：`x86_64` 或 `aarch64` (ARM64)
- **权限**：必须使用 **root** 用户运行
- **依赖**：脚本会自动安装所需软件包（curl, wget, cron, openssl, iptables, jq, iproute2 等）

---

## 📦 安装与运行

```bash
wget -O xsb.sh https://raw.githubusercontent.com/hellooe/singbox-x/refs/heads/master/xsb.sh
chmod +x xsb.sh
./xsb.sh
```

### 入站管理

支持当下最流行的五大协议：

| 协议 | 说明 |
|------|------|
| VLESS+Reality | Reality 强伪装，不需要域名 |
| AnyTLS+Reality | 基于 AnyTLS 的 Reality 入站 |
| AnyTLS+TLS | 基于 AnyTLS + 标准 TLS 证书 |
| Hysteria2 | 支持端口跳跃，UDP 神秘加成 |
| VMess+WSS | WebSocket + TLS，可套 CDN，解决 ip 被墙问题 |

每个入站生成独立的 JSON 文件（`~/xsb/inbounds/inbound_<tag>.json`）

### 出站管理

- **SOCKS5** 出站：支持自定义服务器、端口、用户名/密码，方便配置家宽出口
- **WARP**：配置WARP出站，并添加路由规则，可轻松解锁某些网站，解决 ip 送中等问题

出站配置文件存放于 `~/xsb/outbounds/`，并自动生成对应的路由规则（`~/xsb/conf/routes/route_<tag>.json`）

---

### Cloudflare 配置

#### 配置 Origin Rule
- 自动检测现有 VMess 入站，提取 Host 和 WS 路径
- 创建 Origin Rule，将指定域名的路径请求转发到对应端口

#### 配置 Argo 隧道
- 下载 `cloudflared` 并安装为系统服务
- 自动匹配 VMess 入站，建立固定隧道
- 可在无公网 ip 的情况下使用

#### 配置 DNS 记录
- 获取本机 IPv4 / IPv6，自动添加或更新 Cloudflare A / AAAA 记录
- 方便动态 ip 管理

以上功能均需要配置 Cloudflare API 凭证（`~/xsb/conf/cf_creds`），脚本会引导您填写。

---

### TCP 智能调优

- 自动下载 **Speedtest** CLI 工具
- 测速后根据 **上传带宽** 自动计算并设置内核缓冲区大小
- 同时启用 BBR 拥塞控制算法，优化各项 `sysctl` 参数，保存至 `/etc/sysctl.d/99-tcp.conf`

---

### 获取节点链接

- 为每个入站生成对应的**分享链接**（VLESS、AnyTLS、Hysteria2、VMess 格式）
- 支持 IPv4 和 IPv6 双栈输出

---

## 🔧 配置文件说明

所有数据均存储在 `~/xsb/` 目录下：

```
~/xsb/
├── bin/                # 可执行文件 (sing-box, cloudflared, speedtest)
├── cert/               # 证书 (每个域名一个子目录)
│   └── <domain>/
│       ├── cert.crt
│       └── private.key
├── conf/               # 全局配置
│   ├── cf_creds        # Cloudflare API 凭证 (需手动填写)
│   ├── uuid            # 全局 UUID
│   ├── ipv4 / ipv6     # 本机 IP 缓存
│   ├── argo_token      # Argo 隧道 Token
│   └── routes/         # 路由规则 (每个出站一个)
├── inbounds/           # 入站配置文件 (JSON)
│   ├── inbound_<tag>.json
│   ├── inbound_<tag>.hop          # Hysteria2 端口范围
│   └── inbound_<tag>_reality_*    # Reality 私钥/公钥/short_id
└── outbounds/          # 出站配置文件
    ├── outbound_<tag>.json
    └── endpoint_<tag>.json         # WireGuard 端点
```

---

## ⚙️ Cloudflare 凭证配置

脚本首次运行会在 `~/xsb/conf/cf_creds` 生成模板，您需要手动编辑并填入：

```bash
CF_API_KEY=你的Cloudflare API Key
CF_EMAIL=你的邮箱
ZONE_ID=你的Zone ID
DOMAIN=你的主域名
```

**安全提示**：脚本退出时可选择自动清空凭证内容，避免敏感信息泄露。

---

## 📄 许可

本脚本采用 **MIT 许可证**，自由使用、修改、分发。

---

**祝您使用愉快！** 如有问题，欢迎提交 Issue。
