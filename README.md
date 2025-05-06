# Cloudflare 证书管理工具

这个工具可以帮助您通过 Cloudflare API 管理域名的 SSL 证书，包括创建和自动更新证书。

## 功能

- 创建新的 Origin CA 证书
- 自动更新证书（通过计划任务）
- 使用环境变量存储敏感信息
- 将证书保存到指定目录
- 交互式设置向导（适合新用户）

## 安装依赖

```bash
pip install requests
```

## 使用方法

本工具提供三种使用方式：
- 使用交互式设置向导（推荐新用户使用）
- 手动执行脚本创建证书
- 通过计划任务自动更新证书

### 交互式设置向导

对于新用户，我们提供了一个交互式设置向导，帮助您快速配置证书管理系统：

```bash
sudo ./setup_certificate.sh
```

这个向导将引导您：
1. 输入必要的参数（Cloudflare Origin CA Key、域名和主机名【支持多个，空格分隔】）
2. 通过 Cloudflare API 自动获取 zoneID
3. 创建环境变量文件
4. 设置计划任务（可选）
5. 立即创建证书（可选）

### 环境变量配置

如果您想手动配置，可以按照以下步骤创建环境变量文件：

```bash
sudo mkdir -p /etc/cloudflare
sudo touch /etc/cloudflare/env
sudo chmod 600 /etc/cloudflare/env
```

编辑环境变量文件，添加以下内容：

```bash
CLOUDFLARE_ORIGIN_CA_KEY="your-origin-ca-key"
CERT_DOMAIN="example.com"
CERT_HOSTNAME="www.example.com api.example.com"  # 支持多个主机名，空格分隔
NOTIFICATION_EMAIL="your-email@example.com"  # 可选
CF_ZONE_ID="your-zone-id"  # 由脚本自动获取
```

### 手动创建证书

```bash
# 使用环境变量中的配置
source /etc/cloudflare/env && ./update_certificate.sh

# 或者直接指定参数
python cloudflare_cert_token.py --domain example.com --hostnames www.example.com --cert_dir /etc/cert/
```

### 自动更新证书

设置计划任务，每 90 天自动更新证书：

```bash
sudo bash -c 'echo "# 每 90 天更新一次证书（在每月 1 日的凌晨 3:00 执行）" > /etc/cron.d/cert_update'
sudo bash -c 'echo "0 3 1 */3 * root /path/to/update_certificate.sh" >> /etc/cron.d/cert_update'
```

## 参数说明

### Python 脚本参数

- `--domain`: 要管理证书的域名（必需）
- `--hostnames`: 证书包含的主机名列表（必需，支持多个主机名，空格分隔）
- `--validity`: 证书有效期（天数），默认为 90 天
- `--type`: 证书类型，可选值：`origin-rsa`（默认）、`origin-ecc`
- `--cert_dir`: 证书保存目录，默认为 `/etc/cert/`
- `--origin-ca-key`: Cloudflare Origin CA Key（如果未设置，将从环境变量中读取）
- `--zone_id`: Cloudflare Zone ID（可选，优先于环境变量 CF_ZONE_ID，通常由脚本自动获取）

## 获取 Cloudflare Origin CA Key

1. 登录 Cloudflare 控制面板
2. 进入 "SSL/TLS" > "Origin Server"
3. 点击 "Create Certificate"
4. 在页面底部，找到 "Origin CA Key"
5. 点击 "View" 查看或生成新的 Key

## 文件说明

- `setup_certificate.sh`: 交互式设置向导，帮助新用户配置系统
- `update_certificate.sh`: 主要的更新脚本，负责读取环境变量并调用 Python 脚本
- `cloudflare_cert_token.py`: Python 脚本，负责与 Cloudflare API 交互创建证书

## 证书文件

证书文件将保存在指定的目录中（默认为 `/etc/cert/`）：

- 证书文件：`/etc/cert/hostname.crt`
- 私钥文件：`/etc/cert/hostname.key`
- 指纹文件：`/etc/cert/hostname.fingerprint`

## 日志文件

脚本执行日志保存在 `/var/log/cert_update.log` 文件中。

## 示例

### 使用交互式设置向导

```bash
sudo ./setup_certificate.sh
```

### 创建新证书

```bash
# 使用环境变量
source /etc/cloudflare/env && ./update_certificate.sh

# 直接指定参数
python cloudflare_cert_token.py --domain example.com --hostnames www.example.com --cert_dir /etc/cert/
```

### 查看日志

```bash
sudo cat /var/log/cert_update.log
```

## 错误排查

如果遇到问题，请检查：

1. 环境变量是否正确设置：
   ```bash
   sudo cat /etc/cloudflare/env
   ```

2. 日志文件中的错误信息：
   ```bash
   sudo tail -n 50 /var/log/cert_update.log
   ```

3. 证书目录是否存在并有正确的权限：
   ```bash
   sudo ls -la /etc/cert/
   ```

4. 如果遇到 SSL 证书验证错误，可以尝试以下方法：
   ```bash
   pip install --upgrade certifi
   pip install pip-system-certs
   ``` 