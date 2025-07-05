#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# Add some basic function here
function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}

# check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${red}Fatal error: ${plain} Please run this script with root privilege \n "
    exit 1
fi

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "Failed to check the system OS, please contact the author!" >&2
    exit 1
fi
echo "The OS release is: $release"

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${green}Unsupported CPU architecture! ${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

echo "arch: $(arch)"

check_glibc_version() {
    glibc_version=$(ldd --version | head -n1 | awk '{print $NF}')
    required_version="2.32"
    if [[ "$(printf '%s\n' "$required_version" "$glibc_version" | sort -V | head -n1)" != "$required_version" ]]; then
        echo -e "${red}GLIBC version $glibc_version is too old! Required: 2.32 or higher${plain}"
        echo "Please upgrade to a newer version of your operating system to get a higher GLIBC version."
        exit 1
    fi
    echo "GLIBC version: $glibc_version (meets requirement of 2.32+)"
}
check_glibc_version

install_base() {
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update && apt-get install -y -q wget curl tar tzdata socat
            ;;
        centos | rhel | almalinux | rocky | ol)
            yum -y update && yum install -y -q wget curl tar tzdata socat
            ;;
        fedora | amzn)
            dnf -y update && dnf install -y -q wget curl tar tzdata socat
            ;;
        arch | manjaro | parch)
            pacman -Syu && pacman -Syu --noconfirm wget curl tar tzdata socat
            ;;
        opensuse-tumbleweed)
            zypper refresh && zypper -q install -y wget curl tar timezone socat
            ;;
        *)
            apt-get update && apt install -y -q wget curl tar tzdata socat
            ;;
    esac
}

gen_random_string() {
    local length="$1"
    local random_string=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1)
    echo "$random_string"
}

config_after_install() {
    local existing_hasDefaultCredential=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'hasDefaultCredential: .+' | awk '{print $2}')
    local existing_webBasePath=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local server_ip=$(hostname -I | awk '{print $1}')
    # check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        echo "acme.sh could not be found. we will install it"
        LOGI "Installing acme.sh..."
        cd ~ || return 1 # Ensure you can change to the home directory
        curl -s https://get.acme.sh | sh
        if [ $? -ne 0 ]; then
            LOGE "Installation of acme.sh failed."
            return 1
        else
            LOGI "Installation of acme.sh succeeded."
        fi
    fi

    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_webBasePath=$(gen_random_string 15)
            local config_username=$(gen_random_string 10)
            local config_password=$(gen_random_string 10)

            # get the domain here, and we need to verify it
            local domain=""
            read -p "Please enter your domain name (or press Enter to skip): " domain
            if [ -z "$domain" ]; then
                LOGI "No domain entered. Skipping domain and certificate setup."
            else
                LOGD "Your domain is: ${domain}, checking it..."

                # check if there already exists a certificate
                local currentCert=$(~/.acme.sh/acme.sh --list | tail -1 | awk '{print $1}')
                if [ "${currentCert}" == "${domain}" ]; then
                    LOGI "System already has certificates for this domain. trying to remove"
                    rm -rf ~/.acme.sh/${currentCert}*
                else
                    LOGI "Your domain is ready for issuing certificates now..."
                fi

                # create a directory for the certificate
                certPath="/root/cert/${domain}"
                if [ ! -d "$certPath" ]; then
                    mkdir -p "$certPath"
                else
                    rm -rf "$certPath"
                    mkdir -p "$certPath"
                fi

                # get the port number for the standalone server
                local WebPort=80
                read -p "Please choose which port to use (default is 80): " WebPort
                if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
                    LOGE "Your input ${WebPort} is invalid, will use default port 80."
                    WebPort=80
                fi
                LOGI "Will use port: ${WebPort} to issue certificates. Please make sure this port is open."

                # issue the certificate
                ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
                ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport ${WebPort}
                if [ $? -ne 0 ]; then
                    LOGE "Issuing certificate failed, please check logs."
                    rm -rf ~/.acme.sh/${domain}
                    exit 1
                else
                    LOGE "Issuing certificate succeeded, installing certificates..."
                fi

                # install the certificate
                ~/.acme.sh/acme.sh --installcert -d ${domain} \
                    --key-file /root/cert/${domain}/privkey.pem \
                    --fullchain-file /root/cert/${domain}/fullchain.pem

                if [ $? -ne 0 ]; then
                    LOGE "Installing certificate failed, exiting."
                    rm -rf ~/.acme.sh/${domain}
                    exit 1
                else
                    LOGI "Installing certificate succeeded, enabling auto renew..."
                fi

                # enable auto-renew
                ~/.acme.sh/acme.sh --upgrade --auto-upgrade
                if [ $? -ne 0 ]; then
                    LOGE "Auto renew failed, certificate details:"
                    ls -lah cert/*
                    chmod 755 $certPath/*
                    exit 1
                else
                    LOGI "Auto renew succeeded, certificate details:"
                    ls -lah cert/*
                    chmod 755 $certPath/*
                fi

                # Set panel paths after successful certificate installation
                local webCertFile="/root/cert/${domain}/fullchain.pem"
                local webKeyFile="/root/cert/${domain}/privkey.pem"

                if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
                    /usr/local/x-ui/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                    LOGI "Panel paths set for domain: $domain"
                    LOGI "  - Certificate File: $webCertFile"
                    LOGI "  - Private Key File: $webKeyFile"
                    echo -e "${green}Access URL: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
                    # restart service if needed
                else
                    LOGE "Error: Certificate or private key file not found for domain: $domain."
                fi

                read -p "Would you like to customize the Panel Port settings? (If not, a random port will be applied) [y/n]: " config_confirm
                local config_port
                if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
                    read -p "Please set up the panel port: " config_port
                    echo -e "${yellow}Your Panel Port is: ${config_port}${plain}"
                else
                    config_port=$(shuf -i 1024-62000 -n 1)
                    echo -e "${yellow}Generated random port: ${config_port}${plain}"
                fi

                /usr/local/x-ui/x-ui setting -username "${config_username}" -password "${config_password}" -port "${config_port}" -webBasePath "${config_webBasePath}"
                echo -e "This is a fresh installation, generating random login info for security concerns:"
                echo -e "###############################################"
                echo -e "${green}Username: ${config_username}${plain}"
                echo -e "${green}Password: ${config_password}${plain}"
                echo -e "${green}Port: ${config_port}${plain}"
                echo -e "${green}WebBasePath: ${config_webBasePath}${plain}"
                echo -e "${green}Access URL: https://${domain}:${config_port}/${config_webBasePath}${plain}"
                echo -e "###############################################"
            fi
        else
            local config_webBasePath=$(gen_random_string 15)
            echo -e "${yellow}WebBasePath is missing or too short. Generating a new one...${plain}"
            /usr/local/x-ui/x-ui setting -webBasePath "${config_webBasePath}"
            echo -e "${green}New WebBasePath: ${config_webBasePath}${plain}"
            echo -e "${green}Access URL: https://${domain}:${existing_port}/${config_webBasePath}${plain}"
        fi
    else
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_username=$(gen_random_string 10)
            local config_password=$(gen_random_string 10)

            echo -e "${yellow}Default credentials detected. Security update required...${plain}"
            /usr/local/x-ui/x-ui setting -username "${config_username}" -password "${config_password}"
            echo -e "Generated new random login credentials:"
            echo -e "###############################################"
            echo -e "${green}Username: ${config_username}${plain}"
            echo -e "${green}Password: ${config_password}${plain}"
            echo -e "###############################################"
        else
            echo -e "${green}Username, Password, and WebBasePath are properly set. Exiting...${plain}"
        fi
    fi

    /usr/local/x-ui/x-ui migrate
}

install_x-ui() {
    cd /usr/local/

    if [ $# == 0 ]; then
        tag_version=$(curl -Ls "https://api.github.com/repos/syntakt/tx-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$tag_version" ]]; then
            echo -e "${red}Failed to fetch x-ui version, it may be due to GitHub API restrictions, please try it later${plain}"
            exit 1
        fi
        echo -e "Got x-ui latest version: ${tag_version}, beginning the installation..."
        wget -N --no-check-certificate -O /usr/local/x-ui-linux-$(arch).tar.gz https://github.com/syntakt/tx-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Downloading x-ui failed, please be sure that your server can access GitHub ${plain}"
            exit 1
        fi
    else
        tag_version=$1
        tag_version_numeric=${tag_version#v}
        min_version="0.1"

        if [[ "$(printf '%s\n' "$min_version" "$tag_version_numeric" | sort -V | head -n1)" != "$min_version" ]]; then
            echo -e "${red}Please use a newer version (at least v0.1). Exiting installation.${plain}"
            exit 1
        fi

        url="https://github.com/syntakt/tx-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz"
        echo -e "Beginning to install x-ui $1"
        wget -N --no-check-certificate -O /usr/local/x-ui-linux-$(arch).tar.gz ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Download x-ui $1 failed, please check if the version exists ${plain}"
            exit 1
        fi
    fi

    if [[ -e /usr/local/x-ui/ ]]; then
        systemctl stop x-ui
        rm /usr/local/x-ui/ -rf
    fi

    tar zxvf x-ui-linux-$(arch).tar.gz
    rm x-ui-linux-$(arch).tar.gz -f
    cd x-ui
    chmod +x x-ui

    # Check the system's architecture and rename the file accordingly
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv bin/xray-linux-$(arch) bin/xray-linux-arm
        chmod +x bin/xray-linux-arm
    fi

    if [[ -f bin/xray-linux-$(arch) ]]; then
        chmod +x bin/xray-linux-$(arch)
    fi

    cp -f x-ui.service /etc/systemd/system/
    wget --no-check-certificate -O /usr/bin/x-ui https://raw.githubusercontent.com/syntakt/tx-ui/main/x-ui.sh
    chmod +x /usr/local/x-ui/x-ui.sh
    chmod +x /usr/bin/x-ui
    config_after_install

    systemctl daemon-reload
    systemctl enable x-ui
    systemctl start x-ui

    echo -e "${green}x-ui ${tag_version}${plain} installation finished, it is running now...\n"

    echo -e "┌───────────────────────────────────────────────────────┐"
    echo -e "│  ${blue}x-ui control menu usages (subcommands):${plain}              │"
    echo -e "│                                                       │"
    echo -e "│  ${blue}x-ui${plain}              - Admin Management Script          │"
    echo -e "│  ${blue}x-ui start${plain}        - Start                            │"
    echo -e "│  ${blue}x-ui stop${plain}         - Stop                             │"
    echo -e "│  ${blue}x-ui restart${plain}      - Restart                          │"
    echo -e "│  ${blue}x-ui status${plain}       - Current Status                   │"
    echo -e "│  ${blue}x-ui settings${plain}     - Current Settings                 │"
    echo -e "│  ${blue}x-ui enable${plain}       - Enable Autostart on OS Startup   │"
    echo -e "│  ${blue}x-ui disable${plain}      - Disable Autostart on OS Startup  │"
    echo -e "│  ${blue}x-ui log${plain}          - Check logs                       │"
    echo -e "│  ${blue}x-ui banlog${plain}       - Check Fail2ban ban logs          │"
    echo -e "│  ${blue}x-ui update${plain}       - Update                           │"
    echo -e "│  ${blue}x-ui legacy${plain}       - Legacy version                   │"
    echo -e "│  ${blue}x-ui install${plain}      - Install                          │"
    echo -e "│  ${blue}x-ui uninstall${plain}    - Uninstall                        │"
    echo -e "└───────────────────────────────────────────────────────┘"
}

echo -e "${green}Running...${plain}"
install_base
install_x-ui $1
