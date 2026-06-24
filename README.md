# Sing-box 全能节点管理脚本 (xsb.sh)

语言：[English](README_en.md) | 简体中文

> 一站式 Sing-box 代理节点管理工具，集成了证书管理、入站/出站配置、路由分流、Brutal 安装、端口跳跃、TCP 智能调优、Cloudflare DNS 管理、端口回源与 Argo 隧道配置，并支持 Alpine Linux。  
> **新增**：支持**环境变量驱动的快速部署**，配合 Web 命令生成器可一键生成多任务命令列表。

---

## 📋 简介

`xsb.sh` 专为快速部署和管理 **Sing-box** 代理节点而设计。它采用模块化架构，所有配置文件统一存放在 `~/xsb/` 目录下，并提供两种使用方式：

- **交互式菜单**：适合手动逐项配置，简单直观。
- **非交互式任务模式**：通过 `XSB_TASKS` 环境变量指定任务列表，适合自动化部署（可与 Web 生成器配合使用）。

您可以使用本仓库提供的 **Web 命令生成器**（[https://hellooe.github.io/singbox-x/](https://hellooe.github.io/singbox-x/)）在线生成所需的命令列表，一键复制后到服务器执行，实现一键快速部署。

### 核心功能一览

- 安装 / 更新 / 卸载 Sing-box
- 多域名 ACME 证书管理（HTTP-01 / DNS-01）
- 多种入站协议（VLESS+Reality、AnyTLS+Reality、AnyTLS+TLS、Hysteria2、VMess+WS+TLS、Shadowsocks 2022）
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

### 交互式模式（手动配置）

```bash
wget -O xsb.sh https://raw.githubusercontent.com/hellooe/singbox-x/refs/heads/master/xsb.sh
chmod +x xsb.sh
./xsb.sh
```

运行后会出现主菜单，按提示操作即可。

### 非交互式任务模式（快速部署）

您可以通过环境变量 `XSB_TASKS` 指定要执行的任务（多个任务用逗号分隔），脚本会按顺序执行并自动构建启动服务。

```bash
# 示例：安装本体 + 申请证书
XSB_TASKS="install,cert" \
DOMAIN="example.com" \
ACME_MODE="2" \
CF_Key="your_api_key" \
CF_Email="your_email" \
bash <(curl -Ls https://raw.githubusercontent.com/hellooe/singbox-x/refs/heads/master/xsb.sh)
```

#### 支持的任务列表

| 任务名 | 说明 |
|--------|------|
| `install` | 安装基础依赖和 Sing-box |
| `cert`   | 申请证书（需要 `DOMAIN`, `ACME_MODE` 等变量） |
| `inbound`| 添加入站（需要 `INBOUND_TYPE`, `PORT` 等变量） |
| `outbound`| 添加出站（需要 `OUTBOUND_TYPE`, `OUTBOUND_MATCH` 等） |
| `cf_dns` | 配置 Cloudflare DNS 记录（需要 `DOMAIN`, `ZONE_ID`, CF 凭证） |
| `cf_origin_rule` | 配置 Origin Rule（需要 `DOMAIN`, `ZONE_ID`, `WS_PATH`, `PORT`, CF 凭证） |
| `cf_argo` | 配置 Argo 隧道（需要 `DOMAIN`, `ARGO_TOKEN`, CF 凭证） |
| `tune`   | 执行 TCP 智能调优 |
| `build`  | 仅构建配置并启动服务（通常由其他任务自动触发） |

#### 变量一览表

| 变量 | 说明 | 示例 |
|------|------|------|
| `DOMAIN` | 域名 | `example.com` |
| `ACME_MODE` | 证书验证方式：1=HTTP-01, 2=DNS-01 | `2` |
| `WEB_PORT` | HTTP-01 验证端口（默认 80） | `80` |
| `CF_Key` | Cloudflare API Key | `` |
| `CF_Email` | Cloudflare 登录邮箱 | `` |
| `ZONE_ID` | Cloudflare Zone ID | `` |
| `INBOUND_TYPE` | 入站协议：1~6（见下方协议对照表） | `4` |
| `PORT` | 入站监听端口（0 表示随机） | `0` |
| `UUID` / `PASSWORD` | 身份凭证（留空自动生成） | `` |
| `REALITY_SERVER_NAME` | Reality 伪装域名 | `www.apple.com` |
| `CERT_DOMAIN` | 已有证书域名（用于 TLS 类协议） | `example.com` |
| `WS_PATH` | WebSocket 路径 | `/vm-xxx` |
| `METHOD` | Shadowsocks 加密方法（1=128-gcm, 2=256-gcm, 3=chacha20） | `2` |
| `ENABLE_HOP` | Hysteria2 端口跳跃（y/n） | `y` |
| `HY2_HOP_START` / `HY2_HOP_END` | 端口跳跃范围 | `60000` / `65000` |
| `OUTBOUND_TYPE` | 出站类型：1=SOCKS5, 2=WARP | `` |
| `OUTBOUND_MATCH` | 路由匹配规则（JSON） | `{"ip_cidr":["0.0.0.0/0"]}` |
| `SOCKS5_SERVER` / `SOCKS5_PORT` | SOCKS5 服务器地址和端口 | `127.0.0.1` / `1080` |
| `SOCKS5_USER` / `SOCKS5_PASS` | SOCKS5 认证（可选） | `user` / `pass` |
| `ARGO_TOKEN` | Argo 隧道 Token | `ey...` |

#### 协议对照表（INBOUND_TYPE）

| 值 | 协议 |
|----|------|
| 1  | VLESS+Reality |
| 2  | AnyTLS+Reality |
| 3  | AnyTLS+TLS |
| 4  | Hysteria2 |
| 5  | VMess+WSS |
| 6  | Shadowsocks |

> 💡 推荐配合 **Web 生成器** 使用，无需手动记忆变量，直接通过表单生成命令：  
> [https://hellooe.github.io/singbox-x/](https://hellooe.github.io/singbox-x/)

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
│   ├── env.conf        # 持久化的环境变量（自动保存）
│   ├── argo_token      # Argo 隧道 Token
│   └── routes/         # 路由规则 (每个出站一个)
├── inbounds/           # 入站配置文件 (JSON)
│   ├── inbound_<tag>.json
│   ├── inbound_<tag>.hop          # Hysteria2 端口范围
│   └── inbound_<tag>_reality_*    # Reality 密钥
└── outbounds/          # 出站配置文件
    ├── outbound_<tag>.json
    └── endpoint_<tag>.json         # WireGuard 端点
```

---

## 📄 许可

本脚本采用 **MIT 许可证**，自由使用、修改、分发。

---

**祝您使用愉快！** 如有问题或建议，欢迎提交 [Issue](https://github.com/hellooe/singbox-x/issues)。
