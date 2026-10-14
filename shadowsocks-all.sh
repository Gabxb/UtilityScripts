#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH
#
# Auto install Shadowsocks Server (libev and rust) with v2ray-plugin and xray-plugin
#
# Copyright (C) 2016-2026 Teddysun <i@teddysun.com>
#
# Optimized so that Debian 9/10/11/12/13 (stretch/buster/bullseye/bookworm/trixie)
# all work, including the two EOL releases whose repositories moved to
# archive.debian.org.
#
# Reference URL:
# https://github.com/shadowsocks/shadowsocks-libev
# https://github.com/shadowsocks/shadowsocks-rust
# https://github.com/teddysun/v2ray-plugin
# https://github.com/teddysun/xray-plugin
#
# Thanks:
# @madeye     <https://github.com/madeye>
# @zonyitoo   <https://github.com/zonyitoo>
#
# Intro:  https://teddysun.com/486.html
#
# ---------------------------------------------------------------------------
# Compatibility matrix (why this script differs from the upstream one)
#
#   Debian 9  (stretch)  EOL since 2022. deb.debian.org returns 404, packages
#                        live on archive.debian.org. The Teddysun repo has NO
#                        stretch suite, so libev is taken from
#                        stretch-backports (shadowsocks-libev 3.2.5, full AEAD)
#                        and rust / plugins are installed from GitHub releases.
#                        The plain stretch suite only has libev 2.6.3 which
#                        has no AEAD cipher at all, so backports is preferred.
#   Debian 10 (buster)   EOL since 2024. Same archive redirection. The
#                        Teddysun repo does have a buster suite, but the libev
#                        package there is 3.3.5-12, NOT 3.3.6-2 -> pinning a
#                        version (as the upstream script does) always fails.
#                        This script never pins the version and lets apt pick.
#   Debian 11 (bullseye) / 12 (bookworm) / 13 (trixie)
#                        Fully served by the Teddysun repo.
#
# Two systemd layouts exist and the script detects which one got installed:
#   Teddysun packages : shadowsocks-libev-server.service
#                       /etc/shadowsocks/shadowsocks-libev-config.json
#   Debian packages   : shadowsocks-libev.service
#                       /etc/shadowsocks-libev/config.json
#                       (path taken from $CONFFILE in /etc/default/shadowsocks-libev)
#
# Usage:
#   ./shadowsocks-all.sh [install|uninstall|check|help]
#   ./shadowsocks-all.sh install 2>&1 | tee shadowsocks-all.log
#
# Non-interactive install (useful for automation / cloud-init):
#   SS_PASSWORD=xxx SS_PORT=8388 SS_CIPHER=aes-256-gcm SS_PLUGIN=None \
#       ./shadowsocks-all.sh install
# ---------------------------------------------------------------------------

red='\e[0;31m'
green='\e[0;32m'
yellow='\e[0;33m'
plain='\e[0m'

cur_dir=$(pwd)
software=(Shadowsocks-libev Shadowsocks-rust)
plugins=(None v2ray-plugin xray-plugin)

# Stream ciphers understood by shadowsocks-libev >= 3.0 / shadowsocks-rust
common_ciphers=(
aes-256-gcm
aes-192-gcm
aes-128-gcm
chacha20-ietf-poly1305
xchacha20-ietf-poly1305
)

# Ciphers understood by shadowsocks-rust
rust_ciphers=(
aes-256-gcm
aes-192-gcm
aes-128-gcm
chacha20-ietf-poly1305
xchacha20-ietf-poly1305
2022-blake3-aes-256-gcm
2022-blake3-aes-128-gcm
2022-blake3-chacha20-poly1305
)

# Ciphers understood by shadowsocks-libev < 3.0 (no AEAD at all)
legacy_ciphers=(
aes-256-cfb
aes-192-cfb
aes-128-cfb
chacha20-ietf
)

shadowsocks_libev_config='/etc/shadowsocks/shadowsocks-libev-config.json'
shadowsocks_rust_config='/etc/shadowsocks/shadowsocks-rust-config.json'
debian_libev_config='/etc/shadowsocks-libev/config.json'

# Teddysun APT repository
teddysun_repo_base='https://dl.lamp.sh/shadowsocks'
teddysun_debian_repo="${teddysun_repo_base}/debian"
teddysun_ubuntu_repo="${teddysun_repo_base}/ubuntu"
debian_gpg_url="${teddysun_repo_base}/DEB-GPG-KEY-Teddysun"
debian_keyring='/usr/share/keyrings/deb-gpg-key-teddysun.gpg'

# RHEL repo URL
rhel_repo_url='https://dl.lamp.sh/shadowsocks/rhel/teddysun.repo'
rhel_repo_url_2='https://dl.lamp.sh/linux/rhel/teddysun_linux.repo'

# GitHub release fallback (used when the distro / repo has no package)
github_api='https://api.github.com/repos'
ss_rust_github_repo='shadowsocks/shadowsocks-rust'
ss_rust_fallback_version='1.25.0'
v2ray_plugin_github_repo='teddysun/v2ray-plugin'
xray_plugin_github_repo='teddysun/xray-plugin'

# Test hook: point the detection at another os-release file.
os_release_file="${OS_RELEASE_FILE:-/etc/os-release}"


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
log_info(){
    echo -e "[${green}Info${plain}] $*"
}

log_warn(){
    echo -e "[${yellow}Warning${plain}] $*"
}

log_error(){
    echo -e "[${red}Error${plain}] $*"
}

die(){
    log_error "$*"
    exit 1
}

# version_ge A B -> true when A >= B (A and B are dotted versions)
version_ge(){
    local a b
    a=$(printf '%s' "$1" | sed 's/[^0-9.].*$//')
    b=$(printf '%s' "$2" | sed 's/[^0-9.].*$//')
    [ -n "${a}" ] || return 1
    [ -n "${b}" ] || return 1
    [ "${a}" = "${b}" ] && return 0
    [ "$(printf '%s\n%s\n' "${b}" "${a}" | sort -V | head -n 1)" = "${b}" ]
}

has_command(){
    command -v "$1" > /dev/null 2>&1
}

is_apt(){
    [ "${PACKAGE_MANAGER}" = 'apt' ]
}

is_dnf(){
    [ "${PACKAGE_MANAGER}" = 'dnf' ]
}

# Random port in [9000,19999]; shuf comes from coreutils but keep a fallback.
random_port(){
    if has_command shuf; then
        shuf -i 9000-19999 -n 1
    else
        echo $((9000 + RANDOM % 11000))
    fi
}

# Print the HTTP status code of an URL, or return 1 when nothing can fetch it.
http_status(){
    local url="$1" code
    if has_command curl; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -L "${url}" 2> /dev/null)
        [ -n "${code}" ] || return 1
        printf '%s' "${code}"
    elif has_command wget; then
        if wget -q --spider --timeout=10 "${url}" 2> /dev/null; then
            printf '200'
        else
            printf '404'
        fi
    else
        return 1
    fi
}

# Download an URL to a file, using curl or wget.
download_file(){
    local url="$1" dest="$2"
    if has_command curl; then
        curl -fsSL --retry 3 --max-time 300 "${url}" -o "${dest}"
    elif has_command wget; then
        wget -q -O "${dest}" "${url}"
    else
        return 1
    fi
}

# Read a KEY=value entry from /etc/os-release (or $OS_RELEASE_FILE).
os_release_value(){
    [ -r "${os_release_file}" ] || return 1
    local value
    value=$(sed -n -E "s/^$1=//p" "${os_release_file}" 2> /dev/null | head -n 1)
    [ -n "${value}" ] || return 1
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    printf '%s' "${value}"
}

# ---------------------------------------------------------------------------
# System detection
#
# /etc/os-release exists on every systemd distribution, so it is the primary
# source.  /etc/issue is empty on many cloud images and lsb-release is not
# installed by default (and cannot be installed when APT itself is broken on
# an EOL release), so both are only used as fallbacks.
# ---------------------------------------------------------------------------
DISTRO_ID=''
DISTRO_VERSION_ID=''
DISTRO_CODENAME=''
DISTRO_PRETTY=''
PACKAGE_MANAGER=''

debian_codename_for_version(){
    case "$1" in
        7)  echo 'wheezy' ;;
        8)  echo 'jessie' ;;
        9)  echo 'stretch' ;;
        10) echo 'buster' ;;
        11) echo 'bullseye' ;;
        12) echo 'bookworm' ;;
        13) echo 'trixie' ;;
        14) echo 'forky' ;;
        *)  echo '' ;;
    esac
}

detect_distro(){
    local id version codename

    id=$(os_release_value ID 2> /dev/null | tr '[:upper:]' '[:lower:]')
    version=$(os_release_value VERSION_ID 2> /dev/null)
    codename=$(os_release_value VERSION_CODENAME 2> /dev/null)
    DISTRO_PRETTY=$(os_release_value PRETTY_NAME 2> /dev/null)

    if [ -z "${id}" ] && [ -f /etc/debian_version ]; then
        id='debian'
        [ -n "${version}" ] || version=$(cut -d. -f1 /etc/debian_version 2> /dev/null)
    fi
    if [ -z "${id}" ] && [ -f /etc/redhat-release ]; then
        id='centos'
        version=$(sed -n 's/.*release \([0-9][0-9.]*\).*/\1/p' /etc/redhat-release 2> /dev/null)
    fi
    if [ -z "${id}" ]; then
        if grep -Eqi 'debian|raspbian' /etc/issue 2> /dev/null || grep -Eqi 'debian|raspbian' /proc/version 2> /dev/null; then
            id='debian'
        elif grep -Eqi 'ubuntu' /etc/issue 2> /dev/null || grep -Eqi 'ubuntu' /proc/version 2> /dev/null; then
            id='ubuntu'
        elif grep -Eqi 'centos|red hat|redhat' /etc/issue 2> /dev/null || grep -Eqi 'centos|red hat|redhat' /proc/version 2> /dev/null; then
            id='centos'
        fi
    fi
    [ -n "${id}" ] || die 'Unable to detect the Linux distribution.'

    [ -n "${version}" ] || version=$(cut -d. -f1 /etc/debian_version 2> /dev/null)
    [ -n "${version}" ] || version='0'

    [ -n "${codename}" ] || codename=$(lsb_release -sc 2> /dev/null)
    if [ -z "${codename}" ] && [ "${id}" = 'debian' ]; then
        codename=$(debian_codename_for_version "${version}")
    fi

    DISTRO_ID="${id}"
    DISTRO_VERSION_ID="${version}"
    DISTRO_CODENAME="${codename}"

    if has_command apt-get; then
        PACKAGE_MANAGER='apt'
    elif has_command dnf; then
        PACKAGE_MANAGER='dnf'
    elif has_command yum; then
        PACKAGE_MANAGER='yum'
    else
        PACKAGE_MANAGER=''
    fi
}

# Kept for compatibility with the upstream script's calling convention.
check_sys(){
    local checkType="$1"
    local value="$2"
    case "${checkType}" in
        sysRelease)
            [ "${value}" = "${DISTRO_ID}" ]
            ;;
        packageManager)
            [ "${value}" = "${PACKAGE_MANAGER}" ]
            ;;
        *)
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# APT helpers
# ---------------------------------------------------------------------------
APT_OPTS=()
ARCHIVE_MODE=0
APT_SOURCELIST='/etc/apt/sources.list.d/shadowsocks-archive.list'
TEDDYSUN_SUITE_OK=0

apt_update(){
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" update -qq
}

apt_install(){
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" -y "$@"
}

apt_purge(){
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" -y purge "$@"
}

# deb.debian.org stops serving a release once it is EOL; those releases are
# only reachable through archive.debian.org.  Probe instead of hardcoding so
# future EOL releases keep working.
debian_release_is_archived(){
    local codename="$1" status
    [ -n "${codename}" ] || return 1
    case "${codename}" in
        wheezy|jessie|stretch|buster) return 0 ;;
    esac
    status=$(http_status "https://deb.debian.org/debian/dists/${codename}/Release") || return 1
    [ "${status}" = '404' ]
}

# Point APT at archive.debian.org and make every later apt-get call use that
# list exclusively, so the stale (404) system sources are never parsed.
#
# http:// is used on purpose: Debian 9's apt has no built-in https support and
# installing apt-transport-https + ca-certificates is exactly what we are
# trying to bootstrap.  [trusted=yes] is required because the archive Release
# files are expired; they are fetched over the network either way.
setup_archive_apt_sources(){
    local codename="$1"
    [ -n "${codename}" ] || return 1
    cat > "${APT_SOURCELIST}" <<EOF
# Generated by shadowsocks-all.sh
# Debian ${codename} is EOL, its packages only live on archive.debian.org.
# The original sources.list is left untouched.
deb [trusted=yes] http://archive.debian.org/debian ${codename} main
deb [trusted=yes] http://archive.debian.org/debian-security ${codename}/updates main
deb [trusted=yes] http://archive.debian.org/debian ${codename}-backports main
EOF
    ARCHIVE_MODE=1
    APT_OPTS=(
        -o "Dir::Etc::sourcelist=${APT_SOURCELIST}"
        -o "Dir::Etc::sourceparts=-"
        -o "APT::Get::List-Cleanup=0"
        -o "Acquire::Check-Valid-Until=false"
    )
    log_warn "Debian ${codename} is EOL: switching APT to archive.debian.org."
}

ensure_apt_works(){
    log_info 'Refreshing APT package lists...'
    if apt_update; then
        return 0
    fi
    if [ "${DISTRO_ID}" = 'debian' ] && [ "${ARCHIVE_MODE}" = '0' ] \
        && debian_release_is_archived "${DISTRO_CODENAME}"; then
        setup_archive_apt_sources "${DISTRO_CODENAME}"
        if apt_update; then
            return 0
        fi
    fi
    log_warn 'apt-get update failed, continuing with the cached package lists.'
    return 1
}

# ---------------------------------------------------------------------------
# Repository setup
# ---------------------------------------------------------------------------
ensure_base_tools(){
    # ca-certificates must be present before any https fetch (GPG key, repo).
    apt_install ca-certificates curl gnupg > /dev/null 2>&1
    if ! has_command curl && ! has_command wget; then
        log_error 'Neither curl nor wget is available and none could be installed.'
        return 1
    fi
    if ! has_command gpg; then
        log_error 'gnupg could not be installed.'
        return 1
    fi
    return 0
}

teddysun_repo_suite_available(){
    local distro="$1" codename="$2" status
    [ -n "${codename}" ] || return 1
    status=$(http_status "${teddysun_repo_base}/${distro}/dists/${codename}/Release") || return 1
    [ "${status}" = '200' ]
}

add_rhel_repo(){
    log_info 'Adding Teddysun Shadowsocks Repository for RHEL...'
    dnf install -y yum-utils epel-release > /dev/null 2>&1
    dnf config-manager --set-enabled epel > /dev/null 2>&1
    dnf config-manager --add-repo "${rhel_repo_url}" > /dev/null 2>&1
    dnf config-manager --add-repo "${rhel_repo_url_2}" > /dev/null 2>&1
    if [ -f '/etc/yum.repos.d/teddysun.repo' ] && [ -f '/etc/yum.repos.d/teddysun_linux.repo' ]; then
        log_info 'Repository added successfully.'
        dnf makecache > /dev/null 2>&1
    else
        die 'Failed to add repository.'
    fi
}

add_debian_repo(){
    local distro codename repo line
    distro="${DISTRO_ID}"
    codename="${DISTRO_CODENAME}"
    [ "${distro}" = 'raspbian' ] && distro='debian'

    if [ "${distro}" = 'debian' ]; then
        repo="${teddysun_debian_repo}"
    else
        repo="${teddysun_ubuntu_repo}"
    fi

    log_info "Adding Teddysun Shadowsocks Repository for ${distro}/${codename}..."
    # The Teddysun repository does not exist for every codename (there is no
    # stretch suite, for example).  Detect it instead of failing the install.
    if ! teddysun_repo_suite_available "${distro}" "${codename}"; then
        log_warn "Teddysun repository has no '${codename}' suite for ${distro};"
        log_warn "falling back to the official ${distro} repositories."
        TEDDYSUN_SUITE_OK=0
        return 0
    fi

    ensure_base_tools || die 'Failed to install ca-certificates/curl/gnupg.'

    if ! curl -fsSL "${debian_gpg_url}" | gpg --dearmor --yes -o "${debian_keyring}" > /dev/null 2>&1 \
        || [ ! -s "${debian_keyring}" ]; then
        log_warn 'Failed to fetch the Teddysun GPG key; skipping that repository.'
        TEDDYSUN_SUITE_OK=0
        return 0
    fi
    chmod a+r "${debian_keyring}"

    line="deb [arch=$(dpkg --print-architecture) signed-by=${debian_keyring}] ${repo} ${codename} main"
    if [ "${ARCHIVE_MODE}" = '1' ]; then
        # Dir::Etc::sourceparts is disabled in archive mode, so the repository
        # has to be appended to the list this script owns.
        printf '%s\n' "${line}" >> "${APT_SOURCELIST}"
    else
        printf '%s\n' "${line}" > /etc/apt/sources.list.d/teddysun.list
    fi
    TEDDYSUN_SUITE_OK=1
    log_info 'Repository added successfully.'
}

# ---------------------------------------------------------------------------
# Interactive preparation
#
# Every prompt can be bypassed through an environment variable so the script
# also works unattended (cloud-init, docker, CI):
#   SS_SOFTWARE / SS_PASSWORD / SS_PORT / SS_CIPHER / SS_PLUGIN / SS_PLUGIN_OPTS
# When stdin is not a TTY the defaults are used instead of blocking forever.
# ---------------------------------------------------------------------------
is_interactive(){
    [ -t 0 ]
}

is_valid_port(){
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
    return 0
}

value_in_list(){
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [ "${item}" = "${needle}" ] && return 0
    done
    return 1
}

is_debian_before_9(){
    case "${DISTRO_VERSION_ID}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${DISTRO_VERSION_ID}" -lt 9 ]
}

install_check(){
    if is_dnf; then
        return 0
    fi
    if is_apt; then
        case "${DISTRO_ID}" in
            debian)
                is_debian_before_9 && return 1
                return 0
                ;;
            ubuntu|raspbian|linuxmint|kali)
                return 0
                ;;
        esac
    fi
    return 1
}

install_select(){
    if ! install_check; then
        log_error 'Your OS is not supported to run it!'
        echo 'Please change to CentOS/RHEL 8+, Debian 9+, or Ubuntu 20.04+ and try again.'
        exit 1
    fi

    if [ -n "${SS_SOFTWARE:-}" ]; then
        case "${SS_SOFTWARE}" in
            1|libev|Shadowsocks-libev) selected='1' ;;
            2|rust|Shadowsocks-rust)   selected='2' ;;
            *) die "Invalid SS_SOFTWARE: ${SS_SOFTWARE}" ;;
        esac
        echo "You choose = ${software[${selected}-1]}"
        return 0
    fi

    if ! is_interactive; then
        selected='1'
        log_info "stdin is not a TTY, defaulting to ${software[0]}."
        return 0
    fi

    local i hint
    clear
    while true
    do
    echo  "Which Shadowsocks server you'd select:"
    for ((i=1;i<=${#software[@]};i++ )); do
        hint="${software[$i-1]}"
        echo -e "${green}${i}${plain}) ${hint}"
    done
    read -r -p "Please enter a number (Default ${software[0]}):" selected
    [ -z "${selected}" ] && selected='1'
    case "${selected}" in
        1|2)
        echo
        echo "You choose = ${software[${selected}-1]}"
        echo
        break
        ;;
        *)
        log_error 'Please only enter a number [1-2]'
        ;;
    esac
    done
}

install_prepare_password(){
    if [ -n "${SS_PASSWORD:-}" ]; then
        shadowsockspwd="${SS_PASSWORD}"
        echo "password = ${shadowsockspwd}"
        return 0
    fi
    if ! is_interactive; then
        shadowsockspwd='teddysun.com'
        log_info 'stdin is not a TTY, using the default password.'
        return 0
    fi
    echo "Please enter password for ${software[${selected}-1]}"
    read -r -p '(Default password: teddysun.com):' shadowsockspwd
    [ -z "${shadowsockspwd}" ] && shadowsockspwd='teddysun.com'
    echo
    echo "password = ${shadowsockspwd}"
    echo
}

install_prepare_port(){
    if [ -n "${SS_PORT:-}" ]; then
        is_valid_port "${SS_PORT}" || die "Invalid SS_PORT: ${SS_PORT}"
        shadowsocksport="${SS_PORT}"
        echo "port = ${shadowsocksport}"
        return 0
    fi
    if ! is_interactive; then
        shadowsocksport=$(random_port)
        log_info "stdin is not a TTY, using port ${shadowsocksport}."
        return 0
    fi
    local dport
    while true
    do
    dport=$(random_port)
    echo -e "Please enter a port for ${software[${selected}-1]} [1-65535]"
    read -r -p "(Default port: ${dport}):" shadowsocksport
    [ -z "${shadowsocksport}" ] && shadowsocksport=${dport}
    if is_valid_port "${shadowsocksport}"; then
        echo
        echo "port = ${shadowsocksport}"
        echo
        break
    fi
    log_error 'Please enter a correct number [1-65535]'
    done
}

install_prepare_cipher(){
    local -a ciphers
    if [ "${selected}" = '2' ]; then
        ciphers=("${rust_ciphers[@]}")
    else
        ciphers=("${common_ciphers[@]}")
    fi

    if [ -n "${SS_CIPHER:-}" ]; then
        value_in_list "${SS_CIPHER}" "${ciphers[@]}" \
            || die "Unsupported SS_CIPHER for ${software[${selected}-1]}: ${SS_CIPHER}"
        shadowsockscipher="${SS_CIPHER}"
        echo "cipher = ${shadowsockscipher}"
        return 0
    fi
    if ! is_interactive; then
        shadowsockscipher="${ciphers[0]}"
        log_info "stdin is not a TTY, using cipher ${shadowsockscipher}."
        return 0
    fi

    local pick i hint
    while true
    do
    echo -e "Please select stream cipher for ${software[${selected}-1]}:"
    for ((i=1;i<=${#ciphers[@]};i++ )); do
        hint="${ciphers[$i-1]}"
        echo -e "${green}${i}${plain}) ${hint}"
    done
    read -r -p "Which cipher you'd select(Default: ${ciphers[0]}):" pick
    [ -z "${pick}" ] && pick=1
    if [[ "${pick}" =~ [^0-9] ]]; then
        log_error 'Please enter a number'
        continue
    fi
    if [[ "${pick}" -lt 1 || "${pick}" -gt ${#ciphers[@]} ]]; then
        log_error "Please enter a number between 1 and ${#ciphers[@]}"
        continue
    fi
    shadowsockscipher="${ciphers[${pick}-1]}"
    echo
    echo "cipher = ${shadowsockscipher}"
    echo
    break
    done
}

install_prepare_plugin(){
    if [ -n "${SS_PLUGIN:-}" ]; then
        value_in_list "${SS_PLUGIN}" "${plugins[@]}" || die "Unsupported SS_PLUGIN: ${SS_PLUGIN}"
        plugin_name="${SS_PLUGIN}"
        echo "plugin = ${plugin_name}"
    elif ! is_interactive; then
        plugin_name='None'
        log_info 'stdin is not a TTY, no SIP003 plugin will be used.'
    else
        local pick i hint
        while true
        do
        echo -e "Please select SIP003 plugin for ${software[${selected}-1]}:"
        for ((i=1;i<=${#plugins[@]};i++ )); do
            hint="${plugins[$i-1]}"
            echo -e "${green}${i}${plain}) ${hint}"
        done
        read -r -p "Which plugin you'd select (Default: ${plugins[0]}):" pick
        [ -z "${pick}" ] && pick=1
        if [[ "${pick}" =~ [^0-9] ]]; then
            log_error 'Please enter a number'
            continue
        fi
        if [[ "${pick}" -lt 1 || "${pick}" -gt ${#plugins[@]} ]]; then
            log_error "Please enter a number between 1 and ${#plugins[@]}"
            continue
        fi
        plugin_name="${plugins[${pick}-1]}"
        echo
        echo "plugin = ${plugin_name}"
        echo
        break
        done
    fi

    if [ "${plugin_name}" != 'None' ]; then
        install_prepare_plugin_options
    fi
}

install_prepare_plugin_options(){
    if [ -n "${SS_PLUGIN_OPTS:-}" ]; then
        plugin_opts="${SS_PLUGIN_OPTS}"
        echo "plugin_opts = ${plugin_opts}"
        return 0
    fi
    if ! is_interactive; then
        plugin_opts='server'
        log_info 'stdin is not a TTY, using the default plugin options.'
        return 0
    fi
    echo 'Please enter plugin options (e.g., for v2ray-plugin/xray-plugin):'
    echo 'Examples:'
    echo '  - No TLS: server'
    echo '  - With TLS: server;tls;host=yourdomain.com'
    echo '  - With TLS and path: server;tls;host=yourdomain.com;path=/ws'
    read -r -p '(Default: server):' plugin_opts
    [ -z "${plugin_opts}" ] && plugin_opts='server'
    echo
    echo "plugin_opts = ${plugin_opts}"
    echo
}

install_prepare(){
    install_prepare_password
    install_prepare_port
    install_prepare_cipher
    install_prepare_plugin

    if is_interactive; then
        echo
        echo 'Press any key to start...or Press Ctrl+C to cancel'
        get_char > /dev/null
    fi
}

# ---------------------------------------------------------------------------
# Terminal helper (kept from the upstream script, but non-fatal when there is
# no controlling TTY, e.g. under cloud-init or inside a container).
# ---------------------------------------------------------------------------
get_char(){
    [ -e /dev/tty ] || return 0
    has_command stty || return 0
    local savedstty
    savedstty=$(stty -g < /dev/tty 2> /dev/null) || return 0
    stty -echo < /dev/tty 2> /dev/null
    stty cbreak < /dev/tty 2> /dev/null
    dd if=/dev/tty bs=1 count=1 2> /dev/null
    stty -raw < /dev/tty 2> /dev/null
    stty echo < /dev/tty 2> /dev/null
    stty "${savedstty}" < /dev/tty 2> /dev/null
}

# ---------------------------------------------------------------------------
# GitHub release helpers (fallback for packages the distribution does not ship)
# ---------------------------------------------------------------------------
github_latest_tag(){
    local repo="$1" fallback="$2" tag tmp
    tmp=$(mktemp)
    tag=''
    if download_file "${github_api}/${repo}/releases/latest" "${tmp}" 2> /dev/null; then
        tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${tmp}" | head -n 1)
    fi
    rm -f "${tmp}"
    printf '%s' "${tag:-${fallback}}"
}

# Fully static musl build: runs on every Debian release, including the ones
# whose glibc is too old for the prebuilt packages of newer releases.
rust_musl_target(){
    case "$(uname -m)" in
        x86_64|amd64)        echo 'x86_64-unknown-linux-musl' ;;
        aarch64|arm64)       echo 'aarch64-unknown-linux-musl' ;;
        armv7l|armv6l|armhf) echo 'armv7-unknown-linux-musleabihf' ;;
        i386|i686)           echo 'i686-unknown-linux-musl' ;;
        *) return 1 ;;
    esac
}

plugin_arch(){
    case "$(uname -m)" in
        x86_64|amd64)        echo 'amd64' ;;
        aarch64|arm64)       echo 'arm64' ;;
        armv7l|armv6l|armhf) echo 'arm' ;;
        i386|i686)           echo '386' ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Package installation
# ---------------------------------------------------------------------------
install_dependencies(){
    log_info 'Installing helper packages (qrencode, xz-utils)...'
    apt_install qrencode xz-utils > /dev/null 2>&1
}

installed_libev_version(){
    dpkg-query -W -f='${Version}' shadowsocks-libev 2> /dev/null | sed 's/[^0-9.].*$//'
}

install_shadowsocks_libev(){
    log_info "Installing ${software[0]}..."
    local ok=0 version

    # Debian 9 has no Teddysun suite.  Its *-backports suite ships libev 3.2.5
    # (full AEAD support) while the plain suite only has the AEAD-less 2.6.3,
    # so try backports first.
    if [ "${DISTRO_ID}" = 'debian' ] && [ "${ARCHIVE_MODE}" = '1' ] \
        && [ "${TEDDYSUN_SUITE_OK}" = '0' ] && [ -n "${DISTRO_CODENAME}" ]; then
        if apt_install -t "${DISTRO_CODENAME}-backports" shadowsocks-libev > /dev/null 2>&1; then
            ok=1
        fi
    fi

    # Otherwise let apt resolve the version by itself.  With the Teddysun repo
    # enabled this picks the newest build (3.3.6 on bullseye/bookworm/trixie,
    # 3.3.5 on buster).  The upstream script pinned an exact version and always
    # failed on buster, because buster never shipped 3.3.6-2.
    if [ "${ok}" = '0' ]; then
        apt_install shadowsocks-libev > /dev/null 2>&1 && ok=1
    fi

    if [ ! -x /usr/bin/ss-server ]; then
        die "${software[0]} installation failed."
    fi
    version=$(installed_libev_version)
    [ -n "${version}" ] && log_info "${software[0]} ${version} installed."
}

install_rust_systemd_unit(){
    [ -d /etc/systemd/system ] || return 0
    cat > /etc/systemd/system/shadowsocks-rust-server.service <<'EOF'
[Unit]
Description=Shadowsocks-rust Server Service
After=network.target

[Service]
Type=simple
LimitNOFILE=32768
ExecStart=/usr/bin/ssservice server --log-without-time -c /etc/shadowsocks/shadowsocks-rust-config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
}

install_rust_from_github(){
    local tag target url tmp
    tag=$(github_latest_tag "${ss_rust_github_repo}" "${ss_rust_fallback_version}")
    target=$(rust_musl_target) || die 'Unsupported CPU architecture for the GitHub build.'
    url="https://github.com/${ss_rust_github_repo}/releases/download/${tag}/shadowsocks-${tag}.${target}.tar.xz"
    tmp=$(mktemp -d)
    log_info "Downloading ${url}"
    if ! download_file "${url}" "${tmp}/ss.tar.xz"; then
        rm -rf "${tmp}"
        die 'Failed to download shadowsocks-rust.'
    fi
    if ! tar -xJf "${tmp}/ss.tar.xz" -C "${tmp}" 2> /dev/null; then
        rm -rf "${tmp}"
        die 'Failed to extract shadowsocks-rust (is xz-utils installed?).'
    fi
    if ! install -m 0755 "${tmp}/ssserver" "${tmp}/ssservice" "${tmp}/sslocal" \
            "${tmp}/ssmanager" "${tmp}/ssurl" /usr/bin/ 2> /dev/null; then
        rm -rf "${tmp}"
        die 'Failed to install the shadowsocks-rust binaries.'
    fi
    rm -rf "${tmp}"
    install_rust_systemd_unit
    log_info "shadowsocks-rust ${tag} installed from GitHub."
}

install_shadowsocks_rust(){
    log_info "Installing ${software[1]}..."
    if apt_install shadowsocks-rust > /dev/null 2>&1 && [ -x /usr/bin/ssservice ]; then
        log_info "${software[1]} installed from the package repository."
        return 0
    fi
    log_warn 'No shadowsocks-rust package available, falling back to the GitHub build.'
    install_rust_from_github
}

install_plugin_from_github(){
    local name="$1" repo prefix arch tag asset inner url tmp
    case "${name}" in
        v2ray-plugin) repo="${v2ray_plugin_github_repo}"; prefix='v2ray-plugin' ;;
        xray-plugin)  repo="${xray_plugin_github_repo}";  prefix='xray-plugin' ;;
        *) return 1 ;;
    esac
    arch=$(plugin_arch) || return 1
    tag=$(github_latest_tag "${repo}" '')
    [ -n "${tag}" ] || return 1
    asset="${prefix}-linux-${arch}-${tag}.tar.gz"
    inner="${prefix}_linux_${arch}"
    url="https://github.com/${repo}/releases/download/${tag}/${asset}"
    tmp=$(mktemp -d)
    log_info "Downloading ${url}"
    if download_file "${url}" "${tmp}/plugin.tar.gz" \
        && tar -xzf "${tmp}/plugin.tar.gz" -C "${tmp}" 2> /dev/null \
        && [ -f "${tmp}/${inner}" ]; then
        install -m 0755 "${tmp}/${inner}" "/usr/bin/${name}"
        rm -rf "${tmp}"
        return 0
    fi
    rm -rf "${tmp}"
    return 1
}

install_plugin(){
    if [ "${plugin_name}" = 'None' ]; then
        return 0
    fi
    log_info "Installing ${plugin_name}..."
    if apt_install "${plugin_name}" > /dev/null 2>&1 && [ -x "/usr/bin/${plugin_name}" ]; then
        return 0
    fi
    log_warn "No ${plugin_name} package available, falling back to the GitHub build."
    install_plugin_from_github "${plugin_name}" || die "${plugin_name} installation failed."
}

# shadowsocks-libev < 3.0 has no AEAD cipher at all.  This only happens when
# the plain Debian 9 suite had to be used (no backports), in which case the
# cipher selected by the user has to be downgraded to a stream cipher.
ensure_libev_cipher_supported(){
    [ "${selected}" = '1' ] || return 0
    local version
    version=$(installed_libev_version)
    [ -n "${version}" ] || return 0
    version_ge "${version}" '3.0.0' && return 0
    value_in_list "${shadowsockscipher}" "${legacy_ciphers[@]}" && return 0
    log_warn "shadowsocks-libev ${version} does not support AEAD ciphers;"
    log_warn "switching cipher from ${shadowsockscipher} to aes-256-cfb."
    shadowsockscipher='aes-256-cfb'
    return 0
}

# ---------------------------------------------------------------------------
# systemd layout
#
# Teddysun packages install shadowsocks-libev-server.service and read
# /etc/shadowsocks/shadowsocks-libev-config.json, while the Debian packages
# install shadowsocks-libev.service and read $CONFFILE from
# /etc/default/shadowsocks-libev (default /etc/shadowsocks-libev/config.json).
# Resolve whichever is present so one script handles both sources.
# ---------------------------------------------------------------------------
ss_libev_unit=''
ss_libev_config=''
ss_rust_unit='shadowsocks-rust-server'
ss_rust_config="${shadowsocks_rust_config}"

unit_exists(){
    local unit="$1"
    [ -f "/lib/systemd/system/${unit}.service" ] \
        || [ -f "/usr/lib/systemd/system/${unit}.service" ] \
        || [ -f "/etc/systemd/system/${unit}.service" ]
}

resolve_ss_layout(){
    local conf
    if unit_exists 'shadowsocks-libev-server'; then
        ss_libev_unit='shadowsocks-libev-server'
        ss_libev_config="${shadowsocks_libev_config}"
    elif unit_exists 'shadowsocks-libev'; then
        ss_libev_unit='shadowsocks-libev'
        ss_libev_config="${debian_libev_config}"
        conf=$(sed -n 's/^[[:space:]]*CONFFILE="\?\([^"]*\)"\?.*/\1/p' /etc/default/shadowsocks-libev 2> /dev/null | head -n 1)
        [ -n "${conf}" ] && ss_libev_config="${conf}"
    else
        ss_libev_unit='shadowsocks-libev-server'
        ss_libev_config="${shadowsocks_libev_config}"
    fi
}

get_ip(){
    local IP
    IP=$(ip addr 2> /dev/null | grep -E -o '[0-9]{1,3}(\.[0-9]{1,3}){3}' \
        | grep -E -v '^192\.168|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-2]\.|^10\.|^127\.|^255\.|^0\.' | head -n 1)
    if [ -z "${IP}" ] && has_command curl; then
        IP=$(curl -fsS --max-time 5 http://ipv4.icanhazip.com 2> /dev/null)
        [ -z "${IP}" ] && IP=$(curl -fsS --max-time 5 http://ipinfo.io/ip 2> /dev/null)
    fi
    if [ -z "${IP}" ] && has_command wget; then
        IP=$(wget -qO- -t1 -T2 http://ipv4.icanhazip.com 2> /dev/null)
        [ -z "${IP}" ] && IP=$(wget -qO- -t1 -T2 http://ipinfo.io/ip 2> /dev/null)
    fi
    printf '%s' "${IP}"
}

get_ipv6(){
    local ipv6
    if has_command curl; then
        ipv6=$(curl -fsS --max-time 5 http://ipv6.icanhazip.com 2> /dev/null)
    elif has_command wget; then
        ipv6=$(wget -qO- -t1 -T2 http://ipv6.icanhazip.com 2> /dev/null)
    fi
    [ -n "${ipv6}" ]
}

# Write the shadowsocks JSON config shared by libev and rust.
write_shadowsocks_config(){
    local file="$1" server_value="$2"
    mkdir -p "$(dirname "${file}")"
    if [ "${plugin_name}" != 'None' ]; then
        cat > "${file}" <<EOF
{
    "server":${server_value},
    "server_port":${shadowsocksport},
    "password":"${shadowsockspwd}",
    "timeout":300,
    "method":"${shadowsockscipher}",
    "fast_open":false,
    "nameserver":"8.8.8.8",
    "mode":"tcp_and_udp",
    "plugin":"${plugin_name}",
    "plugin_opts":"${plugin_opts}"
}
EOF
    else
        cat > "${file}" <<EOF
{
    "server":${server_value},
    "server_port":${shadowsocksport},
    "password":"${shadowsockspwd}",
    "timeout":300,
    "method":"${shadowsockscipher}",
    "fast_open":false,
    "nameserver":"8.8.8.8",
    "mode":"tcp_and_udp"
}
EOF
    fi
    # The Debian units drop privileges (nobody / DynamicUser), so the config
    # must stay world readable.
    chmod 644 "${file}"
    log_info "Configuration written to ${file}"
}

config_shadowsocks_libev(){
    local server_value='"0.0.0.0"' version
    [ -n "${ss_libev_config}" ] || resolve_ss_layout
    version=$(installed_libev_version)
    # Listening on an array of addresses only works since libev 3.3.0; older
    # builds (3.2.5 in Debian 9 backports) need a plain string.
    if get_ipv6 && version_ge "${version}" '3.3.0'; then
        server_value='["[::0]","0.0.0.0"]'
    fi
    write_shadowsocks_config "${ss_libev_config}" "${server_value}"
}

config_shadowsocks_rust(){
    local server_value='"0.0.0.0"'
    if get_ipv6; then
        server_value='["[::0]","0.0.0.0"]'
    fi
    write_shadowsocks_config "${ss_rust_config}" "${server_value}"
}

# ---------------------------------------------------------------------------
# Service control
# ---------------------------------------------------------------------------
start_service(){
    local unit="$1"
    if has_command systemctl && [ -d /run/systemd/system ]; then
        systemctl daemon-reload
        systemctl restart "${unit}"
        systemctl enable "${unit}" > /dev/null 2>&1
        return 0
    fi
    return 1
}

start_shadowsocks_libev(){
    if start_service "${ss_libev_unit}"; then
        return 0
    fi
    log_warn 'systemd is not available, starting ss-server directly.'
    nohup /usr/bin/ss-server -c "${ss_libev_config}" -f /var/run/shadowsocks-libev-server.pid > /dev/null 2>&1 &
}

start_shadowsocks_rust(){
    if start_service "${ss_rust_unit}"; then
        return 0
    fi
    log_warn 'systemd is not available, starting ssservice directly.'
    nohup /usr/bin/ssservice server -c "${ss_rust_config}" > /dev/null 2>&1 &
}

config_firewall(){
    if is_dnf; then
        if systemctl status firewalld > /dev/null 2>&1; then
            local default_zone
            default_zone=$(firewall-cmd --get-default-zone)
            firewall-cmd --permanent --zone="${default_zone}" --add-port="${shadowsocksport}"/tcp > /dev/null 2>&1
            firewall-cmd --permanent --zone="${default_zone}" --add-port="${shadowsocksport}"/udp > /dev/null 2>&1
            firewall-cmd --reload > /dev/null 2>&1
            log_info "Firewall port ${shadowsocksport} opened."
        else
            log_warn "firewalld is not running, open port ${shadowsocksport} manually if necessary."
        fi
    fi
    if is_apt; then
        # `ufw status` exits 0 even when the firewall is inactive, so test the
        # reported state instead of the exit code (upstream bug).
        if has_command ufw && ufw status 2> /dev/null | grep -qi '^Status:[[:space:]]*active'; then
            ufw allow "${shadowsocksport}"/tcp > /dev/null 2>&1
            ufw allow "${shadowsocksport}"/udp > /dev/null 2>&1
            log_info "Firewall port ${shadowsocksport} opened."
        else
            log_warn "ufw is not active, open port ${shadowsocksport} manually if necessary."
        fi
    fi
}

install_completed_libev(){
    clear
    echo
    echo -e "Congratulations, ${green}${software[0]}${plain} server install completed!"
    echo -e "Your Server IP        : ${red} $(get_ip) ${plain}"
    echo -e "Your Server Port      : ${red} ${shadowsocksport} ${plain}"
    echo -e "Your Password         : ${red} ${shadowsockspwd} ${plain}"
    echo -e "Your Encryption Method: ${red} ${shadowsockscipher} ${plain}"
    if [ "${plugin_name}" != 'None' ]; then
        echo -e "Your Plugin           : ${red} ${plugin_name} ${plain}"
        echo -e "Your Plugin Options   : ${red} ${plugin_opts} ${plain}"
    fi
}

install_completed_rust(){
    clear
    echo
    echo -e "Congratulations, ${green}${software[1]}${plain} server install completed!"
    echo -e "Your Server IP        : ${red} $(get_ip) ${plain}"
    echo -e "Your Server Port      : ${red} ${shadowsocksport} ${plain}"
    echo -e "Your Password         : ${red} ${shadowsockspwd} ${plain}"
    echo -e "Your Encryption Method: ${red} ${shadowsockscipher} ${plain}"
    if [ "${plugin_name}" != 'None' ]; then
        echo -e "Your Plugin           : ${red} ${plugin_name} ${plain}"
        echo -e "Your Plugin Options   : ${red} ${plugin_opts} ${plain}"
    fi
}

qr_generate(){
    local png="$1" tmp qr_code plugin_encoded
    has_command qrencode || return 0
    if [ "${plugin_name}" != 'None' ]; then
        # SIP003 URL format with plugin
        tmp=$(printf '%s' "${shadowsockscipher}:${shadowsockspwd}" | base64 -w0 | sed 's/=//g')
        plugin_encoded=$(printf '%s' "${plugin_name};${plugin_opts}" | base64 -w0 | sed 's/=//g')
        qr_code="ss://${tmp}@$(get_ip):${shadowsocksport}/?plugin=${plugin_encoded}"
    else
        tmp=$(printf '%s' "${shadowsockscipher}:${shadowsockspwd}@$(get_ip):${shadowsocksport}" | base64 -w0)
        qr_code="ss://${tmp}"
    fi
    echo
    echo 'Your QR Code: (For Shadowsocks Windows, OSX, Android and iOS clients)'
    echo -e "${green} ${qr_code} ${plain}"
    printf '%s' "${qr_code}" | qrencode -s8 -o "${cur_dir}/${png}"
    echo 'Your QR Code has been saved as a PNG file path:'
    echo -e "${green} ${cur_dir}/${png} ${plain}"
}

qr_generate_libev(){
    qr_generate 'shadowsocks_libev_qr.png'
}

qr_generate_rust(){
    qr_generate 'shadowsocks_rust_qr.png'
}

install_main(){
    if [ "${selected}" = '1' ]; then
        install_shadowsocks_libev
        ensure_libev_cipher_supported
        # Resolve the unit/config layout only after the package is installed.
        resolve_ss_layout
        install_plugin
        config_shadowsocks_libev
        start_shadowsocks_libev
        install_completed_libev
        qr_generate_libev
    elif [ "${selected}" = '2' ]; then
        install_shadowsocks_rust
        install_plugin
        config_shadowsocks_rust
        start_shadowsocks_rust
        install_completed_rust
        qr_generate_rust
    fi

    echo
    echo 'Welcome to visit: https://teddysun.com/486.html'
    echo 'Enjoy it!'
    echo
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------
disable_selinux(){
    if [ -s /etc/selinux/config ] && grep -q 'SELINUX=enforcing' /etc/selinux/config; then
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
        setenforce 0 2> /dev/null
    fi
}

install_shadowsocks(){
    disable_selinux
    install_select
    install_prepare

    if is_dnf; then
        add_rhel_repo
    elif is_apt; then
        # Order matters: make APT usable (possibly switching to the Debian
        # archive on EOL releases) before anything is installed from it.
        ensure_apt_works
        ensure_base_tools || die 'Failed to install the base tools (ca-certificates/curl/gnupg).'
        add_debian_repo
        apt_update || log_warn 'apt-get update failed after adding the repository.'
        install_dependencies
    else
        die 'No supported package manager found (apt / dnf).'
    fi

    config_firewall
    install_main
}

remove_untracked_binary(){
    local path="/usr/bin/$1"
    [ -e "${path}" ] || return 0
    # Only delete binaries that no package owns (GitHub fallback installs).
    dpkg -S "${path}" > /dev/null 2>&1 && return 0
    rm -f "${path}"
}

uninstall_shadowsocks_libev(){
    echo -e "Are you sure uninstall ${red}${software[0]}${plain}? [y/n]"
    read -r -p '(default: n):' answer
    [ -z "${answer}" ] && answer='n'
    if [ "${answer}" = 'y' ] || [ "${answer}" = 'Y' ]; then
        resolve_ss_layout
        systemctl stop "${ss_libev_unit}" > /dev/null 2>&1
        systemctl disable "${ss_libev_unit}" > /dev/null 2>&1
        if is_dnf; then
            dnf remove -y shadowsocks-libev v2ray-plugin xray-plugin > /dev/null 2>&1
        elif is_apt; then
            apt_purge shadowsocks-libev v2ray-plugin xray-plugin > /dev/null 2>&1
        fi
        remove_untracked_binary 'v2ray-plugin'
        remove_untracked_binary 'xray-plugin'
        rm -f "${shadowsocks_libev_config}" "${debian_libev_config}"
        log_info "${software[0]} uninstall success"
    else
        echo
        log_info "${software[0]} uninstall cancelled, nothing to do..."
        echo
    fi
}

uninstall_shadowsocks_rust(){
    echo -e "Are you sure uninstall ${red}${software[1]}${plain}? [y/n]"
    read -r -p '(default: n):' answer
    [ -z "${answer}" ] && answer='n'
    if [ "${answer}" = 'y' ] || [ "${answer}" = 'Y' ]; then
        systemctl stop "${ss_rust_unit}" > /dev/null 2>&1
        systemctl disable "${ss_rust_unit}" > /dev/null 2>&1
        if is_dnf; then
            dnf remove -y shadowsocks-rust v2ray-plugin xray-plugin > /dev/null 2>&1
        elif is_apt; then
            apt_purge shadowsocks-rust v2ray-plugin xray-plugin > /dev/null 2>&1
        fi
        # Clean up a possible GitHub fallback install.
        rm -f /etc/systemd/system/shadowsocks-rust-server.service
        remove_untracked_binary 'ssserver'
        remove_untracked_binary 'ssservice'
        remove_untracked_binary 'sslocal'
        remove_untracked_binary 'ssmanager'
        remove_untracked_binary 'ssurl'
        remove_untracked_binary 'v2ray-plugin'
        remove_untracked_binary 'xray-plugin'
        rm -f "${shadowsocks_rust_config}"
        log_info "${software[1]} uninstall success"
    else
        echo
        log_info "${software[1]} uninstall cancelled, nothing to do..."
        echo
    fi
}

uninstall_shadowsocks(){
    local un_select
    while true
    do
    echo 'Which Shadowsocks server you want to uninstall?'
    for ((i=1;i<=${#software[@]};i++ )); do
        hint="${software[$i-1]}"
        echo -e "${green}${i}${plain}) ${hint}"
    done
    read -r -p 'Please enter a number [1-2]:' un_select
    case "${un_select}" in
        1|2)
        echo
        echo "You choose = ${software[${un_select}-1]}"
        echo
        break
        ;;
        *)
        log_error 'Please only enter a number [1-2]'
        ;;
    esac
    done

    if   [ "${un_select}" = '1' ]; then
        uninstall_shadowsocks_libev
    elif [ "${un_select}" = '2' ]; then
        uninstall_shadowsocks_rust
    fi
}

# ---------------------------------------------------------------------------
# Diagnostics / entry point
# ---------------------------------------------------------------------------
check_system(){
    local arch distro
    detect_distro
    arch=$(uname -m)
    distro="${DISTRO_ID}"
    [ "${distro}" = 'raspbian' ] && distro='debian'

    echo
    echo 'System information detected by this script:'
    printf '  %-18s %s\n' 'Distribution:' "${DISTRO_PRETTY:-${DISTRO_ID} ${DISTRO_VERSION_ID}}"
    printf '  %-18s %s\n' 'ID / VERSION_ID:' "${DISTRO_ID} / ${DISTRO_VERSION_ID}"
    printf '  %-18s %s\n' 'Codename:' "${DISTRO_CODENAME:-unknown}"
    printf '  %-18s %s\n' 'Package manager:' "${PACKAGE_MANAGER:-unknown}"
    printf '  %-18s %s\n' 'Architecture:' "${arch}"
    if has_command systemctl && [ -d /run/systemd/system ]; then
        printf '  %-18s %s\n' 'systemd:' 'available'
    else
        printf '  %-18s %s\n' 'systemd:' 'not available (manual start fallback)'
    fi
    if install_check; then
        printf '  %-18s %s\n' 'Supported:' 'yes'
    else
        printf '  %-18s %s\n' 'Supported:' 'no'
    fi
    if is_apt && [ "${DISTRO_ID}" = 'debian' ]; then
        if debian_release_is_archived "${DISTRO_CODENAME}"; then
            printf '  %-18s %s\n' 'Debian release:' 'EOL, packages on archive.debian.org'
        else
            printf '  %-18s %s\n' 'Debian release:' 'current, packages on deb.debian.org'
        fi
        if teddysun_repo_suite_available "${distro}" "${DISTRO_CODENAME}"; then
            printf '  %-18s %s\n' 'Teddysun repo:' 'suite available'
        else
            printf '  %-18s %s\n' 'Teddysun repo:' 'no suite, falls back to distro packages / GitHub'
        fi
    fi
    if [ -e /usr/bin/ss-server ]; then
        printf '  %-18s %s\n' 'ss-server:' "installed ($(installed_libev_version))"
    fi
    if [ -e /usr/bin/ssservice ]; then
        printf '  %-18s %s\n' 'ssservice:' 'installed'
    fi
    echo
}

usage(){
    cat <<'EOF'
Usage: shadowsocks-all.sh [action]

Actions:
  install     Install Shadowsocks-libev or Shadowsocks-rust (default)
  uninstall   Remove a previously installed server
  check       Print the detected system information, change nothing
  help        Show this message

Unattended install environment variables:
  SS_SOFTWARE=1|2|libev|rust     SS_PASSWORD=...     SS_PORT=1-65535
  SS_CIPHER=<cipher name>
  SS_PLUGIN=None|v2ray-plugin|xray-plugin
  SS_PLUGIN_OPTS='server;tls;host=example.com'
EOF
}

main(){
    local action="${1:-install}"

    case "${action}" in
        install|uninstall)
            [[ ${EUID} -ne 0 ]] && die 'This script must be run as root!'
            detect_distro
            ;;
        check|info|help|-h|--help)
            detect_distro
            ;;
        *)
            echo "Arguments error! [${action}]"
            usage
            exit 1
            ;;
    esac

    case "${action}" in
        install)        install_shadowsocks ;;
        uninstall)      uninstall_shadowsocks ;;
        check|info)     check_system ;;
        help|-h|--help) usage ;;
    esac
}

# Allow the script to be sourced by tests without running the installer.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
