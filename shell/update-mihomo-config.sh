#!/usr/bin/env bash
#
# update-mihomo-config.sh
# -----------------------------------------------------------------------------
# 合併版腳本，取代以下兩支舊腳本（舊腳本保留作備份，不用再跑）：
#   - update-subconverter-config.sh（同步 GitHub 模板）
#   - update-clash-config.sh（拉取訂閱、重啟、驗證、回滾）
#
# 流程分兩個階段，一次跑完：
#   Phase A — 同步模板：檢查 GitHub gnowmil/proxy 的 conf/ 有沒有更新，
#     有更新才拉取、注入 secret、備份後覆蓋到 /usr/local/bin/subconverter/。
#     模板沒有更新時跳過這一段，不會因此退出，照樣繼續 Phase B，
#     因為訂閱節點本身每天都可能變。
#   Phase B — 拉取訂閱：從 subconverter 下載新設定，先驗證再覆蓋，
#     然後重啟 mihomo、等它起來並做健康檢查，失敗時自動回滾。
#
# 驗證與回滾（都在 Phase B）：
#   覆蓋前：下載失敗、檔案太小、是 HTML 報錯頁、缺少 proxies / proxy-groups /
#     rules，或 mihomo -t 不通過時，全部直接中止，正式設定檔和正在跑的服務不動；
#     如果是 mihomo -t 不通過，而且這次 Phase A 剛換過模板，會同時把模板還原，
#     因為新模板本身很可能就是令設定檔不通過的原因。
#   覆蓋後：重啟失敗或健康檢查失敗時，自動還原正式設定檔（Phase B 備份），
#     同時還原這次換過的模板，再重啟一次並驗證。
#
# 部署位置（在 mihomo 閘道機 10.0.0.2 上，Debian 13，以 root 執行）：
#   sudo install -m 755 update-mihomo-config.sh /usr/local/bin/update-mihomo-config.sh
#   sudo /usr/local/bin/update-mihomo-config.sh
#
# 依賴：只有 bash、git、curl 與 Debian 自帶的 coreutils 和 systemd，
#   不用 Python、不用 yq，網關不用為這個腳本多裝東西。
#
# 退出碼：0 成功；1 下載／驗證失敗，或重啟失敗但回滾成功；2 回滾也失敗，需人手處理。
#
# 2026-11-05 修復：(1) 健康檢查改為輪詢端口最多 30 秒，唔再重啟後即刻查一次就判失敗；
# (2) Phase A 加測目標模板同 origin/main 的檔案內容係咪一致，回滾後唔會因為 HEAD 相同而跳過再部署。
#
set -euo pipefail
IFS=$'\n\t'

# ============================================================ 在這裏改設定 ==
# 只填這兩個欄位就好，全部放在最前面，打開檔案不用往下翻。
# 這個檔案本身不要提交到 Git 倉庫。
# MIHOMO_SECRET：留空時，正式部署的模板同樣是 secret: ''。
# SUB_PROFILE_URL：subconverter 的訂閱連結，留空時執行會直接退出並說明原因。
#   不要把真密碼或訂閱連結以命令列參數傳入（會出現在 ps / shell history 裏）。
MIHOMO_SECRET="${MIHOMO_SECRET:-}"
SUB_PROFILE_URL="${SUB_PROFILE_URL:-}"
# ============================================================ 在這裏改設定 ==

# ---------------------------------------------------------------- 可調變量 ---
# 除了上面兩個，其餘都可以用環境變量覆蓋，例如：
#   REPO_DIR=/tmp/test-proxy ./update-mihomo-config.sh --dry-run
REPO_URL="${REPO_URL:-https://github.com/gnowmil/proxy.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_DIR="${REPO_DIR:-/usr/local/bin/proxy-conf}"

BASE_SRC_REL="${BASE_SRC_REL:-conf/base/base_tun.yml}"
INI_SRC_REL="${INI_SRC_REL:-conf/config/mihomo.conf.ini}"

SUBCONVERTER_DIR="${SUBCONVERTER_DIR:-/usr/local/bin/subconverter}"
DEST_BASE_DIR="${DEST_BASE_DIR:-$SUBCONVERTER_DIR/base}"
DEST_INI_DIR="${DEST_INI_DIR:-$SUBCONVERTER_DIR/config}"
DEST_BASE_FILE="${DEST_BASE_FILE:-$DEST_BASE_DIR/base_tun.yml}"
DEST_INI_FILE="${DEST_INI_FILE:-$DEST_INI_DIR/mihomo.conf.ini}"
TEMPLATE_BACKUP_ROOT="${TEMPLATE_BACKUP_ROOT:-$SUBCONVERTER_DIR/backup}"
KEEP_TEMPLATE_BACKUPS="${KEEP_TEMPLATE_BACKUPS:-7}"

# 正式設定檔與 mihomo 服務。
CLASH_CONFIG_FILE="${CLASH_CONFIG_FILE:-/etc/mihomo/config.yaml}"
# MIHOMO_HOME 未設定時，取正式設定檔所在的目錄（預設 /etc/mihomo），跟服務的 -d 一致。
MIHOMO_HOME="${MIHOMO_HOME:-}"
if [ -z "$MIHOMO_HOME" ]; then
    MIHOMO_HOME="$(dirname "$CLASH_CONFIG_FILE")"
fi
MIHOMO_SERVICE="${MIHOMO_SERVICE:-mihomo.service}"
MIHOMO_BIN="${MIHOMO_BIN:-mihomo}"
MIHOMO_MIXED_PORT="${MIHOMO_MIXED_PORT:-7897}"
# 下載到的臨時檔，放在正式設定檔同一目錄，mv 才是同一檔案系統內的原子換檔。
TEMP_CONFIG="${TEMP_CONFIG:-/etc/mihomo/.config.yaml.tmp.$$}"
# 正式設定檔的備份目錄。
BACKUP_DIR="${BACKUP_DIR:-/etc/mihomo/conf_bak}"
LOG_FILE="${LOG_FILE:-/var/log/update-mihomo-config.log}"
# 檔案太小就當成報錯頁；備份保留天數；curl 超時與重試。
MIN_CONFIG_SIZE="${MIN_CONFIG_SIZE:-1024}"
KEEP_DAYS="${KEEP_DAYS:-7}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"
CURL_MAX_TIME="${CURL_MAX_TIME:-60}"
LOCK_FILE="${LOCK_FILE:-/run/lock/update-mihomo-config.lock}"

DRY_RUN=0
FORCE=0
SYNC_ONLY=0
FETCH_ONLY=0

# ---------------------------------------------------------------- 內部狀態 ---
STAGE_DIR=""
TEMPLATE_BACKUP_DIR=""
TEMPLATE_CHANGED=0
TEMPLATE_BASE_EXISTED=0
TEMPLATE_INI_EXISTED=0
LIVE_BACKUP_FILE=""
MIHOMO_BIN_PATH=""
OLD_HEAD=""
NEW_HEAD=""
FRESH_CLONE=0

# 日誌全部用英文輸出（使用者要求）；註解用中文。
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    if [ -n "${LOG_FILE:-}" ]; then
        echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

die() {
    log "ERROR: $*"
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

cleanup() {
    if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
        rm -rf "$STAGE_DIR"
    fi
    rm -f "$TEMP_CONFIG"
}
trap cleanup EXIT

# 在暫存副本上把 secret: ... 一行換成 MIHOMO_SECRET 的值，純 bash，不用 Python。
# 為什麼不用 sed：密碼裏的 / & \ 等字符會打斷 sed 的替換語法，要逐個轉義很容易漏；
# 逐行讀再用 printf 輸出就沒有這個問題，/ & \ 都會原樣保留。
# YAML 單引號字串裏，單引號本身要寫成兩個單引號，所以先把 ' 換成 ''。
# 密碼不印到日誌，不傳給命令列參數；含換行符的密碼直接拒絕，因為 YAML 單行寫不下。
apply_secret() {
    local file="$1"
    local tmp_file=""
    local replaced=0
    local line=""
    local escaped=""

    case "$MIHOMO_SECRET" in
        *$'\n'*|*$'\r'*) die "MIHOMO_SECRET must not contain a newline" ;;
    esac
    escaped="${MIHOMO_SECRET//\'/\'\'}"

    tmp_file="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^secret: ]]; then
            printf "secret: '%s'\n" "$escaped"
            replaced=1
        else
            printf '%s\n' "$line"
        fi
    done < "$file" > "$tmp_file"
    if [ "$replaced" -eq 0 ]; then
        rm -f "$tmp_file"
        die "No 'secret:' line found in base file, cannot inject secret"
    fi
    cat "$tmp_file" > "$file"
    rm -f "$tmp_file"
}

# 拉取回來的模板只是先做一次最基本的檢查，避免把明顯壞掉的檔案覆蓋上去。
# 這不是完整的 YAML 解析，也不是 mihomo 的驗證，完整的驗證在 Phase B 的 mihomo -t。
check_template() {
    local base_file="$1"
    local ini_file="$2"
    [ -s "$base_file" ] || die "Base file is empty: $base_file"
    grep -q "^secret:" "$base_file" || die "Base file is missing 'secret:' line: $base_file"
    [ -s "$ini_file" ] || die "INI file is empty: $ini_file"
    grep -q "clash_rule_base" "$ini_file" || die "INI file is missing clash_rule_base: $ini_file"
    grep -q "custom_proxy_group=" "$ini_file" || die "INI file is missing custom_proxy_group=: $ini_file"
}

# 比較目標目錄的模板同 origin/main 的模板係咪一致。
# 只比 HEAD 係唔夠嘅：回滾之後，目標目錄會還原做舊版模板，
# 但倉庫 HEAD 已經係新版，HEAD 相同就唔會再部署，永遠追唔返。
# 所以要直接比較檔案內容。base 檔案要先剔走 secret: 一行再比較，
# 因為目標檔案已經注入咗真密碼，倉庫檔案係 secret: ''，直接比一定唔同。
# 回傳 0 表示唔一致（要部署），回傳 1 表示一致或者比唔到。
templates_differ_from_origin() {
    local tmp_base=""
    local tmp_ini=""
    tmp_base="$(mktemp)"
    tmp_ini="$(mktemp)"
    if ! git show "origin/$REPO_BRANCH:$BASE_SRC_REL" 2>/dev/null | grep -v '^secret:' > "$tmp_base"; then
        rm -f "$tmp_base" "$tmp_ini"
        return 1
    fi
    if ! git show "origin/$REPO_BRANCH:$INI_SRC_REL" 2>/dev/null > "$tmp_ini"; then
        rm -f "$tmp_base" "$tmp_ini"
        return 1
    fi
    if [ ! -f "$DEST_BASE_FILE" ] || [ ! -f "$DEST_INI_FILE" ]; then
        rm -f "$tmp_base" "$tmp_ini"
        return 0
    fi
    if ! grep -v '^secret:' "$DEST_BASE_FILE" 2>/dev/null | cmp -s - "$tmp_base"; then
        rm -f "$tmp_base" "$tmp_ini"
        return 0
    fi
    if ! cmp -s "$DEST_INI_FILE" "$tmp_ini"; then
        rm -f "$tmp_base" "$tmp_ini"
        return 0
    fi
    rm -f "$tmp_base" "$tmp_ini"
    return 1
}

# 等服務真正起來，最多等 30 秒；中途變 failed 就直接回傳失敗，不用等滿。
wait_service_active() {
    local timeout="${1:-30}"
    local i=0
    while [ "$i" -lt "$timeout" ]; do
        if systemctl is-active --quiet "$MIHOMO_SERVICE" 2>/dev/null; then
            return 0
        fi
        if systemctl is-failed --quiet "$MIHOMO_SERVICE" 2>/dev/null; then
            return 1
        fi
        sleep 1
        i=$((i + 1))
    done
    systemctl is-active --quiet "$MIHOMO_SERVICE" 2>/dev/null
}

check_health() {
    # 健康檢查一定要輪詢，唔可以只查一次：systemd 認為服務 active，
    # 只代表進程已經啟動，唔代表 mihomo 已經載完 GeoIP/GeoSite 並綁好端口。
    # 之前版本喺重啟後即刻查一次就判失敗，連用舊設定回滾嗰次都一樣判失敗，
    # 其實服務多等一兩秒就會起來。
    local waited=0
    local warned=0
    while [ "$waited" -lt 30 ]; do
        if systemctl is-active --quiet "$MIHOMO_SERVICE" 2>/dev/null; then
            if ! command -v ss >/dev/null 2>&1; then
                return 0
            fi
            if ss -tln 2>/dev/null | grep -q ":${MIHOMO_MIXED_PORT} "; then
                return 0
            fi
            if [ "$warned" -eq 0 ]; then
                log "Service is active, waiting for port ${MIHOMO_MIXED_PORT} to listen..."
                warned=1
            fi
        elif systemctl is-failed --quiet "$MIHOMO_SERVICE" 2>/dev/null; then
            log "Health check failed: $MIHOMO_SERVICE entered failed state"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    if ! systemctl is-active --quiet "$MIHOMO_SERVICE" 2>/dev/null; then
        log "Health check failed: $MIHOMO_SERVICE is not active after 30s"
    else
        log "Health check failed: port ${MIHOMO_MIXED_PORT} is not listening after 30s"
    fi
    return 1
}

cleanup_old_backups() {
    local count=0
    [ -d "$BACKUP_DIR" ] || return 0
    count="$(find "$BACKUP_DIR" -type f -name "*.yaml" -mtime "+$KEEP_DAYS" | wc -l)"
    count="$(echo "$count" | tr -d ' ')"
    if [ "$count" -gt 0 ]; then
        find "$BACKUP_DIR" -type f -name "*.yaml" -mtime "+$KEEP_DAYS" -delete
        log "Deleted $count backup file(s) older than $KEEP_DAYS days."
    else
        log "No backup older than $KEEP_DAYS days to clean up."
    fi
}

prune_template_backups() {
    # shellcheck disable=SC2012
    ls -1dt "$TEMPLATE_BACKUP_ROOT"/*/ 2>/dev/null | tail -n +"$((KEEP_TEMPLATE_BACKUPS + 1))" | xargs -r rm -rf -- || true
}

# 還原這次換過的模板（只在 TEMPLATE_CHANGED=1 時才有東西可還原）。
# 成功回傳 0，失敗回傳 1。
rollback_templates() {
    if [ "$TEMPLATE_CHANGED" -eq 0 ]; then
        return 0
    fi
    if [ -z "$TEMPLATE_BACKUP_DIR" ] || [ ! -d "$TEMPLATE_BACKUP_DIR" ]; then
        log "ERROR: No template backup available for rollback."
        return 1
    fi
    log "Rolling back templates from $TEMPLATE_BACKUP_DIR"
    if [ "$TEMPLATE_BASE_EXISTED" -eq 1 ]; then
        cp -a "$TEMPLATE_BACKUP_DIR/base_tun.yml" "$DEST_BASE_FILE" \
            || { log "ERROR: Failed to restore base_tun.yml"; return 1; }
    else
        rm -f "$DEST_BASE_FILE"
    fi
    if [ "$TEMPLATE_INI_EXISTED" -eq 1 ]; then
        cp -a "$TEMPLATE_BACKUP_DIR/mihomo.conf.ini" "$DEST_INI_FILE" \
            || { log "ERROR: Failed to restore mihomo.conf.ini"; return 1; }
    else
        rm -f "$DEST_INI_FILE"
    fi
    TEMPLATE_CHANGED=0
    log "Templates rolled back."
    return 0
}

# 還原正式設定檔，再重啟一次並驗證。成功回傳 0，失敗回傳 1。
rollback_live() {
    log "Rolling back live config."
    if [ -z "$LIVE_BACKUP_FILE" ] || [ ! -f "$LIVE_BACKUP_FILE" ]; then
        log "ERROR: No live config backup available for rollback (live config may not have existed before this run). Manual intervention required."
        return 1
    fi
    cp -a "$LIVE_BACKUP_FILE" "$CLASH_CONFIG_FILE" \
        || { log "ERROR: Failed to restore live config from backup: $LIVE_BACKUP_FILE"; return 1; }
    chmod 644 "$CLASH_CONFIG_FILE"
    log "Live config restored from $LIVE_BACKUP_FILE, restarting $MIHOMO_SERVICE"
    systemctl restart "$MIHOMO_SERVICE" 2>/dev/null \
        || { log "ERROR: Restart failed after rollback"; return 1; }
    if wait_service_active 30 && check_health; then
        log "Rollback successful: $MIHOMO_SERVICE is running with the old config."
        return 0
    fi
    log "ERROR: Service still failed after rollback. Check manually: journalctl -u $MIHOMO_SERVICE -n 100"
    return 1
}

# 完整回滾：先還原正式設定檔並重啟驗證，再還原這次換過的模板。
rollback_all() {
    local live_ok=0
    if rollback_live; then
        live_ok=1
    fi
    rollback_templates || live_ok=0
    if [ "$live_ok" -eq 1 ]; then
        return 0
    fi
    return 1
}

resolve_mihomo_bin() {
    if command -v "$MIHOMO_BIN" >/dev/null 2>&1; then
        MIHOMO_BIN_PATH="$(command -v "$MIHOMO_BIN")"
    elif [ -x /usr/local/bin/mihomo ]; then
        MIHOMO_BIN_PATH="/usr/local/bin/mihomo"
    elif [ -x /usr/bin/mihomo ]; then
        MIHOMO_BIN_PATH="/usr/bin/mihomo"
    else
        MIHOMO_BIN_PATH=""
    fi
}

usage() {
    cat <<'EOF'
Usage: update-mihomo-config.sh [--dry-run] [--force] [--sync-only] [--fetch-only] [-h|--help]

  --dry-run    Check only, do not pull, write, or restart.
  --force      Deploy templates even if conf/ has no new change (for testing).
  --sync-only  Run Phase A (template sync) only.
  --fetch-only Run Phase B (subscription fetch) only, skip template sync.

Environment variables (see the top of the script):
  MIHOMO_SECRET, SUB_PROFILE_URL, REPO_DIR, SUBCONVERTER_DIR, and others.
EOF
}

# ---------------------------------------------------------------- 參數解析 ---
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --force) FORCE=1 ;;
        --sync-only) SYNC_ONLY=1 ;;
        --fetch-only) FETCH_ONLY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (use --help for usage)" ;;
    esac
    shift
done

# ---------------------------------------------------------------- Phase A ---
# 同步模板：檢查 GitHub conf/ 有沒有更新，有更新才拉取部署。
# 跟舊腳本不同的是，模板沒有更新時只會跳過這一段，不會直接退出，
# 因為訂閱節點每天都可能變，Phase B 照樣要跑。
sync_templates() {
    if [ "$FETCH_ONLY" -eq 1 ]; then
        log "Phase A: skipped (--fetch-only)."
        return 0
    fi

    if [ ! -d "$REPO_DIR/.git" ]; then
        log "Local repo does not exist, cloning $REPO_URL to $REPO_DIR"
        if [ "$DRY_RUN" -eq 1 ]; then
            log "Dry run: would clone, but will not actually clone. Exiting."
            exit 0
        fi
        mkdir -p "$(dirname "$REPO_DIR")"
        git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR" \
            || die "git clone failed"
        FRESH_CLONE=1
    fi

    cd "$REPO_DIR" || die "Cannot enter repo directory: $REPO_DIR"
    git fetch origin "$REPO_BRANCH" || die "git fetch failed"

    OLD_HEAD="$(git rev-parse HEAD)"
    NEW_HEAD="$(git rev-parse "origin/$REPO_BRANCH")"
    local changed=""
    changed="$(git diff --name-only "$OLD_HEAD" "$NEW_HEAD" -- conf/ || true)"

    # 判斷要不要部署。只比 HEAD 是不夠的：剛 clone 完時，本地 HEAD 本來就等於
    # origin/main，但目標目錄還從來沒有部署過，所以第一次一定要部署。
    local need_deploy=0
    local deploy_reason=""
    if [ "$FRESH_CLONE" -eq 1 ]; then
        need_deploy=1
        deploy_reason="fresh clone, templates have never been deployed"
    elif [ "$FORCE" -eq 1 ]; then
        need_deploy=1
        deploy_reason="forced mode"
    elif [ "$OLD_HEAD" != "$NEW_HEAD" ] && [ -n "$changed" ]; then
        need_deploy=1
        deploy_reason="conf/ updated"
    elif [ ! -f "$DEST_BASE_FILE" ] || [ ! -f "$DEST_INI_FILE" ]; then
        need_deploy=1
        deploy_reason="template files missing in destination"
    elif templates_differ_from_origin; then
        need_deploy=1
        deploy_reason="destination templates differ from origin/$REPO_BRANCH (e.g. rolled back)"
    fi

    if [ "$need_deploy" -eq 0 ]; then
        if [ "$OLD_HEAD" = "$NEW_HEAD" ]; then
            log "Phase A: no template update (local and origin/$REPO_BRANCH are both $OLD_HEAD), skipping deployment."
        else
            log "Phase A: main has new commits, but conf/ did not change, skipping deployment."
        fi
        return 0
    fi

    log "Phase A: deploying templates: $deploy_reason"
    if [ -n "$changed" ]; then
        log "Phase A: changed files in conf/:"
        printf '%s\n' "$changed" | while IFS= read -r f; do log "  - $f"; done
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "Dry run: would pull and deploy templates, but will not actually do so."
        return 0
    fi

    # 本地 conf/ 有未提交改動時不拉取，避免把你的本機改動沖掉。
    if [ -n "$(git status --porcelain -- conf/ || true)" ]; then
        die "Local conf/ has uncommitted changes. Commit or discard them before running this script."
    fi

    git pull --ff-only origin "$REPO_BRANCH" || die "git pull --ff-only failed (local branch may have diverged, please fix manually)"
    NEW_HEAD="$(git rev-parse HEAD)"
    log "Phase A: pulled to $NEW_HEAD"

    [ -f "$REPO_DIR/$BASE_SRC_REL" ] || die "After pull, file not found: $BASE_SRC_REL"
    [ -f "$REPO_DIR/$INI_SRC_REL" ] || die "After pull, file not found: $INI_SRC_REL"

    check_template "$REPO_DIR/$BASE_SRC_REL" "$REPO_DIR/$INI_SRC_REL"
    log "Phase A: template check passed (base contains 'secret:' line, INI contains clash_rule_base and custom_proxy_group=)"

    STAGE_DIR="$(mktemp -d)"
    cp -a "$REPO_DIR/$BASE_SRC_REL" "$STAGE_DIR/base_tun.yml"
    cp -a "$REPO_DIR/$INI_SRC_REL" "$STAGE_DIR/mihomo.conf.ini"
    apply_secret "$STAGE_DIR/base_tun.yml" || die "Failed to inject secret"
    log "Phase A: secret injected into staged copy, repo files unchanged."

    mkdir -p "$DEST_BASE_DIR" "$DEST_INI_DIR" "$TEMPLATE_BACKUP_ROOT"
    TEMPLATE_BACKUP_DIR="$TEMPLATE_BACKUP_ROOT/$(date '+%Y%m%d-%H%M%S')"
    mkdir -p "$TEMPLATE_BACKUP_DIR"
    if [ -f "$DEST_BASE_FILE" ]; then
        TEMPLATE_BASE_EXISTED=1
        cp -a "$DEST_BASE_FILE" "$TEMPLATE_BACKUP_DIR/base_tun.yml"
    fi
    if [ -f "$DEST_INI_FILE" ]; then
        TEMPLATE_INI_EXISTED=1
        cp -a "$DEST_INI_FILE" "$TEMPLATE_BACKUP_DIR/mihomo.conf.ini"
    fi
    printf '%s\n%s\n' "$OLD_HEAD" "$NEW_HEAD" > "$TEMPLATE_BACKUP_DIR/HEAD.txt"
    log "Phase A: old templates backed up to $TEMPLATE_BACKUP_DIR"
    prune_template_backups

    # 用 cp 不用 mv：來源是 Git 倉庫，mv 會把倉庫檔案搬走，下次 pull 會出問題。
    cp -a "$STAGE_DIR/base_tun.yml" "$DEST_BASE_FILE"
    cp -a "$STAGE_DIR/mihomo.conf.ini" "$DEST_INI_FILE"
    chmod 644 "$DEST_BASE_FILE" "$DEST_INI_FILE"
    TEMPLATE_CHANGED=1
    log "Phase A: deployed $DEST_BASE_FILE and $DEST_INI_FILE (new version: $NEW_HEAD, backup: $TEMPLATE_BACKUP_DIR)"
    return 0
}

# ---------------------------------------------------------------- Phase B ---
# 拉取訂閱：從 subconverter 下載新設定，驗證、覆蓋、重啟、健康檢查、失敗回滾。
fetch_subscription() {
    if [ "$SYNC_ONLY" -eq 1 ]; then
        log "Phase B: skipped (--sync-only)."
        return 0
    fi

    if [ -z "${SUB_PROFILE_URL:-}" ]; then
        die "SUB_PROFILE_URL is empty. Fill in the subconverter subscription URL at the top of the script."
    fi

    resolve_mihomo_bin
    if [ -z "$MIHOMO_BIN_PATH" ]; then
        log "WARNING: mihomo binary not found, skipping mihomo -t verification. Restart health check will be the only guard."
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "Phase B: dry run, would fetch subscription from subconverter, verify, deploy, and restart mihomo. No changes made."
        return 0
    fi

    log "[1/4] Backing up the current config file..."
    mkdir -p "$(dirname "$CLASH_CONFIG_FILE")" "$BACKUP_DIR" 2>/dev/null || true
    if [ -f "$CLASH_CONFIG_FILE" ]; then
        LIVE_BACKUP_FILE="$BACKUP_DIR/config_$(date +%Y-%m-%d_%H-%M-%S).yaml"
        cp "$CLASH_CONFIG_FILE" "$LIVE_BACKUP_FILE" \
            || die "Backup failed, stopping update."
        log "Backup successful: $LIVE_BACKUP_FILE"
    else
        log "WARNING: Original config file $CLASH_CONFIG_FILE does not exist. Skipping backup (rollback will not be possible)."
    fi

    log "[2/4] Fetching the latest configuration from subconverter..."
    if ! curl -A "Clash/2.5.12" -L -f -sS \
            --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            --retry 2 --retry-delay 5 \
            -o "$TEMP_CONFIG" "$SUB_PROFILE_URL"; then
        log "ERROR: Failed to download config from subconverter! Check the service or URL. Old config untouched."
        exit 1
    fi

    # 覆蓋前驗證：大小、不是 HTML 報錯頁、含有 Clash 關鍵字、mihomo -t 通過。
    # 任一項失敗都在覆蓋之前中止，舊設定和正在跑的服務都不動。
    local file_size=0
    file_size="$(stat -c%s "$TEMP_CONFIG" 2>/dev/null || echo 0)"
    if [ "$file_size" -lt "$MIN_CONFIG_SIZE" ]; then
        log "ERROR: Downloaded file is too small ($file_size bytes). It might be an error message. Aborting."
        exit 1
    fi
    if grep -qi "<!DOCTYPE html\|<html" "$TEMP_CONFIG"; then
        log "ERROR: Downloaded file looks like an HTML error page. Aborting."
        exit 1
    fi
    local key=""
    for key in "proxies:" "proxy-groups:" "rules:"; do
        if ! grep -q "$key" "$TEMP_CONFIG"; then
            log "ERROR: Invalid config format (missing '$key'). Aborting."
            exit 1
        fi
    done
    if [ -n "$MIHOMO_BIN_PATH" ]; then
        log "Verifying downloaded config with mihomo -t (home: $MIHOMO_HOME)..."
        # 一定要用跟服務一樣的 -d，否則 mihomo 會以 ~/.config/mihomo 為 home，
        # 然後因為 external-ui: /etc/mihomo/ui 不在 home 或 SAFE_PATHS 內而報錯。
        if ! SAFE_PATHS="$MIHOMO_HOME" "$MIHOMO_BIN_PATH" -d "$MIHOMO_HOME" -t -f "$TEMP_CONFIG"; then
            log "ERROR: mihomo -t verification failed. Aborting before replacing the live config."
            # 新模板很可能就是令設定檔不通過的原因（例如 force-domain 的單獨 '+'），
            # 所以先把這次換過的模板還原，再退出。
            rollback_templates || true
            exit 1
        fi
        log "mihomo -t verification passed."
    fi

    log "Configuration verified. Updating $CLASH_CONFIG_FILE ..."
    if ! mv "$TEMP_CONFIG" "$CLASH_CONFIG_FILE"; then
        log "ERROR: Failed to move temporary file to target destination!"
        exit 1
    fi
    chmod 644 "$CLASH_CONFIG_FILE"
    log "New configuration file applied successfully."

    log "[3/4] Restarting the mihomo service..."
    if ! systemctl restart "$MIHOMO_SERVICE"; then
        log "ERROR: mihomo service failed to restart! Rolling back."
        if rollback_all; then
            cleanup_old_backups
            exit 1
        else
            exit 2
        fi
    fi
    if wait_service_active 30 && check_health; then
        log "mihomo service restarted successfully and is now running."
    else
        log "ERROR: mihomo service failed to start / failed health check after restart! Rolling back."
        if rollback_all; then
            cleanup_old_backups
            exit 1
        else
            exit 2
        fi
    fi

    log "[4/4] Cleaning up old backup files..."
    cleanup_old_backups
    return 0
}

main() {
    if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
        die "Please run as root (sudo $0). Only --dry-run can run as a normal user."
    fi

    if [ "$FETCH_ONLY" -eq 0 ]; then
        need_cmd git
    fi
    if [ "$SYNC_ONLY" -eq 0 ]; then
        need_cmd curl
        need_cmd systemctl
    fi

    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

    # 同一時間只跑一份，避免兩個 cron／手動執行互相覆蓋。
    if command -v flock >/dev/null 2>&1; then
        mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
        exec 9>"$LOCK_FILE" 2>/dev/null || log "WARNING: Cannot open lock file, skipping flock: $LOCK_FILE"
        flock -n 9 2>/dev/null || die "Another update-mihomo-config.sh is already running. Exiting."
    fi

    if [ -z "$MIHOMO_SECRET" ]; then
        log "WARNING: MIHOMO_SECRET is empty, deployed templates will keep secret: '' (external controller has no password, use only inside the LAN)."
    else
        log "MIHOMO_SECRET is set (length ${#MIHOMO_SECRET}, content not logged)."
    fi

    echo "============================================================"
    log "Starting mihomo config update task"
    echo "============================================================"

    sync_templates

    if [ "$SYNC_ONLY" -eq 1 ]; then
        echo "============================================================"
        log "Template sync finished"
        echo "============================================================"
        exit 0
    fi

    fetch_subscription

    echo "============================================================"
    log "mihomo config update task finished"
    echo "============================================================"
    exit 0
}

main "$@"
