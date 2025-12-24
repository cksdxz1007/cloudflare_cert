#!/bin/bash

# Cloudflare 证书更新脚本
# 支持从 config.yaml 读取配置，更新指定域名的证书

# 设置日志文件
LOG_FILE="/var/log/cert_update.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"

# 记录日志
log() {
    echo "$(date): $1" >> "$LOG_FILE"
}

# 检查 Python 命令
check_python() {
    if command -v python &> /dev/null; then
        PYTHON_CMD="python"
    elif command -v python3 &> /dev/null; then
        PYTHON_CMD="python3"
    else
        log "错误 - 未找到 python 或 python3 命令，请先安装。"
        echo "错误: 未找到 python 命令"
        exit 1
    fi

    # 检查 pyyaml
    if ! $PYTHON_CMD -c "import yaml" 2>/dev/null; then
        log "错误 - 未安装 pyyaml 库"
        echo "错误: 未安装 pyyaml 库，请运行: pip install pyyaml"
        exit 1
    fi
}

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help     显示此帮助信息"
    echo "  --domain       指定要更新的域名（必填）"
    echo "  --config       指定配置文件路径（默认: config.yaml）"
    echo "  --all          更新所有已配置域名（互斥于 --domain）"
    echo ""
    echo "示例:"
    echo "  $0 --domain example.com     # 更新单个域名"
    echo "  $0 --all                    # 更新所有域名"
    echo ""
}

# 解析命令行参数
DOMAIN=""
UPDATE_ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --all)
            UPDATE_ALL=true
            shift
            ;;
        *)
            echo "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

# 检查配置文件
check_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "错误 - 配置文件不存在: $CONFIG_FILE"
        echo "错误: 配置文件不存在: $CONFIG_FILE"
        exit 1
    fi
}

# 更新单个域名证书
update_domain() {
    local domain="$1"
    local log_prefix="[${domain}]"

    log "${log_prefix} 开始更新证书..."

    # 检查域名是否在配置中
    local hostnames=$($PYTHON_CMD -c "
import yaml
with open('$CONFIG_FILE', 'r') as f:
    config = yaml.safe_load(f)
    domains = config.get('domains', {})
    if '$domain' in domains:
        print(' '.join(domains['$domain'].get('hostnames', [])))
" 2>/dev/null)

    if [ -z "$hostnames" ]; then
        log "${log_prefix} 错误 - 域名未配置"
        echo "[${domain}] 域名未配置"
        return 1
    fi

    # 调用 Python 脚本更新证书
    $PYTHON_CMD "${SCRIPT_DIR}/cert_manager.py" \
        --config "$CONFIG_FILE" \
        --domain "$domain" >> "$LOG_FILE" 2>&1

    if [ $? -eq 0 ]; then
        log "${log_prefix} 证书更新成功"
        echo "[${domain}] 证书更新成功"
        return 0
    else
        log "${log_prefix} 证书更新失败"
        echo "[${domain}] 证书更新失败"
        return 1
    fi
}

# 主程序
main() {
    log "========== 开始证书更新 =========="

    # 检查环境
    check_python
    check_config

    local success=0
    local fail=0

    if [ "$UPDATE_ALL" = true ]; then
        # 更新所有域名
        log "开始更新所有域名的证书"

        domains=$($PYTHON_CMD -c "
import yaml
with open('$CONFIG_FILE', 'r') as f:
    config = yaml.safe_load(f)
    domains = list(config.get('domains', {}).keys())
    print(' '.join(domains))
" 2>/dev/null)

        if [ -z "$domains" ]; then
            log "错误 - 没有已配置的域名"
            echo "错误: 没有已配置的域名"
            exit 1
        fi

        for domain in $domains; do
            if update_domain "$domain"; then
                ((success++))
            else
                ((fail++))
            fi
        done

        echo ""
        log "完成: 成功 ${success}, 失败 ${fail}"
        log "========== 证书更新结束 =========="

    elif [ -n "$DOMAIN" ]; then
        # 更新单个域名
        if update_domain "$DOMAIN"; then
            success=1
        else
            fail=1
        fi
    else
        echo "错误: 请指定 --domain 或 --all"
        show_help
        exit 1
    fi

    # 返回适当的退出码
    if [ $fail -gt 0 ]; then
        exit 1
    fi
    exit 0
}

main
