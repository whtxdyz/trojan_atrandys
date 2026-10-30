#!/bin/bash

blue(){
    echo -e "\033[34m\033[01m$1\033[0m"
}
green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}
red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}
version_lt(){
    test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" != "$1"; 
}
# 支持 systemd + apt/dnf/yum；不自动添加第三方系统软件源。
detect_system(){
    if command -v apt-get >/dev/null 2>&1; then
        release=debian
        systemPackage=apt-get
    elif command -v dnf >/dev/null 2>&1; then
        release=centos
        systemPackage=dnf
    elif command -v yum >/dev/null 2>&1; then
        release=centos
        systemPackage=yum
    else
        red "不支持此系统的包管理器"
        return 1
    fi
    command -v systemctl >/dev/null 2>&1 || return 1
    systempwd=/etc/systemd/system/
}
require_root(){
    if [ "$(id -u)" -ne 0 ] || [ "$HOME" != /root ]; then
        red "请先执行 sudo -i，再运行脚本"
        return 1
    fi
}
check_arch(){
    case "$(uname -m)" in
        x86_64|amd64) return 0 ;;
        *) red "此脚本使用上游amd64预编译程序，不支持当前架构：$(uname -m)。尚未修改系统。"; return 1 ;;
    esac
}
fetch_file(){
    curl -fL --retry 2 --connect-timeout 15 --max-time 300 "$1" -o "$2" || return 1
    [ -s "$2" ]
}
get_release(){
    local metadata
    metadata=$(curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 https://api.github.com/repos/trojan-gfw/trojan/releases/latest) || return 1
    latest_version=$(printf '%s' "$metadata" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])') || return 1
    [[ "$latest_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    latest_version=${latest_version#v}
}
backup_existing(){
    backup_dir=$(mktemp -d /root/trojan-backup-XXXXXXXX) || return 1
    chmod 700 "$backup_dir" || return 1
    [ ! -d /etc/nginx ] || cp -a /etc/nginx "$backup_dir/nginx" || return 1
    [ ! -d /usr/src/trojan-cert ] || cp -a /usr/src/trojan-cert "$backup_dir/cert" || return 1
    green "配置备份：$backup_dir"
}
configure_firewall(){
    if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status | grep -q '^Status: active'; then
        ufw allow 80/tcp || return 1
        ufw allow "${trojan_port}/tcp" || return 1
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=80/tcp || return 1
        firewall-cmd --permanent --add-port="${trojan_port}/tcp" || return 1
        firewall-cmd --reload || return 1
    fi
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != Disabled ]; then
        red "检测到SELinux启用。请先由管理员配置对应策略；脚本不会关闭SELinux或随意改系统端口标签。"
        return 1
    fi
}
# 证书申请、续期与部署：复用 Nginx 的80端口，保留现有Trojan端口和密码。
setup_certificate(){
    local cert_mode="${1:-install}"
    local acme_status
    local -a issue_options=()
    if [ "$(id -u)" -ne 0 ]; then
        red "请先执行 sudo -i，再运行本脚本"
        return 1
    fi
    if [[ ! "$your_domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || [[ "$your_domain" != *.* ]]; then
        red "域名格式不正确，只填写域名，不带协议、端口或路径"
        return 1
    fi
    mkdir -p /usr/src/trojan-cert /usr/src/trojan-temp
    mkdir -p /usr/share/nginx/html/.well-known/acme-challenge
    nginx -t || return 1
    systemctl enable nginx || return 1
    systemctl restart nginx || return 1

    # 确保每日续期任务有实际运行的 cron 服务。
    if ! command -v crontab >/dev/null 2>&1; then
        if [ "$release" = "centos" ]; then
            "$systemPackage" -y install cronie || return 1
        else
            apt-get -y install cron || return 1
        fi
    fi
    if [ "$release" = "centos" ]; then
        systemctl enable --now crond || return 1
    else
        systemctl enable --now cron || return 1
    fi

    if [ ! -x /root/.acme.sh/acme.sh ]; then
        local installer
        installer=$(mktemp) || return 1
        if ! curl -fsS https://get.acme.sh -o "$installer"; then
            rm -f "$installer"
            return 1
        fi
        sh "$installer"
        acme_status=$?
        rm -f "$installer"
        [ "$acme_status" -eq 0 ] || return 1
    fi
    [ -x /root/.acme.sh/acme.sh ] || return 1
    /root/.acme.sh/acme.sh --install-cronjob || return 1

    if [ "$cert_mode" = "repair" ]; then
        cp -a /usr/src/trojan-cert "/root/trojan-cert-backup-$(date +%Y%m%d-%H%M%S)" || return 1
        issue_options+=(--force)
    fi
    /root/.acme.sh/acme.sh --issue \
        -d "$your_domain" \
        --webroot /usr/share/nginx/html \
        --keylength ec-256 \
        --server zerossl "${issue_options[@]}"
    acme_status=$?
    if [ "$acme_status" -ne 0 ] && [ "$acme_status" -ne 2 ]; then
        red "证书申请失败：请检查域名解析、公网80端口和上方错误"
        return 1
    fi

    /root/.acme.sh/acme.sh --install-cert \
        -d "$your_domain" --ecc \
        --key-file /usr/src/trojan-cert/private.key \
        --fullchain-file /usr/src/trojan-cert/fullchain.cer \
        --reloadcmd 'if systemctl cat trojan.service >/dev/null 2>&1; then systemctl restart trojan; fi' \
        || return 1
    chmod 600 /usr/src/trojan-cert/private.key || return 1
    openssl x509 -in /usr/src/trojan-cert/fullchain.cer -noout -subject -dates
}

function install_trojan_files(){
    local workdir
    workdir=$(mktemp -d /root/trojan-install-XXXXXXXX) || return 1
    chmod 700 "$workdir" || return 1
    green "安装工作目录：$workdir（失败时保留，便于排查）"
    get_release || { red "读取上游版本失败"; return 1; }
    fetch_file "https://github.com/trojan-gfw/trojan/releases/download/v${latest_version}/trojan-${latest_version}-linux-amd64.tar.xz" "$workdir/server.tar.xz" || return 1
    tar -xJf "$workdir/server.tar.xz" -C "$workdir" || return 1
    [ -x "$workdir/trojan/trojan" ] || return 1
    "$workdir/trojan/trojan" -v || { red "程序无法运行，可能缺少运行库"; return 1; }
    fetch_file "https://github.com/trojan-gfw/trojan/releases/download/v${latest_version}/trojan-${latest_version}-win.zip" "$workdir/windows.zip" || return 1
    mkdir -p "$workdir/windows" "$workdir/client" || return 1
    unzip -q "$workdir/windows.zip" -d "$workdir/windows" || return 1
    local windows_exe
    windows_exe=$(find "$workdir/windows" -type f -name trojan.exe -print -quit)
    [ -n "$windows_exe" ] || { red "下载包缺少trojan.exe"; return 1; }
    cp "$windows_exe" "$workdir/client/trojan.exe" || return 1

    backup_existing || return 1
    mkdir -p /etc/nginx/conf.d /usr/share/nginx/html/.well-known/acme-challenge || return 1
    if [ -e /etc/nginx/conf.d/trojan-script.conf ]; then
        red "已存在脚本站点配置，请先检查备份并手动处理，避免覆盖"
        return 1
    fi
    # 仅新增站点，不覆盖nginx.conf，不清空已有网页。
    cat > /etc/nginx/conf.d/trojan-script.conf <<EOF || return 1
server {
    listen 80;
    server_name $your_domain;
    root /usr/share/nginx/html;
    index index.html;
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
}
EOF
    if ! nginx -t; then
        rm -f /etc/nginx/conf.d/trojan-script.conf
        red "新增站点配置验证失败，已移除新增文件"
        return 1
    fi
    nginx -T 2>&1 | grep -Fq 'configuration file /etc/nginx/conf.d/trojan-script.conf:' || {
        rm -f /etc/nginx/conf.d/trojan-script.conf
        red "现有Nginx没有加载conf.d站点目录，已移除新增文件，请先配置include"
        return 1
    }
    if [ ! -e /usr/share/nginx/html/index.html ]; then
        printf '%s\n' '<!doctype html><html><head><meta charset="utf-8"><title>Welcome</title></head><body><h1>Welcome</h1></body></html>' > /usr/share/nginx/html/index.html || return 1
    fi
    systemctl enable --now nginx || return 1
    systemctl reload nginx || return 1
    setup_certificate install || return 1
    mkdir -p /usr/src/trojan || return 1
    install -m 755 "$workdir/trojan/trojan" /usr/src/trojan/trojan || return 1
	cat > "$workdir/client/config.json" <<-EOF || return 1
{
    "run_type": "client",
    "local_addr": "127.0.0.1",
    "local_port": 1080,
    "remote_addr": "$your_domain",
    "remote_port": $trojan_port,
    "password": [
        "$trojan_passwd_json"
    ],
    "log_level": 1,
    "ssl": {
        "verify": true,
        "verify_hostname": true,
        "cert": "fullchain.cer",
        "cipher_tls13":"TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384",
	"sni": "",
        "alpn": [
            "h2",
            "http/1.1"
        ],
        "reuse_session": true,
        "session_ticket": false,
        "curves": ""
    },
    "tcp": {
        "no_delay": true,
        "keep_alive": true,
        "fast_open": false,
        "fast_open_qlen": 20
    }
}
EOF
	cat > /usr/src/trojan/server.conf <<-EOF || return 1
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": $trojan_port,
    "remote_addr": "127.0.0.1",
    "remote_port": 80,
    "password": [
        "$trojan_passwd_json"
    ],
    "log_level": 1,
    "ssl": {
        "cert": "/usr/src/trojan-cert/fullchain.cer",
        "key": "/usr/src/trojan-cert/private.key",
        "key_password": "",
        "cipher_tls13":"TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384",
	"prefer_server_cipher": true,
        "alpn": [
            "http/1.1"
        ],
        "reuse_session": true,
        "session_ticket": false,
        "session_timeout": 600,
        "plain_http_response": "",
        "curves": "",
        "dhparam": ""
    },
    "tcp": {
        "no_delay": true,
        "keep_alive": true,
        "fast_open": false,
        "fast_open_qlen": 20
    },
    "mysql": {
        "enabled": false,
        "server_addr": "127.0.0.1",
        "server_port": 3306,
        "database": "trojan",
        "username": "trojan",
        "password": ""
    }
}
EOF

    chmod 600 /usr/src/trojan/server.conf || return 1
    cp /usr/src/trojan-cert/fullchain.cer "$workdir/client/fullchain.cer" || return 1
    printf '@echo off\r\ncd /d "%%~dp0"\r\ntrojan.exe -c config.json\r\npause\r\n' > "$workdir/client/start.bat" || return 1
    # 含密码的客户端包仅保存在root目录，通过SFTP下载，不发布到网页。
    (cd "$workdir/client" && zip -q -r "$workdir/trojan-client.zip" .) || return 1
    install -m 600 "$workdir/trojan-client.zip" /root/trojan-client.zip || return 1
    cat > /etc/systemd/system/trojan.service <<'EOF' || return 1
[Unit]
Description=Trojan server
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/src/trojan/trojan -c /usr/src/trojan/server.conf
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || return 1
    systemctl enable trojan || return 1
    systemctl restart trojan || return 1
    sleep 2
    if ! systemctl is-active --quiet trojan || ! ss -lntp | grep -E ":${trojan_port}[[:space:]]" | grep -q trojan; then
        red "Trojan未正常运行；不会报告安装成功。请查看下方日志。"
        journalctl -u trojan -n 30 --no-pager
        return 1
    fi
    green "Trojan安装成功：$your_domain:$trojan_port"
    printf 'Trojan 密码：%s\n' "$trojan_passwd"
    green "请通过SFTP下载 /root/trojan-client.zip；内含配置、证书、Windows客户端和start.bat"
    green "下载后可删除服务器上的客户端包。使用证书文件的客户端在证书更换后需同步更新。"
    green "请在云平台安全规则中放行TCP 80和${trojan_port}"
    rm -rf -- "$workdir"
}
# 80端口保留用于证书验证；Trojan端口由安装时选择。
valid_trojan_port(){
    [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
    local port_number=$((10#$1))
    (( port_number >= 1 && port_number <= 65535 && port_number != 80 ))
}
# 将密码转义为 JSON 字符串内容，允许引号和反斜杠。
prepare_password_json(){
    local LC_ALL=C
    [[ -n "$trojan_passwd" && ! "$trojan_passwd" =~ [[:cntrl:]] ]] || return 1
    trojan_passwd_json=${trojan_passwd//\\/\\\\}
    trojan_passwd_json=${trojan_passwd_json//\"/\\\"}
}
choose_trojan_password(){
    local password_confirm
    while true; do
        IFS= read -r -s -p "请输入 Trojan 密码 [回车自动生成，输入不显示]：" trojan_passwd || return 1
        printf '\n'
        if [ -z "$trojan_passwd" ]; then
            trojan_passwd=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n') || return 1
            [ "${#trojan_passwd}" -eq 48 ] || return 1
            prepare_password_json || return 1
            green "已生成随机密码，安装成功后显示连接信息"
            return 0
        fi
        if ! prepare_password_json; then
            red "密码不能包含换行、制表符等控制字符，请重新输入"
            continue
        fi
        IFS= read -r -s -p "请再次输入密码：" password_confirm || return 1
        printf '\n'
        if [ "$trojan_passwd" != "$password_confirm" ]; then
            red "两次密码不一致，请重新输入"
            continue
        fi
        return 0
    done
}

choose_trojan_port(){
    local entered_port
    while true; do
        read -r -p "请输入 Trojan 连接端口 [默认443]：" entered_port || return 1
        entered_port=${entered_port:-443}
        if ! valid_trojan_port "$entered_port"; then
            red "请输入1至65535的整数；80端口保留给证书验证"
            continue
        fi
        trojan_port=$((10#$entered_port))
        if netstat -lnt | awk -v port="$trojan_port" '
            $1 ~ /^tcp/ { n=split($4,a,":"); if (a[n]==port) found=1 }
            END {exit !found}'; then
            red "TCP端口 $trojan_port 已被占用，请选择其他端口"
            continue
        fi
        green "Trojan连接端口：$trojan_port；证书验证端口：80"
        return 0
    done
}

function install_trojan(){
    require_root || return 1
    check_arch || return 1
    if [ -e /usr/src/trojan/server.conf ] || systemctl cat trojan.service >/dev/null 2>&1; then
        red "已检测到Trojan安装。请使用修复或升级功能；不会覆盖现有端口、密码。"
        return 1
    fi
    read -r -p "请输入已解析到本服务器的域名：" your_domain || return 1
    if [[ ! "$your_domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || [[ "$your_domain" != *.* ]]; then
        red "域名格式错误"
        return 1
    fi
    if [ "$release" = debian ]; then
        apt-get update || return 1
        apt-get -y install nginx curl unzip zip tar xz-utils openssl ca-certificates python3 cron net-tools iproute2 || return 1
    else
        "$systemPackage" -y install nginx curl unzip zip tar xz openssl ca-certificates python3 cronie net-tools iproute || return 1
    fi
    choose_trojan_port || return 1
    choose_trojan_password || return 1
    configure_firewall || return 1
    install_trojan_files
}

function repair_cert(){
    blue "请输入这台服务器绑定的域名（例如 623.ssccs.xyz）"
    read -r your_domain
    setup_certificate repair || return 1
    green "证书已部署，自动续期与服务重启已配置"
    green "如客户端使用单独保存的证书文件，请同步更新客户端证书"
}

function remove_trojan(){
    local answer domain
    require_root || return 1
    read -r -p "卸载将停止Trojan并删除它的程序和配置；备份、证书和Nginx保留。输入 DELETE 继续：" answer || return 1
    [ "$answer" = DELETE ] || return 0
    backup_existing || return 1
    [ ! -d /usr/src/trojan ] || cp -a /usr/src/trojan "$backup_dir/trojan" || return 1
    if [ -f /usr/src/trojan/server.conf ]; then
        domain=$(openssl x509 -in /usr/src/trojan-cert/fullchain.cer -noout -subject -nameopt RFC2253 2>/dev/null | sed -n 's/.*CN=\([^,]*\).*/\1/p')
        if [ -n "$domain" ] && [ -x /root/.acme.sh/acme.sh ]; then
            /root/.acme.sh/acme.sh --remove -d "$domain" --ecc || return 1
        fi
    fi
    systemctl stop trojan || return 1
    systemctl disable trojan || return 1
    rm -f /etc/systemd/system/trojan.service /lib/systemd/system/trojan.service /usr/lib/systemd/system/trojan.service || return 1
    systemctl daemon-reload || return 1
    rm -rf /usr/src/trojan
    green "Trojan已卸载。Nginx、网页、证书和备份均保留。"
}

function update_trojan(){
    local workdir was_active=0
    require_root || return 1
    check_arch || return 1
    command -v python3 >/dev/null 2>&1 || { red "请先安装python3"; return 1; }
    [ -x /usr/src/trojan/trojan ] || return 1
    get_release || return 1
    workdir=$(mktemp -d /root/trojan-update-XXXXXXXX) || return 1
    fetch_file "https://github.com/trojan-gfw/trojan/releases/download/v${latest_version}/trojan-${latest_version}-linux-amd64.tar.xz" "$workdir/server.tar.xz" || return 1
    tar -xJf "$workdir/server.tar.xz" -C "$workdir" || return 1
    [ -x "$workdir/trojan/trojan" ] || return 1
    "$workdir/trojan/trojan" -v || return 1
    cp -a /usr/src/trojan/trojan "$workdir/trojan.previous" || return 1
    systemctl is-active --quiet trojan && was_active=1
    systemctl stop trojan || return 1
    if ! install -m 755 "$workdir/trojan/trojan" /usr/src/trojan/trojan || ! systemctl start trojan; then
        cp -a "$workdir/trojan.previous" /usr/src/trojan/trojan
        [ "$was_active" -ne 1 ] || systemctl start trojan
        red "升级失败，已尝试恢复旧程序；备份：$workdir"
        return 1
    fi
    sleep 2
    if ! systemctl is-active --quiet trojan; then
        systemctl stop trojan
        cp -a "$workdir/trojan.previous" /usr/src/trojan/trojan || return 1
        [ "$was_active" -ne 1 ] || systemctl start trojan
        red "新版启动失败，已恢复旧程序；备份：$workdir"
        return 1
    fi
    green "程序已更新为 $latest_version；端口、密码和证书配置保留。旧程序备份：$workdir"
}

start_menu(){
    clear
    green " ======================================="
    green " 介绍：一键安装trojan      "
    green " 系统：使用systemd和apt/dnf/yum的Linux；预编译程序仅支持x86_64"
    green " 网站：www.atrandys.com              "
    green " Youtube：Randy's 堡垒                "
    blue " 声明："
    red " *请不要在任何生产环境使用此脚本"
    red " *请保持80端口供Nginx验证证书，Trojan端口可自定义"
    red " *已有安装请使用升级或修复功能，安装不会覆盖现有配置"
    green " ======================================="
    echo
    green " 1. 安装trojan"
    red " 2. 卸载trojan"
    green " 3. 升级trojan"
    green " 4. 修复证书"
    blue " 0. 退出脚本"
    echo
    read -p "请输入数字 :" num
    case "$num" in
    1)
    install_trojan
    ;;
    2)
    remove_trojan 
    ;;
    3)
    update_trojan 
    ;;
    4)
    repair_cert 
    ;;
    0)
    exit 1
    ;;
    *)
    clear
    red "请输入正确数字"
    sleep 1s
    start_menu
    ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    require_root && detect_system && start_menu
fi
