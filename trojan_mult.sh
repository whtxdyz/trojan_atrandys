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
#copy from 秋水逸冰 ss scripts
if [[ -f /etc/redhat-release ]]; then
    release="centos"
    systemPackage="yum"
    systempwd="/usr/lib/systemd/system/"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
    systemPackage="apt-get"
    systempwd="/lib/systemd/system/"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
    systemPackage="apt-get"
    systempwd="/lib/systemd/system/"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
    systemPackage="yum"
    systempwd="/usr/lib/systemd/system/"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
    systemPackage="apt-get"
    systempwd="/lib/systemd/system/"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
    systemPackage="apt-get"
    systempwd="/lib/systemd/system/"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
    systemPackage="yum"
    systempwd="/usr/lib/systemd/system/"
fi
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
            yum -y install cronie || return 1
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
    openssl x509 -in /usr/src/trojan-cert/fullchain.cer -noout -subject -dates
}

function install(){
cat > /etc/nginx/nginx.conf <<-EOF
user  root;
worker_processes  1;
error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;
events {
    worker_connections  1024;
}
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;
    sendfile        on;
    #tcp_nopush     on;
    keepalive_timeout  120;
    client_max_body_size 20m;
    #gzip  on;
    server {
        listen       80;
        server_name  $your_domain;
        root /usr/share/nginx/html;
        index index.php index.html index.htm;
    }
}
EOF
	#设置伪装站
	rm -rf /usr/share/nginx/html/*
	cd /usr/share/nginx/html/
	wget https://github.com/atrandys/v2ray-ws-tls/raw/master/web.zip >/dev/null 2>&1
    	unzip web.zip >/dev/null 2>&1
	setup_certificate install || return 1
	if test -s /usr/src/trojan-cert/fullchain.cer; then
	systemctl start nginx
        cd /usr/src
	#wget https://github.com/trojan-gfw/trojan/releases/download/v1.13.0/trojan-1.13.0-linux-amd64.tar.xz
	wget https://api.github.com/repos/trojan-gfw/trojan/releases/latest >/dev/null 2>&1
	latest_version=`grep tag_name latest| awk -F '[:,"v]' '{print $6}'`
	rm -f latest
	wget https://github.com/trojan-gfw/trojan/releases/download/v${latest_version}/trojan-${latest_version}-linux-amd64.tar.xz >/dev/null 2>&1
	tar xf trojan-${latest_version}-linux-amd64.tar.xz >/dev/null 2>&1
	#下载trojan客户端
	wget https://github.com/atrandys/trojan/raw/master/trojan-cli.zip >/dev/null 2>&1
	wget -P /usr/src/trojan-temp https://github.com/trojan-gfw/trojan/releases/download/v${latest_version}/trojan-${latest_version}-win.zip >/dev/null 2>&1
	unzip trojan-cli.zip >/dev/null 2>&1
	unzip /usr/src/trojan-temp/trojan-${latest_version}-win.zip -d /usr/src/trojan-temp/ >/dev/null 2>&1
	cp /usr/src/trojan-cert/fullchain.cer /usr/src/trojan-cli/fullchain.cer
	mv -f /usr/src/trojan-temp/trojan/trojan.exe /usr/src/trojan-cli/ 
	cat > /usr/src/trojan-cli/config.json <<-EOF
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
	rm -rf /usr/src/trojan/server.conf
	cat > /usr/src/trojan/server.conf <<-EOF
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
	cd /usr/src/trojan-cli/
	zip -q -r trojan-cli.zip /usr/src/trojan-cli/
	trojan_path=$(cat /dev/urandom | head -1 | md5sum | head -c 16)
	mkdir /usr/share/nginx/html/${trojan_path}
	mv /usr/src/trojan-cli/trojan-cli.zip /usr/share/nginx/html/${trojan_path}/
	#增加启动脚本
	
cat > ${systempwd}trojan.service <<-EOF
[Unit]  
Description=trojan  
After=network.target  
   
[Service]  
Type=simple  
PIDFile=/usr/src/trojan/trojan/trojan.pid
ExecStart=/usr/src/trojan/trojan -c "/usr/src/trojan/server.conf"  
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=1s
   
[Install]  
WantedBy=multi-user.target
EOF

	chmod +x ${systempwd}trojan.service
	systemctl daemon-reload || return 1
	systemctl start trojan.service
	systemctl enable trojan.service
	green "======================================================================"
	green "Trojan已安装完成，连接端口：${trojan_port}"
	printf 'Trojan 密码：%s\n' "$trojan_passwd"
	green "请在云平台安全规则中放行TCP ${trojan_port}和80端口"
	green "请使用以下链接下载trojan客户端，此客户端已配置好所有参数"
	green "1、复制下面的链接，在浏览器打开，下载客户端，注意此下载链接将在1个小时后失效"
	blue "http://${your_domain}/$trojan_path/trojan-cli.zip"
	green "2、将下载的压缩包解压，打开文件夹，打开start.bat即打开并运行Trojan客户端"
	green "3、打开stop.bat即关闭Trojan客户端"
	green "4、Trojan客户端需要搭配浏览器插件使用，例如switchyomega等"
	green "======================================================================"
	else
        red "==================================="
	red "https证书没有申请成果，自动安装失败"
	green "不要担心，你可以手动修复证书申请"
	green "1. 重启VPS"
	green "2. 重新执行脚本，使用修复证书功能"
	red "==================================="
	fi
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
if [ "$(id -u)" -ne 0 ]; then
    red "请先执行 sudo -i，再运行本脚本"
    return 1
fi
$systemPackage -y install net-tools socat || return 1
choose_trojan_port || return 1
choose_trojan_password || return 1
nginx_status=`ps -aux | grep "nginx: worker" |grep -v "grep"`
if [ -n "$nginx_status" ]; then
    systemctl stop nginx
fi
Port80=`netstat -tlpn | awk -F '[: ]+' '$1=="tcp"{print $5}' | grep -w 80`
if [ -n "$Port80" ]; then
    process80=`netstat -tlpn | awk -F '[: ]+' '$5=="80"{print $9}'`
    red "==========================================================="
    red "检测到80端口被占用，占用进程为：${process80}，本次安装结束"
    red "==========================================================="
    exit 1
fi
CHECK=$(grep SELINUX= /etc/selinux/config | grep -v "#")
if [ "$CHECK" != "SELINUX=disabled" ]; then
    green "检测到SELinux开启状态，添加放行80和${trojan_port}端口规则"
    yum install -y policycoreutils-python >/dev/null 2>&1
    semanage port -m -t http_port_t -p tcp 80
    semanage port -a -t http_port_t -p tcp "$trojan_port" 2>/dev/null || semanage port -m -t http_port_t -p tcp "$trojan_port"
fi
if [ "$release" == "centos" ]; then
    if  [ -n "$(grep ' 6\.' /etc/redhat-release)" ] ;then
    red "==============="
    red "当前系统不受支持"
    red "==============="
    exit
    fi
    if  [ -n "$(grep ' 5\.' /etc/redhat-release)" ] ;then
    red "==============="
    red "当前系统不受支持"
    red "==============="
    exit
    fi
    firewall_status=`firewall-cmd --state`
    if [ "$firewall_status" == "running" ]; then
        green "检测到firewalld开启状态，添加放行80和${trojan_port}端口规则"
	yum install -y policycoreutils-python >/dev/null 2>&1
        firewall-cmd --zone=public --add-port=80/tcp --permanent
	firewall-cmd --zone=public --add-port="${trojan_port}/tcp" --permanent
	firewall-cmd --reload
    fi
    rpm -Uvh http://nginx.org/packages/centos/7/noarch/RPMS/nginx-release-centos-7-0.el7.ngx.noarch.rpm
elif [ "$release" == "ubuntu" ]; then
    if  [ -n "$(grep ' 14\.' /etc/os-release)" ] ;then
    red "==============="
    red "当前系统不受支持"
    red "==============="
    exit
    fi
    if  [ -n "$(grep ' 12\.' /etc/os-release)" ] ;then
    red "==============="
    red "当前系统不受支持"
    red "==============="
    exit
    fi
    ufw_status=`systemctl status ufw | grep "Active: active"`
    if [ -n "$ufw_status" ]; then
        ufw allow 80/tcp
        ufw allow "${trojan_port}/tcp"
    fi
    apt-get update
elif [ "$release" == "debian" ]; then
    ufw_status=`systemctl status ufw | grep "Active: active"`
    if [ -n "$ufw_status" ]; then
        ufw allow 80/tcp
        ufw allow "${trojan_port}/tcp"
    fi
    apt-get update
fi
$systemPackage -y install  nginx wget unzip zip curl tar >/dev/null 2>&1
systemctl enable nginx
systemctl stop nginx
green "======================="
blue "请输入绑定到本VPS的域名"
green "======================="
read your_domain
real_addr=`ping ${your_domain} -c 1 | sed '1{s/[^(]*(//;s/).*//;q}'`
local_addr=`curl ipv4.icanhazip.com`
if [ $real_addr == $local_addr ] ; then
	green "=========================================="
	green "       域名解析正常，开始安装trojan"
	green "=========================================="
	sleep 1s
        install
	
else
        red "===================================="
	red "域名解析地址与本VPS IP地址不一致"
	red "若你确认解析成功你可强制脚本继续运行"
	red "===================================="
	read -p "是否强制运行 ?请输入 [Y/n] :" yn
	[ -z "${yn}" ] && yn="y"
	if [[ $yn == [Yy] ]]; then
            green "强制继续运行脚本"
	    sleep 1s
	    install
	else
	    exit 1
	fi
fi
}

function repair_cert(){
    blue "请输入这台服务器绑定的域名（例如 623.ssccs.xyz）"
    read -r your_domain
    setup_certificate repair || return 1
    green "证书已部署，自动续期与服务重启已配置"
    green "如客户端使用单独保存的证书文件，请同步更新客户端证书"
}

function remove_trojan(){
    red "================================"
    red "即将卸载trojan"
    red "同时卸载安装的nginx"
    red "================================"
    systemctl stop trojan
    systemctl disable trojan
    rm -f ${systempwd}trojan.service
    if [ "$release" == "centos" ]; then
        yum remove -y nginx
    else
        apt autoremove -y nginx
    fi
    rm -rf /usr/src/trojan*
    rm -rf /usr/share/nginx/html/*
    green "=============="
    green "trojan删除完毕"
    green "=============="
}

function update_trojan(){
    /usr/src/trojan/trojan -v 2>trojan.tmp
    curr_version=`cat trojan.tmp | grep "trojan" | awk '{print $4}'`
    wget https://api.github.com/repos/trojan-gfw/trojan/releases/latest >/dev/null 2>&1
    latest_version=`grep tag_name latest| awk -F '[:,"v]' '{print $6}'`
    rm -f latest
    rm -f trojan.tmp
    if version_lt "$curr_version" "$latest_version"; then
        green "当前版本$curr_version,最新版本$latest_version,开始升级……"
        mkdir trojan_update_temp && cd trojan_update_temp
        wget https://github.com/trojan-gfw/trojan/releases/download/v${latest_version}/trojan-${latest_version}-linux-amd64.tar.xz >/dev/null 2>&1
        tar xf trojan-${latest_version}-linux-amd64.tar.xz >/dev/null 2>&1
        mv ./trojan/trojan /usr/src/trojan/
        cd .. && rm -rf trojan_update_temp
        systemctl restart trojan
	/usr/src/trojan/trojan -v 2>trojan.tmp
	green "trojan升级完成，当前版本：`cat trojan.tmp | grep "trojan" | awk '{print $4}'`"
	rm -f trojan.tmp
    else
        green "当前版本$curr_version,最新版本$latest_version,无需升级"
    fi
   
   
}

start_menu(){
    clear
    green " ======================================="
    green " 介绍：一键安装trojan      "
    green " 系统：centos7+/debian9+/ubuntu16.04+"
    green " 网站：www.atrandys.com              "
    green " Youtube：Randy's 堡垒                "
    blue " 声明："
    red " *请不要在任何生产环境使用此脚本"
    red " *请保持80端口供Nginx验证证书，Trojan端口可自定义"
    red " *若是第二次使用脚本，请先执行卸载trojan"
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

start_menu
