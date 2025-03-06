#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
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

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help     显示此帮助信息并退出"
    echo "  --version      显示版本信息并退出"
    echo ""
    echo "描述:"
    echo "  这个脚本是 Cloudflare 证书管理工具的交互式设置向导。"
    echo "  它将引导您设置环境变量、创建证书目录、设置计划任务，并可选择立即创建证书。"
    echo ""
    echo "示例:"
    echo "  $0             启动交互式设置向导"
    echo "  $0 --help      显示帮助信息"
    echo ""
    exit 0
}

# 显示版本信息
show_version() {
    echo "Cloudflare 证书管理工具 - 交互式设置向导 v1.0"
    echo "作者: Claude AI"
    echo "日期: $(date +%Y-%m-%d)"
    exit 0
}

# 处理命令行参数
for arg in "$@"; do
    case $arg in
        -h|--help)
            show_help
            ;;
        --version)
            show_version
            ;;
        *)
            print_error "未知选项: $arg"
            echo "使用 '$0 --help' 获取更多信息。"
            exit 1
            ;;
    esac
done

# 检查命令是否存在
check_command() {
    if ! command -v $1 &> /dev/null; then
        return 1
    fi
    return 0
}

# 检查 Python
if check_command python; then
    PYTHON_CMD="python"
elif check_command python3; then
    PYTHON_CMD="python3"
else
    print_error "错误: 未找到 python 或 python3 命令，请先安装。"
    exit 1
fi
print_info "找到 Python 命令: $PYTHON_CMD"

# 检查 OpenSSL
if ! check_command openssl; then
    print_error "错误: 未找到 openssl 命令，请先安装。"
    exit 1
fi

# 欢迎信息
clear
print_title "Cloudflare 证书管理工具 - 交互式设置"
echo "这个脚本将帮助您设置 Cloudflare 证书管理系统。"
echo "您需要提供一些必要的信息，如 Cloudflare Origin CA Key、域名和主机名。"
echo ""

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
    print_warning "警告: 此脚本需要 root 权限才能创建环境变量文件和证书目录。"
    echo "请使用 sudo 运行此脚本。"
    exit 1
fi

# 创建环境变量目录
print_title "创建环境变量目录"
mkdir -p /etc/cloudflare
if [ $? -ne 0 ]; then
    print_error "创建目录 /etc/cloudflare 失败！"
    exit 1
fi
print_info "成功创建目录: /etc/cloudflare"

# 创建证书目录
print_title "创建证书目录"
mkdir -p /etc/cert
if [ $? -ne 0 ]; then
    print_error "创建目录 /etc/cert 失败！"
    exit 1
fi
print_info "成功创建目录: /etc/cert"

# 收集用户输入
print_title "收集必要信息"

# 获取 Cloudflare Origin CA Key
echo "请输入您的 Cloudflare Origin CA Key:"
echo "（可以在 Cloudflare 控制面板 > SSL/TLS > Origin Server > Create Certificate 页面底部找到）"
read -p "Origin CA Key: " origin_ca_key
while [ -z "$origin_ca_key" ]; do
    print_error "Origin CA Key 不能为空！"
    read -p "Origin CA Key: " origin_ca_key
done

# 获取域名
echo ""
echo "请输入您的域名（例如: example.com）:"
read -p "域名: " domain
while [ -z "$domain" ]; do
    print_error "域名不能为空！"
    read -p "域名: " domain
done

# 获取主机名
echo ""
echo "请输入您的主机名（例如: www.example.com）:"
read -p "主机名: " hostname
while [ -z "$hostname" ]; do
    print_error "主机名不能为空！"
    read -p "主机名: " hostname
done

# 获取通知邮箱（可选）
echo ""
echo "请输入通知邮箱（可选，用于接收证书更新通知）:"
read -p "通知邮箱: " email

# 创建环境变量文件
print_title "创建环境变量文件"
cat > /etc/cloudflare/env << EOF
CLOUDFLARE_ORIGIN_CA_KEY="$origin_ca_key"
CERT_DOMAIN="$domain"
CERT_HOSTNAME="$hostname"
NOTIFICATION_EMAIL="$email"
EOF

# 设置文件权限
chmod 600 /etc/cloudflare/env
print_info "成功创建环境变量文件: /etc/cloudflare/env"
print_info "已设置文件权限为 600（仅 root 用户可读写）"

# 询问是否设置计划任务
print_title "设置计划任务"
echo "是否设置计划任务，每 90 天自动更新证书？"
read -p "是否设置计划任务？(y/n): " setup_cron
if [[ "$setup_cron" =~ ^[Yy]$ ]]; then
    # 获取脚本路径
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # 创建 crontab 文件
    cat > /etc/cron.d/cert_update << EOF
# 每 90 天更新一次证书（在每月 1 日的凌晨 3:00 执行）
0 3 1 */3 * root $script_dir/update_certificate.sh
EOF
    print_info "成功创建计划任务: /etc/cron.d/cert_update"
else
    print_info "跳过计划任务设置"
fi

# 询问是否立即创建证书
print_title "创建证书"
echo "是否立即创建证书？"
read -p "是否立即创建证书？(y/n): " create_cert
if [[ "$create_cert" =~ ^[Yy]$ ]]; then
    print_info "开始创建证书..."
    
    # 获取脚本路径
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # 执行证书创建脚本
    source /etc/cloudflare/env && $script_dir/update_certificate.sh
    
    if [ $? -eq 0 ]; then
        print_info "证书创建成功！"
        echo "证书文件保存在: /etc/cert/$hostname.crt"
        echo "密钥文件保存在: /etc/cert/$hostname.key"
        echo "指纹文件保存在: /etc/cert/$hostname.fingerprint"
    else
        print_error "证书创建失败！请检查日志文件: /var/log/cert_update.log"
    fi
else
    print_info "跳过证书创建"
    echo "您可以稍后通过以下命令手动创建证书:"
    echo "  source /etc/cloudflare/env && $script_dir/update_certificate.sh"
fi

# 完成信息
print_title "设置完成"
echo "Cloudflare 证书管理系统设置已完成！"
echo ""
echo "环境变量文件: /etc/cloudflare/env"
echo "证书目录: /etc/cert/"
echo "日志文件: /var/log/cert_update.log"
echo ""
echo "如需手动更新证书，请运行:"
echo "  source /etc/cloudflare/env && $script_dir/update_certificate.sh"
echo ""
echo "如需查看证书更新日志，请运行:"
echo "  sudo cat /var/log/cert_update.log"
echo ""
print_info "感谢使用 Cloudflare 证书管理工具！" 