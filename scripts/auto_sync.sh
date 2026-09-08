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
#   bash scripts/auto_sync.sh                       # 同步一次
#   bash scripts/auto_sync.sh --loop 1800           # 无 cron 环境下自带循环
#   bash scripts/auto_sync.sh --install-cron 1440   # 装 crontab，每天一次（当前配置）
#   bash scripts/auto_sync.sh --uninstall-cron      # 移除 crontab 条目
#   bash scripts/auto_sync.sh --run-pipeline sub.md # 同步前先重跑订阅流水线
#   bash scripts/auto_sync.sh --dry-run             # 只看会做什么，不提交不推送
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
  "scripts/gen_readme.sh"
)

DRY_RUN=0
WITH_REPORT=0
GEN_README=1
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

# 同时写终端与日志，cron 下无终端也能留痕。
#
# 但 crontab 那行本身就带 >> $LOG_FILE，此时 tee 与重定向指向同一个文件，
# 每条日志会落盘两遍 —— 实测 290 行里只有 164 行是唯一的。
# 所以先比较 stdout 与日志文件的 inode，已经是同一个文件就不再 tee。
# 不能直接 stat /dev/stdout：命令替换 $(...) 本身会把 stdout 接成管道，
# 探到的永远是那个管道（device 12 pipefs）而不是真正的输出目标。
# 先把 fd 1 复制到一个空闲描述符，子进程继承后再 stat /proc/self/fd/N 才能看到原始目标。
# 这里用 fd 8 而不是 9：fd 9 归 main 里的 flock 长期占用，两处复用同一个
# 描述符的话，一旦将来有人在中间插入代码，锁会静默失效而不是报错
_same_file() {
  local a b
  exec 8>&1 || return 1
  a=$(stat -Lc '%d:%i' /proc/self/fd/8 2>/dev/null) || true
  exec 8>&-
  b=$(stat -Lc '%d:%i' "$LOG_FILE" 2>/dev/null) || true
  [[ -n "$a" && "$a" == "$b" ]]
}
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
if _same_file; then
  _emit() { cat; }            # stdout 已重定向到日志文件，直接输出即可
else
  _emit() { tee -a "$LOG_FILE"; }
fi

_stamp() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s[%s INFO]%s %s\n' "$C_CYN" "$(_stamp)" "$C_RST" "$*" | _emit; }
ok()   { printf '%s[%s  OK ]%s %s\n' "$C_GRN" "$(_stamp)" "$C_RST" "$*" | _emit; }
warn() { printf '%s[%s WARN]%s %s\n' "$C_YLW" "$(_stamp)" "$C_RST" "$*" | _emit >&2; }
die()  { printf '%s[%s FAIL]%s %s\n' "$C_RED" "$(_stamp)" "$C_RST" "$*" | _emit >&2; exit 1; }

usage() {
  cat <<'EOF'
自动同步本地产物到 GitHub（幂等，本地优先）

可选参数：
  --loop <秒>          自带循环，用于没有 cron 的环境（如精简容器）
  --install-cron <分>  安装 crontab 条目，每 N 分钟同步一次，并拉起 cron 守护进程
                       传 1440 及以上按每天一次处理，落到随机时刻错峰
  --uninstall-cron     移除本脚本的 crontab 条目
  --run-pipeline "源…" 同步前先跑一次订阅流水线重新生成 sub.txt
  --with-report        同时提交 sub_report.tsv（内含真实出口 IP，公开仓库慎用）
  --no-readme          跳过 README.md 自动刷新（默认每次同步前刷新）
  --dry-run            只打印将要执行的操作，不提交不推送
  -h, --help           显示帮助

环境变量：
  AUTO_SYNC_REPO     仓库路径（默认取脚本所在仓库）
  AUTO_SYNC_BRANCH   目标分支（默认 main）
  AUTO_SYNC_LOG      日志路径（默认 <仓库>/.auto_sync.log）
  AUTO_SYNC_LOG_MAX  日志行数上限，超过则截半保留尾部（默认 2000）
EOF
}

# 参数校验：非数字进到 (( )) 里会被当成变量名，set -u 下报
# "abc: unbound variable"，错误信息完全指不到真正的原因
num_or_die() {
  [[ "$2" =~ ^[0-9]+$ ]] || die "${1} 需要正整数，收到：${2}"
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --loop)          num_or_die --loop "${2:?缺少秒数}"
                       LOOP_SECONDS="$2"; shift 2 ;;
      --install-cron)  num_or_die --install-cron "${2:?缺少分钟数}"
                       INSTALL_CRON="$2"; shift 2 ;;
      --uninstall-cron) INSTALL_CRON="remove"; shift ;;
      --run-pipeline)  RUN_PIPELINE="${2:?缺少订阅来源}"; shift 2 ;;
      --with-report)   WITH_REPORT=1; shift ;;
      --no-readme)     GEN_README=0; shift ;;
      --dry-run)       DRY_RUN=1; shift ;;
      -h | --help)     usage; exit 0 ;;
      *)               die "未知参数：$1（-h 查看帮助）" ;;
    esac
  done
  (( WITH_REPORT )) && TRACKED+=("sub_report.tsv")
  return 0
}
# ---------------------------------------------------------------- 前置检查
# 只做本地检查。凡是需要网络的判断都不放这里 —— 见下面的 ssh_ready
preflight() {
  [[ -d "$REPO_DIR/.git" ]] || die "不是 git 仓库：${REPO_DIR}"
  cd "$REPO_DIR"
  command -v git >/dev/null || die "找不到 git"

  local cur
  cur=$(git rev-parse --abbrev-ref HEAD)
  [[ "$cur" == "$BRANCH" ]] || die "当前在 ${cur} 分支，预期 ${BRANCH}。请先切换或改 AUTO_SYNC_BRANCH"

  git remote get-url origin >/dev/null 2>&1 || die "未配置 origin 远端"

  # 提交身份必须存在，否则 commit 会失败
  git config user.name  >/dev/null || die "未配置 user.name（git config user.name <名字>）"
  git config user.email >/dev/null || die "未配置 user.email"
}

# SSH 可用性探测，且刻意不是硬失败。
#
# 原来这段写在 preflight 里直接 die：网络抖一下，README 采集和订阅流水线
# 也一起丢了 —— 而这两件事根本不需要网络出得去。现在探测结果只决定是否
# 跳过 fetch/push，本地该做的照做，提交留在本地，下一轮连同本次一起推。
# 一次运行只探一次：结果缓存进 SSH_STATE，loop 模式下不会反复握手
SSH_STATE=""
SSH_PROBE=""
ssh_ready() {
  if [[ -z "$SSH_STATE" ]]; then
    # cron 环境没有 ssh-agent，依赖 ~/.ssh/config 里的 IdentityFile + 无密码密钥
    SSH_PROBE=$(ssh -T -o BatchMode=yes -o ConnectTimeout=15 git@github.com 2>&1 || true)
    if [[ "$SSH_PROBE" == *"successfully authenticated"* ]]; then
      SSH_STATE=0
    else
      SSH_STATE=1
      # 密钥问题和网络问题的处置完全不同，提示要分得开
      case "$SSH_PROBE" in
        *"publickey"* | *"Permission denied"*)
          warn "SSH 认证被拒，密钥未被 GitHub 接受。若密钥设了密码短语，cron 环境无法解锁，请改用无密码短语的部署密钥" ;;
        *) warn "SSH 连不上 github.com（多为网络问题，会自行恢复）" ;;
      esac
      warn "  | ${SSH_PROBE:-无输出}"
    fi
  fi
  return "$SSH_STATE"
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
# 只暂存白名单里确实存在且有变化的文件。
# 顺手记下实际暂存了哪些 —— dry-run 回滚时只动这几个，不碰别人的暂存区
STAGED_FILES=()
stage_changes() {
  local file
  STAGED_FILES=()
  for file in "${TRACKED[@]}"; do
    [[ -e "$file" ]] || continue
    if ! git diff --quiet HEAD -- "$file" 2>/dev/null || \
       [[ -n "$(git ls-files --others --exclude-standard -- "$file")" ]]; then
      git add -- "$file"
      STAGED_FILES+=("$file")
    fi
  done
  (( ${#STAGED_FILES[@]} ))
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
    # 只回滚自己刚暂存的那几个文件。原来是 git reset HEAD -- .，作用域是整个
    # 仓库 —— --dry-run 号称什么都不改，实际会清掉用户手工 add 的内容
    git reset --quiet HEAD -- "${STAGED_FILES[@]}" 2>/dev/null || true
    return 0
  fi

  local msg
  msg="chore: sync subscription output $(date '+%Y-%m-%d %H:%M %Z')"
  git commit --quiet -m "$msg" || die "git commit 失败"
  ok "已提交：$(git log -1 --oneline)"

  # 推送需要网络，本地提交不需要。SSH 不通时提交先落地，
  # 下一轮 cron 会把积压的提交一起推上去，采集结果不会丢
  if ! ssh_ready; then
    warn "SSH 不可用，已本地提交但未推送，下一轮会连同本次一起推"
    return 0
  fi

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
    # 卸载路径要在算术之前提前返回：minutes 此时是字符串 remove，
    # $((minutes * 60)) 会在 set -u 下报 "remove: unbound variable"，
    # 把真正该给出的提示整条顶掉
    if [[ "$minutes" == "remove" ]]; then
      ok "系统没有 crontab，也就没有条目可移除"
      return 0
    fi
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

  # 避开整点 0 分与半点：这两个时刻人人都写，错峰能减少集中请求
  local expr min hour
  min=$(( RANDOM % 60 ))
  (( min == 0 || min == 30 )) && min=7

  if (( minutes >= 1440 )); then
    # 一天及以上：固定到每天某个时刻。小时字段上限是 23，
    # 原来一律写 */$((minutes/60))，minutes=1440 会得到 */24 —— 超出字段范围，
    # 实际只在 0 点匹配，看着像"每天"其实是撞巧。这里直接落到具体小时
    hour=$(( RANDOM % 24 ))
    expr="${min} ${hour} * * *"
  elif (( minutes >= 60 )); then
    expr="${min} */$(( minutes / 60 )) * * *"
  else
    expr="${min}-59/${minutes} * * * *"
  fi

  {
    [[ -n "$existing" ]] && printf '%s\n' "$existing"
    printf '%s\n' "$CRON_MARK"
    printf '%s cd %q && /usr/bin/env bash scripts/auto_sync.sh >> %q 2>&1\n' \
      "$expr" "$REPO_DIR" "$LOG_FILE"
  } | crontab -
  if (( minutes >= 1440 )); then
    ok "已写入 crontab：${expr}（每天 $(printf '%02d:%02d' "$hour" "$min")）"
  else
    ok "已写入 crontab：${expr}（每 ${minutes} 分钟）"
  fi

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
# README 里的环境信息由 gen_readme.sh 实时采集，内容无实质变化时它不会动文件，
# 所以这里每次都跑也不会产生只有时间戳差异的空洞提交
refresh_readme() {
  local gen="${REPO_DIR}/scripts/gen_readme.sh"
  [[ -x "$gen" ]] || return 0
  if (( DRY_RUN )); then
    log "[dry-run] 将刷新 README.md"
    return 0
  fi
  local out rc
  out=$(bash "$gen" 2>&1) && rc=0 || rc=$?
  if (( rc == 0 )); then
    log "README: $(printf '%s' "$out" | head -1)"
    return 0
  fi
  # 原来只记 tail -1：脚本在 set -e 下中途退出时末行往往是空的，
  # 日志里只剩一句没有下文的"生成失败"，白丢了 8 天的诊断线索。
  # 现在记退出码 + 全部输出（逐行加前缀，避免多行日志串行难读）
  warn "README 生成失败（退出码 ${rc}）"
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out" | while IFS= read -r l; do warn "  | ${l}"; done
  else
    warn "  | 无任何输出，脚本可能在采集阶段被 set -e 中断"
  fi
}

sync_once() {
  preflight
  # 先与远端对齐，再生成 README。反过来的话 README 是按旧基线算出来的，
  # 远端刚动过同一个文件时反而要走"冲突取本地"那条路，白折腾一轮 rebase。
  # SSH 不通就跳过这一步：本地采集与提交照做，不受网络牵连
  if ssh_ready; then
    sync_with_remote
  else
    warn "跳过与远端对齐，本轮只做本地采集与提交"
  fi
  if (( GEN_README )); then refresh_readme; fi
  [[ -n "$RUN_PIPELINE" ]] && run_pipeline "$RUN_PIPELINE"
  commit_and_push
}

# 日志无人清理会一直长。按行数截断而非按大小，避免把一行日志切成两半；
# 保留尾部即最近的记录，早期记录对排查已无价值
readonly LOG_MAX_LINES="${AUTO_SYNC_LOG_MAX:-2000}"
rotate_log() {
  local n tmp
  n=$(wc -l <"$LOG_FILE" 2>/dev/null || echo 0)
  (( n > LOG_MAX_LINES )) || return 0
  tmp=$(mktemp) || return 0
  tail -n "$(( LOG_MAX_LINES / 2 ))" "$LOG_FILE" >"$tmp" 2>/dev/null &&
    mv "$tmp" "$LOG_FILE" &&
    log "日志已截断：${n} 行 → $(wc -l <"$LOG_FILE" | xargs) 行（上限 ${LOG_MAX_LINES}）"
  rm -f "$tmp" 2>/dev/null || true
}

main() {
  parse_args "$@"
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  rotate_log

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
