# Sing-box Universal Node Management Script (xsb.sh)

Language: English | [简体中文](README.md)

> All-in-one Sing-box proxy node management script, integrating certificate management, inbound/outbound configuration, routing rules, Brutal installation, port hopping, TCP intelligent tuning, Cloudflare DNS management, Cloudflare origin rules, Argo tunnel setup, and Alpine Linux support.  
> **New**: Supports **environment-variable-driven rapid deployment**, and works with a Web Generator to produce one-click multi-task command lists.

---

## 📋 Introduction

`xsb.sh` is designed for rapid deployment and management of **Sing-box** proxy nodes. It adopts a modular architecture, with all configuration files stored under `~/xsb/`. Two usage modes are provided:

- **Interactive Menu**: Suitable for manual step-by-step configuration, intuitive and straightforward.
- **Non-interactive Task Mode**: Specify tasks via the `XSB_TASKS` environment variable, ideal for automated deployment (can be used with the Web Generator).

You can use the **Web Generator** provided in this repository ([https://hellooe.github.io/singbox-x/](https://hellooe.github.io/singbox-x/)) to generate the required command list online, then copy and execute it on your server for one‑click rapid deployment.

### Core Features

- Install / Update / Uninstall Sing-box
- Multi‑domain ACME certificate management (HTTP-01 / DNS-01)
- Multiple inbound protocols (VLESS+Reality, AnyTLS+Reality, AnyTLS+TLS, Hysteria2, VMess+WS+TLS, Shadowsocks 2022)
- Outbound proxies (SOCKS5, WARP)
- Hysteria2 port hopping (based on iptables)
- TCP kernel parameter intelligent tuning (based on speed test results)
- Cloudflare DNS record management, Origin Rules, and Argo fixed tunnel configuration
- Automatic Sing-box configuration building and service startup
- Retrieve node links (supports IPv4 / IPv6)

---

## 🚀 System Requirements

- **Operating System**: Debian / Ubuntu / CentOS / Alpine Linux
- **Architecture**: `x86_64` or `aarch64` (ARM64)
- **Privileges**: Must be run as **root**
- **Dependencies**: The script automatically installs required packages (curl, wget, cron, openssl, iptables, jq, iproute2, etc.)

---

## 📦 Installation & Usage

### Interactive Mode (Manual Configuration)

```bash
wget -O xsb.sh https://raw.githubusercontent.com/hellooe/singbox-x/refs/heads/master/xsb.sh
chmod +x xsb.sh
./xsb.sh
```

After running, the main menu will appear; follow the on‑screen instructions.

### Non‑interactive Task Mode (Rapid Deployment)

You can specify a list of tasks via the `XSB_TASKS` environment variable (comma‑separated). The script will execute them in order and automatically build the configuration and start the service.

```bash
# Example: Install + obtain certificate
XSB_TASKS="install,cert" \
DOMAIN="example.com" \
ACME_MODE="2" \
CF_Key="your_api_key" \
CF_Email="your_email" \
bash <(curl -Ls https://raw.githubusercontent.com/hellooe/singbox-x/refs/heads/master/xsb.sh)
```

#### Supported Task List

| Task Name | Description |
|-----------|-------------|
| `install` | Install base dependencies and Sing-box |
| `cert`    | Obtain a certificate (requires `DOMAIN`, `ACME_MODE`, etc.) |
| `inbound` | Add an inbound (requires `INBOUND_TYPE`, `PORT`, etc.) |
| `outbound`| Add an outbound (requires `OUTBOUND_TYPE`, `OUTBOUND_MATCH`, etc.) |
| `cf_dns`  | Configure Cloudflare DNS records (requires `DOMAIN`, `ZONE_ID`, CF credentials) |
| `cf_origin_rule` | Configure Origin Rule (requires `DOMAIN`, `ZONE_ID`, `WS_PATH`, `PORT`, CF credentials) |
| `cf_argo` | Configure Argo tunnel (requires `DOMAIN`, `ARGO_TOKEN`, CF credentials) |
| `tune`    | Perform TCP intelligent tuning |
| `build`   | Only build configuration and start service (usually triggered automatically) |

#### Environment Variable Reference

| Variable | Description | Example |
|----------|-------------|---------|
| `DOMAIN` | Domain name | `example.com` |
| `ACME_MODE` | Certificate validation method: 1=HTTP-01, 2=DNS-01 | `2` |
| `WEB_PORT` | HTTP-01 validation port (default 80) | `80` |
| `CF_Key` | Cloudflare API Key | `` |
| `CF_Email` | Cloudflare login email | `` |
| `ZONE_ID` | Cloudflare Zone ID | `` |
| `INBOUND_TYPE` | Inbound protocol: 1~6 (see protocol mapping table) | `4` |
| `PORT` | Inbound listening port (0 = random) | `0` |
| `UUID` / `PASSWORD` | Credentials (leave empty for auto‑generation) | `` |
| `REALITY_SERVER_NAME` | Reality server name | `www.apple.com` |
| `CERT_DOMAIN` | Domain for existing certificate | `example.com` |
| `WS_PATH` | WebSocket path | `/vm-xxx` |
| `METHOD` | Shadowsocks encryption method (1=128-gcm, 2=256-gcm, 3=chacha20) | `2` |
| `ENABLE_HOP` | Hysteria2 port hopping (y/n) | `y` |
| `HY2_HOP_START` / `HY2_HOP_END` | Port hopping range | `60000` / `65000` |
| `OUTBOUND_TYPE` | Outbound type: 1=SOCKS5, 2=WARP | `` |
| `OUTBOUND_MATCH` | Routing match rules (JSON) | `{"ip_cidr":["0.0.0.0/0"]}` |
| `SOCKS5_SERVER` / `SOCKS5_PORT` | SOCKS5 server address and port | `127.0.0.1` / `1080` |
| `SOCKS5_USER` / `SOCKS5_PASS` | SOCKS5 authentication (optional) | `user` / `pass` |
| `ARGO_TOKEN` | Argo tunnel Token | `ey...` |

#### Protocol Mapping (INBOUND_TYPE)

| Value | Protocol |
|-------|----------|
| 1     | VLESS+Reality |
| 2     | AnyTLS+Reality |
| 3     | AnyTLS+TLS |
| 4     | Hysteria2 |
| 5     | VMess+WSS |
| 6     | Shadowsocks |

> 💡 It is recommended to use the **Web Generator** – no need to remember variables manually. Generate commands via a simple form:  
> [https://hellooe.github.io/singbox-x/](https://hellooe.github.io/singbox-x/)

---

## 🌐 Web Generator

This project provides a **visual command generator** to help you quickly generate a complete deployment command list by filling out a form. Steps:

1. Visit [https://hellooe.github.io/singbox-x/](https://hellooe.github.io/singbox-x/)
2. Add certificate, inbound, outbound, Cloudflare configurations, etc., as needed
3. Click "Generate Commands" and copy the full list
4. Execute on your server (as root) in order

The generator automatically adds `install` and `tune` tasks and intelligently validates Cloudflare credentials to ensure complete and correct commands.

---

## 🔧 Configuration Directory Structure

All data is stored under `~/xsb/`:

```
~/xsb/
├── bin/                # Executables (sing-box, cloudflared, speedtest)
├── cert/               # Certificates (one subdirectory per domain)
│   └── <domain>/
│       ├── cert.crt
│       └── private.key
├── conf/               # Global configuration
│   ├── env.conf        # Persisted environment variables (auto‑saved)
│   ├── argo_token      # Argo tunnel token
│   └── routes/         # Routing rules (one per outbound)
├── inbounds/           # Inbound configuration files (JSON)
│   ├── inbound_<tag>.json
│   ├── inbound_<tag>.hop          # Hysteria2 port range
│   └── inbound_<tag>_reality_*    # Reality keys
└── outbounds/          # Outbound configuration files
    ├── outbound_<tag>.json
    └── endpoint_<tag>.json         # WireGuard endpoint
```

---

## 📄 License

This script is released under the **MIT License** – free to use, modify, and distribute.

---

**Enjoy!** If you have any questions or suggestions, feel free to open an [Issue](https://github.com/hellooe/singbox-x/issues).
