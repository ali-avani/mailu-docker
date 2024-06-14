#!/bin/bash

function generate_password() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 13
    echo ''
}

# Varibales
export PUBLIC_IP=$(curl -s ifconfig.me)
export REMARK_PREFIX=$(echo $DOMAIN | cut -d '.' -f1)

# SCRIPT SETUP

export PROJECT_PATH="$(dirname $(realpath "$0"))"
cd "$PROJECT_PATH" || exit

export PROJECT_CONFIGS="$PROJECT_PATH/configs"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit
fi

# UTILITY FUNCTIONS

export TERMINAL_COLUMNS="$(stty -a 2>/dev/null | grep -Po '(?<=columns )\d+' || echo 0)"

print_separator() {
    for ((i = 0; i < "$TERMINAL_COLUMNS"; i++)); do
        printf $1
    done
}

echo_run() {
    line_count=$(wc -l <<<$1)
    echo -n ">$(if [ ! -z ${2+x} ]; then echo "($2)"; fi)_ $(sed -e '/^[[:space:]]*$/d' <<<$1 | head -1 | xargs)"
    if (($line_count > 1)); then
        echo -n "(command truncated....)"
    fi
    echo
    if [ -z ${2+x} ]; then
        eval $1
    else
        FUNCTIONS=$(declare -pf)
        echo "$FUNCTIONS; $1" | sudo --preserve-env -H -u $2 bash
    fi
    print_separator "+"
    echo -e "\n"
}

function gcf() {
    export GCF_ED='$'
    envsubst <$1
}

function gcfc() {
    gcf $PROJECT_CONFIGS/$1
}

function certbot_domains_fix() {
    echo -n $(certbot certificates --cert-name $DOMAIN 2>/dev/null | grep Domains | cut -d':' -f2 | xargs | tr -s '[:blank:]' ',')
}

function certbot_expand() {
    OLD_DOMAINS=$(certbot_domains_fix)
    echo_run "certbot certonly --cert-name $DOMAIN -d $OLD_DOMAINS,$@ --email $CERTBOT_EMAIL --expand --standalone --agree-tos --noninteractive"
}

function certbot_expand_nginx() {
    OLD_DOMAINS=$(certbot_domains_fix)
    echo_run "certbot --nginx --cert-name $DOMAIN -d $OLD_DOMAINS,$@ --email $CERTBOT_EMAIL --expand --agree-tos --noninteractive"
}

function ln_ssl() {
    echo_run "ln -s /etc/letsencrypt/live/$DOMAIN/{fullchain.pem,privkey.pem} ."
}

function dcd() {
    mkdir -p ~/docker/$1/
    cd ~/docker/$1/
}

function cpc() {
    echo "Config $1 copied."
    cp $PROJECT_CONFIGS/$1 .
}

function change_config() {
    echo -n "Changing $1 to $2 in $3... "
    sed -i "s/$1=.*/$1=$2/" $3 && echo "Done" || echo "Failed"
}

function get_subdomains() {
    echo -n $1 | awk -F. '{NF-=2} $1=$1' | tr -s '[:blank:]' '.'
}

function ln_nginx() {
    echo_run "ln -s /etc/nginx/sites-available/$1.conf /etc/nginx/sites-enabled/"
}

# ACTIONS

server_initial_setup() {
    echo_run "ln -fs /usr/share/zoneinfo/Asia/Tehran /etc/localtime"
    echo_run "dpkg-reconfigure -f noninteractive tzdata"
    echo_run "apt update -y"
    echo_run "apt install -y apg tmux vim net-tools docker.io docker-compose"
    echo_run "apt full-upgrade -y"
    echo_run "apt autoremove -y"
    echo_run "sleep 5"
    echo_run "reboot"
}

function install_mailu {
    nginx_config=$(gcfc mailu/nginx.conf)
    docker_config=$(gcfc mailu/docker-compose.yml)
    dcd mailu
    cpc mailu/docker-compose.yml
    cpc mailu/mailu.env
    echo_run "docker-compose up -d"
}

ACTIONS=(
    server_initial_setup
    install_mailu
)

while true; do
    echo "Which action? $(if [ ! -z ${LAST_ACTION} ]; then echo "($LAST_ACTION)"; fi)"
    for i in "${!ACTIONS[@]}"; do
        echo -e "\t$((i + 1)). ${ACTIONS[$i]}"
    done
    read ACTION
    LAST_ACTION=$ACTION
    print_separator "-"
    $ACTION
    print_separator "-"
done
