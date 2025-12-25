#!/bin/bash

# 设置日志文件
LOG_FILE="/var/log/cert_update.log"

# 记录开始时间
echo "$(date): 开始更新证书..." >> $LOG_FILE

# 设置工作目录
cd "$HOME/cloudflare_cert"

# 检查 Python 命令
if command -v python &> /dev/null; then
    PYTHON_CMD="python"
elif command -v python3 &> /dev/null; then
    PYTHON_CMD="python3"
else
    echo "$(date): 错误 - 未找到 python 或 python3 命令，请先安装。" >> $LOG_FILE
    echo "$(date): 证书更新失败!" >> $LOG_FILE
    exit 1
fi
echo "$(date): 使用 Python 命令: $PYTHON_CMD" >> $LOG_FILE

# 直接读取环境变量文件
if [ -f "/etc/cloudflare/env" ]; then
    source /etc/cloudflare/env
    echo "$(date): 已加载环境变量文件" >> $LOG_FILE
else
    echo "$(date): 错误 - 环境变量文件 /etc/cloudflare/env 不存在!" >> $LOG_FILE
    echo "$(date): 证书更新失败!" >> $LOG_FILE
    exit 1
fi

# 检查环境变量是否存在
if [ -z "$CLOUDFLARE_ORIGIN_CA_KEY" ]; then
    echo "$(date): 错误 - 环境变量 CLOUDFLARE_ORIGIN_CA_KEY 未设置!" >> $LOG_FILE
    echo "$(date): 证书更新失败!" >> $LOG_FILE
    exit 1
fi

# 检查域名环境变量
if [ -z "$CERT_DOMAIN" ]; then
    echo "$(date): 错误 - 环境变量 CERT_DOMAIN 未设置!" >> $LOG_FILE
    echo "$(date): 证书更新失败!" >> $LOG_FILE
    exit 1
fi

# 检查主机名环境变量
if [ -z "$CERT_HOSTNAME" ]; then
    echo "$(date): 错误 - 环境变量 CERT_HOSTNAME 未设置!" >> $LOG_FILE
    echo "$(date): 证书更新失败!" >> $LOG_FILE
    exit 1
fi

# 检查通知邮箱环境变量（可选）
NOTIFICATION_EMAIL=${NOTIFICATION_EMAIL:-""}

# 确保证书基础目录存在 (实际证书将保存在 主机名 子目录下)
mkdir -p /etc/cert/

# 增加调试信息
echo "调试信息: CLOUDFLARE_ORIGIN_CA_KEY=${CLOUDFLARE_ORIGIN_CA_KEY:0:10}..." >> $LOG_FILE

# 显式传递所有参数给 Python 脚本
$PYTHON_CMD cloudflare_cert_token.py \
  --origin-ca-key "$CLOUDFLARE_ORIGIN_CA_KEY" \
  --domain "$CERT_DOMAIN" \
  --hostnames $CERT_HOSTNAME \
  --zone_id "$CF_ZONE_ID" \
  --cert_dir /etc/cert/ >> $LOG_FILE 2>&1

# 检查执行结果
if [ $? -eq 0 ]; then
    echo "$(date): 证书更新成功!" >> $LOG_FILE
    
    # 重启相关服务（如果需要）
    # systemctl restart nginx
    
    # 发送成功通知（如果设置了邮箱）
    if [ ! -z "$NOTIFICATION_EMAIL" ]; then
        echo "证书已成功更新" | mail -s "证书更新成功" $NOTIFICATION_EMAIL
    fi
else
    echo "$(date): 证书更新失败!" >> $LOG_FILE
    
    # 发送失败通知（如果设置了邮箱）
    if [ ! -z "$NOTIFICATION_EMAIL" ]; then
        echo "证书更新失败，请检查日志文件 $LOG_FILE" | mail -s "证书更新失败" $NOTIFICATION_EMAIL
    fi
fi

echo "$(date): 证书更新过程结束" >> $LOG_FILE
echo "----------------------------------------" >> $LOG_FILE 