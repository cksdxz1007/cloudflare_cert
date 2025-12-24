#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色

# 打印带颜色的标题
print_title() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

# 打印带颜色的信息
print_info() {
    echo -e "${GREEN}$1${NC}"
}

# 打印带颜色的警告
print_warning() {
    echo -e "${YELLOW}$1${NC}"
}

# 打印带颜色的错误
print_error() {
    echo -e "${RED}$1${NC}"
}

# 打印带颜色的选项
print_option() {
    echo -e "${CYAN}$1${NC}"
}

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help     显示此帮助信息并退出"
    echo "  --version      显示版本信息并退出"
    echo "  --add-domain   添加新域名配置"
    echo "  --list         列出所有已配置域名"
    echo "  --remove       删除域名配置"
    echo ""
    echo "描述:"
    echo "  Cloudflare 证书管理工具的交互式设置向导。"
    echo "  支持多域名管理，每个域名单独配置和调度。"
    echo ""
    echo "示例:"
    echo "  $0             启动交互式设置向导（首次配置）"
    echo "  $0 --add-domain 添加新域名"
    echo "  $0 --list      列出所有域名"
    echo "  $0 --remove    删除域名配置"
    echo ""
    exit 0
}

# 显示版本信息
show_version() {
    echo "Cloudflare 证书管理工具 v2.0"
    echo "支持多域名独立配置"
    echo "日期: $(date +%Y-%m-%d)"
    exit 0
}

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"

# 检查 Python
check_python() {
    if command -v python &> /dev/null; then
        PYTHON_CMD="python"
    elif command -v python3 &> /dev/null; then
        PYTHON_CMD="python3"
    else
        print_error "错误: 未找到 python 或 python3 命令，请先安装。"
        exit 1
    fi
    # 检查 pyyaml
    if ! $PYTHON_CMD -c "import yaml" 2>/dev/null; then
        print_error "错误: 未安装 pyyaml 库，请运行: pip install pyyaml"
        exit 1
    fi
    print_info "Python 环境检查通过"
}

# 检查 OpenSSL
check_openssl() {
    if ! command -v openssl &> /dev/null; then
        print_error "错误: 未找到 openssl 命令，请先安装。"
        exit 1
    fi
    print_info "OpenSSL 检查通过"
}

# 初始化配置文件
init_config() {
    if [ -f "$CONFIG_FILE" ]; then
        print_info "配置文件已存在: $CONFIG_FILE"
        return 0
    fi

    print_title "初始化配置文件"
    echo "将基于 config.example.yaml 创建配置文件..."

    cp "${SCRIPT_DIR}/config.example.yaml" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    print_info "已创建配置文件: $CONFIG_FILE"
}

# 备份配置文件
backup_config() {
    if [ -f "$CONFIG_FILE" ]; then
        backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        cp "$CONFIG_FILE" "$backup_file"
        print_info "已备份配置文件到: $backup_file"
    fi
}

# 读取配置中的默认 Origin CA Key
get_default_origin_ca_key() {
    $PYTHON_CMD -c "
import yaml
with open('$CONFIG_FILE', 'r') as f:
    config = yaml.safe_load(f)
    default = config.get('default', {})
    key = default.get('origin_ca_key', '')
    if key and key != 'your-origin-ca-key':
        print(key)
"
}

# 检查配置是否已初始化
is_config_initialized() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi

    default_key=$($PYTHON_CMD -c "
import yaml
with open('$CONFIG_FILE', 'r') as f:
    config = yaml.safe_load(f)
    default = config.get('default', {})
    key = default.get('origin_ca_key', '')
    print(key)
" 2>/dev/null)

    if [ -z "$default_key" ] || [ "$default_key" = "your-origin-ca-key" ]; then
        return 1
    fi
    return 0
}

# 添加新域名
add_domain() {
    print_title "添加新域名配置"

    # 检查配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        print_warning "配置文件不存在，将先初始化..."
        init_config
    fi

    # 获取 Cloudflare Origin CA Key
    echo ""
    echo "请输入您的 Cloudflare Origin CA Key:"
    echo "（可以在 Cloudflare 控制面板 > SSL/TLS > Origin Server > Create Certificate 页面底部找到）"
    read -p "Origin CA Key (直接回车使用全局默认): " origin_ca_key

    # 获取域名
    echo ""
    echo "请输入要添加的域名（例如: example.com）:"
    read -p "域名: " domain
    while [ -z "$domain" ]; do
        print_error "域名不能为空！"
        read -p "域名: " domain
    done

    # 获取主机名
    echo ""
    echo "请输入该域名的主机名（可输入多个，空格分隔，例如: www.example.com api.example.com）:"
    read -p "主机名: " hostname
    while [ -z "$hostname" ]; do
        print_error "主机名不能为空！"
        read -p "主机名: " hostname
    done

    # 获取通知邮箱（可选）
    echo ""
    echo "请输入通知邮箱（可选，用于接收证书更新通知）:"
    read -p "通知邮箱: " email

    # 询问是否需要自动获取 Zone ID
    echo ""
    echo "是否需要自动获取 Zone ID？"
    read -p "自动获取 Zone ID？(y/n): " get_zone_id

    zone_id=""
    if [[ "$get_zone_id" =~ ^[Yy]$ ]]; then
        echo ""
        echo "请在 Cloudflare 控制面板创建一个只有「Zone:Zone:Read」权限的 API Token"
        read -s -p "输入 API Token: " cf_api_token
        echo

        if [ -n "$cf_api_token" ]; then
            echo "正在通过 Cloudflare API 获取 zoneID..."
            zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$domain" \
                -H "Authorization: Bearer $cf_api_token" \
                -H "Content-Type: application/json" | \
                grep -o '"id":"[a-zA-Z0-9]\{32\}"' | head -n1 | cut -d'"' -f4)

            if [ -z "$zone_id" ]; then
                print_error "zoneID 获取失败，请检查 API Token 和域名是否正确！"
                print_warning "将继续而不设置 zoneID。"
            else
                print_info "成功获取 zoneID: $zone_id"
            fi
        fi
    fi

    # 询问是否设置计划任务
    echo ""
    echo "是否为该域名设置自动更新计划任务？"
    read -p "设置计划任务？(y/n): " setup_cron

    # 备份配置
    backup_config

    # 更新配置文件
    $PYTHON_CMD << PYEOF
import yaml
import sys

# 读取现有配置
try:
    with open('$CONFIG_FILE', 'r') as f:
        config = yaml.safe_load(f)
except:
    config = {'default': {}, 'domains': {}}

# 确保结构存在
if 'default' not in config:
    config['default'] = {}
if 'domains' not in config:
    config['domains'] = {}

# 更新默认配置
if not config['default'].get('origin_ca_key') or '$origin_ca_key':
    config['default']['origin_ca_key'] = '$origin_ca_key' if '$origin_ca_key' else config['default'].get('origin_ca_key', '')

# 添加新域名配置
config['domains']['$domain'] = {
    'hostnames': '$hostname'.split(),
}

if '$zone_id':
    config['domains']['$domain']['zone_id'] = '$zone_id'

if '$email':
    config['domains']['$domain']['notification_email'] = '$email'

if '$setup_cron' and '$setup_cron'.lower() in ['y', 'yes']:
    config['domains']['$domain']['enable_cron'] = True

# 写入配置
with open('$CONFIG_FILE', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True)

print("配置已更新")
PYEOF

    if [ $? -eq 0 ]; then
        print_info "域名 $domain 添加成功！"
    else
        print_error "域名添加失败！"
        exit 1
    fi

    # 询问是否立即创建证书
    echo ""
    echo "是否立即为该域名创建证书？"
    read -p "立即创建证书？(y/n): " create_cert
    if [[ "$create_cert" =~ ^[Yy]$ ]]; then
        print_info "开始创建证书..."
        $PYTHON_CMD "${SCRIPT_DIR}/cert_manager.py" --config "$CONFIG_FILE" --domain "$domain"
        if [ $? -eq 0 ]; then
            print_info "证书创建成功！"
        else
            print_error "证书创建失败！请检查日志"
        fi
    fi

    print_title "添加完成"
}

# 列出所有域名
list_domains() {
    print_title "已配置域名列表"

    if [ ! -f "$CONFIG_FILE" ]; then
        print_warning "尚未配置任何域名"
        return
    fi

    domains=$($PYTHON_CMD -c "
import yaml
with open('$CONFIG_FILE', 'r') as f:
    config = yaml.safe_load(f)
    domains = config.get('domains', {})
    for domain, cfg in domains.items():
        hostnames = ', '.join(cfg.get('hostnames', []))
        cron = '是' if cfg.get('enable_cron', True) else '否'
        print(f'{domain}: {hostnames} (自动更新: {cron})')
" 2>/dev/null)

    if [ -n "$domains" ]; then
        echo "$domains"
    else
        print_warning "未找到已配置的域名"
    fi
}

# 删除域名
remove_domain() {
    print_title "删除域名配置"

    if [ ! -f "$CONFIG_FILE" ]; then
        print_warning "尚未配置任何域名"
        return
    fi

    # 获取域名列表
    domains=$($PYTHON_CMD -c "
import yaml
with open('$CONFIG_FILE', 'r') as f:
    config = yaml.safe_load(f)
    domains = list(config.get('domains', {}).keys())
    print(' '.join(domains))
" 2>/dev/null)

    if [ -z "$domains" ]; then
        print_warning "未找到已配置的域名"
        return
    fi

    echo "已配置的域名: $domains"
    echo ""
    read -p "请输入要删除的域名: " domain

    if [ -z "$domain" ]; then
        print_error "域名不能为空！"
        return
    fi

    # 确认删除
    echo ""
    echo "警告: 将删除域名 $domain 的配置和证书文件！"
    read -p "确认删除？(y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消删除"
        return
    fi

    # 备份配置
    backup_config

    # 删除配置
    $PYTHON_CMD << PYEOF
import yaml

with open('$CONFIG_FILE', 'r') as f:
    config = yaml.safe_load(f)

if 'domains' in config and '$domain' in config['domains']:
    del config['domains']['$domain']

    with open('$CONFIG_FILE', 'w') as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)

    print("配置已更新")
else:
    print("域名不存在")
PYEOF

    if [ $? -eq 0 ]; then
        print_info "域名 $domain 已删除"
    else
        print_error "删除失败！"
    fi
}

# 首次配置向导
wizard() {
    print_title "Cloudflare 证书管理工具设置向导"

    # 检查依赖
    check_python
    check_openssl

    # 初始化配置
    init_config

    # 获取全局 Origin CA Key
    echo ""
    print_title "设置全局配置"
    echo "请输入您的 Cloudflare Origin CA Key:"
    echo "（此 Key 将作为所有域名的默认值，可单独覆盖）"
    read -p "Origin CA Key: " origin_ca_key
    while [ -z "$origin_ca_key" ]; do
        print_error "Origin CA Key 不能为空！"
        read -p "Origin CA Key: " origin_ca_key
    done

    # 设置默认参数
    echo ""
    echo "设置默认证书参数（可直接回车使用默认值）:"
    read -p "证书类型 [origin-rsa]: " cert_type
    cert_type=${cert_type:-origin-rsa}

    read -p "有效期(天) [90]: " validity
    validity=${validity:-90}

    read -p "证书基础目录 [/etc/cert]: " cert_dir
    cert_dir=${cert_dir:-/etc/cert}

    # 创建配置
    $PYTHON_CMD << PYEOF
import yaml

config = {
    'default': {
        'origin_ca_key': '$origin_ca_key',
        'cert_type': '$cert_type',
        'validity_days': int($validity),
        'base_cert_dir': '$cert_dir',
        'enable_cron': True,
        'notification_email': ''
    },
    'domains': {}
}

with open('$CONFIG_FILE', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True)

print("配置已创建")
PYEOF

    print_info "全局配置已保存"

    # 添加第一个域名
    echo ""
    echo "现在添加您的第一个域名配置..."
    echo ""
    read -p "是否添加域名配置？(y/n): " add_first
    if [[ "$add_first" =~ ^[Yy]$ ]]; then
        add_domain
    fi

    print_title "设置完成"
    echo "配置文件: $CONFIG_FILE"
    echo ""
    echo "常用命令:"
    echo "  添加域名: $0 --add-domain"
    echo "  列出域名: $0 --list"
    echo "  删除域名: $0 --remove"
    echo "  创建证书: python ${SCRIPT_DIR}/cert_manager.py --config $CONFIG_FILE --domain example.com"
}

# 处理命令行参数
case "${1:-}" in
    -h|--help)
        show_help
        ;;
    --version)
        show_version
        ;;
    --add-domain)
        check_python
        add_domain
        ;;
    --list)
        list_domains
        ;;
    --remove)
        check_python
        remove_domain
        ;;
    "")
        wizard
        ;;
    *)
        print_error "未知选项: $1"
        echo "使用 '$0 --help' 获取更多信息。"
        exit 1
        ;;
esac
