#!/bin/bash
#===============================================================
# 一站式 Sing-box 全能节点管理脚本
# 所有文件存放于 ~/xsb/
# 功能: 安装Singbox | ACME多证书管理 | 增删入站/出站
#       安装Brutal并实现端口跳跃 | TCP智能调优
#       Cloudflare Origin Rule + Argo隧道
#       支持 Alpine Linux
#===============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PLAIN='\033[0m'
XSB_DIR="$HOME/xsb"
mkdir -p "$XSB_DIR"/{bin,cert,conf,inbounds,outbounds,routes}
export PATH="$XSB_DIR/bin:$PATH"
XSB_CONF_FILE="$XSB_DIR/conf/env.conf"

save_config() {
    local var="$1"
    local value="$2"
    if [[ -f "$XSB_CONF_FILE" ]]; then
        if grep -q "^$var=" "$XSB_CONF_FILE"; then
            awk -v v="$var" -v val="$value" 'BEGIN{OFS=FS="="} $1==v {$0=v "=" val} 1' "$XSB_CONF_FILE" > "${XSB_CONF_FILE}.tmp" && mv "${XSB_CONF_FILE}.tmp" "$XSB_CONF_FILE"
        else
            echo "$var=$value" >> "$XSB_CONF_FILE"
        fi
    else
        echo "$var=$value" > "$XSB_CONF_FILE"
        chmod 600 "$XSB_CONF_FILE"
    fi
}

get_or_ask() {
    local var="$1"
    local prompt="$2"
    local default="$3"
    local value=""

    eval "value=\${$var:-}"
    if [[ -n "$value" ]]; then
        save_config "$var" "$value"
        echo "$value"
        return 0
    fi

    if [[ -f "$XSB_CONF_FILE" ]]; then
        value=$(grep -E "^$var=" "$XSB_CONF_FILE" 2>/dev/null | head -1 | cut -d'=' -f2-)
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        fi
    fi

    read -p "$prompt: " value
    if [[ -z "$value" ]]; then
        value="$default"
    fi
    save_config "$var" "$value"
    echo "$value"
}

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 root 用户运行${PLAIN}" && exit 1
fi

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${RED}无法识别系统${PLAIN}" && exit 1
fi

install_deps() {
    echo -e "${GREEN}安装基础依赖...${PLAIN}"
    case $OS in
        debian|ubuntu)
            apt update -y
            apt install -y curl wget cron openssl iptables iptables-persistent jq iproute2 coreutils
            ;;
        centos|rhel|fedora)
            yum install -y epel-release
            yum install -y curl wget openssl iptables iptables-services jq iproute2 coreutils
            ;;
        alpine)
            apk update
            apk add curl wget openssl iptables iptables-openrc jq iproute2 coreutils
            ;;
        *)
            echo -e "${RED}不支持的系统${PLAIN}" && exit 1
    esac
}

install_singbox() {
    if [[ -f "$XSB_DIR/bin/sing-box" ]]; then
        echo -e "${YELLOW}Sing-box 已安装，版本: $(sing-box version | head -1)${PLAIN}"
        return 0
    fi
    echo -e "${GREEN}安装 Sing-box...${PLAIN}"
    LATEST=$(curl -s --max-time 5 https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | head -1 | awk -F '"' '{print $4}' | sed 's/v//')
    [[ -z "$LATEST" ]] && LATEST="1.13.13"
    case $(uname -m) in
        x86_64)  SB_ARCH="amd64" ;;
        aarch64) SB_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构${PLAIN}"; return 1 ;;
    esac
    ldd --version 2>&1 | grep -q musl && LIBC="musl" || LIBC="glibc"
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST}/sing-box-${LATEST}-linux-${SB_ARCH}-${LIBC}.tar.gz"
    wget -O /tmp/sing-box.tar.gz "$DOWNLOAD_URL" || { echo -e "${RED}下载失败${PLAIN}"; return 1; }
    tar -xzf /tmp/sing-box.tar.gz -C /tmp
    EXTRACT_DIR=$(find /tmp -maxdepth 1 -type d -name "sing-box-${LATEST}-linux-*" | head -1)
    cp "$EXTRACT_DIR/sing-box" "$XSB_DIR/bin/"
    chmod +x "$XSB_DIR/bin/sing-box"
    rm -rf /tmp/sing-box*
    command -v sing-box &>/dev/null || { echo -e "${RED}安装失败${PLAIN}"; exit 1; }
    echo -e "${GREEN}Sing-box 版本: $(sing-box version | head -1)${PLAIN}"
}

update_singbox() {
    echo -e "${GREEN}更新 Sing-box...${PLAIN}"
    rm -f "$XSB_DIR/bin/sing-box"
    install_singbox
}

uninstall_singbox() {
    echo -e "${YELLOW}卸载 Sing-box...${PLAIN}"
    if [[ "$OS" == "alpine" ]]; then
        rc-service sing-box stop 2>/dev/null
        rc-update del sing-box 2>/dev/null
        rm -f /etc/init.d/sing-box
    else
        systemctl stop sing-box 2>/dev/null
        systemctl disable sing-box 2>/dev/null
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
    fi
    rm -f "$XSB_DIR/bin/sing-box"
    echo -e "${GREEN}已卸载。配置文件保留，不需要可直接 rm -rf $XSB_DIR${PLAIN}"
}

list_certs() {
    echo -e "${GREEN}已安装的证书:${PLAIN}"
    if [[ -d "$XSB_DIR/cert" ]]; then
        find "$XSB_DIR/cert" -maxdepth 1 -type d -not -path "$XSB_DIR/cert" | while read d; do
            domain=$(basename "$d")
            [[ -f "$d/cert.crt" && -f "$d/private.key" ]] && echo "  $domain"
        done
    else
        echo "  无"
    fi
}

add_cert() {
    DOMAIN=$(get_or_ask "DOMAIN" "请输入域名" "")
    [[ -z "$DOMAIN" ]] && { echo -e "${RED}域名不能为空${PLAIN}"; return 1; }
    [[ -d "$XSB_DIR/cert/$DOMAIN" ]] && { echo -e "${YELLOW}证书已存在${PLAIN}"; return 1; }
    mkdir -p "$XSB_DIR/cert/$DOMAIN"
    [[ ! -f ~/.acme.sh/acme.sh ]] && curl -s https://get.acme.sh | sh

    ACME_MODE=$(get_or_ask "ACME_MODE" "验证方式 (1=HTTP-01, 2=DNS-01)" "2")
    case $ACME_MODE in
        1)
            WEB_PORT=$(get_or_ask "WEB_PORT" "HTTP 验证端口" "80")
            ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
            ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --httpport $WEB_PORT
            ;;
        2)
            CF_Key=$(get_or_ask "CF_Key" "Cloudflare API Key" "")
            CF_Email=$(get_or_ask "CF_Email" "Cloudflare Email" "")
            if [[ -z "$CF_Key" || -z "$CF_Email" ]]; then
                echo -e "${RED}需要 Cloudflare 凭证 (CF_Key, CF_Email)${PLAIN}"
                return 1
            fi
            ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
            ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" -d "*.${DOMAIN}"
            ;;
        *) echo -e "${RED}无效选择${PLAIN}"; return 1 ;;
    esac
    ~/.acme.sh/acme.sh --installcert -d "$DOMAIN" \
        --key-file "$XSB_DIR/cert/$DOMAIN/private.key" \
        --fullchain-file "$XSB_DIR/cert/$DOMAIN/cert.crt"
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    chmod 600 "$XSB_DIR/cert/$DOMAIN/private.key"
    echo -e "${GREEN}证书已安装到 $XSB_DIR/cert/$DOMAIN/${PLAIN}"
}

delete_cert() {
    list_certs
    DOMAIN=$(get_or_ask "DELETE_DOMAIN" "请输入要删除的域名" "")
    if [[ -d "$XSB_DIR/cert/$DOMAIN" ]]; then
        ~/.acme.sh/acme.sh --remove -d "$DOMAIN" 2>/dev/null
        rm -rf "$XSB_DIR/cert/$DOMAIN"
        echo -e "${GREEN}已删除${PLAIN}"
    else
        echo -e "${RED}证书不存在${PLAIN}"
    fi
}

check_port_available() { ! ss -lntu | grep -q ":$1 "; }

list_inbounds() {
    echo -e "${GREEN}当前入站:${PLAIN}"
    for f in "$XSB_DIR"/inbounds/inbound_*.json; do
        [[ -f "$f" ]] && echo "  $(basename "$f" .json | sed 's/inbound_//')"
    done
}

add_inbound() {
    if ! command -v sing-box &>/dev/null; then
        echo -e "${RED}请先安装 Sing-box${PLAIN}" && return 1
    fi

    INBOUND_TYPE=$(get_or_ask "INBOUND_TYPE" "选择协议 (1=VLESS+Reality,2=AnyReality,3=AnyTLS,4=Hysteria2,5=VMess+WSS,6=Shadowsocks)" "")
    case $INBOUND_TYPE in
        1) PROTO="vless-reality" ;;
        2) PROTO="anytls-reality" ;;
        3) PROTO="anytls-tls" ;;
        4) PROTO="hysteria2" ;;
        5) PROTO="vmess-wss" ;;
        6) PROTO="shadowsocks" ;;
        *) echo -e "${RED}无效选择${PLAIN}"; return 1 ;;
    esac

    tag="$(date +%s)"
    PORT=$(get_or_ask "PORT" "端口 (0=随机)" "0")

    if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}端口必须是数字${PLAIN}"
        return 1
    fi

    if [[ "$PORT" == "0" ]]; then
        while true; do
            PORT=$(shuf -i 10000-65535 -n 1)
            check_port_available "$PORT" && break
        done
    elif ! check_port_available "$PORT"; then
        echo -e "${YELLOW}端口 $PORT 不可用，将使用随机端口${PLAIN}"
        while true; do
            PORT=$(shuf -i 10000-65535 -n 1)
            check_port_available "$PORT" && break
        done
    fi

    if [[ "$PROTO" == "shadowsocks" ]]; then
        METHOD=$(get_or_ask "METHOD" "加密方法 (1=aes-128-gcm,2=aes-256-gcm,3=chacha20-poly1305)" "2")
        case $METHOD in
            1) method="2022-blake3-aes-128-gcm"; key_len=16 ;;
            2) method="2022-blake3-aes-256-gcm"; key_len=32 ;;
            3) method="2022-blake3-chacha20-poly1305"; key_len=32 ;;
            *) method="2022-blake3-aes-256-gcm"; key_len=32 ;;
        esac
        PASSWORD=$(get_or_ask "PASSWORD" "Shadowsocks 密钥 (留空自动生成)" "")
        [[ -z "$PASSWORD" ]] && PASSWORD=$(sing-box generate rand --base64 $key_len)
    else
        UUID=$(get_or_ask "UUID" "UUID (留空自动生成)" "")
        [[ -z "$UUID" ]] && UUID=$(sing-box generate uuid)
    fi

    case $PROTO in
        vless-reality|anytls-reality)
            REALITY_SERVER_NAME=$(get_or_ask "REALITY_SERVER_NAME" "Reality 伪装域名" "www.apple.com")
            KEYPAIR=$(sing-box generate reality-keypair)
            PRIVATE_KEY=$(echo "$KEYPAIR" | awk '/PrivateKey/ {print $2}' | tr -d '"')
            PUBLIC_KEY=$(echo "$KEYPAIR" | awk '/PublicKey/ {print $2}' | tr -d '"')
            SHORT_ID=$(sing-box generate rand --hex 4)
            echo "$PRIVATE_KEY" > "$XSB_DIR/inbounds/inbound_${tag}_reality_private_key"
            echo "$PUBLIC_KEY" > "$XSB_DIR/inbounds/inbound_${tag}_reality_public_key"
            echo "$SHORT_ID" > "$XSB_DIR/inbounds/inbound_${tag}_reality_short_id"
            chmod 600 "$XSB_DIR/inbounds/inbound_${tag}"_*
            ;;
        anytls-tls|hysteria2|vmess-wss)
            list_certs
            CERT_DOMAIN=$(get_or_ask "CERT_DOMAIN" "证书域名" "")
            if [[ ! -d "$XSB_DIR/cert/$CERT_DOMAIN" ]]; then
                echo -e "${RED}证书不存在${PLAIN}"; return 1
            fi
            ;;
    esac

    case $PROTO in
        vless-reality)
            jq -n --arg type "vless" --arg tag "$tag" --arg listen "::" --argjson port "$PORT" \
                --arg uuid "$UUID" --arg sni "$REALITY_SERVER_NAME" --arg privkey "$PRIVATE_KEY" --arg shortid "$SHORT_ID" \
                '{
                    type: $type, tag: $tag, listen: $listen, listen_port: $port,
                    users: [ { uuid: $uuid, flow: "xtls-rprx-vision" } ],
                    tls: { enabled: true, server_name: $sni, reality: { enabled: true, handshake: { server: $sni, server_port: 443 }, private_key: $privkey, short_id: [ $shortid ] } }
                }' > "$XSB_DIR/inbounds/inbound_${tag}.json"
            ;;
        anytls-reality)
            jq -n --arg type "anytls" --arg tag "$tag" --arg listen "::" --argjson port "$PORT" \
                --arg password "$UUID" --arg sni "$REALITY_SERVER_NAME" --arg privkey "$PRIVATE_KEY" --arg shortid "$SHORT_ID" \
                '{
                    type: $type, tag: $tag, listen: $listen, listen_port: $port,
                    users: [ { password: $password } ],
                    tls: { enabled: true, server_name: $sni, reality: { enabled: true, handshake: { server: $sni, server_port: 443 }, private_key: $privkey, short_id: [ $shortid ] } }
                }' > "$XSB_DIR/inbounds/inbound_${tag}.json"
            ;;
        anytls-tls)
            jq -n --arg type "anytls" --arg tag "$tag" --arg listen "::" --argjson port "$PORT" \
                --arg password "$UUID" --arg domain "$CERT_DOMAIN" \
                --arg cert_path "$XSB_DIR/cert/$CERT_DOMAIN/cert.crt" \
                --arg key_path "$XSB_DIR/cert/$CERT_DOMAIN/private.key" \
                '{
                    type: $type, tag: $tag, listen: $listen, listen_port: $port,
                    users: [ { password: $password } ],
                    tls: { enabled: true, server_name: $domain, certificate_path: $cert_path, key_path: $key_path }
                }' > "$XSB_DIR/inbounds/inbound_${tag}.json"
            ;;
        hysteria2)
            jq -n --arg type "hysteria2" --arg tag "$tag" --arg listen "::" --argjson port "$PORT" \
                --arg password "$UUID" --arg domain "$CERT_DOMAIN" \
                --arg cert_path "$XSB_DIR/cert/$CERT_DOMAIN/cert.crt" \
                --arg key_path "$XSB_DIR/cert/$CERT_DOMAIN/private.key" \
                '{
                    type: $type, tag: $tag, listen: $listen, listen_port: $port,
                    users: [ { password: $password } ],
                    ignore_client_bandwidth: false,
                    tls: { enabled: true, server_name: $domain, certificate_path: $cert_path, key_path: $key_path }
                }' > "$XSB_DIR/inbounds/inbound_${tag}.json"

            install_brutal
            ENABLE_HOP=$(get_or_ask "ENABLE_HOP" "是否启用端口跳跃？(y/n)" "n")
            if [[ "$ENABLE_HOP" == "y" || "$ENABLE_HOP" == "Y" ]]; then
                HY2_HOP_START=$(get_or_ask "HY2_HOP_START" "起始端口" "60000")
                HY2_HOP_END=$(get_or_ask "HY2_HOP_END" "结束端口" "65000")
                echo "${HY2_HOP_START}-${HY2_HOP_END}" > "$XSB_DIR/inbounds/inbound_${tag}.hop"
                chmod 600 "$XSB_DIR/inbounds/inbound_${tag}.hop"
                setup_hy2_hop "$PORT" "$HY2_HOP_START" "$HY2_HOP_END" "$tag"
            fi
            ;;
        vmess-wss)
            WS_PATH=$(get_or_ask "WS_PATH" "WebSocket 路径" "/vm-${UUID}")
            jq -n --arg type "vmess" --arg tag "$tag" --arg listen "::" --argjson port "$PORT" \
                --arg uuid "$UUID" --arg domain "$CERT_DOMAIN" --arg path "$WS_PATH" \
                --arg cert_path "$XSB_DIR/cert/$CERT_DOMAIN/cert.crt" \
                --arg key_path "$XSB_DIR/cert/$CERT_DOMAIN/private.key" \
                '{
                    type: $type, tag: $tag, listen: $listen, listen_port: $port,
                    users: [ { uuid: $uuid, alterId: 0 } ],
                    transport: { type: "ws", path: $path, headers: { Host: $domain }, early_data_header_name: "Sec-WebSocket-Protocol" },
                    tls: { enabled: true, server_name: $domain, certificate_path: $cert_path, key_path: $key_path }
                }' > "$XSB_DIR/inbounds/inbound_${tag}.json"
            ;;
        shadowsocks)
            jq -n --arg type "shadowsocks" --arg tag "$tag" --arg listen "::" --argjson port "$PORT" \
                --arg method "$method" --arg password "$PASSWORD" \
                '{type: $type, tag: $tag, listen: $listen, listen_port: $port, method: $method, password: $password}' \
                > "$XSB_DIR/inbounds/inbound_${tag}.json"
            ;;
    esac

    echo -e "${GREEN}入站 $tag 添加成功 (端口 $PORT)${PLAIN}"
}

delete_inbound() {
    list_inbounds
    tag=$(get_or_ask "DELETE_INBOUND_TAG" "请输入要删除的入站标签" "")
    if [[ -f "$XSB_DIR/inbounds/inbound_${tag}.json" ]]; then
        rm -f "$XSB_DIR/inbounds/inbound_${tag}.json"
        [[ -f "$XSB_DIR/inbounds/inbound_${tag}.hop" ]] && { rm -f "$XSB_DIR/inbounds/inbound_${tag}.hop"; cleanup_hy2_hop "$tag"; }
        rm -f "$XSB_DIR/inbounds/inbound_${tag}"_reality_*
        echo -e "${GREEN}已删除${PLAIN}"
    else
        echo -e "${RED}不存在${PLAIN}"
    fi
}

install_brutal() {
    if lsmod | grep -q brutal; then
        echo -e "${GREEN}Brutal 已加载${PLAIN}"
    else
        echo -e "${GREEN}安装 tcp-brutal...${PLAIN}"
        bash <(curl -fsSL https://raw.githubusercontent.com/apernet/tcp-brutal/refs/heads/master/scripts/install_dkms.sh)
    fi
}

setup_hy2_hop() {
    local hy2_port=$1 hop_start=$2 hop_end=$3 tag=$4
    echo -e "${GREEN}配置 Hysteria2 端口跳跃 (${hop_start}-${hop_end}) -> ${hy2_port}${PLAIN}"
    iptables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports :${hy2_port} -m comment --comment "xsb_hy2_${tag}"
    ip6tables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports :${hy2_port} -m comment --comment "xsb_hy2_${tag}"
    persist_iptables
}

cleanup_hy2_hop() {
    local tag=$1
    iptables -t nat -D PREROUTING -p udp -m comment --comment "xsb_hy2_${tag}" -j REDIRECT 2>/dev/null
    ip6tables -t nat -D PREROUTING -p udp -m comment --comment "xsb_hy2_${tag}" -j REDIRECT 2>/dev/null
    persist_iptables
}

persist_iptables() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save && return 0
    fi
    if ! command -v iptables-save >/dev/null 2>&1; then
        echo -e "${YELLOW}未找到 iptables-save，跳过持久化${PLAIN}"
        return 1
    fi
    local v4_file v6_file
    if [[ -d /etc/iptables ]]; then
        v4_file="/etc/iptables/rules.v4"; v6_file="/etc/iptables/rules.v6"
    elif [[ -d /etc/sysconfig ]]; then
        v4_file="/etc/sysconfig/iptables"; v6_file="/etc/sysconfig/ip6tables"
    elif [[ -d /etc/local.d ]]; then
        mkdir -p /etc/iptables
        v4_file="/etc/iptables/rules.v4"; v6_file="/etc/iptables/rules.v6"
        cat > /etc/local.d/iptables-restore.start <<EOF
#!/bin/sh
iptables-restore < /etc/iptables/rules.v4 2>/dev/null
ip6tables-restore < /etc/iptables/rules.v6 2>/dev/null
EOF
        chmod +x /etc/local.d/iptables-restore.start
        rc-update add local default 2>/dev/null
    else
        echo -e "${RED}无法持久化 iptables 规则${PLAIN}"
        return 1
    fi
    iptables-save > "$v4_file" && ip6tables-save > "$v6_file" && echo -e "${GREEN}规则已持久化${PLAIN}"
}

list_outbounds() {
    echo -e "${GREEN}当前出站:${PLAIN}"
    for f in "$XSB_DIR"/outbounds/outbound_*.json "$XSB_DIR"/outbounds/endpoint_*.json; do
        [[ -f "$f" ]] && echo "  $(basename "$f" .json | sed 's/^outbound_//;s/^endpoint_//')"
    done
}

add_outbound() {
    OUTBOUND_TYPE=$(get_or_ask "OUTBOUND_TYPE" "出站类型 (1=SOCKS5, 2=WARP)" "")
    tag="$(date +%s)"
    OUTBOUND_MATCH=$(get_or_ask "OUTBOUND_MATCH" "路由匹配规则 (JSON)" '{"ip_cidr":["0.0.0.0/0","::/0"]}')
    case $OUTBOUND_TYPE in
        1)
            server=$(get_or_ask "SOCKS5_SERVER" "SOCKS5 服务器" "127.0.0.1")
            port=$(get_or_ask "SOCKS5_PORT" "端口" "1080")
            user=$(get_or_ask "SOCKS5_USER" "用户名 (可选)" "")
            pass=$(get_or_ask "SOCKS5_PASS" "密码 (可选)" "")
            jq -n --arg type "socks" --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                --arg user "$user" --arg pass "$pass" \
                '{type: $type, tag: $tag, server: $server, server_port: $port, username: $user, password: $pass}' \
                > "$XSB_DIR/outbounds/outbound_${tag}.json"
            add_route_rule "$tag" "$OUTBOUND_MATCH"
            ;;
        2)
            WARP_PRIVATE_KEY=$(get_or_ask "WARP_PRIVATE_KEY" "请输入 Private Key" "")
            WARP_IPV6=$(get_or_ask "WARP_IPV6" "请输入 IPv6 地址（不含 /128）" "")
            WARP_RESERVED=$(get_or_ask "WARP_RESERVED" "请输入 reserved 值）" "")
            if [[ -z "$WARP_PRIVATE_KEY" || -z "$WARP_IPV6" || -z "$WARP_RESERVED" ]]; then
                echo -e "${RED}缺少必要 WARP 参数，请配置后再试${PLAIN}"
                return 1
            fi
            curl -s4 --max-time 3 ifconfig.me >/dev/null 2>&1 && WARP_PEER_ADDR="162.159.192.1" || WARP_PEER_ADDR="[2606:4700:d0::a29f:c001]"
            jq -n --arg type "wireguard" --arg tag "$tag" \
                --arg addr_v4 "172.16.0.2/32" --arg addr_v6 "$WARP_IPV6/128" \
                --arg privkey "$WARP_PRIVATE_KEY" --arg peer_addr "$WARP_PEER_ADDR" \
                --argjson reserved "$WARP_RESERVED" \
                '{
                    type: $type, tag: $tag,
                    address: [ $addr_v4, $addr_v6 ],
                    private_key: $privkey,
                    peers: [ { address: $peer_addr, port: 2408, public_key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", allowed_ips: ["0.0.0.0/0", "::/0"], reserved: $reserved } ]
                }' > "$XSB_DIR/outbounds/endpoint_${tag}.json"
            add_route_rule "$tag" "$OUTBOUND_MATCH"
            ;;
        *) echo -e "${RED}无效选择${PLAIN}"; return 1 ;;
    esac
    echo -e "${GREEN}出站 $tag 添加成功${PLAIN}"
}

delete_outbound() {
    list_outbounds
    tag=$(get_or_ask "DELETE_OUTBOUND_TAG" "请输入要删除的出站标签" "")
    rm -f "$XSB_DIR/outbounds/outbound_${tag}.json" "$XSB_DIR/outbounds/endpoint_${tag}.json" "$XSB_DIR/routes/route_${tag}.json"
    echo -e "${GREEN}已删除${PLAIN}"
}

add_route_rule() {
    mkdir -p "$XSB_DIR/routes"
    jq -n --arg outbound "$1" --argjson spec "$2" '$spec + { outbound: $outbound }' > "$XSB_DIR/routes/route_${1}.json"
}

cf_api_request() {
    local method=$1 url=$2 data=$3
    CF_Key=$(get_or_ask "CF_Key" "Cloudflare API Key" "")
    CF_Email=$(get_or_ask "CF_Email" "Cloudflare Email" "")
    if [[ -z "$CF_Key" || -z "$CF_Email" ]]; then
        echo -e "${RED}需要 Cloudflare 凭证 (CF_Key, CF_Email)${PLAIN}"
        return 1
    fi
    headers=(-H "X-Auth-Email: $CF_Email" -H "X-Auth-Key: $CF_Key" -H "Content-Type: application/json")
    if [[ -n "$data" ]]; then
        curl -s --max-time 10 --retry 2 -X "$method" "$url" "${headers[@]}" --data "$data"
    else
        curl -s --max-time 10 --retry 2 -X "$method" "$url" "${headers[@]}"
    fi
}

cf_delete_record() {
    local domain=$1 zone_id=$2
    local resp=$(cf_api_request "GET" "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?name=$domain")
    echo "$resp" | jq -r --arg domain "$domain" '.result[] | select(.type=="A" or .type=="AAAA" or .type=="CNAME") | select(.name==$domain) | .id' | while read -r rec_id; do
        [[ -n "$rec_id" ]] && cf_api_request "DELETE" "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$rec_id" > /dev/null && echo "已删除记录: $rec_id"
    done
}

cf_add_record() {
    local domain=$1 type=$2 content=$3 zone_id=$4 proxied="${5:-true}"
    local data=$(jq -n --arg type "$type" --arg name "$domain" --arg content "$content" --argjson proxied "$proxied" \
        '{type: $type, name: $name, content: $content, ttl: 120, proxied: $proxied}')
    cf_api_request "POST" "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" "$data" > /dev/null
    echo "已添加 $type 记录: $domain -> $content"
}

cf_dns() {
    echo -e "${YELLOW}配置 Cloudflare DNS 记录${PLAIN}"
    DOMAIN=$(get_or_ask "DOMAIN" "主域名" "")
    ZONE_ID=$(get_or_ask "ZONE_ID" "Zone ID" "")
    [[ -z "$DOMAIN" || -z "$ZONE_ID" ]] && { echo -e "${RED}需要 DOMAIN 和 ZONE_ID${PLAIN}"; return 1; }
    ipv4=$(curl -s4 --max-time 3 ifconfig.me 2>/dev/null)
    ipv6=$(curl -s6 --max-time 3 ifconfig.me 2>/dev/null)
    echo -e "${GREEN}当前 IP: IPv4=${ipv4:-无}, IPv6=${ipv6:-无}${PLAIN}"
    read -p "是否清除现有记录并添加新记录？[Y/n]: " confirm
    [[ "$confirm" =~ [Nn] ]] && return 0
    cf_delete_record "$DOMAIN" "$ZONE_ID"
    [[ -n "$ipv4" ]] && cf_add_record "$DOMAIN" "A" "$ipv4" "$ZONE_ID" "true"
    [[ -n "$ipv6" ]] && cf_add_record "$DOMAIN" "AAAA" "$ipv6" "$ZONE_ID" "true"
    echo -e "${GREEN}DNS 记录更新完成${PLAIN}"
}

cf_origin_rule() {
    echo -e "${YELLOW}配置 Origin Rule${PLAIN}"
    DOMAIN=$(get_or_ask "DOMAIN" "主域名" "")
    ZONE_ID=$(get_or_ask "ZONE_ID" "Zone ID" "")
    WS_PATH=$(get_or_ask "WS_PATH" "WebSocket 路径" "")
    PORT=$(get_or_ask "PORT" "目标端口" "")
    [[ -z "$DOMAIN" || -z "$ZONE_ID" || -z "$WS_PATH" || -z "$PORT" ]] && { echo -e "${RED}缺少必要参数${PLAIN}"; return 1; }
    RULE_DATA=$(cat <<EOF
{ "targets": [ { "target": "hostname", "value": "$DOMAIN" }, { "target": "path", "value": "$WS_PATH" } ], "actions": [ { "target": "port", "value": $PORT } ] }
EOF
)
    RESP=$(cf_api_request "POST" "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rules/origin_rules" "$RULE_DATA")
    if echo "$RESP" | jq -e '.success == true' >/dev/null; then
        echo -e "${GREEN}Origin Rule 已配置 (路径 $WS_PATH -> 端口 $PORT)${PLAIN}"
    else
        echo -e "${RED}配置失败: $(echo "$RESP" | jq -r '.errors[0].message')${PLAIN}"
    fi
}

cf_argo() {
    echo -e "${YELLOW}配置 Argo 固定隧道${PLAIN}"

    if [[ ! -f "$XSB_DIR/bin/cloudflared" ]]; then
        echo -e "${GREEN}下载 cloudflared...${PLAIN}"
        case $(uname -m) in
            x86_64)  CF_ARCH="amd64" ;;
            aarch64) CF_ARCH="arm64" ;;
            *) echo -e "${RED}不支持的架构${PLAIN}"; return 1 ;;
        esac
        wget -O "$XSB_DIR/bin/cloudflared" \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
            || { echo -e "${RED}下载失败${PLAIN}"; return 1; }
        chmod +x "$XSB_DIR/bin/cloudflared"
    fi

    TUNNEL_NAME=$(get_or_ask "TUNNEL_NAME" "隧道标识" "main")
    ARGO_TOKEN=$(get_or_ask "ARGO_TOKEN" "请输入 Argo Tunnel Token" "")
    [[ -z "$ARGO_TOKEN" ]] && { echo -e "${RED}Token 不能为空${PLAIN}"; return 1; }

    TOKEN_FILE="$XSB_DIR/conf/argo_token_${TUNNEL_NAME}"
    echo "$ARGO_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"

    SERVICE_NAME="argo-tunnel-${TUNNEL_NAME}"

    if [[ "$OS" == "alpine" ]]; then
        INIT_FILE="/etc/init.d/${SERVICE_NAME}"
        cat > "$INIT_FILE" <<EOF
#!/sbin/openrc-run
command="$XSB_DIR/bin/cloudflared"
command_args="tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token-file \"$TOKEN_FILE\""
command_user="root"
pidfile="/run/${SERVICE_NAME}.pid"
name="Argo Tunnel ${TUNNEL_NAME}"
description="Cloudflare Argo Tunnel (${TUNNEL_NAME})"
start_stop_daemon_args="--background --make-pidfile"
depend() { need net; }
EOF
        chmod +x "$INIT_FILE"
        rc-update add "$SERVICE_NAME" default 2>/dev/null
        rc-service "$SERVICE_NAME" restart
    else
        SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Argo Tunnel (${TUNNEL_NAME})
After=network.target

[Service]
Type=simple
ExecStart=$XSB_DIR/bin/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token-file "$TOKEN_FILE"
Restart=on-failure
RestartSec=10s
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME" 2>/dev/null
        systemctl restart "$SERVICE_NAME"
    fi

    echo -e "${GREEN}Argo 隧道 [${TUNNEL_NAME}] 已创建/重启${PLAIN}"
    echo -e "查看状态: $([[ "$OS" == "alpine" ]] && echo "rc-service ${SERVICE_NAME} status" || echo "systemctl status ${SERVICE_NAME}")"
}

tcp_tune() {
    echo -e "${YELLOW}TCP 智能调优${PLAIN}"
    if [[ ! -f "$XSB_DIR/bin/speedtest" ]]; then
        echo -e "${GREEN}安装 Speedtest...${PLAIN}"
        case $(uname -m) in x86_64) ST_ARCH="x86_64" ;; aarch64) ST_ARCH="aarch64" ;; *) echo -e "${RED}不支持的架构${PLAIN}"; return 1 ;; esac
        FILE_NAME=$(curl -s --max-time 5 "https://www.speedtest.net/apps/cli" | grep -o "ookla-speedtest-[0-9.]\+-linux-${ST_ARCH}\.tgz" | head -1)
        [[ -z "$FILE_NAME" ]] && { echo -e "${RED}未找到安装包${PLAIN}"; return 1; }
        wget -O /tmp/speedtest.tgz "https://install.speedtest.net/app/cli/${FILE_NAME}" || return 1
        tar -xzf /tmp/speedtest.tgz -C /tmp && mv /tmp/speedtest "$XSB_DIR/bin/" && chmod +x "$XSB_DIR/bin/speedtest"
        rm -f /tmp/speedtest.tgz
    fi
    SERVER_ID=$(get_or_ask "TUNE_SERVER_ID" "测速服务器 ID (默认 1536)" "1536")
    echo -e "${GREEN}测速中...${PLAIN}"
    LANG=C speedtest_output=$("$XSB_DIR/bin/speedtest" --accept-license --accept-gdpr --server-id="$SERVER_ID" 2>&1)
    echo "$speedtest_output"
    UPLOAD=$(echo "$speedtest_output" | awk -F': ' '/Upload:/ {printf("%.0f", $2)}')
    [[ -z "$UPLOAD" ]] && UPLOAD=$(get_or_ask "TUNE_BANDWIDTH" "手动输入带宽 (Mbit/s)" "100")
    BUFFER_MB=$(( ($(echo "$UPLOAD" | awk '{printf("%.0f", $1)}') / 8 + 3) / 4 * 4 ))
    [ $BUFFER_MB -lt 8 ] && BUFFER_MB=8
    HARD_LIMIT_MB=128
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    MAX_ALLOWED_MB=$(( TOTAL_RAM_MB / 4 ))
    [ $MAX_ALLOWED_MB -gt $HARD_LIMIT_MB ] && MAX_ALLOWED_MB=$HARD_LIMIT_MB
    [ $BUFFER_MB -gt $MAX_ALLOWED_MB ] && BUFFER_MB=$MAX_ALLOWED_MB
    BUFFER_BYTES=$((BUFFER_MB * 1024 * 1024))
    cat > /etc/sysctl.d/99-tcp.conf <<EOF
kernel.panic = 10
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.min_free_kbytes = 65536
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.netdev_max_backlog = 25000
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.core.rmem_max = ${BUFFER_BYTES}
net.core.wmem_max = ${BUFFER_BYTES}
net.ipv4.tcp_rmem = 4096 4194304 ${BUFFER_BYTES}
net.ipv4.tcp_wmem = 4096 4194304 ${BUFFER_BYTES}
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_notsent_lowat = 16384
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_recovery = 1
net.ipv4.tcp_reordering = 5
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_limit_output_bytes = 4194304
EOF
    sysctl -p /etc/sysctl.d/99-tcp.conf
    echo -e "${GREEN}TCP 调优完成 (缓冲区 ${BUFFER_MB}MB)${PLAIN}"
}

build_and_start() {
    echo -e "${GREEN}构建完整配置...${PLAIN}"
    inbounds_files=("$XSB_DIR"/inbounds/inbound_*.json)
    inbounds_json='[]'
    if [[ ${#inbounds_files[@]} -gt 0 && -f "${inbounds_files[0]}" ]]; then
        inbounds_json=$(jq -s '.' "${inbounds_files[@]}" 2>/dev/null) || { echo -e "${RED}入站 JSON 合并失败${PLAIN}"; return 1; }
    fi
    outbounds_files=("$XSB_DIR"/outbounds/outbound_*.json)
    outbounds_json='[]'
    if [[ ${#outbounds_files[@]} -gt 0 && -f "${outbounds_files[0]}" ]]; then
        outbounds_json=$(jq -s '.' "${outbounds_files[@]}" 2>/dev/null) || { echo -e "${RED}出站 JSON 合并失败${PLAIN}"; return 1; }
    fi
    endpoints_files=("$XSB_DIR"/outbounds/endpoint_*.json)
    endpoints_json='[]'
    if [[ ${#endpoints_files[@]} -gt 0 && -f "${endpoints_files[0]}" ]]; then
        endpoints_json=$(jq -s '.' "${endpoints_files[@]}" 2>/dev/null) || { echo -e "${RED}端点 JSON 合并失败${PLAIN}"; return 1; }
    fi
    routes_files=("$XSB_DIR"/routes/route_*.json)
    rules_json='[]'
    if [[ ${#routes_files[@]} -gt 0 && -f "${routes_files[0]}" ]]; then
        rules_json=$(jq -s '.' "${routes_files[@]}" 2>/dev/null) || { echo -e "${RED}路由规则合并失败${PLAIN}"; return 1; }
    fi
    preset_rules='[ { "action": "sniff" }, { "action": "resolve", "strategy": "prefer_ipv4" } ]'
    all_rules=$(jq -n --argjson preset "$preset_rules" --argjson user "$rules_json" '$preset + $user')
    if [[ "$outbounds_json" == "[]" ]]; then
        outbounds_json='[ { "type": "direct", "tag": "direct" } ]'
    else
        outbounds_json=$(jq -n --argjson out "$outbounds_json" '$out + [ { "type": "direct", "tag": "direct" } ]')
    fi
    jq -n --argjson inbounds "$inbounds_json" --argjson outbounds "$outbounds_json" --argjson endpoints "$endpoints_json" --argjson rules "$all_rules" \
        '{ log: { level: "info" }, inbounds: $inbounds, outbounds: $outbounds, endpoints: $endpoints, route: { rules: $rules, final: "direct" } }' \
        > "$XSB_DIR/conf/config.json"
    echo -e "${GREEN}配置文件生成: $XSB_DIR/conf/config.json${PLAIN}"
    if ! "$XSB_DIR/bin/sing-box" check -c "$XSB_DIR/conf/config.json" >/dev/null 2>&1; then
        echo -e "${RED}配置文件检查失败:${PLAIN}"
        "$XSB_DIR/bin/sing-box" check -c "$XSB_DIR/conf/config.json"
        return 1
    fi
    if [[ "$OS" == "alpine" ]]; then
        cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
command="$XSB_DIR/bin/sing-box"
command_args="run -c $XSB_DIR/conf/config.json"
command_user="root"
pidfile="/run/sing-box.pid"
name="Sing-box"
description="Sing-box Service"
start_stop_daemon_args="--background --make-pidfile"
depend() { need net; }
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default 2>/dev/null
        rc-service sing-box restart
    else
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
Type=simple
ExecStart=$XSB_DIR/bin/sing-box run -c $XSB_DIR/conf/config.json
Restart=on-failure
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box 2>/dev/null
        systemctl restart sing-box
    fi
    echo -e "${GREEN}已创建/更新 sing-box 服务${PLAIN}"
    echo -e "查看状态: $([[ "$OS" == "alpine" ]] && echo "rc-service sing-box status" || echo "systemctl status sing-box")"
}

show_info() {
    ipv4=$(curl -s4 --max-time 3 ifconfig.me 2>/dev/null)
    ipv6=$(curl -s6 --max-time 3 ifconfig.me 2>/dev/null)
    echo "=================================================="
    echo -e "${GREEN}节点 IP 信息:${PLAIN}"
    echo "  IPv4: ${ipv4:-无}"
    echo "  IPv6: ${ipv6:-无}"
    echo "--------------------------------------------------"

    for f in "$XSB_DIR"/inbounds/inbound_*.json; do
        [[ ! -f "$f" ]] && continue
        tag=$(basename "$f" .json | sed 's/inbound_//')
        type=$(jq -r '.type' "$f")
        port=$(jq -r '.listen_port' "$f")

        case $type in
            vless)
                uuid=$(jq -r '.users[0].uuid' "$f")
                sni=$(jq -r '.tls.server_name' "$f")
                sid=$(jq -r '.tls.reality.short_id[0]' "$f")
                pub_key_file="$XSB_DIR/inbounds/inbound_${tag}_reality_public_key"
                [[ -f "$pub_key_file" ]] && PUBLIC_KEY=$(cat "$pub_key_file") || PUBLIC_KEY=""
                [[ -n "$ipv4" ]] && echo "vless://$uuid@$ipv4:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$PUBLIC_KEY&sid=$sid&type=tcp#$tag"
                [[ -n "$ipv6" ]] && echo "vless://$uuid@[$ipv6]:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$PUBLIC_KEY&sid=$sid&type=tcp#$tag"
                ;;
            anytls)
                password=$(jq -r '.users[0].password' "$f")
                sni=$(jq -r '.tls.server_name' "$f")
                if jq -e '.tls.reality' "$f" >/dev/null 2>&1; then
                    sid=$(jq -r '.tls.reality.short_id[0]' "$f")
                    pub_key_file="$XSB_DIR/inbounds/inbound_${tag}_reality_public_key"
                    [[ -f "$pub_key_file" ]] && PUBLIC_KEY=$(cat "$pub_key_file") || PUBLIC_KEY=""
                    [[ -n "$ipv4" ]] && echo "anytls://$password@$ipv4:$port?security=reality&sni=$sni&fp=chrome&pbk=$PUBLIC_KEY&sid=$sid&type=tcp#$tag"
                    [[ -n "$ipv6" ]] && echo "anytls://$password@[$ipv6]:$port?security=reality&sni=$sni&fp=chrome&pbk=$PUBLIC_KEY&sid=$sid&type=tcp#$tag"
                else
                    [[ -n "$ipv4" ]] && echo "anytls://$password@$ipv4:$port?security=tls&sni=$sni&insecure=0&type=tcp#$tag"
                    [[ -n "$ipv6" ]] && echo "anytls://$password@[$ipv6]:$port?security=tls&sni=$sni&insecure=0&type=tcp#$tag"
                fi
                ;;
            hysteria2)
                password=$(jq -r '.users[0].password' "$f")
                sni=$(jq -r '.tls.server_name' "$f")
                hop_file="$XSB_DIR/inbounds/inbound_${tag}.hop"
                hop_range=""
                [[ -f "$hop_file" ]] && hop_range=$(cat "$hop_file")
                [[ -n "$ipv4" ]] && echo "hysteria2://$password@$ipv4:$port?sni=$sni&insecure=0${hop_range:+&mport=$hop_range}#$tag"
                [[ -n "$ipv6" ]] && echo "hysteria2://$password@[$ipv6]:$port?sni=$sni&insecure=0${hop_range:+&mport=$hop_range}#$tag"
                ;;
            vmess)
                uuid=$(jq -r '.users[0].uuid' "$f")
                host=$(jq -r '.transport.headers.Host' "$f")
                path=$(jq -r '.transport.path' "$f")
                sni=$(jq -r '.tls.server_name' "$f")
                vmess_json="{\"v\":\"2\",\"ps\":\"$tag\",\"add\":\"$ipv4\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"host\":\"$host\",\"path\":\"$path\",\"tls\":\"tls\"，\"sni\": \"$sni\"}"
                [[ -n "$ipv4" ]] && echo "vmess://$(echo -n "$vmess_json" | base64 -w 0 2>/dev/null || openssl base64 -A 2>/dev/null)"
                vmess_json="{\"v\":\"2\",\"ps\":\"$tag\",\"add\":\"$ipv6\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"host\":\"$host\",\"path\":\"$path\",\"tls\":\"tls\"，\"sni\": \"$sni\"}"
                [[ -n "$ipv6" ]] && echo "vmess://$(echo -n "$vmess_json" | base64 -w 0 2>/dev/null || openssl base64 -A 2>/dev/null)"
                ;;
            shadowsocks)
                method=$(jq -r '.method' "$f")
                password=$(jq -r '.password' "$f")
                ss_userinfo=$(echo -n "$method:$password" | base64 -w 0 2>/dev/null || openssl base64 -A 2>/dev/null)
                tag_b64=$(echo -n "$tag" | base64 -w 0 2>/dev/null || openssl base64 -A 2>/dev/null)
                [[ -n "$ipv4" ]] && echo "ss://$ss_userinfo@$ipv4:$port#$tag_b64"
                [[ -n "$ipv6" ]] && echo "ss://$ss_userinfo@[$ipv6]:$port#$tag_b64"
                ;;
        esac
    done
    echo "=================================================="
}

interactive_menu() {
    while true; do
        echo -e "\n${YELLOW}========== 主菜单 ==========${PLAIN}"
        echo "1) 安装/更新/卸载 Sing-box"
        echo "2) 管理证书"
        echo "3) 管理入站"
        echo "4) 管理出站"
        echo "5) Cloudflare 配置 (DNS / Origin Rule / Argo)"
        echo "6) TCP 智能调优"
        echo "7) 构建配置并启动服务"
        echo "8) 显示节点信息"
        echo "0) 退出"
        read -p "请选择 [0-8]: " main_choice
        case $main_choice in
            1)
                echo "1) 安装  2) 更新  3) 卸载"
                read -p "选择 [1-3]: " sub
                case $sub in 1) install_singbox ;; 2) update_singbox ;; 3) uninstall_singbox ;; *) echo -e "${RED}无效${PLAIN}" ;; esac
                ;;
            2)
                echo "1) 列出证书  2) 添加证书  3) 删除证书"
                read -p "选择 [1-3]: " sub
                case $sub in 1) list_certs ;; 2) add_cert ;; 3) delete_cert ;; *) echo -e "${RED}无效${PLAIN}" ;; esac
                ;;
            3)
                echo "1) 列出入站  2) 添加入站  3) 删除入站"
                read -p "选择 [1-3]: " sub
                case $sub in 1) list_inbounds ;; 2) add_inbound ;; 3) delete_inbound ;; *) echo -e "${RED}无效${PLAIN}" ;; esac
                ;;
            4)
                echo "1) 列出出站  2) 添加出站  3) 删除出站"
                read -p "选择 [1-3]: " sub
                case $sub in 1) list_outbounds ;; 2) add_outbound ;; 3) delete_outbound ;; *) echo -e "${RED}无效${PLAIN}" ;; esac
                ;;
            5)
                echo "1) DNS 记录  2) Origin Rule  3) Argo 隧道"
                read -p "选择 [1-3]: " sub
                case $sub in 1) cf_dns ;; 2) cf_origin_rule ;; 3) cf_argo ;; *) echo -e "${RED}无效${PLAIN}" ;; esac
                ;;
            6) tcp_tune ;;
            7) build_and_start ;;
            8) show_info ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${PLAIN}" ;;
        esac
    done
}

XSB_TASKS="${XSB_TASKS:-}"
if [[ -n "$XSB_TASKS" ]]; then
    for task in $(echo "$XSB_TASKS" | tr ',' ' '); do
        case "$task" in
            install) 
                install_deps
                install_singbox
                ;;
            cert) add_cert ;;
            inbound) add_inbound ;;
            outbound) add_outbound ;;
            cf_dns) cf_dns ;;
            cf_origin_rule) cf_origin_rule ;;
            cf_argo) cf_argo ;;
            tune) tcp_tune ;;
            build) 
                build_and_start 
                show_info
                ;;
            *) echo -e "${RED}未知任务: $task${PLAIN}" ;;
        esac
    done
    if [[ "$XSB_TASKS" =~ inbound ]] && [[ ! "$XSB_TASKS" =~ build ]]; then
        echo -e "${YELLOW}检测到配置变更，自动构建并启动...${PLAIN}"
        build_and_start
        show_info
    fi
    exit 0
else
    install_deps
    interactive_menu
fi
