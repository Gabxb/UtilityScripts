#!/usr/bin/env bash
#
# 自动同步：把本地产物推到 GitHub，冲突时以本地为准
#
# 设计前提：
#   · 幂等 —— 没有变化就什么都不做，不产生空提交，可放心让 cron 反复跑
#   · 本地优先 —— 产物是本机重新生成的，远端同名文件冲突时一律用本地版本
#   · 白名单 —— 只提交明确列出的文件，避免把缓存/私有目录带上公开仓库
#   · 串行 —— flock 加锁，cron 周期短于单次耗时也不会重叠执行
#
# 用法：
#   bash scripts/auto_sync.sh                     # 同步一次
#   bash scripts/auto_sync.sh --loop 1800         # 无 cron 环境下自带循环
#   bash scripts/auto_sync.sh --install-cron 30   # 装 crontab，每 30 分钟一次
#   bash scripts/auto_sync.sh --dry-run           # 只看会做什么，不提交不推送
#
set -euo pipefail

# cron 的 PATH 极简，显式补全，否则找不到 git/ssh
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

readonly REPO_DIR="${AUTO_SYNC_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly BRANCH="${AUTO_SYNC_BRANCH:-main}"
readonly LOCK_FILE="/tmp/auto_sync_$(echo "$REPO_DIR" | md5sum | cut -c1-12).lock"
readonly LOG_FILE="${AUTO_SYNC_LOG:-${REPO_DIR}/.auto_sync.log}"

# 要同步的文件白名单。sub_report.tsv 默认不含 —— 它记录了每个节点的真实
# 出口 IP，推到公开仓库等于公开落地服务器，需要时用 --with-report 显式加上
TRACKED=(
  ".gitignore"
  "README.md"
  "sub.txt"
  "sub_alive.txt"
  "scripts/subs_pipeline.py"
  "scripts/normalize_subs.py"
  "scripts/probe_nodes.py"
  "scripts/github-ssh-push.sh"
  "scripts/auto_sync.sh"
)

DRY_RUN=0
WITH_REPORT=0
LOOP_SECONDS=0
INSTALL_CRON=""
RUN_PIPELINE=""
# ---------------------------------------------------------------- 输出
if [[ -t 1 ]]; then
  readonly C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YLW=$'\033[33m'
  readonly C_CYN=$'\033[36m' C_RST=$'\033[0m'
else
  readonly C_RED="" C_GRN="" C_YLW="" C_CYN="" C_RST=""
fi

# 同时写终端与日志，cron 下无终端也能留痕
_stamp() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s[%s INFO]%s %s\n' "$C_CYN" "$(_stamp)" "$C_RST" "$*" | tee -a "$LOG_FILE"; }
ok()   { printf '%s[%s  OK ]%s %s\n' "$C_GRN" "$(_stamp)" "$C_RST" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '%s[%s WARN]%s %s\n' "$C_YLW" "$(_stamp)" "$C_RST" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { printf '%s[%s FAIL]%s %s\n' "$C_RED" "$(_stamp)" "$C_RST" "$*" | tee -a "$LOG_FILE" >&2; exit 1; }

usage() {
  cat <<'EOF'
自动同步本地产物到 GitHub（幂等，本地优先）

可选参数：
  --loop <秒>          自带循环，用于没有 cron 的环境（如精简容器）
  --install-cron <分>  安装 crontab 条目，每 N 分钟同步一次，并拉起 cron 守护进程
  --uninstall-cron     移除本脚本的 crontab 条目
  --run-pipeline "源…" 同步前先跑一次订阅流水线重新生成 sub.txt
  --with-report        同时提交 sub_report.tsv（内含真实出口 IP，公开仓库慎用）
  --dry-run            只打印将要执行的操作，不提交不推送
  -h, --help           显示帮助

环境变量：
  AUTO_SYNC_REPO    仓库路径（默认取脚本所在仓库）
  AUTO_SYNC_BRANCH  目标分支（默认 main）
  AUTO_SYNC_LOG     日志路径（默认 <仓库>/.auto_sync.log）
EOF
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --loop)          LOOP_SECONDS="${2:?缺少秒数}"; shift 2 ;;
      --install-cron)  INSTALL_CRON="${2:?缺少分钟数}"; shift 2 ;;
      --uninstall-cron) INSTALL_CRON="remove"; shift ;;
      --run-pipeline)  RUN_PIPELINE="${2:?缺少订阅来源}"; shift 2 ;;
      --with-report)   WITH_REPORT=1; shift ;;
      --dry-run)       DRY_RUN=1; shift ;;
      -h | --help)     usage; exit 0 ;;
      *)               die "未知参数：$1（-h 查看帮助）" ;;
    esac
  done
  (( WITH_REPORT )) && TRACKED+=("sub_report.tsv")
  return 0
}
# ---------------------------------------------------------------- 前置检查
preflight() {
  [[ -d "$REPO_DIR/.git" ]] || die "不是 git 仓库：${REPO_DIR}"
  cd "$REPO_DIR"
  command -v git >/dev/null || die "找不到 git"

  local cur
  cur=$(git rev-parse --abbrev-ref HEAD)
  [[ "$cur" == "$BRANCH" ]] || die "当前在 ${cur} 分支，预期 ${BRANCH}。请先切换或改 AUTO_SYNC_BRANCH"

  git remote get-url origin >/dev/null 2>&1 || die "未配置 origin 远端"

  # cron 环境没有 ssh-agent，依赖 ~/.ssh/config 里的 IdentityFile + 无密码密钥
  local probe
  probe=$(ssh -T -o BatchMode=yes -o ConnectTimeout=15 git@github.com 2>&1 || true)
  [[ "$probe" == *"successfully authenticated"* ]] \
    || die "SSH 认证失败，无法推送：${probe}
若密钥设了密码短语，cron 环境无法解锁，请改用无密码短语的部署密钥。"

  # 提交身份必须存在，否则 commit 会失败
  git config user.name  >/dev/null || die "未配置 user.name（git config user.name <名字>）"
  git config user.email >/dev/null || die "未配置 user.email"
}

# 与远端对齐：远端有新提交时 rebase，产物文件冲突一律取本地
sync_with_remote() {
  git fetch --quiet origin "$BRANCH" || die "git fetch 失败"

  local behind
  behind=$(git rev-list --count "HEAD..origin/${BRANCH}")
  (( behind == 0 )) && return 0

  log "远端有 ${behind} 个新提交，先对齐"
  if (( DRY_RUN )); then
    log "[dry-run] 将执行 git rebase origin/${BRANCH}"
    return 0
  fi

  if git rebase "origin/${BRANCH}" >/dev/null 2>&1; then
    ok "已 rebase 到 origin/${BRANCH}"
    return 0
  fi

  # rebase 冲突：产物文件按「本地为准」解决，其余交给人处理
  warn "rebase 出现冲突，对产物文件采用本地版本"
  local conflicted resolved=1
  conflicted=$(git diff --name-only --diff-filter=U)
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if printf '%s\n' "${TRACKED[@]}" | grep -qxF "$file"; then
      # 注意：rebase 期间 --theirs 指的是正在重放的本地提交，
      # --ours 反而是远端分支，与 merge 时的语义正好相反
      git checkout --theirs -- "$file" 2>/dev/null || { resolved=0; continue; }
      git add -- "$file"
      log "  冲突文件取本地版本：${file}"
    else
      warn "  非产物文件冲突，无法自动处理：${file}"
      resolved=0
    fi
  done <<<"$conflicted"

  if (( resolved )); then
    GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || {
      git rebase --abort 2>/dev/null || true
      die "rebase --continue 失败，已回滚，请手工处理"
    }
    ok "冲突已按本地优先解决"
  else
    git rebase --abort 2>/dev/null || true
    die "存在无法自动解决的冲突，已回滚 rebase"
  fi
}
# ---------------------------------------------------------------- 提交与推送
# 只暂存白名单里确实存在且有变化的文件
stage_changes() {
  local staged=0 file
  for file in "${TRACKED[@]}"; do
    [[ -e "$file" ]] || continue
    if ! git diff --quiet HEAD -- "$file" 2>/dev/null || \
       [[ -n "$(git ls-files --others --exclude-standard -- "$file")" ]]; then
      git add -- "$file"
      staged=1
    fi
  done
  (( staged ))
}

commit_and_push() {
  if ! stage_changes; then
    log "白名单文件无变化，跳过（无需提交）"
    return 0
  fi

  local summary
  summary=$(git diff --cached --stat | tail -1)
  log "待提交：$(git diff --cached --name-only | tr '\n' ' ')"

  if (( DRY_RUN )); then
    log "[dry-run] 将提交并推送到 origin/${BRANCH}：${summary}"
    git reset --quiet HEAD -- . 2>/dev/null || true
    return 0
  fi

  local msg
  msg="chore: sync subscription output $(date '+%Y-%m-%d %H:%M %Z')"
  git commit --quiet -m "$msg" || die "git commit 失败"
  ok "已提交：$(git log -1 --oneline)"

  if git push --quiet origin "$BRANCH" 2>/dev/null; then
    ok "推送成功 → origin/${BRANCH}（${summary}）"
    return 0
  fi

  # 推送失败多半是期间远端又有了新提交，对齐一次后重试
  warn "推送被拒，重新对齐远端后重试"
  sync_with_remote
  git push origin "$BRANCH" || die "重试后仍推送失败，请手工检查"
  ok "重试后推送成功 → origin/${BRANCH}"
}

run_pipeline() {
  local sources="$1"
  command -v python3 >/dev/null || die "找不到 python3，无法跑流水线"
  log "先跑订阅流水线：${sources}"
  if (( DRY_RUN )); then
    log "[dry-run] 将执行 python3 scripts/subs_pipeline.py ${sources}"
    return 0
  fi
  # shellcheck disable=SC2086
  python3 "${REPO_DIR}/scripts/subs_pipeline.py" $sources \
      -o "${REPO_DIR}/sub.txt" -a "${REPO_DIR}/sub_alive.txt" \
      -r "${REPO_DIR}/sub_report.tsv" >>"$LOG_FILE" 2>&1 \
    || warn "流水线执行失败，仍继续同步已有产物（详见 ${LOG_FILE}）"
}
# ---------------------------------------------------------------- 定时任务
readonly CRON_MARK="# auto_sync.sh (managed)"

manage_cron() {
  local minutes="$1"
  if ! command -v crontab >/dev/null 2>&1; then
    warn "系统没有 crontab。Debian/Ubuntu 装法：apt-get install -y cron"
    warn "容器里没有 systemd，装完需手动拉起守护进程：cron"
    warn "不想装 cron 的话，用自带循环：bash scripts/auto_sync.sh --loop $((minutes * 60)) &"
    return 1
  fi

  local existing
  existing=$(crontab -l 2>/dev/null | grep -vF "$CRON_MARK" | grep -v 'auto_sync\.sh' || true)

  if [[ "$minutes" == "remove" ]]; then
    printf '%s\n' "$existing" | crontab -
    ok "已移除 auto_sync 的 crontab 条目"
    return 0
  fi

  # 避开整点 0 分：所有人都写 0 分，错峰能减少同一时刻的集中请求
  local offset=$(( (RANDOM % (minutes > 1 ? minutes : 2)) ))
  local expr
  if (( minutes >= 60 )); then
    expr="${offset} */$(( minutes / 60 )) * * *"
  else
    expr="${offset}-59/${minutes} * * * *"
  fi

  {
    [[ -n "$existing" ]] && printf '%s\n' "$existing"
    printf '%s\n' "$CRON_MARK"
    printf '%s cd %q && /usr/bin/env bash scripts/auto_sync.sh >> %q 2>&1\n' \
      "$expr" "$REPO_DIR" "$LOG_FILE"
  } | crontab -
  ok "已写入 crontab：${expr}（每 ${minutes} 分钟）"

  pgrep -x cron >/dev/null 2>&1 || {
    cron 2>/dev/null && ok "已拉起 cron 守护进程" \
      || warn "cron 守护进程未启动，手动执行：cron"
  }
  crontab -l | tail -3
}

loop_forever() {
  local interval="$1"
  log "进入循环模式，每 ${interval} 秒同步一次（Ctrl-C 退出）"
  while :; do
    sync_once || warn "本轮同步失败，${interval} 秒后重试"
    sleep "$interval"
  done
}
# ---------------------------------------------------------------- 主流程
sync_once() {
  preflight
  [[ -n "$RUN_PIPELINE" ]] && run_pipeline "$RUN_PIPELINE"
  sync_with_remote
  commit_and_push
}

main() {
  parse_args "$@"
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  if [[ -n "$INSTALL_CRON" ]]; then
    manage_cron "$INSTALL_CRON"
    exit $?
  fi

  # flock 保证同一仓库只有一个同步在跑，cron 周期短于单次耗时也安全
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
      log "已有同步在运行（锁：${LOCK_FILE}），本次跳过"
      exit 0
    fi
  fi

  if (( LOOP_SECONDS > 0 )); then
    loop_forever "$LOOP_SECONDS"
  else
    sync_once
  fi
}

main "$@"
