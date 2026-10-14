#!/usr/bin/env bash
# Validation harness for /workspace/shadowsocks-all.sh
# Sources the script (the entry-point guard keeps main() from running) and
# exercises the Debian 9..13 detection / repository-selection logic.
set -u

SCRIPT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/shadowsocks-all.sh}"
[ -r "${SCRIPT}" ] || { echo "cannot read ${SCRIPT}" >&2; exit 2; }
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

. "${SCRIPT}"

pass=0
fail=0
check(){
    if [ "$2" = "$3" ]; then
        pass=$((pass+1))
        printf '  ok   %-46s %s\n' "$1" "$3"
    else
        fail=$((fail+1))
        printf '  FAIL %-46s got=[%s] want=[%s]\n' "$1" "$3" "$2"
    fi
}

mkos(){
    # mkos <id> <version> <codename> <pretty>
    local f="${TMP}/os-$1-$2"
    {
        echo "PRETTY_NAME=\"$4\""
        echo "NAME=\"$1\""
        echo "VERSION_ID=\"$2\""
        echo "VERSION_CODENAME=$3"
        echo "ID=$1"
    } > "${f}"
    printf '%s' "${f}"
}

echo '== distro detection (os-release) =='
for spec in \
    'debian|9|stretch|Debian GNU/Linux 9 (stretch)' \
    'debian|10|buster|Debian GNU/Linux 10 (buster)' \
    'debian|11|bullseye|Debian GNU/Linux 11 (bullseye)' \
    'debian|12|bookworm|Debian GNU/Linux 12 (bookworm)' \
    'debian|13|trixie|Debian GNU/Linux 13 (trixie)' \
    'ubuntu|22.04|jammy|Ubuntu 22.04.4 LTS' \
    'raspbian|11|bullseye|Raspbian GNU/Linux 11 (bullseye)'
do
    IFS='|' read -r id ver codename pretty <<< "${spec}"
    os_release_file=$(mkos "${id}" "${ver}" "${codename}" "${pretty}")
    detect_distro
    printf '%-9s %-6s -> id=%-8s ver=%-6s codename=%-9s pm=%s\n' \
        "${id}" "${ver}" "${DISTRO_ID}" "${DISTRO_VERSION_ID}" "${DISTRO_CODENAME}" "${PACKAGE_MANAGER}"
    check "${id}${ver} id" "${id}" "${DISTRO_ID}"
    check "${id}${ver} version" "${ver}" "${DISTRO_VERSION_ID}"
    check "${id}${ver} codename" "${codename}" "${DISTRO_CODENAME}"
    if install_check; then check "${id}${ver} supported" 'yes' 'yes'; else check "${id}${ver} supported" 'yes' 'no'; fi
done

echo
echo '== codename fallback when VERSION_CODENAME is missing =='
cat > "${TMP}/os-nocodename" <<'EOF'
PRETTY_NAME="Debian GNU/Linux 9 (stretch)"
ID=debian
VERSION_ID="9"
EOF
os_release_file="${TMP}/os-nocodename"
detect_distro
check 'debian 9 codename fallback' 'stretch' "${DISTRO_CODENAME}"

echo
echo '== Debian 8 must be rejected =='
cat > "${TMP}/os-d8" <<'EOF'
ID=debian
VERSION_ID="8"
VERSION_CODENAME=jessie
EOF
os_release_file="${TMP}/os-d8"
detect_distro
if install_check; then check 'debian 8 unsupported' 'no' 'yes'; else check 'debian 8 unsupported' 'no' 'no'; fi

echo
echo '== archive detection (network) =='
for c in stretch buster bullseye bookworm trixie; do
    if debian_release_is_archived "${c}"; then r='EOL/archive'; else r='current'; fi
    printf '  %-9s %s\n' "${c}" "${r}"
done
if debian_release_is_archived stretch; then check 'stretch archived' 'yes' 'yes'; else check 'stretch archived' 'yes' 'no'; fi
if debian_release_is_archived buster;  then check 'buster archived'  'yes' 'yes'; else check 'buster archived'  'yes' 'no'; fi
if debian_release_is_archived bookworm; then check 'bookworm current' 'no' 'yes'; else check 'bookworm current' 'no' 'no'; fi

echo
echo '== helpers =='
if version_ge 3.3.6 3.3.0; then check 'version_ge 3.3.6>=3.3.0' 'yes' 'yes'; else check 'version_ge 3.3.6>=3.3.0' 'yes' 'no'; fi
if version_ge 2.6.3 3.0.0; then check 'version_ge 2.6.3>=3.0.0' 'no' 'yes'; else check 'version_ge 2.6.3>=3.0.0' 'no' 'no'; fi
if version_ge 3.2.5 3.3.0; then check 'version_ge 3.2.5>=3.3.0' 'no' 'yes'; else check 'version_ge 3.2.5>=3.3.0' 'no' 'no'; fi
check 'libev version strips suffix' '3.3.6' "$(printf '%s' '3.3.6-2~debian.12~bookworm' | sed 's/[^0-9.].*$//')"
if is_valid_port 8388; then check 'is_valid_port 8388' 'yes' 'yes'; else check 'is_valid_port 8388' 'yes' 'no'; fi
if is_valid_port 0; then check 'is_valid_port 0' 'no' 'yes'; else check 'is_valid_port 0' 'no' 'no'; fi
if is_valid_port 70000; then check 'is_valid_port 70000' 'no' 'yes'; else check 'is_valid_port 70000' 'no' 'no'; fi
check 'rust musl target' 'x86_64-unknown-linux-musl' "$(rust_musl_target)"
check 'plugin arch' 'amd64' "$(plugin_arch)"
if value_in_list aes-256-gcm "${common_ciphers[@]}"; then check 'cipher in list' 'yes' 'yes'; else check 'cipher in list' 'yes' 'no'; fi
if value_in_list bogus-cipher "${common_ciphers[@]}"; then check 'cipher not in list' 'no' 'yes'; else check 'cipher not in list' 'no' 'no'; fi

echo
echo '== config generation =='
plugin_name='None'
shadowsocksport=8388
shadowsockspwd='s3cr3t'
shadowsockscipher='aes-256-gcm'
write_shadowsocks_config "${TMP}/plain.json" '"0.0.0.0"' > /dev/null
if python3 -c "import json,sys; d=json.load(open('${TMP}/plain.json')); sys.exit(0 if d['server_port']==8388 and d['method']=='aes-256-gcm' and d['mode']=='tcp_and_udp' and 'plugin' not in d else 1)"; then
    check 'plain config valid json' 'yes' 'yes'
else
    check 'plain config valid json' 'yes' 'no'
fi
plugin_name='xray-plugin'
plugin_opts='server;tls;host=example.com'
write_shadowsocks_config "${TMP}/plugin.json" '["[::0]","0.0.0.0"]' > /dev/null
if python3 -c "import json,sys; d=json.load(open('${TMP}/plugin.json')); sys.exit(0 if d['plugin']=='xray-plugin' and d['plugin_opts']=='server;tls;host=example.com' and d['server']==['[::0]','0.0.0.0'] else 1)"; then
    check 'plugin config valid json' 'yes' 'yes'
else
    check 'plugin config valid json' 'yes' 'no'
fi
check 'config mode 644' '644' "$(stat -c '%a' "${TMP}/plugin.json")"

echo
echo '== non-interactive prompts (no TTY) =='
os_release_file=/etc/os-release
detect_distro
selected=''
shadowsockspwd=''; shadowsocksport=''; shadowsockscipher=''; plugin_name=''
install_select > /dev/null </dev/null
install_prepare_password > /dev/null </dev/null
install_prepare_port > /dev/null </dev/null
install_prepare_cipher > /dev/null </dev/null
install_prepare_plugin > /dev/null </dev/null
check 'default software' '1' "${selected}"
check 'default password' 'teddysun.com' "${shadowsockspwd}"
check 'default cipher' 'aes-256-gcm' "${shadowsockscipher}"
check 'default plugin' 'None' "${plugin_name}"
if is_valid_port "${shadowsocksport}"; then check 'default port valid' 'yes' 'yes'; else check 'default port valid' 'yes' 'no'; fi

echo
echo '== environment overrides =='
SS_SOFTWARE=rust SS_PASSWORD=pw SS_PORT=9999 SS_CIPHER=2022-blake3-aes-256-gcm SS_PLUGIN=xray-plugin SS_PLUGIN_OPTS='server;tls' \
    bash -c '. '"${SCRIPT}"'; detect_distro; install_select >/dev/null </dev/null; install_prepare_password >/dev/null </dev/null; install_prepare_port >/dev/null </dev/null; install_prepare_cipher >/dev/null </dev/null; install_prepare_plugin >/dev/null </dev/null; echo "${selected}|${shadowsockspwd}|${shadowsocksport}|${shadowsockscipher}|${plugin_name}|${plugin_opts}"' > "${TMP}/env.out"
check 'env overrides honoured' '2|pw|9999|2022-blake3-aes-256-gcm|xray-plugin|server;tls' "$(cat "${TMP}/env.out")"

echo
echo '== legacy cipher downgrade (libev < 3.0) =='
selected='1'
shadowsockscipher='aes-256-gcm'
installed_libev_version(){ echo '2.6.3'; }
ensure_libev_cipher_supported
check 'AEAD downgraded on libev 2.6.3' 'aes-256-cfb' "${shadowsockscipher}"
shadowsockscipher='aes-256-gcm'
installed_libev_version(){ echo '3.2.5'; }
ensure_libev_cipher_supported
check 'AEAD kept on libev 3.2.5' 'aes-256-gcm' "${shadowsockscipher}"

echo
echo '== archive apt sources generation =='
APT_SOURCELIST="${TMP}/archive.list"
setup_archive_apt_sources stretch
check 'archive main line'      'yes' "$(grep -q 'archive.debian.org/debian stretch main' "${APT_SOURCELIST}" && echo yes || echo no)"
check 'archive security line'  'yes' "$(grep -q 'debian-security stretch/updates main' "${APT_SOURCELIST}" && echo yes || echo no)"
check 'archive backports line' 'yes' "$(grep -q 'stretch-backports main' "${APT_SOURCELIST}" && echo yes || echo no)"
check 'archive over http'      'yes' "$(grep -q 'http://archive.debian.org' "${APT_SOURCELIST}" && echo yes || echo no)"
check 'archive mode flag'      '1'   "${ARCHIVE_MODE}"
check 'apt opts sourcelist'    'yes' "$(printf '%s\n' "${APT_OPTS[@]}" | grep -q "Dir::Etc::sourcelist=${TMP}/archive.list" && echo yes || echo no)"
check 'apt opts valid-until'   'yes' "$(printf '%s\n' "${APT_OPTS[@]}" | grep -q 'Acquire::Check-Valid-Until=false' && echo yes || echo no)"
check 'apt opts sourceparts'   'yes' "$(printf '%s\n' "${APT_OPTS[@]}" | grep -q 'Dir::Etc::sourceparts=-' && echo yes || echo no)"
if setup_archive_apt_sources ''; then check 'empty codename rejected' 'no' 'yes'; else check 'empty codename rejected' 'no' 'no'; fi

echo
echo '== systemd layout resolution (no units installed) =='
resolve_ss_layout
check 'fallback unit'   'shadowsocks-libev-server' "${ss_libev_unit}"
check 'fallback config' "${shadowsocks_libev_config}" "${ss_libev_config}"
check 'rust unit'       'shadowsocks-rust-server' "${ss_rust_unit}"
check 'rust config'     "${shadowsocks_rust_config}" "${ss_rust_config}"

echo
echo '== orchestration order (stubbed) =='
log(){ echo "$1"; }
install_select(){ log select; }
install_prepare(){ log prepare; }
ensure_apt_works(){ log apt_update_check; }
ensure_base_tools(){ log base_tools; }
add_debian_repo(){ log add_repo; }
apt_update(){ log apt_update; }
install_dependencies(){ log dependencies; }
config_firewall(){ log firewall; }
install_main(){ log main; }
disable_selinux(){ log selinux; }
PACKAGE_MANAGER='apt'
order=$(install_shadowsocks 2> /dev/null | tr '\n' ' ')
check 'install order (apt)' 'selinux select prepare apt_update_check base_tools add_repo apt_update dependencies firewall main ' "${order}"

PACKAGE_MANAGER='dnf'
add_rhel_repo(){ log add_rhel_repo; }
order=$(install_shadowsocks 2> /dev/null | tr '\n' ' ')
check 'install order (dnf)' 'selinux select prepare add_rhel_repo firewall main ' "${order}"

echo
echo '== install_main dispatch (stubbed) =='
# Re-source to restore the real install_main (it was stubbed above).
. "${SCRIPT}"
log(){ echo "$1"; }
install_shadowsocks_libev(){ log libev_install; }
ensure_libev_cipher_supported(){ log libev_cipher; }
resolve_ss_layout(){ log libev_layout; }
install_plugin(){ log libev_plugin; }
config_shadowsocks_libev(){ log libev_config; }
start_shadowsocks_libev(){ log libev_start; }
install_completed_libev(){ log libev_done; }
qr_generate_libev(){ log libev_qr; }
install_shadowsocks_rust(){ log rust_install; }
config_shadowsocks_rust(){ log rust_config; }
start_shadowsocks_rust(){ log rust_start; }
install_completed_rust(){ log rust_done; }
qr_generate_rust(){ log rust_qr; }
selected='1'
order=$(install_main 2> /dev/null | sed '/^$/d' | grep -v 'Welcome to visit\|Enjoy it' | tr '\n' ' ')
check 'libev dispatch' 'libev_install libev_cipher libev_layout libev_plugin libev_config libev_start libev_done libev_qr ' "${order}"
selected='2'
order=$(install_main 2> /dev/null | sed '/^$/d' | grep -v 'Welcome to visit\|Enjoy it' | tr '\n' ' ')
check 'rust dispatch' 'rust_install libev_plugin rust_config rust_start rust_done rust_qr ' "${order}"

echo
echo "PASS=${pass} FAIL=${fail}"
[ "${fail}" -eq 0 ]

