#!/usr/bin/env bash
#
# GitHub Key 生成 + 推送脚本
#
# 流程（直线，无自动上传）：
#   输入用户名/邮箱 → 本机生成密钥 → 终端展示公钥
#   → 你去 GitHub 网页添加 → 回车继续 → 验证 → add/commit/push
#
# 用法：
#   bash github-ssh-push.sh                   # SSH key（默认）
#   bash github-ssh-push.sh --gpg             # 额外生成 GPG key 用于提交签名
#   bash github-ssh-push.sh --show-key        # 只展示已有公钥
#
set -euo pipefail

# ---------------------------------------------------------------- 常量
readonly SSH_DIR="${HOME}/.ssh"
readonly GITHUB_HOST="github.com"
readonly SSH_KEY_URL="https://github.com/settings/ssh/new"
readonly GPG_KEY_URL="https://github.com/settings/gpg/new"

# ---------------------------------------------------------------- 变量
GH_USER=""        # GitHub 用户名
GH_EMAIL=""       # 提交邮箱
REPO_NAME=""      # 仓库名
BRANCH=""         # 推送分支
COMMIT_MSG=""     # 提交信息
KEY_PATH=""       # SSH 私钥路径
GPG_KEY_ID=""     # GPG 密钥 ID
WITH_GPG=0        # 是否同时生成 GPG key
SHOW_KEY_ONLY=0   # 仅展示公钥后退出
ASSUME_YES=0      # 跳过确认
SSH_HOSTNAME=""   # 实际连接主机
SSH_PORT=""       # 实际连接端口

# ---------------------------------------------------------------- 输出
if [[ -t 1 ]]; then
  readonly C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YLW=$'\033[33m'
  readonly C_CYN=$'\033[36m' C_RST=$'\033[0m'
else
  readonly C_RED="" C_GRN="" C_YLW="" C_CYN="" C_RST=""
fi

log()  { printf '%s[INFO]%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
step() { printf '\n%s==> %s%s\n' "$C_CYN" "$*" "$C_RST"; }
# ---------------------------------------------------------------- 交互
# 危险操作确认：仅接受明确的肯定回答
confirm() {
  local action="$1" scope="$2" risk="$3" reply=""
  if (( ASSUME_YES )); then warn "已通过 --yes 跳过确认：${action}"; return 0; fi
  printf '\n%s⚠️  危险操作检测！%s\n' "$C_YLW" "$C_RST"
  printf '操作类型：%s\n影响范围：%s\n风险评估：%s\n\n' "$action" "$scope" "$risk"
  printf '请确认是否继续？[y/yes/是 = 继续，其它 = 中止]: '
  read -r reply || reply=""
  case "$reply" in
    y | Y | yes | YES | 是 | 确认 | 继续) return 0 ;;
    *) return 1 ;;
  esac
}

# 带默认值的必填输入
ask() {
  local prompt="$1" default="${2:-}" __out="$3" reply=""
  while :; do
    [[ -n "$default" ]] && printf '%s [%s]: ' "$prompt" "$default" || printf '%s: ' "$prompt"
    if ! read -r reply; then
      printf '\n'
      [[ -n "$default" ]] || die "非交互环境缺少输入：${prompt}（请用命令行参数传入）"
      reply=""
    fi
    reply="${reply:-$default}"
    [[ -n "$reply" ]] && break
    warn "该项不能为空。"
  done
  printf -v "$__out" '%s' "$reply"
}

# 等待用户完成网页操作
pause() {
  printf '\n%s%s%s\n按回车继续...' "$C_YLW" "$1" "$C_RST"
  read -r _ || true
}

usage() {
  cat <<'EOF'
GitHub Key 生成 + 推送脚本

流程：输入用户名/邮箱 → 本机生成密钥 → 终端展示公钥
      → 你去 GitHub 网页添加 → 回车继续 → 验证 → add/commit/push

可选参数：
  -u, --user <name>     GitHub 用户名
  -e, --email <mail>    提交邮箱
  -r, --repo <name>     仓库名（无 origin 远端时使用）
  -b, --branch <name>   推送分支（默认：当前分支）
  -m, --message <msg>   提交信息
  -k, --key <path>      SSH 私钥路径（默认：~/.ssh/id_ed25519_github）
  -g, --gpg             额外生成 GPG key 并开启提交签名
  -s, --show-key        只校验并展示已有公钥，然后退出
  -y, --yes             跳过所有确认（危险）
  -h, --help            显示帮助
EOF
}
parse_args() {
  while (( $# )); do
    case "$1" in
      -u | --user)     GH_USER="${2:?缺少用户名}"; shift 2 ;;
      -e | --email)    GH_EMAIL="${2:?缺少邮箱}"; shift 2 ;;
      -r | --repo)     REPO_NAME="${2:?缺少仓库名}"; shift 2 ;;
      -b | --branch)   BRANCH="${2:?缺少分支名}"; shift 2 ;;
      -m | --message)  COMMIT_MSG="${2:?缺少提交信息}"; shift 2 ;;
      -k | --key)      KEY_PATH="${2:?缺少密钥路径}"; shift 2 ;;
      -g | --gpg)      WITH_GPG=1; shift ;;
      -s | --show-key) SHOW_KEY_ONLY=1; shift ;;
      -y | --yes)      ASSUME_YES=1; shift ;;
      -h | --help)     usage; exit 0 ;;
      *)               die "未知参数：$1（-h 查看帮助）" ;;
    esac
  done
}

# ---------------------------------------------------------------- 1. 检查依赖
check_deps() {
  step "步骤 1/7：检查依赖"
  local missing=() cmd
  for cmd in git ssh ssh-keygen ssh-agent; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} )) && die "缺少命令：${missing[*]}
Debian/Ubuntu: apt-get install -y git openssh-client
macOS: 自带，若缺失执行 xcode-select --install"
  if (( WITH_GPG )); then
    command -v gpg >/dev/null 2>&1 || die "缺少 gpg（apt-get install -y gnupg）"
  fi
  ok "依赖就绪（git $(git --version | awk '{print $3}')）"
}

# ---------------------------------------------------------------- 2. 采集输入
collect_input() {
  step "步骤 2/7：输入身份信息"
  [[ -n "$GH_USER" ]]  || ask "GitHub 用户名" "$(git config --get user.name || true)" GH_USER
  [[ -n "$GH_EMAIL" ]] || ask "GitHub 邮箱"   "$(git config --get user.email || true)" GH_EMAIL

  [[ "$GH_EMAIL" == *@*.* ]] || die "邮箱格式不合法：$GH_EMAIL"
  [[ "$GH_USER" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || die "用户名格式不合法：$GH_USER"

  KEY_PATH="${KEY_PATH:-${SSH_DIR}/id_ed25519_github}"
  ok "用户名 ${GH_USER}｜邮箱 ${GH_EMAIL}"
}
# ---------------------------------------------------------------- 3. 生成 SSH key
generate_ssh_key() {
  step "步骤 3/7：生成 SSH 密钥（ed25519）"
  mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"

  if [[ -f "$KEY_PATH" ]]; then
    ok "密钥已存在，直接复用（不会覆盖）：${KEY_PATH}"
  else
    log "密码短语可直接回车留空，留空则 push 时无需解锁。"
    ssh-keygen -t ed25519 -C "$GH_EMAIL" -f "$KEY_PATH"
  fi
  chmod 600 "$KEY_PATH"
  [[ -f "${KEY_PATH}.pub" ]] || die "公钥缺失：${KEY_PATH}.pub"
  chmod 644 "${KEY_PATH}.pub"
  validate_public_key
}

# 校验公钥为合法 OpenSSH 单行格式
# GitHub 只接受该格式，否则报 "Key is invalid. You must supply a key in
# OpenSSH public key format"；按误用频率从高到低依次拦截
validate_public_key() {
  local pub="${KEY_PATH}.pub" first lines
  [[ -f "$pub" ]] || die "公钥文件不存在：${pub}"
  [[ -s "$pub" ]] || die "公钥文件为空：${pub}（请删除后重新生成）"

  first=$(head -n1 "$pub")
  if [[ "$first" == -----BEGIN* ]]; then
    die "${pub} 是私钥或 PEM 内容，不是 OpenSSH 公钥。私钥绝不可粘贴到 GitHub。
从私钥重新导出公钥：ssh-keygen -y -f \"${KEY_PATH}\" > \"${pub}\""
  fi

  lines=$(grep -c '' "$pub")
  (( lines == 1 )) || die "公钥必须是单行，当前 ${lines} 行。GitHub 不接受换行的 Key。"

  case "$first" in
    ssh-ed25519\ * | ssh-rsa\ * | ecdsa-sha2-*\ * | sk-*\ *) ;;
    *) die "公钥前缀不合法：${first:0:30}...
应以算法名开头（ssh-ed25519 / ssh-rsa / ecdsa-sha2-* / sk-*）。" ;;
  esac

  ssh-keygen -lf "$pub" >/dev/null 2>&1 || die "公钥内容损坏，无法解析：${pub}"
  ok "公钥格式校验通过（OpenSSH 单行，$(ssh-keygen -lf "$pub" | awk '{print $1" bit "$NF}')）"
}
# ---------------------------------------------------------------- 4. 展示公钥
# 只打印公钥本体与指纹。公钥是公开信息，可安全打印；私钥永不输出
print_public_key() {
  local pub="${KEY_PATH}.pub"
  printf '\n%s================== 复制下面这一整行 ==================%s\n' "$C_GRN" "$C_RST"
  # 独占一行、无任何前后缀，确保整行复制不会带入多余字符
  cat "$pub"
  printf '%s======================================================%s\n' "$C_GRN" "$C_RST"
  printf '  指纹：%s\n' "$(ssh-keygen -lf "$pub" | awk '{print $2}')"
  printf '  文件：%s\n' "$pub"
  printf '  添加：%s\n' "$SSH_KEY_URL"
}

show_ssh_key() {
  step "步骤 5/7：展示公钥，请到 GitHub 页面添加"
  print_public_key
  printf '\n%s操作步骤：%s\n' "$C_YLW" "$C_RST"
  printf '  1) 打开 %s\n' "$SSH_KEY_URL"
  printf '  2) Title 随意填，用于自己识别这台机器\n'
  printf '  3) Key Type 选 Authentication Key\n'
  printf '  4) Key 粘贴上面那一整行，点 Add SSH key\n'
  printf '\n若提示 Key is invalid：检查开头是否为 ssh-ed25519、是否被终端折行拆断、开头有无空格。\n'
  pause "添加完成后回车，脚本会立刻验证连接。"
}

# ---------------------------------------------------------------- 5. 配置 SSH
# 探测可用端点：优先 22，被防火墙拦截时降级到 ssh.github.com:443
# 判定依据：SSH 握手完成即可（publickey 被拒也说明链路通）
detect_ssh_endpoint() {
  local endpoint host port out
  for endpoint in "${GITHUB_HOST}:22" "ssh.${GITHUB_HOST}:443"; do
    host="${endpoint%:*}"; port="${endpoint##*:}"
    out=$(timeout 25 ssh -T -p "$port" -o StrictHostKeyChecking=accept-new \
          -o ConnectTimeout=10 -o BatchMode=yes "git@${host}" 2>&1 || true)
    if [[ "$out" == *"successfully authenticated"* || "$out" == *"Permission denied"* ]]; then
      SSH_HOSTNAME="$host"; SSH_PORT="$port"
      [[ "$port" == 443 ]] && warn "22 端口不通，改用 SSH over HTTPS（${host}:443）"
      ok "SSH 链路可达：${host}:${port}"
      return 0
    fi
  done
  warn "22 与 443 均不通，仍按默认 ${GITHUB_HOST}:22 配置"
  SSH_HOSTNAME="$GITHUB_HOST"; SSH_PORT=22
}
configure_ssh() {
  step "步骤 4/7：配置 ssh-agent 与 ssh config"

  ssh-add -l >/dev/null 2>&1 || eval "$(ssh-agent -s)" >/dev/null
  ssh-add "$KEY_PATH" 2>/dev/null && ok "私钥已加载到 ssh-agent" \
    || warn "ssh-add 未成功（可能需手动输入密码短语），不影响后续步骤"

  detect_ssh_endpoint

  local cfg="${SSH_DIR}/config"
  touch "$cfg" && chmod 600 "$cfg"
  if grep -qE "^[[:space:]]*Host[[:space:]]+${GITHUB_HOST}[[:space:]]*$" "$cfg"; then
    if [[ "$SSH_PORT" == 443 ]] && ! grep -qE "^[[:space:]]*Port[[:space:]]+443" "$cfg"; then
      warn "${cfg} 已有 ${GITHUB_HOST} 配置但未走 443，而当前网络仅 443 可用。"
      warn "请手动改为：HostName ssh.${GITHUB_HOST} / Port 443"
    else
      ok "~/.ssh/config 已有 ${GITHUB_HOST} 配置，跳过"
    fi
  else
    {
      printf '\n# --- 由 github-ssh-push.sh 添加 ---\n'
      printf 'Host %s\n'          "$GITHUB_HOST"
      printf '  HostName %s\n'    "$SSH_HOSTNAME"
      printf '  Port %s\n'        "$SSH_PORT"
      printf '  User git\n'
      printf '  IdentityFile %s\n' "$KEY_PATH"
      printf '  IdentitiesOnly yes\n'
    } >>"$cfg"
    ok "已写入 ~/.ssh/config（${SSH_HOSTNAME}:${SSH_PORT}）"
  fi

  local kh="${SSH_DIR}/known_hosts" pattern
  [[ "$SSH_PORT" == 22 ]] && pattern="$SSH_HOSTNAME" || pattern="[${SSH_HOSTNAME}]:${SSH_PORT}"
  grep -qF "$pattern" "$kh" 2>/dev/null || \
    ssh-keyscan -p "$SSH_PORT" -t rsa,ecdsa,ed25519 "$SSH_HOSTNAME" >>"$kh" 2>/dev/null || true
}

# 验证连接，未通过则允许重试（等你在网页上把 key 加好）
verify_ssh() {
  step "步骤 6/7：验证 SSH 连接"
  local out attempt=1
  while :; do
    out=$(ssh -T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
          "git@${GITHUB_HOST}" 2>&1 || true)
    if [[ "$out" == *"successfully authenticated"* ]]; then
      ok "认证成功：${out}"
      return 0
    fi
    warn "第 ${attempt} 次验证失败：${out}"
    (( attempt >= 3 )) && die "已重试 3 次仍失败。请确认公钥已出现在 https://github.com/settings/keys"
    pause "公钥可能还没添加好。请到 ${SSH_KEY_URL} 确认后重试。"
    (( attempt++ ))
  done
}
# ---------------------------------------------------------------- GPG（可选）
setup_gpg() {
  step "附加步骤：GPG 提交签名密钥"
  local list
  list=$(gpg --list-secret-keys --keyid-format=long "$GH_EMAIL" 2>/dev/null || true)
  GPG_KEY_ID=$(printf '%s\n' "$list" | awk '/^sec/{print $2}' | cut -d/ -f2 | head -n1)

  if [[ -n "$GPG_KEY_ID" ]]; then
    ok "复用已有 GPG 密钥：${GPG_KEY_ID}"
  else
    log "生成 GPG 密钥（ed25519 / 签名用途 / 2 年有效期 / 无密码短语）..."
    gpg --batch --passphrase '' --quick-generate-key \
      "${GH_USER} <${GH_EMAIL}>" ed25519 sign 2y >/dev/null 2>&1 \
      || die "GPG 密钥生成失败"
    GPG_KEY_ID=$(gpg --list-secret-keys --keyid-format=long "$GH_EMAIL" \
      | awk '/^sec/{print $2}' | cut -d/ -f2 | head -n1)
    [[ -n "$GPG_KEY_ID" ]] || die "GPG 密钥生成后无法读取 ID"
    ok "GPG 密钥已生成：${GPG_KEY_ID}"
  fi

  printf '\n%s========= 复制下面整段（含首尾 BEGIN / END 两行）=========%s\n' "$C_GRN" "$C_RST"
  gpg --armor --export "$GPG_KEY_ID"
  printf '%s=========================================================%s\n' "$C_GRN" "$C_RST"
  printf '\n%s请在 GitHub 完成添加：%s\n' "$C_YLW" "$C_RST"
  printf '  1) 打开 %s\n' "$GPG_KEY_URL"
  printf '  2) 粘贴上面整段（GPG 是多行，与 SSH 不同），点 Add GPG key\n'
  pause "添加完成后回车继续。"

  git config user.signingkey "$GPG_KEY_ID"
  git config commit.gpgsign true
  ok "已对本仓库开启提交签名（signingkey=${GPG_KEY_ID}）"
}

# ---------------------------------------------------------------- 7. git 与推送
configure_git() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "当前目录不是 git 仓库，请先执行 git init"

  # 仓库级配置，不污染全局
  git config user.name  "$GH_USER"
  git config user.email "$GH_EMAIL"
  ok "已设置仓库级 user.name / user.email"

  local url path
  if url=$(git remote get-url origin 2>/dev/null); then
    case "$url" in
      git@${GITHUB_HOST}:*)
        ok "origin 已是 SSH：${url}" ;;
      https://${GITHUB_HOST}/*)
        path="${url#https://${GITHUB_HOST}/}"; path="${path%.git}"
        git remote set-url origin "git@${GITHUB_HOST}:${path}.git"
        ok "origin 由 HTTPS 切换为 SSH：git@${GITHUB_HOST}:${path}.git" ;;
      *)
        warn "origin 非 GitHub 地址，保持不变：${url}" ;;
    esac
  else
    [[ -n "$REPO_NAME" ]] || ask "未检测到 origin，请输入 GitHub 仓库名" "$(basename "$PWD")" REPO_NAME
    git remote add origin "git@${GITHUB_HOST}:${GH_USER}/${REPO_NAME}.git"
    ok "已添加 origin：git@${GITHUB_HOST}:${GH_USER}/${REPO_NAME}.git"
  fi
}
# 提交前扫描暂存区，避免凭据被推上去
scan_secrets() {
  local hits
  hits=$(git diff --cached --name-only | grep -Ei \
    '(^|/)(\.env|\.env\..*|id_rsa|id_ed25519|.*\.pem|.*\.p12|.*\.keystore|credentials(\.json)?)$' || true)
  [[ -z "$hits" ]] && return 0
  warn "暂存区包含疑似敏感文件："
  printf '%s\n' "$hits" | sed 's/^/  - /'
  confirm "提交疑似敏感文件" "上述文件将写入 git 历史并推送到 GitHub" \
          "凭据一旦推送即视为泄露，需重新签发；建议先加入 .gitignore" \
    || die "已中止。执行 git restore --staged <文件> 后重试。"
}

commit_and_push() {
  BRANCH="${BRANCH:-$(git symbolic-ref --short HEAD 2>/dev/null || echo main)}"
  COMMIT_MSG="${COMMIT_MSG:-chore: initial commit}"

  if [[ -n "$(git status --porcelain)" ]]; then
    printf '\n当前改动：\n'
    git status --short
    confirm "git add -A + git commit" "上述全部改动将被暂存并生成一次提交" \
            "提交会写入本地历史，推送后不可静默撤销" \
      || die "已中止，未做任何提交。"
    git add -A || die "git add 失败，请检查上方输出。"
    scan_secrets
    # 显式判断而非依赖 set -e：commit 失败时必须停在这里，不能带着空提交去 push
    git commit -m "$COMMIT_MSG" \
      || die "git commit 失败。常见原因：未配置 user.name/user.email，或没有实际可提交的改动。"
    ok "已提交：$(git log -1 --oneline)"
  else
    log "工作区干净，跳过提交"
    git rev-parse HEAD >/dev/null 2>&1 || die "仓库没有任何提交，无内容可推送。"
  fi

  # 从 origin URL 解析 owner/repo，避免与 GH_USER 不一致时拼错
  local target
  target=$(git remote get-url origin)
  target="${target#git@${GITHUB_HOST}:}"
  target="${target#https://${GITHUB_HOST}/}"
  target="${target%.git}"

  confirm "git push -u origin ${BRANCH}" \
          "本地 ${BRANCH} 分支将推送到远端 ${target}" \
          "推送后远端历史对协作者可见，撤销需强制推送" \
    || die "已中止，未推送。"

  if git push -u origin "$BRANCH"; then
    ok "推送成功：https://github.com/${target}/tree/${BRANCH}"
  else
    die "推送失败，常见原因：
  1) 远端仓库不存在 → 先在 https://github.com/new 创建 ${target}
  2) 远端已有提交    → git pull --rebase origin ${BRANCH}
  3) 无写入权限      → 确认 ${GH_USER} 对该仓库有 push 权限"
  fi
}

# ---------------------------------------------------------------- 主流程
main() {
  parse_args "$@"

  # --show-key：只校验并展示已有公钥，不改动任何配置
  if (( SHOW_KEY_ONLY )); then
    KEY_PATH="${KEY_PATH:-${SSH_DIR}/id_ed25519_github}"
    validate_public_key
    print_public_key
    exit 0
  fi

  printf '%s=== GitHub Key 生成 + 推送 ===%s\n' "$C_CYN" "$C_RST"
  check_deps
  collect_input
  generate_ssh_key
  configure_ssh
  show_ssh_key
  verify_ssh
  step "步骤 7/7：配置 git 并推送"
  configure_git
  if (( WITH_GPG )); then setup_gpg; fi
  commit_and_push
  printf '\n'; ok "全部完成。"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
