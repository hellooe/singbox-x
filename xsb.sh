#!/bin/bash
#===============================================================
# 交互式 Sing-box 全能节点管理脚本
# 所有文件存放于 ~/xsb/
# 功能: 安装Singbox | ACME多证书管理 | 增删入站/出站
#       安装Brutal并实现端口跳跃 | TCP智能调优
#       Cloudflare Origin Rule + Argo隧道
#       支持 Alpine Linux
#===============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PLAIN='\033[0m'
XSB_DIR="$HOME/xsb"
mkdir -p "$XSB_DIR"/{bin,cert,conf,inbounds,outbounds}
export PATH="$XSB_DIR/bin:$PATH"

# -------------------- 检测系统 --------------------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 root 用户运行${PLAIN}" && exit 1
fi

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${RED}无法识别系统${PLAIN}" && exit 1
fi

case $(uname -m) in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) echo -e "${RED}不支持的架构${PLAIN}" && exit 1 ;;
esac

# -------------------- 依赖安装 --------------------
install_deps() {
    echo -e "${GREEN}安装基础依赖...${PLAIN}"
    case $OS in
        debian|ubuntu)
            apt update -y
            apt install -y curl wget cron openssl iptables iptables-persistent jq iproute2 coreutils
            ;;
        centos|rhel|fedora)
            yum install -y epel-release
            yum install -y curl wget cronie openssl iptables iptables-services jq iproute2 coreutils
            ;;
        alpine)
            apk update
            apk add curl wget cronie openssl iptables iptables-openrc jq iproute2 coreutils
            ;;
        *)
            echo -e "${RED}不支持的系统${PLAIN}" && exit 1
    esac
}

init_cf_creds() {
    local cred_file="$XSB_DIR/conf/cf_creds"
    if [[ ! -f "$cred_file" ]]; then
        mkdir -p "$(dirname "$cred_file")"
        cat > "$cred_file" <<EOF
CF_API_KEY=
CF_EMAIL=
ZONE_ID=
DOMAIN=
EOF
        chmod 600 "$cred_file" 2>/dev/null
        echo -e "${YELLOW}已创建凭证模板文件: $cred_file${PLAIN}"
        echo -e "请根据需要编辑该文件，填写相应的信息"
    fi
}

cleanup_creds() {
    local cred_file="$XSB_DIR/conf/cf_creds"
    if [[ -f "$cred_file" ]]; then
        cat > "$cred_file" <<EOF
CF_API_KEY=
CF_EMAIL=
ZONE_ID=
DOMAIN=
EOF
        echo -e "${YELLOW}已清除 Cloudflare 凭证值${PLAIN}"
    fi
    unset CF_API_KEY CF_EMAIL ZONE_ID DOMAIN
}

ensure_cf_creds() {
    local cred_file="$XSB_DIR/conf/cf_creds"
    if [[ ! -f "$cred_file" ]]; then
        echo -e "${RED}凭证文件不存在${PLAIN}" >&2
        return 1
    fi

    set -a
    source "$cred_file"
    set +a

    if [[ -z "$CF_API_KEY" || -z "$CF_EMAIL" ]]; then
        echo -e "${RED}凭证不完整：请设置 CF_API_KEY 和 CF_EMAIL${PLAIN}" >&2
        return 1
    fi
    return 0
}

cf_api_request() {
    local method=$1
    local url=$2
    local data=$3
    headers=(-H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_API_KEY" -H "Content-Type: application/json")

    if [[ -n "$data" ]]; then
        curl -s --max-time 10 --retry 2 -X "$method" "$url" "${headers[@]}" --data "$data"
    else
        curl -s --max-time 10 --retry 2 -X "$method" "$url" "${headers[@]}"
    fi
}

# -------------------- Sing-box 安装/更新/卸载 --------------------
install_singbox() {
    if [[ -f "$XSB_DIR/bin/sing-box" ]]; then
        echo -e "${YELLOW}Sing-box 已安装，版本: $(sing-box version | head -1)${PLAIN}"
        return 0
    fi
    echo -e "${GREEN}下载并安装 Sing-box 到 $XSB_DIR/bin...${PLAIN}"
    LATEST=$(curl -s --max-time 5 https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | head -1 | awk -F '"' '{print $4}' | sed 's/v//')
    if [[ -z "$LATEST" ]]; then
        echo -e "${YELLOW}获取最新版本失败，使用默认 1.10.6${PLAIN}"
        LATEST="1.10.6"
    fi
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST}/sing-box-${LATEST}-linux-${ARCH}.tar.gz"
    wget -O /tmp/sing-box.tar.gz "$DOWNLOAD_URL" || { echo -e "${RED}下载失败${PLAIN}"; return 1; }
    tar -xzf /tmp/sing-box.tar.gz -C /tmp
    cp /tmp/sing-box-${LATEST}-linux-${ARCH}/sing-box "$XSB_DIR/bin/"
    rm -rf /tmp/sing-box*
    if ! command -v sing-box &>/dev/null; then
        echo -e "${RED}Sing-box 安装失败${PLAIN}" && exit 1
    fi
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
    fi
    rm -f "$XSB_DIR/bin/sing-box"
    echo -e "${GREEN}已卸载。配置文件保留在 $XSB_DIR/conf${PLAIN}"
}

manage_singbox() {
    echo -e "\n${YELLOW}--- Sing-box 管理 ---${PLAIN}"
    echo "1) 安装"
    echo "2) 更新"
    echo "3) 卸载"
    read -p "选择 [1-3]: " choice
    case $choice in
        1) install_singbox ;;
        2) update_singbox ;;
        3) uninstall_singbox ;;
        *) echo -e "${RED}无效选择${PLAIN}" ;;
    esac
}

# -------------------- 证书管理（多域名） --------------------
list_certs() {
    echo -e "${GREEN}已安装的证书:${PLAIN}"
    if [[ -d "$XSB_DIR/cert" ]]; then
        find "$XSB_DIR/cert" -maxdepth 1 -type d -not -path "$XSB_DIR/cert" | while read d; do
            domain=$(basename "$d")
            if [[ -f "$d/cert.crt" && -f "$d/private.key" ]]; then
                echo "  $domain"
            fi
        done
    else
        echo "  无"
    fi
}

add_cert() {
    echo -e "${YELLOW}添加新证书${PLAIN}"
    read -p "请输入域名: " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}域名不能为空${PLAIN}" && return 1
    fi
    if [[ -d "$XSB_DIR/cert/$DOMAIN" ]]; then
        echo -e "${YELLOW}该域名证书已存在${PLAIN}" && return 1
    fi
    mkdir -p "$XSB_DIR/cert/$DOMAIN"

    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        echo -e "${GREEN}安装 acme.sh 到 ~/.acme.sh...${PLAIN}"
        curl -s https://get.acme.sh | sh
    fi

    echo "选择验证方式: 1) HTTP-01  2) DNS-01 (Cloudflare)"
    read -p "输入 [1/2]: " acme_mode
    case $acme_mode in
        1)
            read -p "HTTP 验证端口（默认 80）: " WEB_PORT
            WEB_PORT=${WEB_PORT:-80}
            ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
            ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --httpport $WEB_PORT
            ;;
        2)
            ensure_cf_creds || return 1
            export CF_Key="$CF_API_KEY"
            export CF_Email="$CF_EMAIL"
            ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
            ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" -d "*.${DOMAIN}"
            ;;
        *)
            echo -e "${RED}无效选择${PLAIN}" && return 1
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
    read -p "请输入要删除的域名: " DOMAIN
    if [[ -d "$XSB_DIR/cert/$DOMAIN" ]]; then
        ~/.acme.sh/acme.sh --remove -d "$DOMAIN" 2>/dev/null
        rm -rf "$XSB_DIR/cert/$DOMAIN"
        echo -e "${GREEN}已删除 $DOMAIN 证书并清理 acme.sh 记录${PLAIN}"
    else
        echo -e "${RED}证书不存在${PLAIN}"
    fi
}

manage_certs() {
    echo -e "\n${YELLOW}--- 证书管理 ---${PLAIN}"
    echo "1) 列出证书"
    echo "2) 添加证书"
    echo "3) 删除证书"
    read -p "选择 [1-3]: " choice
    case $choice in
        1) list_certs ;;
        2) add_cert ;;
        3) delete_cert ;;
        *) echo -e "${RED}无效选择${PLAIN}" ;;
    esac
}

# -------------------- 保存本机 IP --------------------
save_ip() {
    IPV4=$(curl -s4 --max-time 3 ifconfig.me 2>/dev/null)
    IPV6=$(curl -s6 --max-time 3 ifconfig.me 2>/dev/null)
    echo "$IPV4" > "$XSB_DIR/conf/ipv4"
    echo "$IPV6" > "$XSB_DIR/conf/ipv6"
    export IPV4 IPV6
}

# -------------------- 入站管理 --------------------
check_singbox_installed() {
    if ! command -v sing-box &>/dev/null; then
        echo -e "${RED}请先安装 Sing-box${PLAIN}"
        return 1
    fi
    return 0
}

check_port_available() {
    local port=$1
    if ss -lntu | grep -q ":$port "; then
        return 1
    fi
    return 0
}

list_inbounds() {
    echo -e "${GREEN}当前入站:${PLAIN}"
    if [[ -d "$XSB_DIR/inbounds" ]]; then
        for f in "$XSB_DIR"/inbounds/inbound_*.json; do
            [[ -f "$f" ]] && echo "  $(basename "$f" .json | sed 's/inbound_//')"
        done
    else
        echo "  无"
    fi
}

add_inbound() {
    check_singbox_installed || return 1
    echo -e "${YELLOW}添加入站协议${PLAIN}"
    echo "1) VLESS+Reality"
    echo "2) AnyReality"
    echo "3) AnyTLS"
    echo "4) Hysteria2"
    echo "5) VMess+WS (with TLS)"
    read -p "选择 [1-5]: " proto
    case $proto in
        1|2|3|4|5) ;;
        *) echo -e "${RED}无效${PLAIN}" && return 1 ;;
    esac

    tag="inbound_$(date +%s)"
    read -p "请输入端口（留空随机）: " PORT
    if [[ -z "$PORT" ]]; then
        while true; do
            PORT=$(shuf -i 10000-65535 -n 1)
            check_port_available "$PORT" && break
        done
    elif [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}端口必须是数字${PLAIN}"
        return 1
    else
        if ! check_port_available "$PORT"; then
            echo -e "${YELLOW}端口 $PORT 不可用${PLAIN}"
            read -p "请重新输入（或按回车使用随机端口）: " new_port
            if [[ -n "$new_port" ]]; then
                if [[ ! "$new_port" =~ ^[0-9]+$ ]]; then
                    echo -e "${RED}端口必须是数字，将自动分配随机端口${PLAIN}"
                    PORT=$(shuf -i 10000-65535 -n 1)
                    while ! check_port_available "$PORT"; do
                        PORT=$(shuf -i 10000-65535 -n 1)
                    done
                elif check_port_available "$new_port"; then
                    PORT="$new_port"
                else
                    echo -e "${RED}仍不可用，将自动分配随机端口${PLAIN}"
                    PORT=$(shuf -i 10000-65535 -n 1)
                    while ! check_port_available "$PORT"; do
                        PORT=$(shuf -i 10000-65535 -n 1)
                    done
                fi
            else
                while true; do
                    PORT=$(shuf -i 10000-65535 -n 1)
                    check_port_available "$PORT" && break
                done
            fi
        fi
    fi

    if [[ -f "$XSB_DIR/conf/uuid" ]]; then
        UUID=$(cat "$XSB_DIR/conf/uuid")
    else
        UUID=$(sing-box generate uuid 2>/dev/null)
        echo "$UUID" > "$XSB_DIR/conf/uuid"
        chmod 600 "$XSB_DIR/conf/uuid"
    fi

    REALITY_SERVER_NAME=""
    PRIVATE_KEY=""
    PUBLIC_KEY=""
    SHORT_ID=""
    if [[ $proto -eq 1 || $proto -eq 2 ]]; then
        read -p "Reality 伪装域名（默认 www.apple.com）: " REALITY_SERVER_NAME
        REALITY_SERVER_NAME=${REALITY_SERVER_NAME:-www.apple.com}
        KEYPAIR=$(sing-box generate reality-keypair)
        PRIVATE_KEY=$(echo "$KEYPAIR" | awk '/PrivateKey/ {print $2}' | tr -d '"')
        PUBLIC_KEY=$(echo "$KEYPAIR" | awk '/PublicKey/ {print $2}' | tr -d '"')
        SHORT_ID=$(sing-box generate rand --hex 4)
        echo "$PRIVATE_KEY" > "$XSB_DIR/inbounds/inbound_${tag}_reality_private_key"
        echo "$PUBLIC_KEY" > "$XSB_DIR/inbounds/inbound_${tag}_reality_public_key"
        echo "$SHORT_ID" > "$XSB_DIR/inbounds/inbound_${tag}_reality_short_id"
        chmod 600 "$XSB_DIR/inbounds/inbound_${tag}_reality_private_key" \
                  "$XSB_DIR/inbounds/inbound_${tag}_reality_public_key" \
                  "$XSB_DIR/inbounds/inbound_${tag}_reality_short_id"
    fi

    CERT_DOMAIN=""
    if [[ $proto -eq 3 || $proto -eq 4 || $proto -eq 5 ]]; then
        list_certs
        read -p "请选择证书域名（输入域名）: " CERT_DOMAIN
        if [[ ! -d "$XSB_DIR/cert/$CERT_DOMAIN" ]]; then
            echo -e "${RED}证书不存在，请先添加证书${PLAIN}" && return 1
        fi
    fi

    case $proto in
        1) # VLESS+Reality
            jq -n \
                --arg type "vless" \
                --arg tag "$tag" \
                --arg listen "::" \
                --argjson port "$PORT" \
                --arg uuid "$UUID" \
                --arg sni "$REALITY_SERVER_NAME" \
                --arg privkey "$PRIVATE_KEY" \
                --arg shortid "$SHORT_ID" \
                '{
                    type: $type,
                    tag: $tag,
                    listen: $listen,
                    listen_port: $port,
                    users: [ { uuid: $uuid, flow: "xtls-rprx-vision" } ],
                    tls: {
                        enabled: true,
                        server_name: $sni,
                        reality: {
                            enabled: true,
                            handshake: { server: $sni, server_port: 443 },
                            private_key: $privkey,
                            short_id: [ $shortid ]
                        }
                    }
                }' > "$XSB_DIR/inbounds/inbound_${tag}.json"
            ;;
        2) # AnyTLS+Reality
            jq -n \
                --arg type "anytls" \
                --arg tag "$tag" \
                --arg listen "::" \
                --argjson port "$PORT" \
                --arg uuid "$UUID" \
                --arg sni "$REALITY_SERVER_NAME" \
                --arg privkey "$PRIVATE_KEY" \
                --arg shortid "$SHORT_ID" \
                '{
                    type: $type,
                    tag: $tag,
                    listen: $listen,
                    listen_port: $port,
                    users: [ { password: $uuid } ],
                    tls: {
                        enabled: true,
                        server_name: $sni,
                        reality: {
                            enabled: true,
                            handshake: { server: $sni, server_port: 443 },
                            private_key: $privkey,
                            short_id: [ $shortid ]
                        }
                    }
                }' > "$XSB_DIR/inbounds/inbound_${tag}.json"
            ;;
        3) # AnyTLS+TLS
            jq -n \
                --arg type "anytls" \
                --arg tag "$tag" \
                --arg listen "::" \
                --argjson port "$PORT" \
                --arg uuid "$UUID" \
                --arg domain "$CERT_DOMAIN" \
                --arg cert_path "$XSB_DIR/cert/$CERT_DOMAIN/cert.crt" \
                --arg key_path "$XSB_DIR/cert/$CERT_DOMAIN/private.key" \
                '{
                    type: $type,
                    tag: $tag,
                    listen: $listen,
                    listen_port: $port,
                    users: [ { password: $uuid } ],
                    tls: {
                        enabled: true,
                        server_name: $domain,
                        certificate_path: $cert_path,
                        key_path: $key_path
                    }
                }' > "$XSB_DIR/inbounds/inbound_${tag}.json"
            ;;
        4) # Hysteria2
            read -p "请输入起始端口（默认 60000）: " HOP_START
            HOP_START=${HOP_START:-60000}
            read -p "请输入结束端口（默认 65000）: " HOP_END
            HOP_END=${HOP_END:-65000}
            echo "${HOP_START}-${HOP_END}" > "$XSB_DIR/inbounds/inbound_${tag}.hop"
            chmod 600 "$XSB_DIR/inbounds/inbound_${tag}.hop"

            jq -n \
                --arg type "hysteria2" \
                --arg tag "$tag" \
                --arg listen "::" \
                --argjson port "$PORT" \
                --arg uuid "$UUID" \
                --arg domain "$CERT_DOMAIN" \
                --arg cert_path "$XSB_DIR/cert/$CERT_DOMAIN/cert.crt" \
                --arg key_path "$XSB_DIR/cert/$CERT_DOMAIN/private.key" \
                '{
                    type: $type,
                    tag: $tag,
                    listen: $listen,
                    listen_port: $port,
                    users: [ { password: $uuid } ],
                    ignore_client_bandwidth: false,
                    tls: {
                        enabled: true,
                        server_name: $domain,
                        certificate_path: $cert_path,
                        key_path: $key_path
                    }
                }' > "$XSB_DIR/inbounds/inbound_${tag}.json"

            install_brutal
            setup_hy2_hop "$PORT" "$HOP_START" "$HOP_END" "$tag"
            ;;
        5) # VMess+WSS
            WS_PATH="/vm-${UUID}"
            jq -n \
                --arg type "vmess" \
                --arg tag "$tag" \
                --arg listen "::" \
                --argjson port "$PORT" \
                --arg uuid "$UUID" \
                --arg domain "$CERT_DOMAIN" \
                --arg path "$WS_PATH" \
                --arg cert_path "$XSB_DIR/cert/$CERT_DOMAIN/cert.crt" \
                --arg key_path "$XSB_DIR/cert/$CERT_DOMAIN/private.key" \
                '{
                    type: $type,
                    tag: $tag,
                    listen: $listen,
                    listen_port: $port,
                    users: [ { uuid: $uuid, alterId: 0 } ],
                    transport: {
                        type: "ws",
                        path: $path,
                        headers: { Host: $domain }
                    },
                    tls: {
                        enabled: true,
                        server_name: $domain,
                        certificate_path: $cert_path,
                        key_path: $key_path
                    }
                }' > "$XSB_DIR/inbounds/inbound_${tag}.json"
            ;;
    esac
    echo -e "${GREEN}入站 $tag 添加成功 (端口 $PORT)${PLAIN}"
}

delete_inbound() {
    list_inbounds
    read -p "请输入要删除的入站标签: " tag
    if [[ -f "$XSB_DIR/inbounds/inbound_${tag}.json" ]]; then
        rm -f "$XSB_DIR/inbounds/inbound_${tag}.json"
        if [[ -f "$XSB_DIR/inbounds/inbound_${tag}.hop" ]]; then
            rm -f "$XSB_DIR/inbounds/inbound_${tag}.hop"
            cleanup_hy2_hop "$tag"
        fi
        rm -f "$XSB_DIR/inbounds/inbound_${tag}_reality_private_key" \
              "$XSB_DIR/inbounds/inbound_${tag}_reality_public_key" \
              "$XSB_DIR/inbounds/inbound_${tag}_reality_short_id"
        echo -e "${GREEN}已删除${PLAIN}"
    else
        echo -e "${RED}不存在${PLAIN}"
    fi
}

manage_inbounds() {
    echo -e "\n${YELLOW}--- 入站管理 ---${PLAIN}"
    echo "1) 列出入站"
    echo "2) 添加入站"
    echo "3) 删除入站"
    read -p "选择 [1-3]: " choice
    case $choice in
        1) list_inbounds ;;
        2) add_inbound ;;
        3) delete_inbound ;;
        *) echo -e "${RED}无效${PLAIN}" ;;
    esac
}

install_brutal() {
    if lsmod | grep -q brutal; then
        echo -e "${GREEN}Brutal 已加载${PLAIN}" && return 0
    fi
    echo -e "${GREEN}安装 tcp-brutal...${PLAIN}"
    bash <(curl -fsSL https://github.com/apernet/tcp-brutal/blob/master/scripts/install_dkms.sh)
}

setup_hy2_hop() {
    local hy2_port=$1
    local hop_start=$2
    local hop_end=$3
    local tag=$4
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
        echo -e "${YELLOW}netfilter-persistent 保存失败，尝试其他方式${PLAIN}"
    fi

    if ! command -v iptables-save >/dev/null 2>&1; then
        echo -e "${YELLOW}未找到 iptables-save，跳过规则持久化${PLAIN}"
        return 1
    fi

    local save_dir=""
    local v4_file=""
    local v6_file=""

    if [[ -d /etc/iptables ]]; then
        save_dir="/etc/iptables"
        v4_file="$save_dir/rules.v4"
        v6_file="$save_dir/rules.v6"
    elif [[ -d /etc/sysconfig ]]; then
        save_dir="/etc/sysconfig"
        v4_file="$save_dir/iptables"
        v6_file="$save_dir/ip6tables"
    elif [[ -d /etc/local.d ]]; then
        cat > /etc/local.d/iptables-restore.start <<EOF
#!/bin/sh
iptables-restore < /etc/iptables/rules.v4 2>/dev/null
ip6tables-restore < /etc/iptables/rules.v6 2>/dev/null
EOF
        chmod +x /etc/local.d/iptables-restore.start
        rc-update add local default 2>/dev/null
        save_dir="/etc/iptables"
        v4_file="$save_dir/rules.v4"
        v6_file="$save_dir/rules.v6"
        mkdir -p "$save_dir"
    else
        echo -e "${RED}规则持久化失败，无法确定保存目录${PLAIN}"
        return 1
    fi

    local save_ok=true
    if ! iptables-save > "$v4_file" 2>/dev/null; then
        echo -e "${YELLOW}保存规则到 $v4_file 失败${PLAIN}"
        save_ok=false
    fi
    if ! ip6tables-save > "$v6_file" 2>/dev/null; then
        echo -e "${YELLOW}保存规则到 $v6_file 失败${PLAIN}"
        save_ok=false
    fi

    if $save_ok; then
        echo -e "${GREEN}iptables 规则已持久化到 $save_dir${PLAIN}"
        return 0
    else
        return 1
    fi
}

# -------------------- 出站管理 --------------------
list_outbounds() {
    echo -e "${GREEN}当前出站:${PLAIN}"
    if [[ -d "$XSB_DIR/outbounds" ]]; then
        for f in "$XSB_DIR"/outbounds/outbound_*.json "$XSB_DIR"/outbounds/endpoint_*.json; do
            [[ -f "$f" ]] && echo "  $(basename "$f" .json | sed 's/^outbound_//;s/^endpoint_//')"
        done
    else
        echo "  无"
    fi
}

add_outbound() {
    echo -e "${YELLOW}添加出站${PLAIN}"
    echo "1) SOCKS5"
    echo "2) WARP (WireGuard)"
    read -p "选择 [1-2]: " choice
    tag="outbound_$(date +%s)"
    case $choice in
        1) # SOCKS5
            read -p "服务器地址（默认 127.0.0.1）: " server
            server=${server:-127.0.0.1}
            read -p "端口（默认 1080）: " port
            port=${port:-1080}
            read -p "用户名（可选）: " user
            read -p "密码（可选）: " pass
            jq -n \
                --arg type "socks" \
                --arg tag "$tag" \
                --arg server "$server" \
                --argjson port "$port" \
                --arg user "$user" \
                --arg pass "$pass" \
                '{
                    type: $type,
                    tag: $tag,
                    server: $server,
                    server_port: $port,
                    username: $user,
                    password: $pass
                }' > "$XSB_DIR/outbounds/outbound_${tag}.json"
            add_route_rule "$tag" '{"ip_cidr":["0.0.0.0/0","::/0"]}'
            ;;
        2) # WARP
            echo -e "${GREEN}获取 WARP 配置...${PLAIN}"
            WARP_DATA=$(curl -s --max-time 5 https://warp.xijp.eu.org)
            if [[ -z "$WARP_DATA" ]]; then
                WARP_PRIVATE_KEY="52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A="
                WARP_IPV6="2606:4700:110:8d8d:1845:c39f:2dd5:a03a"
                WARP_RESERVED="[215, 69, 233]"
            else
                WARP_PRIVATE_KEY=$(echo "$WARP_DATA" | grep Private_key | awk -F'：' '{print $2}' | xargs)
                WARP_IPV6=$(echo "$WARP_DATA" | grep IPV6 | awk -F'：' '{print $2}' | xargs)
                WARP_RESERVED=$(echo "$WARP_DATA" | grep reserved | awk -F'：' '{print $2}' | xargs)
            fi
            if curl -s4 --max-time 3 ifconfig.me >/dev/null 2>&1; then
                WARP_PEER_ADDR="162.159.192.1"
            else
                WARP_PEER_ADDR="[2606:4700:d0::a29f:c001]"
            fi

            jq -n \
                --arg type "wireguard" \
                --arg tag "$tag" \
                --arg addr_v4 "172.16.0.2/32" \
                --arg addr_v6 "$WARP_IPV6/128" \
                --arg privkey "$WARP_PRIVATE_KEY" \
                --arg peer_addr "$WARP_PEER_ADDR" \
                --argjson reserved "$WARP_RESERVED" \
                '{
                    type: $type,
                    tag: $tag,
                    address: [ $addr_v4, $addr_v6 ],
                    private_key: $privkey,
                    peers: [
                        {
                            address: $peer_addr,
                            port: 2408,
                            public_key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                            allowed_ips: ["0.0.0.0/0", "::/0"],
                            reserved: $reserved
                        }
                    ]
                }' > "$XSB_DIR/outbounds/endpoint_${tag}.json"

            add_route_rule "$tag" '{"domain_keyword":["google","gmail","youtube","gstatic","ytimg"]}'
            ;;
        *)
            echo -e "${RED}无效${PLAIN}" && return 1
    esac
    echo -e "${GREEN}出站 $tag 添加成功，并已添加路由规则${PLAIN}"
}

delete_outbound() {
    list_outbounds
    read -p "请输入要删除的出站标签: " tag
    if [[ -f "$XSB_DIR/outbounds/outbound_${tag}.json" ]] || [[ -f "$XSB_DIR/outbounds/endpoint_${tag}.json" ]]; then
        rm -f "$XSB_DIR/outbounds/outbound_${tag}.json" "$XSB_DIR/outbounds/endpoint_${tag}.json"
        rm -f "$XSB_DIR/conf/routes/route_${tag}.json"
        echo -e "${GREEN}已删除${PLAIN}"
    else
        echo -e "${RED}不存在${PLAIN}"
    fi
}

manage_outbounds() {
    echo -e "\n${YELLOW}--- 出站管理 ---${PLAIN}"
    echo "1) 列出出站"
    echo "2) 添加出站"
    echo "3) 删除出站"
    read -p "选择 [1-3]: " choice
    case $choice in
        1) list_outbounds ;;
        2) add_outbound ;;
        3) delete_outbound ;;
        *) echo -e "${RED}无效${PLAIN}" ;;
    esac
}

add_route_rule() {
    local outbound_tag=$1
    local match_spec=$2

    mkdir -p "$XSB_DIR/conf/routes"

    jq -n \
        --arg outbound "$outbound_tag" \
        --argjson spec "$match_spec" \
        '$spec + { outbound: $outbound }' \
        > "$XSB_DIR/conf/routes/route_${outbound_tag}.json"
}

cf_delete_record() {
    local domain=$1
    local zone_id=$2
    local resp=$(cf_api_request "GET" "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?name=$domain")
    echo "$resp" | jq -r --arg domain "$domain" '.result[] | select(.type=="A" or .type=="AAAA" or .type=="CNAME") | select(.name==$domain) | .id' | while read -r rec_id; do
        if [[ -n "$rec_id" ]]; then
            cf_api_request "DELETE" "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$rec_id" > /dev/null
            echo "已删除记录: $rec_id"
        fi
    done
}

cf_add_record() {
    local domain=$1
    local type=$2
    local content=$3
    local zone_id=$4
    local proxied="${5:-true}"
    local data=$(jq -n --arg type "$type" --arg name "$domain" --arg content "$content" --argjson proxied "$proxied" \
        '{type: $type, name: $name, content: $content, ttl: 120, proxied: $proxied}')
    cf_api_request "POST" "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" "$data" > /dev/null
    echo "已添加 $type 记录: $domain -> $content"
}

cf_dns() {
    echo -e "${YELLOW}配置 Cloudflare DNS 记录 (A/AAAA) 指向本机 IP${PLAIN}"
    ensure_cf_creds || return 1
    if [[ -z "$ZONE_ID" || -z "$DOMAIN" ]]; then
        echo -e "${RED}需要 ZONE_ID 和 DOMAIN，请在 $XSB_DIR/conf/cf_creds 中填写${PLAIN}"
        return 1
    fi

    save_ip
    ipv4=$(cat "$XSB_DIR/conf/ipv4" 2>/dev/null)
    ipv6=$(cat "$XSB_DIR/conf/ipv6" 2>/dev/null)

    echo -e "${GREEN}当前 IP: IPv4=${ipv4:-无}, IPv6=${ipv6:-无}${PLAIN}"
    read -p "是否清除现有 A/AAAA 记录并添加新记录？ [Y/n]: " confirm
    [[ "$confirm" =~ [Nn] ]] && return 0

    cf_delete_record "$DOMAIN" "$ZONE_ID"

    if [[ -n "$ipv4" ]]; then
        cf_add_record "$DOMAIN" "A" "$ipv4" "$ZONE_ID" "true"
    fi
    if [[ -n "$ipv6" ]]; then
        cf_add_record "$DOMAIN" "AAAA" "$ipv6" "$ZONE_ID" "true"
    fi
    echo -e "${GREEN}DNS 记录更新完成${PLAIN}"
}

select_vmess_inbound() {
    local domain="$1"
    local tags=() ports=() paths=()
    if [[ -d "$XSB_DIR/inbounds" ]]; then
        for f in "$XSB_DIR"/inbounds/inbound_*.json; do
            [[ -f "$f" ]] || continue
            if jq -e '.type == "vmess"' "$f" >/dev/null 2>&1; then
                host=$(jq -r '.transport.headers.Host' "$f")
                if [[ "$host" == "$domain" ]]; then
                    tag=$(basename "$f" .json | sed 's/inbound_//')
                    port=$(jq -r '.listen_port' "$f")
                    path=$(jq -r '.transport.path' "$f")
                    tags+=("$tag")
                    ports+=("$port")
                    paths+=("$path")
                fi
            fi
        done
    fi
    local count=${#tags[@]}
    if [[ $count -eq 0 ]]; then
        echo -e "${RED}未找到 Host 为 $domain 的 VMess 入站${PLAIN}" >&2
        return 1
    elif [[ $count -eq 1 ]]; then
        echo "${tags[0]}|${ports[0]}|${paths[0]}"
        return 0
    else
        echo -e "${YELLOW}找到多个 Host 为 $domain 的 VMess 入站：${PLAIN}" >&2
        for i in "${!tags[@]}"; do
            echo "  $((i+1))) tag=${tags[$i]}, 端口=${ports[$i]}, 路径=${paths[$i]}" >&2
        done
        echo -n "请选择 (输入序号): " >&2
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            local idx=$((choice-1))
            echo "${tags[$idx]}|${ports[$idx]}|${paths[$idx]}"
            return 0
        else
            echo -e "${RED}无效选择${PLAIN}" >&2
            return 1
        fi
    fi
}

cf_origin_rule() {
    echo -e "${YELLOW}配置 Origin Rule${PLAIN}"
    
    ensure_cf_creds || return 1
    if [[ -z "$ZONE_ID" || -z "$DOMAIN" ]]; then
        echo -e "${RED}Origin Rule 需要 ZONE_ID 和 DOMAIN，请在 $XSB_DIR/conf/cf_creds 中填写${PLAIN}"
        return 1
    fi

    local vmess_info
    vmess_info=$(select_vmess_inbound "$DOMAIN") || return 1
    IFS='|' read -r vmess_tag PORT WS_PATH <<< "$vmess_info"

    echo -e "${GREEN}清除现有 DNS 记录...${PLAIN}"
    cf_delete_record "$DOMAIN" "$ZONE_ID"

    save_ip
    ipv4=$(cat "$XSB_DIR/conf/ipv4" 2>/dev/null)
    ipv6=$(cat "$XSB_DIR/conf/ipv6" 2>/dev/null)
    if [[ -n "$ipv4" ]]; then
        cf_add_record "$DOMAIN" "A" "$ipv4" "$ZONE_ID" "true" 
    fi
    if [[ -n "$ipv6" ]]; then
        cf_add_record "$DOMAIN" "AAAA" "$ipv6" "$ZONE_ID" "true"
    fi
    echo -e "${GREEN}DNS 记录已更新（A/AAAA）${PLAIN}"

    RULE_DATA=$(cat <<EOF
{
  "targets": [
    { "target": "hostname", "value": "$DOMAIN" },
    { "target": "path", "value": "$WS_PATH" }
  ],
  "actions": [
    { "target": "port", "value": $PORT }
  ]
}
EOF
)
    RESP=$(cf_api_request "POST" "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rules/origin_rules" "$RULE_DATA")
    if echo "$RESP" | jq -e '.success == true' >/dev/null; then
        echo -e "${GREEN}Origin Rule 已配置 (路径 $WS_PATH -> 端口 $PORT)${PLAIN}"
    else
        echo -e "${RED}Origin Rule 配置失败: $(echo "$RESP" | jq -r '.errors[0].message')${PLAIN}"
    fi
}

cf_argo() {
    echo -e "${YELLOW}配置 Cloudflare Argo 固定隧道${PLAIN}"

    if [[ ! -f "$XSB_DIR/bin/cloudflared" ]]; then
        echo -e "${GREEN}下载 cloudflared...${PLAIN}"
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH"
        wget -O "$XSB_DIR/bin/cloudflared" "$url" || { echo -e "${RED}下载失败${PLAIN}"; return 1; }
        chmod +x "$XSB_DIR/bin/cloudflared"
    fi

    local cred_file="$XSB_DIR/conf/cf_creds"
    local DOMAIN=""
    if [[ -f "$cred_file" ]]; then
        set -a
        source "$cred_file"
        set +a
    fi

    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}请在 $cred_file 中设置 DOMAIN${PLAIN}"
        return 1
    fi

    local vmess_info
    vmess_info=$(select_vmess_inbound "$DOMAIN") || return 1
    IFS='|' read -r vmess_tag PORT WS_PATH <<< "$vmess_info"

    echo -e "${GREEN}在 Cloudflare 中创建一条隧道，并添加路由 $DOMAIN$WS_PATH 指向 https://localhost:$PORT${PLAIN}"

    read -p "请输入隧道 Token：" token_input
    if [[ -z "$token_input" ]]; then
        echo -e "${RED}Token 不能为空${PLAIN}"
        return 1
    fi

    local token_file="$XSB_DIR/conf/argo_token"
    echo "$token_input" > "$token_file"
    chmod 600 "$token_file"
    echo -e "${GREEN}Token 已保存至 $token_file${PLAIN}"

    if [[ "$OS" == "alpine" ]]; then
        cat > /etc/init.d/argo-tunnel <<EOF
#!/sbin/openrc-run
command="$XSB_DIR/bin/cloudflared"
command_args="tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token-file $token_file"
command_user="root"
pidfile="/run/argo-tunnel.pid"
name="Cloudflare Argo Tunnel"
description="Cloudflare Argo Tunnel ($DOMAIN)"

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/argo-tunnel
        rc-update add argo-tunnel default 2>/dev/null
        rc-service argo-tunnel restart
    else
        SERVICE_FILE="/etc/systemd/system/argo-tunnel.service"
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Argo Tunnel ($DOMAIN)
After=network.target

[Service]
Type=simple
ExecStart=$XSB_DIR/bin/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token-file $token_file
Restart=on-failure
RestartSec=10s
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable argo-tunnel 2>/dev/null
        systemctl restart argo-tunnel
    fi

    echo -e "${GREEN}Argo 隧道服务已启动，域名: $DOMAIN${PLAIN}"
    echo -e "查看状态: $([[ "$OS" == "alpine" ]] && echo "rc-service argo-tunnel status" || echo "systemctl status argo-tunnel")"
}

manage_cf() {
    echo -e "\n${YELLOW}--- Cloudflare 配置 ---${PLAIN}"
    echo "1) 配置 Origin Rule"
    echo "2) 配置 Argo 隧道"
    echo "3) 配置 DNS 记录"
    read -p "选择 [1-3]: " choice
    case $choice in
        1) cf_origin_rule ;;
        2) cf_argo ;;
        3) cf_dns ;;
        *) echo -e "${RED}无效${PLAIN}" ;;
    esac
}

# -------------------- TCP 智能调优 --------------------
tcp_tune() {
    echo -e "${YELLOW}开始 TCP 智能调优${PLAIN}"
    if [[ ! -f "$XSB_DIR/bin/speedtest" ]]; then
        echo -e "${GREEN}安装 Speedtest...${PLAIN}"
        wget -O /tmp/speedtest.tgz "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${ARCH}.tgz" || { echo -e "${RED}下载失败${PLAIN}"; return 1; }
        tar -xzf /tmp/speedtest.tgz -C /tmp
        mv /tmp/speedtest "$XSB_DIR/bin/"
        chmod +x "$XSB_DIR/bin/speedtest"
        rm -f /tmp/speedtest.tgz
    fi
    read -p "服务器 ID（默认 1536 香港）: " SERVER_ID
    SERVER_ID=${SERVER_ID:-1536}
    echo -e "${GREEN}测速中...${PLAIN}"
    LANG=C speedtest_output=$("$XSB_DIR/bin/speedtest" --accept-license --accept-gdpr --server-id="$SERVER_ID" 2>&1)
    echo -e "${GREEN}本次测速结果：${PLAIN}"
    echo "$speedtest_output"
    UPLOAD=$(echo "$speedtest_output" | awk -F': ' '/Upload:/ {print $2}' | awk '{print $1}')
    if [[ -z "$UPLOAD" ]]; then
        read -p "请手动输入带宽 (Mbit/s): " UPLOAD
        [ -z "$UPLOAD" ] && UPLOAD=100
    fi
    UPLOAD_INT=$(echo "$UPLOAD" | awk '{printf("%.0f", $1)}')
    BUFFER_MB=$(( (UPLOAD_INT / 8 + 3) / 4 * 4 ))
    BUFFER_BYTES=$((BUFFER_MB * 1024 * 1024))
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-tcp.conf <<EOF
# xsb 调优
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

# -------------------- 构建配置并启动服务 --------------------
build_and_start() {
    echo -e "${GREEN}构建完整配置...${PLAIN}"

    inbounds_files=("$XSB_DIR"/inbounds/inbound_*.json)
    if [[ ${#inbounds_files[@]} -eq 0 || ! -f "${inbounds_files[0]}" ]]; then
        inbounds_json="[]"
    else
        inbounds_json=$(jq -s '.' "${inbounds_files[@]}" 2>/dev/null)
        if [[ -z "$inbounds_json" ]]; then
            echo -e "${RED}入站 JSON 合并失败${PLAIN}"
            return 1
        fi
    fi

    outbounds_files=("$XSB_DIR"/outbounds/outbound_*.json)
    if [[ ${#outbounds_files[@]} -eq 0 || ! -f "${outbounds_files[0]}" ]]; then
        outbounds_json='[]'
    else
        outbounds_json=$(jq -s '.' "${outbounds_files[@]}" 2>/dev/null)
        if [[ -z "$outbounds_json" ]]; then
            echo -e "${RED}出站 JSON 合并失败${PLAIN}"
            return 1
        fi
    fi

    endpoints_files=("$XSB_DIR"/outbounds/endpoint_*.json)
    if [[ ${#endpoints_files[@]} -eq 0 || ! -f "${endpoints_files[0]}" ]]; then
        endpoints_json='[]'
    else
        endpoints_json=$(jq -s '.' "${endpoints_files[@]}" 2>/dev/null)
        if [[ -z "$endpoints_json" ]]; then
            echo -e "${RED}端点 JSON 合并失败${PLAIN}"
            return 1
        fi
    fi

    routes_files=("$XSB_DIR"/conf/routes/route_*.json)
    rules_json='[]'
    if [[ ${#routes_files[@]} -gt 0 && -f "${routes_files[0]}" ]]; then
        rules_json=$(jq -s '.' "${routes_files[@]}" 2>/dev/null)
        if [[ -z "$rules_json" ]]; then
            echo -e "${RED}路由规则 JSON 合并失败${PLAIN}"
            return 1
        fi
    fi

    # 预设规则（sniff, resolve）
    preset_rules='[
        { "action": "sniff" },
        { "action": "resolve", "strategy": "prefer_ipv4" }
    ]'
    # 合并路由规则
    all_rules=$(jq -n --argjson preset "$preset_rules" --argjson user "$rules_json" '$preset + $user')

    # 合并出站规则
    if [[ "$outbounds_json" == "[]" ]]; then
        outbounds_json='[ { "type": "direct", "tag": "direct" } ]'
    else
        outbounds_json=$(jq -n --argjson out "$outbounds_json" '$out + [ { "type": "direct", "tag": "direct" } ]')
    fi

    # 生成最终配置
    jq -n \
        --argjson inbounds "$inbounds_json" \
        --argjson outbounds "$outbounds_json" \
        --argjson endpoints "$endpoints_json" \
        --argjson rules "$all_rules" \
        '{
            log: { level: "info" },
            inbounds: $inbounds,
            outbounds: $outbounds,
            endpoints: $endpoints,
            route: {
                rules: $rules,
                final: "direct"
            }
        }' > "$XSB_DIR/conf/config.json"

    echo -e "${GREEN}配置文件生成: $XSB_DIR/conf/config.json${PLAIN}"

    if ! "$XSB_DIR/bin/sing-box" check -c "$XSB_DIR/conf/config.json" >/dev/null 2>&1; then
        echo -e "${RED}配置文件存在问题。${PLAIN}"
        "$XSB_DIR/bin/sing-box" check -c "$XSB_DIR/conf/config.json"  # 显示详细错误
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

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default 2>/dev/null
        rc-service sing-box restart
        sleep 2
        if rc-service sing-box status | grep -q "started"; then
            echo -e "${GREEN}Sing-box 已成功启动${PLAIN}"
        else
            echo -e "${RED}Sing-box 启动失败，请检查日志${PLAIN}"
            return 1
        fi
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

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box 2>/dev/null
        systemctl restart sing-box
        sleep 2
        if systemctl is-active --quiet sing-box; then
            echo -e "${GREEN}Sing-box 已成功启动${PLAIN}"
        else
            echo -e "${RED}Sing-box 启动失败，请检查日志${PLAIN}"
            return 1
        fi
    fi
    echo -e "${GREEN}Sing-box 已启动${PLAIN}"
}

# -------------------- 显示节点信息 --------------------
show_info() {
    local ipv4=$(cat "$XSB_DIR/conf/ipv4" 2>/dev/null)
    local ipv6=$(cat "$XSB_DIR/conf/ipv6" 2>/dev/null)
    echo "=================================================="
    echo -e "${GREEN}节点 IP 信息:${PLAIN}"
    echo "  IPv4: ${ipv4:-无}"
    echo "  IPv6: ${ipv6:-无}"
    echo "--------------------------------------------------"
    UUID=$(cat "$XSB_DIR/conf/uuid" 2>/dev/null || echo "未设置")
    echo "UUID: $UUID"
    for f in "$XSB_DIR"/inbounds/inbound_*.json; do
        [[ ! -f "$f" ]] && continue
        tag=$(basename "$f" .json | sed 's/inbound_//')
        type=$(jq -r '.type' "$f")
        port=$(jq -r '.listen_port' "$f")
        case $type in
            vless)
                sni=$(jq -r '.tls.server_name' "$f")
                sid=$(jq -r '.tls.reality.short_id[0]' "$f")
                pub_key_file="$XSB_DIR/inbounds/inbound_${tag}_reality_public_key"
                if [[ -f "$pub_key_file" ]]; then
                    PUBLIC_KEY=$(cat "$pub_key_file")
                else
                    PUBLIC_KEY=""
                fi
                if [[ -n "$ipv4" ]]; then
                    echo "vless://$UUID@$ipv4:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$PUBLIC_KEY&sid=$sid&type=tcp"
                fi
                if [[ -n "$ipv6" ]]; then
                    echo "vless://$UUID@[$ipv6]:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$PUBLIC_KEY&sid=$sid&type=tcp"
                fi
                ;;
            anytls)
                sni=$(jq -r '.tls.server_name' "$f")
                if jq -e '.tls.reality' "$f" >/dev/null 2>&1; then
                    sid=$(jq -r '.tls.reality.short_id[0]' "$f")
                    pub_key_file="$XSB_DIR/inbounds/inbound_${tag}_reality_public_key"
                    if [[ -f "$pub_key_file" ]]; then
                        PUBLIC_KEY=$(cat "$pub_key_file")
                    else
                        PUBLIC_KEY=""
                    fi
                    if [[ -n "$ipv4" ]]; then
                        echo "anytls://$UUID@$ipv4:$port?security=reality&sni=$sni&fp=chrome&pbk=$PUBLIC_KEY&sid=$sid&type=tcp"
                    fi
                    if [[ -n "$ipv6" ]]; then
                        echo "anytls://$UUID@[$ipv6]:$port?security=reality&sni=$sni&fp=chrome&pbk=$PUBLIC_KEY&sid=$sid&type=tcp"
                    fi
                else
                    if [[ -n "$ipv4" ]]; then
                        echo "anytls://$UUID@$ipv4:$port?security=tls&sni=$sni&insecure=0&type=tcp"
                    fi
                    if [[ -n "$ipv6" ]]; then
                        echo "anytls://$UUID@[$ipv6]:$port?security=tls&sni=$sni&insecure=0&type=tcp"
                    fi
                fi
                ;;
            hysteria2)
                sni=$(jq -r '.tls.server_name' "$f")
                hop_file="$XSB_DIR/inbounds/inbound_${tag}.hop"
                if [[ -f "$hop_file" ]]; then
                    hop_range=$(cat "$hop_file")
                fi
                if [[ -n "$ipv4" ]]; then
                    echo "hysteria2://$UUID@$ipv4:$port?sni=$sni&insecure=0&mport=$hop_range"
                fi
                if [[ -n "$ipv6" ]]; then
                    echo "hysteria2://$UUID@[$ipv6]:$port?sni=$sni&insecure=0&mport=$hop_range"
                fi
                ;;
            vmess)
                host=$(jq -r '.transport.headers.Host' "$f")
                path=$(jq -r '.transport.path' "$f")
                if [[ -n "$ipv4" ]]; then
                    vmess_json="{\"v\":\"2\",\"ps\":\"$tag\",\"add\":\"$ipv4\",\"port\":\"$port\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"host\":\"$host\",\"path\":\"$path\",\"tls\":\"tls\"}"
                    echo "vmess://$(echo -n "$vmess_json" | openssl base64 -A 2>/dev/null)"
                fi
                if [[ -n "$ipv6" ]]; then
                    vmess_json="{\"v\":\"2\",\"ps\":\"$tag\",\"add\":\"[$ipv6]\",\"port\":\"$port\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"host\":\"$host\",\"path\":\"$path\",\"tls\":\"tls\"}"
                    echo "vmess://$(echo -n "$vmess_json" | openssl base64 -A 2>/dev/null)"
                fi
                ;;
        esac
    done
    echo "=================================================="
}

# -------------------- 主菜单 --------------------
main() {
    install_deps
    init_cf_creds
    save_ip
    while true; do
        echo -e "\n${YELLOW}========== 主菜单 ==========${PLAIN}"
        echo "1) 安装/更新/卸载 Sing-box"
        echo "2) 管理证书"
        echo "3) 管理入站"
        echo "4) 管理出站"
        echo "5) Cloudflare 配置 (Origin Rule / Argo / DNS)"
        echo "6) TCP 智能调优"
        echo "7) 构建配置并启动服务"
        echo "8) 显示节点信息"
        echo "0) 退出"
        read -p "请选择 [0-8]: " main_choice
        case $main_choice in
            1) manage_singbox ;;
            2) manage_certs ;;
            3) manage_inbounds ;;
            4) manage_outbounds ;;
            5) manage_cf ;;
            6) tcp_tune ;;
            7) build_and_start ;;
            8) show_info ;;
            0)
                read -p "是否清除 Cloudflare 凭证文件中的敏感信息？[y/N]: " clean
                if [[ "$clean" =~ [Yy] ]]; then
                    cleanup_creds
                fi
                exit 0
                ;;
            *) echo -e "${RED}无效选择${PLAIN}" ;;
        esac
    done
}

main "$@"