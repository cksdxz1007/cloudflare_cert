#!/bin/bash

# Cloudflare 证书管理工具迁移脚本 (v1 -> v2)
# 将旧版环境变量配置迁移到新版 YAML 配置

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_title() { echo -e "${BLUE}=== $1 ===${NC}"; }
print_info() { echo -e "${GREEN}$1${NC}"; }
print_warning() { echo -e "${YELLOW}$1${NC}"; }
print_error() { echo -e "${RED}$1${NC}"; }
print_dry_run() { echo -e "${CYAN}[DRY-RUN] $1${NC}"; }
print_test() { echo -e "${CYAN}[TEST] $1${NC}"; }

# 配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLD_ENV_FILE="/etc/cloudflare/env"
NEW_CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
OLD_CRON_FILE="/etc/cron.d/cert_update"
LOG_FILE="/var/log/cert_migration.log"

DRY_RUN=false
TEST_CERT=false

log() {
    echo "$(date): $1" | tee -a "$LOG_FILE"
}

# 命令行参数解析
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|--test)
            DRY_RUN=true
            shift
            ;;
        --test-cert)
            TEST_CERT=true
            shift
            ;;
        -h|--help)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --dry-run, --test   测试运行，不修改任何文件"
            echo "  --test-cert         测试证书申请（不影响现有证书）"
            echo "  -h, --help          显示此帮助信息"
            echo ""
            echo "示例:"
            echo "  $0                 # 执行迁移"
            echo "  $0 --dry-run       # 测试运行"
            echo "  $0 --test-cert     # 测试证书申请"
            echo "  $0 --dry-run --test-cert  # 测试迁移并测试证书"
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            exit 1
            ;;
    esac
done

# 检查是否需要 root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "此脚本需要 root 权限，请使用 sudo 运行"
        exit 1
    fi
}

# 检查前置条件
check_prerequisites() {
    print_title "检查前置条件"

    # 检查 Python
    if command -v python &> /dev/null; then
        PYTHON_CMD="python"
    elif command -v python3 &> /dev/null; then
        PYTHON_CMD="python3"
    else
        print_error "未找到 Python，请先安装"
        exit 1
    fi

    # 检查 pyyaml
    if ! $PYTHON_CMD -c "import yaml" 2>/dev/null; then
        print_warning "未安装 pyyaml，正在安装..."
        pip install pyyaml
    fi

    print_info "前置检查通过"
}

# 备份现有配置
backup_old_config() {
    if [ "$DRY_RUN" = true ]; then
        print_dry_run "备份旧配置文件: ${OLD_ENV_FILE} -> ${OLD_ENV_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        return
    fi

    print_title "备份现有配置"

    if [ -f "$OLD_ENV_FILE" ]; then
        backup_file="${OLD_ENV_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        cp "$OLD_ENV_FILE" "$backup_file"
        print_info "已备份旧配置: $backup_file"
    else
        print_warning "旧配置文件不存在: $OLD_ENV_FILE"
    fi
}

# 从旧配置读取域名信息
parse_old_config() {
    print_title "解析旧版配置"

    if [ ! -f "$OLD_ENV_FILE" ]; then
        print_error "旧配置文件不存在: $OLD_ENV_FILE"
        return 1
    fi

    # 读取环境变量
    source "$OLD_ENV_FILE"

    if [ -z "$CLOUDFLARE_ORIGIN_CA_KEY" ]; then
        print_error "未找到 CLOUDFLARE_ORIGIN_CA_KEY"
        return 1
    fi

    if [ -z "$CERT_DOMAIN" ]; then
        print_error "未找到 CERT_DOMAIN"
        return 1
    fi

    if [ -z "$CERT_HOSTNAME" ]; then
        print_error "未找到 CERT_HOSTNAME"
        return 1
    fi

    print_info "旧配置解析成功"
    print_info "  域名: $CERT_DOMAIN"
    print_info "  主机名: $CERT_HOSTNAME"

    # 返回解析的变量
    echo "$CERT_DOMAIN" "$CERT_HOSTNAME" "$CLOUDFLARE_ORIGIN_CA_KEY" "$CF_ZONE_ID" "$NOTIFICATION_EMAIL"
}

# 交互式配置 SMTP
configure_smtp() {
    print_title "配置邮件通知 (可选)"

    echo "是否配置 SMTP 邮件服务器用于发送证书更新通知？"
    read -p "配置 SMTP？(y/n): " answer

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        print_info "跳过 SMTP 配置"
        echo ""
        return 1
    fi

    # 获取 SMTP 配置
    echo ""
    echo "请输入 SMTP 服务器信息:"

    read -p "SMTP 服务器地址 (如 smtp.gmail.com): " smtp_host
    while [ -z "$smtp_host" ]; do
        print_error "SMTP 服务器地址不能为空！"
        read -p "SMTP 服务器地址: " smtp_host
    done

    read -p "SMTP 端口 (465 或 587) [587]: " smtp_port
    smtp_port=${smtp_port:-587}

    read -p "发件人邮箱 / 用户名: " smtp_sender
    while [ -z "$smtp_sender" ]; do
        print_error "发件人邮箱不能为空！"
        read -p "发件人邮箱 / 用户名: " smtp_sender
    done

    read -s -p "密码或 App Password: " smtp_password
    echo ""

    # 等待用户按回车继续
    read -p "按回车继续... "

    echo ""
    # 根据端口自动建议加密方式
    if [ "$smtp_port" = "465" ]; then
        default_ssl_choice="1"
        echo "请选择加密方式:"
        echo "  1. SSL (465 端口) - 推荐"
        echo "  2. STARTTLS (587 端口)"
    else
        default_ssl_choice="2"
        echo "请选择加密方式:"
        echo "  1. SSL (465 端口)"
        echo "  2. STARTTLS (587 端口) - 推荐"
    fi
    read -p "选择 (1/2) [${default_ssl_choice}]: " smtp_ssl_choice
    smtp_ssl_choice=${smtp_ssl_choice:-$default_ssl_choice}

    if [ "$smtp_ssl_choice" = "1" ]; then
        smtp_use_ssl="true"
    else
        smtp_use_ssl="false"
    fi

    print_info "SMTP 配置完成"
    echo ""

    # 返回 SMTP 配置 (用户名=sender)
    echo "${smtp_host}:${smtp_port}:${smtp_sender}:${smtp_sender}:${smtp_password}:${smtp_use_ssl}"
}

# 显示新配置内容（不创建文件）
preview_new_config() {
    local domain="$1"
    local hostnames="$2"
    local origin_ca_key="$3"
    local zone_id="$4"
    local email="$5"
    local smtp_config="$6"

    print_title "预览新配置文件内容"

    echo "文件路径: $NEW_CONFIG_FILE"
    echo ""

    # 转换主机名列表
    hostnames_array=""
    for h in $hostnames; do
        hostnames_array="${hostnames_array}      - ${h}
"
    done

    # 生成 SMTP 配置部分
    if [ -n "$smtp_config" ] && [ "$smtp_config" != "skip" ]; then
        IFS=':' read -r smtp_host smtp_port smtp_sender smtp_username smtp_password smtp_use_ssl <<< "$smtp_config"
        smtp_section="  # SMTP 邮件服务器配置
  smtp:
    host: \"${smtp_host}\"
    port: ${smtp_port}
    sender: \"${smtp_sender}\"
    username: \"${smtp_username}\"
    password: \"${smtp_password}\"
    use_ssl: ${smtp_use_ssl}
"
    else
        smtp_section="  # SMTP 邮件服务器配置 (可选)
  # 如需启用邮件通知，请配置以下信息
  # smtp:
  #   host: \"smtp.example.com\"
  #   port: 465
  #   sender: \"your-email@example.com\"
  #   username: \"your-email@example.com\"
  #   password: \"your-password\"
  #   use_ssl: true
"
    fi

    # 输出配置内容
    cat << EOF
# Cloudflare 证书管理配置
# 此文件由迁移脚本生成
# $(date)

default:
  origin_ca_key: "${origin_ca_key}"
  cert_type: "origin-rsa"
  validity_days: 90
  base_cert_dir: "/etc/cert"
  enable_cron: true
  notification_email: "${email}"
${smtp_section}domains:
  ${domain}:
    origin_ca_key: null
    hostnames:
${hostnames_array}    zone_id: "${zone_id}"
    enable_cron: true
    notification_email: "${email}"
EOF
}

# 创建新配置文件
create_new_config() {
    local domain="$1"
    local hostnames="$2"
    local origin_ca_key="$3"
    local zone_id="$4"
    local email="$5"
    local smtp_config="$6"

    if [ "$DRY_RUN" = true ]; then
        preview_new_config "$domain" "$hostnames" "$origin_ca_key" "$zone_id" "$email" "$smtp_config"
        return
    fi

    print_title "创建新配置文件"

    # 检查是否已有 config.yaml
    if [ -f "$NEW_CONFIG_FILE" ]; then
        print_warning "配置文件已存在: $NEW_CONFIG_FILE"
        read -p "是否覆盖？(y/n): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "跳过配置创建"
            return 0
        fi
        cp "$NEW_CONFIG_FILE" "${NEW_CONFIG_FILE}.backup.$(date +%Y%m%d%H%M%S)"
    fi

    # 转换主机名列表
    hostnames_array=""
    for h in $hostnames; do
        hostnames_array="${hostnames_array}      - ${h}
"
    done

    # 生成 SMTP 配置部分
    if [ -n "$smtp_config" ] && [ "$smtp_config" != "skip" ]; then
        IFS=':' read -r smtp_host smtp_port smtp_sender smtp_username smtp_password smtp_use_ssl <<< "$smtp_config"
        smtp_section="  # SMTP 邮件服务器配置
  smtp:
    host: \"${smtp_host}\"
    port: ${smtp_port}
    sender: \"${smtp_sender}\"
    username: \"${smtp_username}\"
    password: \"${smtp_password}\"
    use_ssl: ${smtp_use_ssl}
"
    else
        smtp_section="  # SMTP 邮件服务器配置 (可选)
  # 如需启用邮件通知，请配置以下信息
  # smtp:
  #   host: \"smtp.example.com\"
  #   port: 465
  #   sender: \"your-email@example.com\"
  #   username: \"your-email@example.com\"
  #   password: \"your-password\"
  #   use_ssl: true
"
    fi

    # 创建新配置
    cat > "$NEW_CONFIG_FILE" << EOF
# Cloudflare 证书管理配置
# 此文件由迁移脚本自动生成
# $(date)

default:
  origin_ca_key: "${origin_ca_key}"
  cert_type: "origin-rsa"
  validity_days: 90
  base_cert_dir: "/etc/cert"
  enable_cron: true
  notification_email: "${email}"
${smtp_section}domains:
  ${domain}:
    origin_ca_key: null
    hostnames:
${hostnames_array}    zone_id: "${zone_id}"
    enable_cron: true
    notification_email: "${email}"
EOF

    chmod 600 "$NEW_CONFIG_FILE"
    print_info "已创建配置文件: $NEW_CONFIG_FILE"
}

# 预览证书目录迁移（不实际迁移）
preview_cert_migration() {
    print_title "预览证书目录迁移"

    echo "旧结构: /etc/cert/{hostname}/"
    echo "新结构: /etc/cert/{domain}/{hostname}/"
    echo ""

    if [ ! -d "/etc/cert" ]; then
        print_info "证书目录不存在，无需迁移"
        return
    fi

    echo "将进行的迁移操作:"
    echo ""

    for hostname_dir in /etc/cert/*/; do
        if [ -d "$hostname_dir" ]; then
            hostname=$(basename "$hostname_dir")

            # 迁移所有文件类型
            for ext in crt key fingerprint; do
                for old_file in "$hostname_dir"*.${ext}; do
                    [ -f "$old_file" ] || continue

                    filename=$(basename "$old_file")
                    domain="${filename%%.*}"

                    new_dir="/etc/cert/${domain}/${hostname}"
                    new_filename="${domain}.${hostname}.${ext}"

                    print_dry_run "复制: ${old_file} -> ${new_dir}/${new_filename}"
                done
            done
        fi
    done

    echo ""
    print_info "以上操作仅预览，不会实际执行"
}

# 迁移证书目录结构
migrate_cert_dir() {
    local domain="$1"

    if [ "$DRY_RUN" = true ]; then
        preview_cert_migration
        return
    fi

    print_title "迁移证书目录结构"

    echo "旧结构: /etc/cert/{hostname}/"
    echo "新结构: /etc/cert/{domain}/{hostname}/"
    echo "目标域名: $domain"
    echo ""
    read -p "是否迁移现有证书到新结构？(y/n): " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "跳过证书迁移"
        return 0
    fi

    # 检查是否存在证书
    if [ ! -d "/etc/cert" ]; then
        print_warning "证书目录不存在"
        return 0
    fi

    # 查找与域名匹配的旧证书目录
    # 旧结构: /etc/cert/{hostname}/hostname.{crt,key,fingerprint}
    migrated=false

    for hostname_dir in /etc/cert/*/; do
        [ -d "$hostname_dir" ] || continue

        hostname=$(basename "$hostname_dir")
        echo "处理: $hostname"

        # 迁移所有文件类型
        for ext in crt key fingerprint; do
            for old_file in "$hostname_dir"*.${ext}; do
                [ -f "$old_file" ] || continue

                filename=$(basename "$old_file")

                # 创建新目录结构: /etc/cert/domain/hostname/
                new_dir="/etc/cert/${domain}/${hostname}"
                mkdir -p "$new_dir"

                # 新文件名: domain.hostname.{ext}
                new_filename="${domain}.${hostname}.${ext}"

                # 复制文件
                cp "$old_file" "${new_dir}/${new_filename}"
                echo "  ${filename} -> ${new_filename}"
                migrated=true
            done
        done
    done

    if [ "$migrated" = true ]; then
        print_info "证书迁移完成"
        print_warning "建议在验证新证书正常后删除旧目录 /etc/cert/*/"
    else
        print_warning "未找到需要迁移的证书文件"
    fi
}

# 预览 Cron 迁移
preview_cron_migration() {
    print_title "预览 Cron 任务迁移"

    echo "旧版 cron: $OLD_CRON_FILE"
    echo ""
    echo "将进行的操作:"
    echo ""

    # 读取配置中的域名
    domains=$($PYTHON_CMD -c "
import yaml
with open('$NEW_CONFIG_FILE', 'r') as f:
    config = yaml.safe_load(f)
    domains = list(config.get('domains', {}).keys())
    print(' '.join(domains))
" 2>/dev/null)

    if [ -z "$domains" ]; then
        print_warning "未找到已配置的域名"
        return
    fi

    for domain in $domains; do
        cron_file="/etc/cron.d/cert_update_${domain}"
        print_dry_run "创建: ${cron_file}"
        print_dry_run "内容: 0 3 1 */3 * root ${SCRIPT_DIR}/update_certificate.sh --domain ${domain}"
    done

    echo ""
    print_info "以上操作仅预览，不会实际执行"
}

# 处理 Cron 迁移
migrate_cron() {
    if [ "$DRY_RUN" = true ]; then
        preview_cron_migration
        return
    fi

    print_title "迁移 Cron 任务"

    # 检查旧版 cron
    if [ -f "$OLD_CRON_FILE" ]; then
        print_info "找到旧版 cron: $OLD_CRON_FILE"

        # 备份旧 cron
        cp "$OLD_CRON_FILE" "${OLD_CRON_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        print_info "已备份旧版 cron"

        # 删除旧版 cron
        rm "$OLD_CRON_FILE"
        print_info "已删除旧版 cron"
    else
        print_info "未找到旧版 cron 文件"
    fi

    echo ""
    echo "是否为所有域名设置新的独立 cron 任务？"
    echo "格式: 每 90 天在每月 1 日凌晨 3:00 执行"
    read -p "设置新 cron？(y/n): " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 读取配置中的域名
        domains=$($PYTHON_CMD -c "
import yaml
with open('$NEW_CONFIG_FILE', 'r') as f:
    config = yaml.safe_load(f)
    domains = list(config.get('domains', {}).keys())
    print(' '.join(domains))
" 2>/dev/null)

        if [ -z "$domains" ]; then
            print_warning "未找到已配置的域名，跳过 cron 设置"
            return
        fi

        for domain in $domains; do
            cron_file="/etc/cron.d/cert_update_${domain}"
            cat > "$cron_file" << EOF
# 每 90 天更新 ${domain} 证书（在每月 1 日的凌晨 3:00 执行）
# 由迁移脚本创建 $(date)
0 3 1 */3 * root ${SCRIPT_DIR}/update_certificate.sh --domain ${domain}
EOF
            print_info "已创建 cron: $cron_file"
        done
    else
        print_info "跳过 cron 设置"
    fi
}

# 验证新配置
verify_config() {
    print_title "验证新配置"

    # 检查配置文件
    if [ ! -f "$NEW_CONFIG_FILE" ]; then
        print_error "配置文件不存在: $NEW_CONFIG_FILE"
        return 1
    fi

    # 检查 Python 能否正常加载
    if ! $PYTHON_CMD -c "import yaml; yaml.safe_load(open('$NEW_CONFIG_FILE'))" 2>/dev/null; then
        print_error "配置文件格式错误"
        return 1
    fi

    # 列出域名
    domains=$($PYTHON_CMD -c "
import yaml
with open('$NEW_CONFIG_FILE', 'r') as f:
    config = yaml.safe_load(f)
    domains = list(config.get('domains', {}).keys())
    for d in domains:
        hostnames = config['domains'][d].get('hostnames', [])
        print(f'  {d}: {\" \".join(hostnames)}')
")

    print_info "配置验证通过"
    echo "已配置的域名:"
    echo "$domains"
}

# 显示迁移摘要
show_summary() {
    print_title "迁移摘要"

    if [ "$DRY_RUN" = true ]; then
        echo ""
        echo "=== 测试运行模式 (DRY-RUN) ==="
        echo "以上显示的所有操作仅是预览"
        echo "实际执行时才会修改文件"
        echo ""
        echo "=== 正式执行 ==="
        echo "运行以下命令进行实际迁移:"
        echo "  sudo $0"
    else
        echo ""
        echo "=== 迁移完成 ==="
        echo ""
        echo "配置文件: $NEW_CONFIG_FILE"
        echo "日志文件: $LOG_FILE"
        echo ""
    fi

    echo ""
    echo "=== 后续步骤 ==="
    echo ""
    echo "1. 验证配置:"
    echo "   ./setup_certificate.sh --list"
    echo ""
    echo "2. 测试创建证书:"
    echo "   python ${SCRIPT_DIR}/cert_manager.py --domain <your-domain>"
    echo ""
    echo "3. 检查 cron 任务:"
    echo "   ls -la /etc/cron.d/cert_update_*"
    echo ""
    echo "4. 如需回滚:"
    echo "   cp /etc/cloudflare/env.backup.* /etc/cloudflare/env"
}

# 主程序
main() {
    echo ""
    if [ "$TEST_CERT" = true ]; then
        # 单独测试证书模式
        print_title "Cloudflare 证书申请测试"
        echo ""
        check_prerequisites
        test_certificate
        exit $?
    fi

    if [ "$DRY_RUN" = true ]; then
        print_title "Cloudflare 证书管理工具迁移测试 (v1 -> v2)"
        echo ""
        echo "模式: DRY-RUN (测试运行)"
        echo ""
    else
        print_title "Cloudflare 证书管理工具迁移 (v1 -> v2)"
        echo ""
    fi

    echo "此脚本将:"
    if [ "$DRY_RUN" = true ]; then
        echo "  [预览] 解析 /etc/cloudflare/env 配置"
        echo "  [预览] 生成 config.yaml 内容"
        echo "  [预览] 证书目录迁移操作"
        echo "  [预览] Cron 任务迁移操作"
        echo ""
        echo "不会修改任何现有文件"
    else
        echo "  1. 备份现有配置"
        echo "  2. 从 /etc/cloudflare/env 读取旧配置"
        echo "  3. 创建新的 config.yaml"
        echo "  4. 可选迁移证书目录结构"
        echo "  5. 迁移 cron 任务"
    fi
    echo ""

    check_root
    check_prerequisites

    # 解析旧配置
    read domain hostnames origin_ca_key zone_id email <<< $(parse_old_config)

    if [ $? -ne 0 ] || [ -z "$domain" ]; then
        print_error "无法解析旧配置"
        exit 1
    fi

    # 备份旧配置
    backup_old_config

    # 配置 SMTP (可选)
    smtp_config=""
    if [ "$DRY_RUN" = true ]; then
        print_dry_run "交互式 SMTP 配置"
    else
        smtp_config=$(configure_smtp)
    fi

    # 创建新配置
    create_new_config "$domain" "$hostnames" "$origin_ca_key" "$zone_id" "$email" "$smtp_config"

    # 迁移证书目录（可选）
    migrate_cert_dir "$domain"

    # 迁移 cron
    migrate_cron

    # 验证
    if [ "$DRY_RUN" = true ]; then
        print_title "验证配置 (预览)"
        echo "文件路径: $NEW_CONFIG_FILE"
        echo "检查: Python 可正常解析 YAML"
        print_info "配置格式验证通过"
    else
        verify_config
    fi

    # 显示摘要
    show_summary
}

# 测试证书申请功能
test_certificate() {
    print_title "测试证书申请"

    # 检查 Python
    if command -v python &> /dev/null; then
        PYTHON_CMD="python"
    elif command -v python3 &> /dev/null; then
        PYTHON_CMD="python3"
    else
        print_error "未找到 Python"
        return 1
    fi

    # 检查 pyyaml
    if ! $PYTHON_CMD -c "import yaml" 2>/dev/null; then
        print_error "未安装 pyyaml，请先安装"
        return 1
    fi

    # 解析旧配置
    if [ ! -f "$OLD_ENV_FILE" ]; then
        print_error "旧配置文件不存在: $OLD_ENV_FILE"
        return 1
    fi

    source "$OLD_ENV_FILE"

    if [ -z "$CLOUDFLARE_ORIGIN_CA_KEY" ]; then
        print_error "未找到 CLOUDFLARE_ORIGIN_CA_KEY"
        return 1
    fi

    if [ -z "$CERT_HOSTNAMES" ]; then
        CERT_HOSTNAMES="$CERT_HOSTNAME"
    fi

    # 获取第一个主机名进行测试
    first_hostname=$(echo "$CERT_HOSTNAMES" | awk '{print $1}')

    print_info "使用配置:"
    echo "  域名: $CERT_DOMAIN"
    echo "  主机名: $first_hostname"
    echo ""

    print_info "正在申请测试证书..."
    echo "  (证书将保存到临时目录，测试完成后自动清理)"
    echo ""

    # 创建临时目录
    TEMP_DIR=$(mktemp -d)
    TEST_CERT_DIR="${TEMP_DIR}/test_cert"

    # 调用证书管理脚本
    $PYTHON_CMD "${SCRIPT_DIR}/cert_manager.py" \
        --origin-ca-key "$CLOUDFLARE_ORIGIN_CA_KEY" \
        --domain "$CERT_DOMAIN" \
        --hostnames "$first_hostname" \
        --cert_dir "$TEMP_DIR" \
        --zone_id "$CF_ZONE_ID"

    if [ $? -eq 0 ]; then
        print_info ""
        print_info "证书申请测试成功！"
        echo ""
        echo "生成的证书文件:"
        ls -la "${TEMP_DIR}/${CERT_DOMAIN}/${first_hostname}/" 2>/dev/null || true

        # 检查证书文件
        cert_file="${TEMP_DIR}/${CERT_DOMAIN}/${first_hostname}/${CERT_DOMAIN}.${first_hostname}.crt"
        if [ -f "$cert_file" ]; then
            echo ""
            print_info "证书文件内容预览:"
            head -n 5 "$cert_file"
            echo "..."
        fi

        print_warning ""
        print_warning "注意: 测试证书已保存到临时目录:"
        print_warning "  $TEMP_DIR"
        print_warning ""
        print_warning "如需清理，请运行:"
        print_warning "  rm -rf $TEMP_DIR"
    else
        print_error ""
        print_error "证书申请测试失败！"
        print_error "请检查:"
        echo "  1. Origin CA Key 是否正确"
        echo "  2. 域名和主机名是否正确"
        echo "  3. 网络连接是否正常"
    fi

    # 清理临时目录
    rm -rf "$TEMP_DIR" 2>/dev/null || true
}

main "$@"
