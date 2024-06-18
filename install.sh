#!/bin/bash

function generate_password() {
    local length=${1:-13}
    tr -dc A-Za-z0-9 </dev/urandom | head -c $length
    echo ''
}

if [ ! -f ".env" ]; then
    echo ".env file does not exist."
    exit
fi

source .env

export MAILU_HTTP_PORT=${MAILU_HTTP_PORT:-880}
export MAILU_HTTPS_PORT=${MAILU_HTTPS_PORT:-8443}

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
    export GCF_ED="$"
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
    echo_run "ln -fs /etc/letsencrypt/live/$DOMAIN/{fullchain.pem,privkey.pem} ."
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
    echo_run "ln -fs /etc/nginx/sites-available/$1.conf /etc/nginx/sites-enabled/"
}

# ACTIONS

server_initial_setup() {
    echo_run "ln -fs /usr/share/zoneinfo/Asia/Tehran /etc/localtime"
    echo_run "dpkg-reconfigure -f noninteractive tzdata"
    echo_run "apt update -y"
    echo_run "apt install -y apg tmux vim net-tools docker.io docker-compose-v2"
    echo_run "apt full-upgrade -y"
    echo_run "apt autoremove -y"
    echo_run "sleep 5"
    echo_run "reboot"
}

server_os_upgrade() {
    change_config Prompt normal /etc/update-manager/release-upgrades
    echo "Close script and run this command in terminal:"
    echo "do-release-upgrade"
}
install_ssl() {
    echo_run "apt install certbot python3-certbot-nginx -y"
    echo_run "certbot certonly -d $DOMAIN --email $CERTBOT_EMAIL --standalone --agree-tos --noninteractive"
}

install_nginx() {
    echo_run "apt install nginx python3-certbot-nginx -y"
    certbot_expand_nginx $DOMAIN
    echo_run "systemctl restart nginx"
}

_add_mailu_admin() {
    local username=$1
    local password=$2
    dcd mailu
    echo_run "docker-compose exec admin flask mailu admin $username $MAILU_DOMAIN $password"
}

install_mailu_nginx() {
    export MAILU_DOMAIN=mail.$DOMAIN
    echo -e "Add the following DNS record to $DOMAIN DNS settings:"
    echo -e "\tType: CNAME"
    echo -e "\tName: $(get_subdomains $MAILU_DOMAIN)"
    echo -e "\tValue: $DOMAIN"
    echo "Press enter to continue"
    echo_run "read"
    echo_run "gcfc mailu/nginx.conf > /etc/nginx/sites-available/mailu.conf"
    ln_nginx mailu
    certbot_expand_nginx $MAILU_DOMAIN
    echo "URL: https://$MAILU_DOMAIN"
}

install_mailu() {
    if ! command -v nginx &>/dev/null; then
        echo "nginx is not installed. Exiting..."
        exit
    fi

    export MAILU_DOMAIN
    MAILU_ADMIN_PASSWORD="$(generate_password)"
    MAILU_WEBSITE="https://$MAILU_DOMAIN"
    MAILU_SECRET_KEY=$(generate_password 16)
    MAILU_POSTMASTER=${MAILU_POSTMASTER:-"admin"}
    DOCKER_COMPOSE_ENVS=(
        MAILU_HOSTNAMES
        MAILU_DOMAIN
        MAILU_POSTMASTER
        MAILU_SECRET_KEY
        MAILU_WEBSITE
        MAILU_HTTP_PORT
        MAILU_HTTPS_PORT
    )

    dcd mailu
    gcfc mailu/docker-compose.yml >docker-compose.yml
    gcfc mailu/mailu.conf >mailu.conf
    cpc mailu/mailu.env

    for env in "${DOCKER_COMPOSE_ENVS[@]}"; do
        key="${env#MAILU_}"
        echo "$key=${!env}" >>mailu.env
    done

    echo_run "cp mailu.conf /etc/nginx/sites-available/mailu.conf"
    echo_run "ln_nginx mailu"
    echo_run "mkdir -p /mailu/certs"
    echo_run "ln_ssl "/mailu/certs" $MAILU_DOMAIN"
    echo_run "systemctl restart nginx"

    echo_run "docker-compose up -d"
    _add_mailu_admin "admin" $MAILU_ADMIN_PASSWORD
}

add_mailu_admin() {
    echo -n "Enter username: "
    read MAILU_ADMIN_USERNAME

    echo -n "Enter password: "
    stty -echo
    read MAILU_ADMIN_PASSWORD
    stty echo

    _add_mailu_admin $MAILU_ADMIN_USERNAME $MAILU_ADMIN_PASSWORD
}

ACTIONS=(
    server_initial_setup
    server_os_upgrade
    install_ssl
    install_nginx
    install_mailu
    add_mailu_admin
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
