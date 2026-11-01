#!/usr/bin/env bash
# =====================================================================
#  trixie-toolbox :: vps-init.sh
#  Debian 13 (trixie) VPS 初始化脚本
#
#  功能：
#    1. 安装 curl / wget / sudo / nftables，并用 nftables 接管本机防火墙
#    2. 交互式终端菜单，第一项为「防火墙管理」
#    3. 防火墙默认不启用；启用后仅放行常用服务端口，其余入站全部丢弃
#
#  用法：
#    sudo bash vps-init.sh
#
#  说明：
#    - 仅针对 Debian 13 (trixie) 测试
#    - 防火墙规则持久化在 /etc/trixie-toolbox/ 下，开机自动加载
# =====================================================================

set -o pipefail

APP_NAME="trixie-toolbox"
APP_VERSION="1.1.0"
APP_TITLE="VPS 初始化工具"

STATE_DIR="/etc/trixie-toolbox"
PORT_DB="${STATE_DIR}/ports.db"
FW_STATE="${STATE_DIR}/firewall.state"
RULES_NFT="${STATE_DIR}/trixie-toolbox.nft"
BACKUP_DIR="${STATE_DIR}/backups"
NFT_CONF="/etc/nftables.conf"
FW_TABLE="vps_filter"
GUARD_FLAG="/run/trixie-toolbox-guard"
LOG_FILE="/var/log/trixie-toolbox.log"

# 回滚保护：通过 SSH 启用防火墙后，若在此秒数内未确认则自动回滚
GUARD_SECS=30

# 首次启用防火墙时写入的默认放行端口
# 格式: 端口|协议|说明   (协议: tcp / udp / both)
DEFAULT_PORTS=(
    "22|tcp|SSH 远程登录"
    "20|tcp|FTP 数据传输端口"
    "21|tcp|FTP 控制端口"
    "80|tcp|HTTP 明文网页"
    "443|both|HTTPS 加密网页 / QUIC(HTTP3)"
    "3389|both|Windows 远程桌面 RDP"
    "3306|tcp|MySQL / MariaDB"
    "5432|tcp|PostgreSQL"
    "6379|tcp|Redis"
)

# 高危端口：对公网放行前需要额外提醒
RISKY_PORTS=(3306 5432 6379)

REQUIRED_PKGS=(curl wget sudo nftables)

# TCP 调优：内置 vendor/tcpfit.sh，缺失时按 URL 拉取
TCPFIT_URL="https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh"
TCPFIT_MIRROR="https://gh-proxy.com/https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh"
TCPFIT_CACHE="/usr/local/lib/trixie-toolbox/tcpfit.sh"

# ---------------------------------------------------------------------
#  输出与工具函数
# ---------------------------------------------------------------------
if [ -t 1 ]; then
    C_R=$'\033[31m'
    C_G=$'\033[32m'
    C_Y=$'\033[33m'
    C_B=$'\033[36m'
    C_W=$'\033[1m'
    C_0=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_W=""; C_0=""
fi

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${LOG_FILE}" 2>/dev/null
}

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[  OK  ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[ 警告 ]%s %s\n' "$C_Y" "$C_0" "$*"; }
err()  { printf '%s[ 错误 ]%s %s\n' "$C_R" "$C_0" "$*"; }
info() { printf '%s[ 提示 ]%s %s\n' "$C_B" "$C_0" "$*"; }

pause() {
    printf '\n%s按回车键继续...%s' "$C_B" "$C_0"
    read -r _
}

confirm() {
    local prompt="${1}" def="${2:-y}" ans
    if [ "$def" = "y" ]; then
        printf '%s [Y/n]: ' "$prompt"
    else
        printf '%s [y/N]: ' "$prompt"
    fi
    read -r ans
    [ -z "$ans" ] && ans="$def"
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    cat <<'USAGE'
用法: sudo bash vps-init.sh

  -h, --help     显示帮助
  -v, --version  显示版本

直接运行则进入交互菜单。
USAGE
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        case "$0" in
            /dev/fd/*|/proc/self/fd/*)
                err "请以 root 运行: sudo bash <(curl -fsSL <脚本地址>)"
                exit 1
                ;;
        esac
        if command -v sudo >/dev/null 2>&1; then
            exec sudo -E bash "$0" "$@"
        fi
        err "请使用 root 用户运行本脚本"
        exit 1
    fi
}

ensure_state() {
    if [ ! -d "$STATE_DIR" ]; then
        mkdir -p "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || {
            err "无法创建目录 $STATE_DIR"
            exit 1
        }
        chmod 700 "$STATE_DIR" 2>/dev/null
    fi
    [ -d "$BACKUP_DIR" ] || mkdir -p "$BACKUP_DIR" 2>/dev/null

    if [ ! -s "$PORT_DB" ]; then
        printf '%s\n' "${DEFAULT_PORTS[@]}" > "$PORT_DB"
        chmod 600 "$PORT_DB" 2>/dev/null
        log "初始化默认端口配置: $PORT_DB"
    fi
}

detect_os() {
    OS_ID="unknown"
    OS_VERSION=""
    OS_PRETTY="unknown"
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-}"
        OS_PRETTY="${PRETTY_NAME:-${OS_ID}}"
    fi
}

# ---------------------------------------------------------------------
#  依赖包
# ---------------------------------------------------------------------
pkg_ok() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

MISSING=()
collect_missing() {
    MISSING=()
    local p
    for p in "${REQUIRED_PKGS[@]}"; do
        pkg_ok "$p" || MISSING+=("$p")
    done
}

install_packages() {
    collect_missing
    if [ "${#MISSING[@]}" -eq 0 ]; then
        ok "依赖已全部安装"
        return 0
    fi
    warn "缺少软件包: ${MISSING[*]}"
    confirm "使用 apt 安装这些软件包?" y || return 1

    export DEBIAN_FRONTEND=noninteractive
    info "apt-get update ..."
    if ! apt-get update -qq; then
        warn "apt-get update 失败，尝试使用现有软件包缓存继续"
    fi
    info "安装中: ${MISSING[*]}"
    if ! apt-get install -y --no-install-recommends "${MISSING[@]}"; then
        err "软件包安装失败"
        return 1
    fi
    ok "依赖安装完成"
    log "安装软件包: ${MISSING[*]}"
}

# ---------------------------------------------------------------------
#  防火墙接管
# ---------------------------------------------------------------------
takeover_firewall() {
    say ""
    say "检查本机防火墙状态 ..."
    local found=0

    if systemctl is-active --quiet ufw 2>/dev/null; then
        found=1
        warn "检测到 ufw 正在运行"
        if confirm "停用并禁用 ufw，改为由 nftables 接管?" y; then
            ufw disable >/dev/null 2>&1
            systemctl disable --now ufw >/dev/null 2>&1
            ok "ufw 已停用"
            log "停用 ufw"
        else
            warn "保留 ufw，可能与 nftables 规则冲突"
        fi
    fi

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        found=1
        warn "检测到 firewalld 正在运行"
        if confirm "停用并禁用 firewalld，改为由 nftables 接管?" y; then
            systemctl disable --now firewalld >/dev/null 2>&1
            ok "firewalld 已停用"
            log "停用 firewalld"
        else
            warn "保留 firewalld，可能与 nftables 规则冲突"
        fi
    fi

    if command -v iptables >/dev/null 2>&1; then
        if iptables -S 2>/dev/null | grep -qvE '^-P (INPUT|FORWARD|OUTPUT) ACCEPT$'; then
            found=1
            warn "检测到已存在的 iptables 规则"
            info "启用防火墙时脚本会先备份当前规则集，不会立即删除"
        fi
    fi

    if [ "$found" -eq 0 ]; then
        ok "未发现其它防火墙服务冲突"
    fi

    if ! command -v nft >/dev/null 2>&1; then
        err "nft 命令不可用，请先安装 nftables"
        return 1
    fi
    ok "nftables 就绪（版本: $(nft -v 2>/dev/null | awk '{print $NF}')）"
    return 0
}

# ---------------------------------------------------------------------
#  端口配置读写
# ---------------------------------------------------------------------
port_exists() {
    grep -q "^${1}|" "$PORT_DB" 2>/dev/null
}

port_line_of() {
    grep -m1 "^${1}|" "$PORT_DB" 2>/dev/null
}

port_remove() {
    local port="$1"
    if ! port_exists "$port"; then
        return 1
    fi
    grep -v "^${port}|" "$PORT_DB" > "${PORT_DB}.tmp" 2>/dev/null
    mv -f "${PORT_DB}.tmp" "$PORT_DB"
    chmod 600 "$PORT_DB" 2>/dev/null
    return 0
}

port_add() {
    local port="$1" proto="${2}" note="${3}"
    if port_exists "$port"; then
        local old
        old="$(port_line_of "$port")"
        if ! confirm "端口 $port 已存在（${old}），是否覆盖?" n; then
            return 1
        fi
        port_remove "$port"
    fi
    printf '%s|%s|%s\n' "$port" "$proto" "$note" >> "$PORT_DB"
    return 0
}

restore_default_ports() {
    if ! confirm "恢复默认端口会覆盖当前自定义配置，继续?" n; then
        return 0
    fi
    printf '%s\n' "${DEFAULT_PORTS[@]}" > "$PORT_DB"
    chmod 600 "$PORT_DB" 2>/dev/null
    ok "已恢复默认放行端口（${#DEFAULT_PORTS[@]} 项）"
    log "恢复默认端口列表"
}

validate_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null || return 1
    return 0
}

# 检测本机 sshd 实际监听端口
detect_ssh_ports() {
    local ports=() p
    if command -v ss >/dev/null 2>&1; then
        while read -r p; do
            [ -n "$p" ] && ports+=("$p")
        done < <(ss -tlnpH 2>/dev/null | awk '/sshd/ && $4 ~ /:/ { n = split($4, a, ":"); print a[n] }' | sort -un)
    fi
    if [ "${#ports[@]}" -eq 0 ]; then
        while read -r p; do
            [ -n "$p" ] && ports+=("$p")
        done < <(grep -hiE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{ print $2 }' | sort -un)
    fi
    if [ "${#ports[@]}" -eq 0 ]; then
        ports=(22)
    fi
    printf '%s\n' "${ports[@]}"
}

# ---------------------------------------------------------------------
#  nftables 规则生成与应用
# ---------------------------------------------------------------------
fw_is_on() {
    command -v nft >/dev/null 2>&1 || return 1
    nft list table inet "$FW_TABLE" >/dev/null 2>&1
}

build_rules() {
    ensure_state

    local port proto note
    local tcp_list=() udp_list=()

    while IFS='|' read -r port proto note; do
        [ -n "$port" ] || continue
        case "$proto" in
            tcp)  tcp_list+=("$port") ;;
            udp)  udp_list+=("$port") ;;
            both) tcp_list+=("$port"); udp_list+=("$port") ;;
        esac
    done < <(sort -t'|' -k1,1n "$PORT_DB" 2>/dev/null)

    local old_ifs="$IFS"
    IFS=','
    local tcp_str="${tcp_list[*]}"
    local udp_str="${udp_list[*]}"
    IFS="$old_ifs"

    {
        printf '# =====================================================\n'
        printf '#  %s 自动生成 — 请勿手工编辑\n' "$APP_NAME"
        printf '#  生成时间: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '#  修改规则请运行: bash vps-init.sh\n'
        printf '# =====================================================\n'
        printf '\n'
        printf 'table inet %s {\n' "$FW_TABLE"
        printf '    chain input {\n'
        printf '        type filter hook input priority filter; policy drop;\n'
        printf '\n'
        printf '        iif "lo" accept\n'
        printf '        ct state established,related accept\n'
        printf '        ct state invalid drop\n'
        printf '        ip protocol icmp accept\n'
        printf '        ip6 nexthdr ipv6-icmp accept\n'
        printf '\n'
        printf '        # ---- 放行端口 ----\n'
        while IFS='|' read -r port proto note; do
            [ -n "$port" ] || continue
            printf '        # %s/%s %s\n' "$port" "$proto" "$note"
        done < <(sort -t'|' -k1,1n "$PORT_DB" 2>/dev/null)
        if [ -n "$tcp_str" ]; then
            printf '        tcp dport { %s } accept\n' "$tcp_str"
        fi
        if [ -n "$udp_str" ]; then
            printf '        udp dport { %s } accept\n' "$udp_str"
        fi
        printf '    }\n'
        printf '\n'
        printf '    chain forward {\n'
        printf '        type filter hook forward priority filter; policy accept;\n'
        printf '    }\n'
        printf '\n'
        printf '    chain output {\n'
        printf '        type filter hook output priority filter; policy accept;\n'
        printf '    }\n'
        printf '}\n'
    } > "$RULES_NFT"

    chmod 600 "$RULES_NFT" 2>/dev/null
    return 0
}

apply_rules() {
    if ! command -v nft >/dev/null 2>&1; then
        err "nftables 未安装，无法应用规则"
        return 1
    fi

    local ts backup_ruleset backup_conf
    ts="$(date '+%Y%m%d-%H%M%S')"
    backup_ruleset="$BACKUP_DIR/ruleset.$ts.nft"
    backup_conf="$BACKUP_DIR/nftables.conf.$ts"

    nft list ruleset > "$backup_ruleset" 2>/dev/null || true
    if [ -f "$NFT_CONF" ]; then
        cp -f "$NFT_CONF" "$backup_conf" 2>/dev/null
    fi

    build_rules || return 1

    cat > "$NFT_CONF" <<EOF
#!/usr/sbin/nft -f
# 由 ${APP_NAME} ${APP_VERSION} 生成，请勿手工编辑
flush ruleset
include "$RULES_NFT"
EOF
    chmod 644 "$NFT_CONF"

    # 语法检查：换成临时表名，避免与已存在的同名表冲突
    local check_file="/tmp/trixie-toolbox-check.nft"
    sed "s/table inet $FW_TABLE {/table inet ${FW_TABLE}_chk {/" "$RULES_NFT" > "$check_file"

    if ! nft -c -f "$check_file" >/tmp/trixie-toolbox-nftcheck.log 2>&1; then
        err "规则语法检查失败:"
        cat /tmp/trixie-toolbox-nftcheck.log
        rm -f "$check_file"
        if [ -f "$backup_conf" ]; then
            cp -f "$backup_conf" "$NFT_CONF" 2>/dev/null
        fi
        return 1
    fi
    rm -f "$check_file"

    systemctl enable nftables >/dev/null 2>&1
    if ! systemctl restart nftables >/dev/null 2>&1; then
        err "nftables 启动失败，正在回滚"
        nft flush ruleset >/dev/null 2>&1
        if [ -s "$backup_ruleset" ]; then
            nft -f "$backup_ruleset" >/dev/null 2>&1
        fi
        if [ -f "$backup_conf" ]; then
            cp -f "$backup_conf" "$NFT_CONF" 2>/dev/null
        fi
        systemctl disable nftables >/dev/null 2>&1
        err "已回滚到操作前的规则"
        return 1
    fi

    if ! fw_is_on; then
        err "规则加载后未检测到 ${FW_TABLE} 表，请检查 systemctl status nftables"
        return 1
    fi

    return 0
}

write_fw_state() {
    printf 'enabled=%s\n' "$1" > "$FW_STATE"
    printf 'enabled_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$FW_STATE"
    printf 'table=%s\n' "$FW_TABLE" >> "$FW_STATE"
    chmod 600 "$FW_STATE" 2>/dev/null
}

start_guard() {
    local secs="$GUARD_SECS"
    cat > /run/trixie-toolbox-guard.sh <<EOF
#!/usr/bin/env bash
sleep $secs
if [ -f "$GUARD_FLAG" ]; then
    nft delete table inet $FW_TABLE >/dev/null 2>&1
    systemctl disable --now nftables >/dev/null 2>&1
    printf 'enabled=0\n' > "$FW_STATE"
    printf '[guard] 防火墙未确认，已自动回滚\n' >> "$LOG_FILE"
    rm -f "$GUARD_FLAG"
fi
EOF
    chmod +x /run/trixie-toolbox-guard.sh
    : > "$GUARD_FLAG"
    if command -v setsid >/dev/null 2>&1; then
        nohup setsid bash /run/trixie-toolbox-guard.sh >/dev/null 2>&1 &
    else
        nohup bash /run/trixie-toolbox-guard.sh >/dev/null 2>&1 &
    fi
}

# ---------------------------------------------------------------------
#  防火墙操作
# ---------------------------------------------------------------------
fw_enable() {
    if fw_is_on; then
        warn "防火墙已处于启用状态"
        return 0
    fi
    if ! command -v nft >/dev/null 2>&1; then
        err "nftables 未安装，请先在主菜单执行依赖安装"
        return 1
    fi

    ensure_state

    # --- SSH 断连保护 ---
    local ssh_ports p
    ssh_ports="$(detect_ssh_ports)"
    local missing_ssh=()
    for p in $ssh_ports; do
        port_exists "$p" || missing_ssh+=("$p")
    done
    if [ "${#missing_ssh[@]}" -gt 0 ]; then
        warn "检测到 SSH 监听端口 ${missing_ssh[*]} 不在放行列表中"
        info "若不加入，启用防火墙后会立即断开当前连接"
        if confirm "自动加入放行列表?" y; then
            for p in "${missing_ssh[@]}"; do
                port_add "$p" tcp "SSH 自动检测"
            done
        fi
    fi

    # --- 高危端口提醒 ---
    local risky=() rp
    for rp in "${RISKY_PORTS[@]}"; do
        port_exists "$rp" && risky+=("$rp")
    done
    if [ "${#risky[@]}" -gt 0 ]; then
        warn "以下数据库端口将被对公网放行: ${risky[*]}"
        info "若服务不面向公网，请先返回菜单用「删除放行端口」移除它们"
        confirm "仍然继续启用防火墙?" y || return 0
    fi

    # --- 规则摘要 ---
    say ""
    say "即将应用的入站规则（其它端口一律丢弃）："
    printf '  %-8s %-6s %s\n' "端口" "协议" "备注"
    local port proto note
    while IFS='|' read -r port proto note; do
        [ -n "$port" ] || continue
        printf '  %-8s %-6s %s\n' "$port" "$proto" "$note"
    done < <(sort -t'|' -k1,1n "$PORT_DB" 2>/dev/null)
    say ""

    confirm "确认启用防火墙?" y || return 0

    info "正在生成并应用规则 ..."
    if ! apply_rules; then
        err "防火墙启用失败"
        return 1
    fi

    write_fw_state 1
    ok "防火墙已启用"
    log "启用防火墙"

    # --- 通过 SSH 操作时启用自动回滚 ---
    if [ -t 0 ] && [ -n "${SSH_CONNECTION:-}" ] && [ "${TTB_NO_ROLLBACK:-0}" != "1" ]; then
        start_guard
        say ""
        warn "你正在通过 SSH 操作，已启动 ${GUARD_SECS} 秒自动回滚保护"
        info "请另开一个终端验证 SSH 是否仍可连接"
        printf '%s' "确认连接正常? [y/N] "
        local ans=""
        read -r -t "$GUARD_SECS" ans || ans=""
        if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
            rm -f "$GUARD_FLAG"
            ok "已确认，取消自动回滚"
            log "用户确认防火墙生效"
        else
            warn "未在 ${GUARD_SECS} 秒内确认，防火墙将被自动回滚"
        fi
    fi
    return 0
}

fw_disable() {
    if ! fw_is_on; then
        warn "防火墙当前已处于关闭状态"
        systemctl disable nftables >/dev/null 2>&1
        return 0
    fi
    confirm "确认关闭防火墙? 关闭后所有端口都会恢复放行" n || return 0

    local ts
    ts="$(date '+%Y%m%d-%H%M%S')"
    nft list ruleset > "$BACKUP_DIR/ruleset.disable.$ts.nft" 2>/dev/null

    systemctl disable nftables >/dev/null 2>&1
    nft delete table inet "$FW_TABLE" >/dev/null 2>&1
    nft flush ruleset >/dev/null 2>&1

    cat > "$NFT_CONF" <<EOF
#!/usr/sbin/nft -f
# 由 ${APP_NAME} 管理：防火墙当前为关闭状态
flush ruleset
EOF
    chmod 644 "$NFT_CONF"

    write_fw_state 0
    ok "防火墙已关闭，规则已清空"
    log "关闭防火墙"
    return 0
}

fw_show_rules() {
    if ! fw_is_on; then
        warn "防火墙未启用"
        return 0
    fi
    say ""
    nft list table inet "$FW_TABLE"
    say ""
    say "持久化文件: $RULES_NFT"
}

fw_reload() {
    if ! fw_is_on; then
        warn "防火墙未启用，无需重载"
        return 0
    fi
    info "重新生成并加载规则 ..."
    if apply_rules; then
        ok "规则已重新加载"
        log "重新加载防火墙规则"
    else
        err "规则重新加载失败"
    fi
}

# ---------------------------------------------------------------------
#  菜单
# ---------------------------------------------------------------------
draw_header() {
    [ -t 1 ] && clear 2>/dev/null
    printf '%s====================================================%s\n' "$C_W" "$C_0"
    printf '%s  %s · %s  v%s%s\n' "$C_W" "$APP_NAME" "$APP_TITLE" "$APP_VERSION" "$C_0"
    printf '  %s\n' "$OS_PRETTY"
    printf '%s====================================================%s\n' "$C_W" "$C_0"
}

draw_status() {
    local fw_text dep_text
    if fw_is_on; then
        fw_text="${C_G}已启用${C_0}"
    else
        fw_text="${C_Y}未启用${C_0}"
    fi
    collect_missing
    if [ "${#MISSING[@]}" -eq 0 ]; then
        dep_text="${C_G}完整${C_0} (curl wget sudo nftables)"
    else
        dep_text="${C_R}缺少: ${MISSING[*]}${C_0}"
    fi
    printf '  防火墙: %s\n' "$fw_text"
    printf '  依赖:   %s\n' "$dep_text"
    printf '%s----------------------------------------------------%s\n' "$C_W" "$C_0"
}

menu_firewall() {
    local choice
    while true; do
        draw_header
        draw_status
        if fw_is_on; then
            printf '  状态说明: 入站默认丢弃，仅放行配置中的端口\n'
        else
            printf '  状态说明: 规则未加载，所有端口均可访问\n'
        fi
        printf '%s----------------------------------------------------%s\n' "$C_W" "$C_0"
        printf '  1) 启用防火墙\n'
        printf '  2) 关闭防火墙\n'
        printf '  3) 查看当前规则\n'
        printf '  4) 放行新端口\n'
        printf '  5) 删除放行端口\n'
        printf '  6) 查看已配置端口\n'
        printf '  7) 恢复默认放行端口\n'
        printf '  b) 返回主菜单\n'
        printf '%s----------------------------------------------------%s\n' "$C_W" "$C_0"
        read -r -p "请选择: " choice || return 0
        case "$choice" in
            1) fw_enable; pause ;;
            2) fw_disable; pause ;;
            3) fw_show_rules; pause ;;
            4) fw_add_port_interactive; pause ;;
            5) fw_del_port_interactive; pause ;;
            6) fw_list_ports; pause ;;
            7) restore_default_ports; pause ;;
            b|B|q|Q) return 0 ;;
            *) warn "无效选项: $choice"; sleep 1 ;;
        esac
    done
}

fw_list_ports() {
    say ""
    if [ ! -s "$PORT_DB" ]; then
        warn "当前没有配置任何放行端口"
        return 0
    fi
    printf '  %-8s %-6s %s\n' "端口" "协议" "备注"
    printf '  %s\n' "--------------------------------------------"
    local port proto note
    while IFS='|' read -r port proto note; do
        [ -n "$port" ] || continue
        printf '  %-8s %-6s %s\n' "$port" "$proto" "$note"
    done < <(sort -t'|' -k1,1n "$PORT_DB" 2>/dev/null)
    say ""
    say "配置文件: $PORT_DB"
}

fw_add_port_interactive() {
    say ""
    say "输入要放行的端口号，多个端口用逗号分隔（例如 8080,8443）"
    say "输入 b 返回"
    local input
    read -r -p "端口: " input
    [ -z "$input" ] && return 0
    if [ "$input" = "b" ] || [ "$input" = "B" ]; then return 0; fi

    input="${input// /}"
    local raw=() ports=() p
    IFS=',' read -r -a raw <<< "$input"
    for p in "${raw[@]}"; do
        if ! validate_port "$p"; then
            warn "端口号非法，已跳过: $p"
            continue
        fi
        ports+=("$p")
    done
    if [ "${#ports[@]}" -eq 0 ]; then
        err "没有可用的有效端口"
        return 1
    fi

    say ""
    say "选择协议:"
    say "  1) TCP"
    say "  2) UDP"
    say "  3) TCP + UDP (两者都放行)"
    local proto_choice proto
    read -r -p "协议 [1]: " proto_choice
    case "$proto_choice" in
        2) proto="udp" ;;
        3) proto="both" ;;
        *) proto="tcp" ;;
    esac

    say ""
    local note
    read -r -p "备注（可选，直接回车跳过）: " note
    [ -n "$note" ] || note="自定义放行"
    note="${note//|/-}"

    local added=0
    for p in "${ports[@]}"; do
        if port_exists "$p"; then
            warn "端口 $p 已在配置中，跳过"
            continue
        fi
        printf '%s|%s|%s\n' "$p" "$proto" "$note" >> "$PORT_DB"
        added=$((added + 1))
        ok "已添加: $p/$proto ($note)"
    done

    if [ "$added" -eq 0 ]; then
        return 1
    fi
    log "添加放行端口: ${ports[*]} ($proto) - $note"

    if fw_is_on; then
        say ""
        if confirm "防火墙正在运行，立即重新加载规则使其生效?" y; then
            fw_reload
        fi
    else
        info "防火墙未启用，规则将在下次启用时生效"
    fi
    return 0
}

fw_del_port_interactive() {
    say ""
    if [ ! -s "$PORT_DB" ]; then
        warn "当前没有配置任何放行端口"
        return 0
    fi
    printf '  %-8s %-6s %s\n' "端口" "协议" "备注"
    printf '  %s\n' "--------------------------------------------"
    local port proto note
    while IFS='|' read -r port proto note; do
        [ -n "$port" ] || continue
        printf '  %-8s %-6s %s\n' "$port" "$proto" "$note"
    done < <(sort -t'|' -k1,1n "$PORT_DB" 2>/dev/null)
    say ""

    local sel
    read -r -p "输入要删除的端口号（b 返回）: " sel
    [ -z "$sel" ] && return 0
    if [ "$sel" = "b" ] || [ "$sel" = "B" ]; then return 0; fi

    if ! validate_port "$sel"; then
        err "端口号非法: $sel"
        return 1
    fi
    if ! port_exists "$sel"; then
        err "配置中不存在端口: $sel"
        return 1
    fi
    port_remove "$sel"
    ok "已删除端口: $sel"
    log "删除放行端口: $sel"

    if fw_is_on; then
        if confirm "防火墙正在运行，立即重新加载规则?" y; then
            fw_reload
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------
#  TCP 调优（tcpfit）
# ---------------------------------------------------------------------
tcpfit_script_path() {
    local here
    here="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
    if [ -n "$here" ] && [ -f "$here/vendor/tcpfit.sh" ]; then
        printf '%s\n' "$here/vendor/tcpfit.sh"
        return 0
    fi
    if [ -f "$TCPFIT_CACHE" ]; then
        printf '%s\n' "$TCPFIT_CACHE"
        return 0
    fi
    return 1
}

fetch_tcpfit() {
    local url tmp
    mkdir -p "$(dirname "$TCPFIT_CACHE")" 2>/dev/null
    tmp="$TCPFIT_CACHE.tmp"
    for url in "$TCPFIT_URL" "$TCPFIT_MIRROR"; do
        info "下载 tcpfit: $url"
        rm -f "$tmp"
        if curl -fsSL --connect-timeout 15 -m 300 -o "$tmp" "$url" 2>/dev/null; then
            if head -1 "$tmp" | grep -q '^#!' \
                && grep -q '^VERSION=' "$tmp" \
                && bash -n "$tmp" 2>/dev/null; then
                mv -f "$tmp" "$TCPFIT_CACHE"
                chmod +x "$TCPFIT_CACHE"
                ok "下载完成（$(du -h "$TCPFIT_CACHE" 2>/dev/null | cut -f1)）"
                return 0
            fi
            warn "下载内容校验失败，换下一个源"
        fi
    done
    rm -f "$tmp"
    return 1
}

run_tcpfit() {
    if command -v tcpfit >/dev/null 2>&1; then
        say "启动已安装的 tcpfit ..."
        tcpfit
        return $?
    fi

    local script
    if script="$(tcpfit_script_path)"; then
        say "使用内置 tcpfit: $script"
    else
        if ! confirm "本地未找到 tcpfit，需要联网下载（约 240 KB），继续?" y; then
            return 1
        fi
        fetch_tcpfit || { err "tcpfit 下载失败"; return 1; }
        script="$TCPFIT_CACHE"
    fi

    say "即将进入 tcpfit 交互界面，退出后回到本菜单。"
    bash "$script"
}

show_tcp_status() {
    say ""
    say "拥塞控制:     $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
    say "默认队列:     $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未知')"
    say "tcp_rmem:     $(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo '未知')"
    say "tcp_wmem:     $(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo '未知')"
    say "rmem_max:     $(sysctl -n net.core.rmem_max 2>/dev/null || echo '未知')"
    say "wmem_max:     $(sysctl -n net.core.wmem_max 2>/dev/null || echo '未知')"
    say "somaxconn:    $(sysctl -n net.core.somaxconn 2>/dev/null || echo '未知')"
    say "tcp_tw_reuse: $(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null || echo '未知')"
    say ""
    if [ -f /etc/sysctl.d/99-tcpfit.conf ]; then
        ok "tcpfit 调优已应用（/etc/sysctl.d/99-tcpfit.conf 存在）"
    else
        info "尚未应用过 tcpfit 调优"
    fi
    if command -v tcpfit >/dev/null 2>&1; then
        ok "tcpfit 命令已安装: $(command -v tcpfit)"
    else
        info "tcpfit 未安装到 /usr/local/bin（可直接用内置脚本运行）"
    fi
    local sp
    if sp="$(tcpfit_script_path)"; then
        ok "内置脚本: $sp"
    fi
}

tcpfit_rollback() {
    if ! command -v tcpfit >/dev/null 2>&1; then
        err "未检测到 tcpfit 命令，无法回滚（请先安装或运行一次）"
        return 1
    fi
    confirm "确认回滚 tcpfit 的全部改动?" n || return 0
    tcpfit rollback
}

tcpfit_uninstall() {
    if ! command -v tcpfit >/dev/null 2>&1; then
        err "未检测到 tcpfit 命令"
        return 1
    fi
    confirm "确认卸载 tcpfit（会先回滚改动）?" n || return 0
    tcpfit uninstall
}

menu_tcp() {
    local choice
    while true; do
        draw_header
        printf '  TCP 调优 · 由 tcpfit 提供（MIT / kylin010）\n'
        printf '%s----------------------------------------------------%s\n' "$C_W" "$C_0"
        printf '  当前算法: %s    当前队列: %s\n' \
            "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')" \
            "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
        if command -v tcpfit >/dev/null 2>&1; then
            printf '  tcpfit:   %s已安装%s\n' "$C_G" "$C_0"
        else
            printf '  tcpfit:   %s未安装%s（可用内置脚本直接运行）\n' "$C_Y" "$C_0"
        fi
        printf '%s----------------------------------------------------%s\n' "$C_W" "$C_0"
        printf '  1) 启动 tcpfit 交互界面（推荐，含一键自动调优）\n'
        printf '  2) 查看当前 TCP 参数\n'
        printf '  3) 回滚 tcpfit 改动\n'
        printf '  4) 卸载 tcpfit\n'
        printf '  b) 返回主菜单\n'
        printf '%s----------------------------------------------------%s\n' "$C_W" "$C_0"
        read -r -p "请选择: " choice || return 0
        case "$choice" in
            1) run_tcpfit; pause ;;
            2) show_tcp_status; pause ;;
            3) tcpfit_rollback; pause ;;
            4) tcpfit_uninstall; pause ;;
            b|B|q|Q) return 0 ;;
            *) warn "无效选项: $choice"; sleep 1 ;;
        esac
    done
}

menu_env() {
    local choice
    while true; do
        draw_header
        draw_status
        printf '  1) 安装 / 检查基础依赖 (curl wget sudo nftables)\n'
        printf '  2) 防火墙接管检查（停用 ufw / firewalld）\n'
        printf '  3) 查看系统信息\n'
        printf '  4) 查看运行日志\n'
        printf '  b) 返回主菜单\n'
        printf '%s----------------------------------------------------%s\n' "$C_W" "$C_0"
        read -r -p "请选择: " choice || return 0
        case "$choice" in
            1) install_packages; pause ;;
            2) takeover_firewall; pause ;;
            3) show_sysinfo; pause ;;
            4) show_log; pause ;;
            b|B|q|Q) return 0 ;;
            *) warn "无效选项: $choice"; sleep 1 ;;
        esac
    done
}

show_sysinfo() {
    say ""
    say "系统:     ${OS_PRETTY}"
    say "内核:     $(uname -r)"
    say "架构:     $(uname -m)"
    say "主机名:   $(hostname)"
    say "内存:     $(free -h 2>/dev/null | awk '/^Mem:/ {print $2 " 总量 / " $7 " 可用"}')"
    say "磁盘:     $(df -h / 2>/dev/null | awk 'NR==2 {print $3 " 已用 / " $2 " (" $5 ")"}')"
    say "运行时间: $(uptime -p 2>/dev/null | sed 's/^up //')"
    say "nftables: $(nft -v 2>/dev/null || echo '未安装')"
    if fw_is_on; then
        say "防火墙:   已启用"
    else
        say "防火墙:   未启用"
    fi
}

show_log() {
    say ""
    if [ -f "$LOG_FILE" ]; then
        tail -n 30 "$LOG_FILE"
    else
        warn "暂无日志"
    fi
}

show_help() {
    say ""
    say "本脚本用于快速初始化 Debian 13 VPS："
    say "  1. 安装 curl / wget / sudo / nftables"
    say "  2. 用 nftables 接管本机防火墙（自动停用 ufw / firewalld）"
    say "  3. 提供终端菜单管理防火墙与放行端口"
    say "  4. 集成 tcpfit：按机器实测推导的 TCP 调优（主菜单第 3 项）"
    say ""
    say "默认放行端口（防火墙首次启用时写入）："
    printf '  %-8s %-6s %s\n' "端口" "协议" "服务"
    local item port proto note
    for item in "${DEFAULT_PORTS[@]}"; do
        IFS='|' read -r port proto note <<< "$item"
        printf '  %-8s %-6s %s\n' "$port" "$proto" "$note"
    done
    say ""
    say "安全提示："
    say "  - 3306 / 5432 / 6379 放行到公网存在被爆破风险，不需要请删除"
    say "  - 防火墙默认关闭，需要手动启用"
    say "  - 通过 SSH 启用防火墙时会有 ${GUARD_SECS} 秒自动回滚保护"
    say ""
    say "文件位置："
    say "  配置目录: $STATE_DIR"
    say "  端口配置: $PORT_DB"
    say "  规则文件: $RULES_NFT"
    say "  系统配置: $NFT_CONF"
    say "  备份目录: $BACKUP_DIR"
}

menu_main() {
    local choice
    while true; do
        draw_header
        draw_status
        printf '  1) 防火墙管理\n'
        printf '  2) 基础环境 / 依赖安装\n'
        printf '  3) TCP 调优 (tcpfit)\n'
        printf '  4) 查看系统信息\n'
        printf '  5) 使用帮助\n'
        printf '  q) 退出\n'
        printf '%s----------------------------------------------------%s\n' "$C_W" "$C_0"
        read -r -p "请选择: " choice || return 0
        case "$choice" in
            1) menu_firewall ;;
            2) menu_env ;;
            3) menu_tcp ;;
            4) show_sysinfo; pause ;;
            5) show_help; pause ;;
            q|Q|exit) return 0 ;;
            *) warn "无效选项: $choice"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------
#  主流程
# ---------------------------------------------------------------------
main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        -v|--version) printf '%s %s\n' "$APP_NAME" "$APP_VERSION"; exit 0 ;;
    esac

    require_root "$@"
    detect_os
    ensure_state
    log "启动 ${APP_NAME} ${APP_VERSION}"

    if [ "$OS_ID" != "debian" ]; then
        warn "当前系统不是 Debian（检测到: ${OS_ID}），脚本仅针对 Debian 13 测试"
        confirm "仍然继续?" n || exit 1
    elif [ -n "$OS_VERSION" ] && [ "${OS_VERSION%%.*}" -lt 13 ] 2>/dev/null; then
        warn "当前 Debian 版本 ${OS_VERSION} 低于 13 (trixie)，部分行为可能不同"
        confirm "仍然继续?" y || exit 1
    fi

    if [ ! -f "$STATE_DIR/.initialized" ]; then
        collect_missing
        if [ "${#MISSING[@]}" -gt 0 ]; then
            say ""
            warn "检测到缺少依赖: ${MISSING[*]}"
            if confirm "现在安装? (curl wget sudo nftables)" y; then
                install_packages
            fi
        fi
        say ""
        takeover_firewall
        : > "$STATE_DIR/.initialized"
        pause
    fi

    menu_main
    say ""
    say "再见。"
}

main "$@"
