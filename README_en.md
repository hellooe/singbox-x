# Sing-box All-in-One Node Management Script (xsb.sh)

Languages: English | [简体中文](README.md)

> A one-stop Sing-box proxy node management tool that integrates certificate management, inbound/outbound configuration, smart routing, Brutal installation, port hopping, TCP smart tuning, Cloudflare DNS management, origin rules, Argo tunnel setup, and supports Alpine Linux.

---

## 📋 Overview

`xsb.sh` is a Bash script designed for rapid deployment and management of **Sing-box** proxy nodes. It follows a modular architecture, storing all configuration files under `~/xsb/`, and provides an interactive menu to easily accomplish the following tasks:

- Install / update / uninstall Sing-box
- Multi-domain ACME certificate management (HTTP-01 / DNS-01)
- Multiple inbound protocols (VLESS+Reality, AnyTLS+Reality, AnyTLS+TLS, Hysteria2, VMess+WS+TLS)
- Outbound proxies (SOCKS5, WARP)
- Hysteria2 port hopping (based on iptables)
- TCP kernel parameter smart tuning (based on speed test results)
- Cloudflare DNS record management, Origin Rule, and Argo fixed tunnel configuration
- Automatically build Sing-box configuration and start the service
- Generate node share links (supports IPv4 / IPv6)

---

## 🚀 System Requirements

- **Operating System**: Debian / Ubuntu / CentOS / Alpine Linux
- **Architecture**: `x86_64` or `aarch64` (ARM64)
- **Privileges**: Must be run as **root**
- **Dependencies**: The script automatically installs required packages (curl, wget, cron, openssl, iptables, jq, iproute2, etc.)

---

## 📦 Installation and Execution

```bash
wget -O xsb.sh https://github.com/hellooe/singbox-x/blob/master/xsb.sh
chmod +x xsb.sh
./xsb.sh
```

### Inbound Management

Supports five of the most popular protocols:

| Protocol | Description |
|----------|-------------|
| VLESS+Reality | Reality with strong camouflage, no domain required |
| AnyTLS+Reality | AnyTLS-based Reality inbound |
| AnyTLS+TLS | AnyTLS + standard TLS certificate |
| Hysteria2 | Supports port hopping, UDP acceleration |
| VMess+WSS | WebSocket + TLS, can be CDN‑proxied, solves IP blocking issues |

Each inbound generates an independent JSON file (`~/xsb/inbounds/inbound_<tag>.json`).

### Outbound Management

- **SOCKS5** outbound: supports custom server, port, username/password.
- **WARP**: configure a WARP outbound and add routing rules to easily unlock certain websites.

Outbound configuration files are stored in `~/xsb/outbounds/`, and corresponding routing rules are automatically generated (`~/xsb/conf/routes/route_<tag>.json`).

---

### Cloudflare Configuration

#### Configure Origin Rule
- Automatically detect existing VMess inbound, extract Host and WS path.
- Create an Origin Rule that forwards requests for the specified domain path to the corresponding port.

#### Configure Argo Tunnel
- Download `cloudflared` and install it as a system service.
- Automatically match VMess inbound and establish a fixed tunnel.
- Works even without a public IP address.

#### Configure DNS Records
- Obtain the machine’s IPv4 / IPv6 addresses and automatically add or update Cloudflare A / AAAA records.
- Convenient for dynamic IP management.

All the above features require Cloudflare API credentials (`~/xsb/conf/cf_creds`); the script will guide you through filling them in.

---

### TCP Smart Tuning

- Automatically download the **Speedtest** CLI tool.
- After a speed test, automatically calculate and set kernel buffer sizes based on **upload bandwidth**.
- Enable BBR congestion control and optimize various `sysctl` parameters, saved to `/etc/sysctl.d/99-tcp.conf`.

---

### Retrieve Node Links

- Generate **share links** (VLESS, AnyTLS, Hysteria2, VMess formats) for each inbound.
- Supports both IPv4 and IPv6 output.

---

## 🔧 Configuration File Structure

All data is stored under `~/xsb/`:

```
~/xsb/
├── bin/                # Executable files (sing-box, cloudflared, speedtest)
├── cert/               # Certificates (one subdirectory per domain)
│   └── <domain>/
│       ├── cert.crt
│       └── private.key
├── conf/               # Global configuration
│   ├── cf_creds        # Cloudflare API credentials (to be filled manually)
│   ├── uuid            # Global UUID
│   ├── ipv4 / ipv6     # Cached local IPs
│   ├── argo_token      # Argo tunnel token
│   └── routes/         # Routing rules (one per outbound)
├── inbounds/           # Inbound configuration files (JSON)
│   ├── inbound_<tag>.json
│   ├── inbound_<tag>.hop          # Hysteria2 port range
│   └── inbound_<tag>_reality_*    # Reality private/public key and short_id
└── outbounds/          # Outbound configuration files
    ├── outbound_<tag>.json
    └── endpoint_<tag>.json         # WireGuard endpoint
```

---

## ⚙️ Cloudflare Credentials Configuration

On first run, the script generates a template at `~/xsb/conf/cf_creds`. You need to edit it and fill in:

```bash
CF_API_KEY=your_cloudflare_api_key
CF_EMAIL=your_email
ZONE_ID=your_zone_id
DOMAIN=your_main_domain
```

**Security Tip**: When exiting the script, you can choose to clear the credential contents automatically to prevent sensitive information leakage.

---

## 📄 License

This script is released under the **MIT License**. Free to use, modify, and distribute.

---

**Enjoy using it!** If you have any issues, feel free to submit an Issue.