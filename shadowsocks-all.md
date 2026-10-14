# shadowsocks-all.sh — Debian 9~13 兼容版说明

上游脚本（[teddysun/shadowsocks_install](https://github.com/teddysun/shadowsocks_install)）头部明确写着
`System Required: Debian 11+`，在 Debian 9/10 上会失败。本仓库的
[`shadowsocks-all.sh`](./shadowsocks-all.sh) 是它的兼容性改造版，
**在 Debian 9 stretch / 10 buster / 11 bullseye / 12 bookworm / 13 trixie 上均可安装**。

验证：`bash scripts/tests/test_shadowsocks_all.sh`（72 项断言全部通过）+ `shellcheck` 无告警。

## 用法

```bash
wget --no-check-certificate -O shadowsocks-all.sh \
  https://raw.githubusercontent.com/Gabxb/UtilityScripts/main/shadowsocks-all.sh
chmod +x shadowsocks-all.sh

./shadowsocks-all.sh check       # 只探测系统，不安装
./shadowsocks-all.sh diagnose    # check + 完整 APT 状态（源、policy、dry-run）
./shadowsocks-all.sh install 2>&1 | tee shadowsocks-all.log
./shadowsocks-all.sh uninstall
```

无人值守安装（cloud-init / 容器 / CI，无 TTY 时也会自动取默认值而不是卡住）：

```bash
SS_SOFTWARE=libev SS_PASSWORD='xxx' SS_PORT=8388 \
SS_CIPHER=aes-256-gcm SS_PLUGIN=None \
  ./shadowsocks-all.sh install
```

## 修了哪些问题（附核实依据）

| # | 问题 | 依据 | 处理 |
|---|---|---|---|
| 1 | `check_sys` 只读 `/etc/issue`，云镜像上该文件常为空；`lsb-release` 需联网安装，EOL 系统上装不上 | Debian 12/13 云镜像 `/etc/issue` 可能为空 | 改为优先读 `/etc/os-release`（`ID`/`VERSION_ID`/`VERSION_CODENAME`），再回退 `/etc/issue`、`/etc/debian_version`、`lsb_release`、内置版本号→代号映射表 |
| 2 | Debian 9/10 已 EOL，`deb.debian.org` 返回 404，`apt-get update` 直接失败 | `curl -o /dev/null -w %{http_code} https://deb.debian.org/debian/dists/{stretch,buster}/Release` → `404`；`archive.debian.org` → `200` | 首次 `apt-get update` 失败且判定为 EOL 时，生成 `/etc/apt/sources.list.d/shadowsocks-archive.list` 指向 `archive.debian.org`（含 `-security`、`-backports`），并用 `Dir::Etc::sourcelist` 独占该列表、`Acquire::Check-Valid-Until=false` 绕开过期 Release。**不改动系统原有 sources.list** |
| 3 | Teddysun 仓库没有 `stretch` 套件，Debian 9 上装不上 | `https://dl.lamp.sh/shadowsocks/debian/dists/` 只有 `buster/bullseye/bookworm/trixie` | 安装前探测套件是否存在；不存在则回落 Debian 官方/归档仓库 |
| 4 | Debian 9 主仓库的 libev 是 `2.6.3`，**完全不支持 AEAD**（无 aes-256-gcm） | `strings ss-server` 中无任何 AEAD 套件名；`stretch-backports` 里是 `3.2.5`（支持全部 AEAD） | 无 Teddysun 套件时优先 `apt-get install -t stretch-backports shadowsocks-libev`；万一仍落到 2.6.3，自动把加密方式降级为 `aes-256-cfb` 并告警 |
| 5 | 硬编码版本号 `shadowsocks-libev=3.3.6-2~debian.10~buster` 在 Debian 10 必然失败 | buster 仓库里只有 `3.3.5-12~debian.10~buster` | 不再锁定版本，交给 apt 选最高版本 |
| 6 | Teddysun 包与 Debian 包的 systemd 单元名/配置路径不同，`systemctl start shadowsocks-libev-server` 在官方包上必然失败 | Teddysun：`shadowsocks-libev-server.service` + `/etc/shadowsocks/shadowsocks-libev-config.json`；Debian：`shadowsocks-libev.service` + `/etc/shadowsocks-libev/config.json`（取自 `/etc/default/shadowsocks-libev` 的 `CONFFILE`） | 安装后探测实际单元与配置路径，二者皆可 |
| 7 | `server` 写成地址数组（`["[::0]","0.0.0.0"]`）只被 libev ≥ 3.3.0 支持 | v2.6.3/v3.2.5 源码 `jconf.c` 的 `server` 解析只接受字符串 | 仅在 libev ≥ 3.3.0 且检测到 IPv6 时使用数组 |
| 8 | 无 systemd 时（容器）服务起不来 | — | 检测不到 systemd 时用 `nohup` 直接拉起并提示 |
| 9 | `ufw status` 在未启用时也返回 0，导致上游脚本误判 | `ufw status` 退出码不反映状态 | 改为匹配 `Status: active` |
| 10 | `get_char` 在无 `/dev/tty` 时报错；交互式 `read` 在无 TTY 时永久阻塞 | — | 两者均做了无 TTY 兜底 |
| 11 | `wget` 不一定存在 | — | 下载统一走 `curl`，缺 curl 时回退 `wget` |
| 12 | **apt 的所有报错都被 `>/dev/null 2>&1` 吞掉**，装不上时完全看不出原因 | 用户实测：`[Error] Shadowsocks-libev installation failed.` 无任何细节 | 新增 `apt_install_checked`，失败时把 apt 输出（末 40 行）打到 stderr；并新增 `diagnose` 动作输出源列表、`apt-cache policy`、`apt-get --dry-run` |
| 13 | **只在 `apt-get update` 失败时才切归档源**，若系统 sources 为空/残缺，`update` 会"成功"，随后 Teddysun 包的依赖（libsodium23、libev4…）全都装不上，最终以"安装失败"收场 | 用户环境为 Debian 10 且未出现 EOL 警告 → 说明 update 返回 0，但依赖无法解析 | 改为**在首次 update 之前**就为 EOL 发行版接入 `archive.debian.org`（依赖也来自那里），不再依赖"update 失败"这一信号 |
| 14 | 安装失败后没有回退 | — | libev 安装改为 4 级回退：① apt 自行选版（Teddysun 最新）→ ② `-t <代号>-backports` → ③ `-t <代号>`（发行版自带包）→ ④ `apt-get -f install` 修复依赖后重试；仍失败则打印诊断信息 |

## 各版本最终安装来源

| 系统 | libev 来源 | 版本 | rust 来源 | 插件来源 |
|---|---|---|---|---|
| Debian 9 stretch | `archive.debian.org` + `stretch-backports` | 3.2.5（AEAD 完整） | GitHub 静态 musl 包 | GitHub 静态包 |
| Debian 10 buster | Teddysun `buster`（APT 走 archive） | 3.3.5 | Teddysun `buster` | Teddysun `buster` |
| Debian 11 bullseye | Teddysun `bullseye` | 3.3.6 | Teddysun `bullseye` | Teddysun `bullseye` |
| Debian 12 bookworm | Teddysun `bookworm` | 3.3.6 | Teddysun `bookworm` | Teddysun `bookworm` |
| Debian 13 trixie | Teddysun `trixie` | 3.3.6 | Teddysun `trixie` | Teddysun `trixie` |

GitHub 回退使用的是**静态 musl / Go 静态二进制**，不依赖 glibc，因此在老系统上同样可运行。
对应的 release 地址与包内文件名均已实测确认（HTTP 200、内部二进制名匹配）。

## 注意事项

- Debian 9/10 已 EOL，即使脚本能装成功，系统本身也不再收到安全更新，建议尽快升级。
- 归档源使用 `[trusted=yes]`（归档 Release 已过期，且 Debian 9 的 apt 不支持 https），
  这是让 EOL 系统能继续装包的常规做法，代价是跳过仓库签名校验。
- `check` 动作不需要 root，也不修改任何文件；`install` / `uninstall` 需要 root。
