# Cloudflare 证书管理工具 (v2.0)

这个工具可以帮助您通过 Cloudflare API 管理域名的 SSL 证书，支持同一账号下多个域名的独立管理。

## 新功能 (v2.0)

- **多域名支持**: 使用 YAML 配置文件管理多个域名
- **独立配置**: 每个域名单独设置主机名、证书类型、有效期
- **独立调度**: 每个域名单独的自动更新计划任务
- **集中存储**: 证书按 `域名/主机名/` 目录结构存储

## 安装依赖

推荐使用 uv 管理：

```bash
# 安装依赖并创建虚拟环境
uv sync

# 激活虚拟环境
source .venv/bin/activate

# 安装完成，现在可以使用 python cert_manager.py
```

传统方式（不推荐）：
```bash
pip install -r requirements.txt
```

## 配置文件

### config.example.yaml (模板)

复制为 `config.yaml` 并填入真实配置：

```yaml
default:
  origin_ca_key: "your-origin-ca-key"  # 全局默认 Key
  cert_type: "origin-rsa"
  validity_days: 90
  base_cert_dir: "/etc/cert"

domains:
  example.com:
    hostnames:
      - www.example.com
      - api.example.com
    enable_cron: true
```

### 重要说明

- `config.yaml` 包含敏感信息，已加入 `.gitignore`
- `config.example.yaml` 是模板文件，会被 git 追踪

## 使用方法

### 交互式设置向导

首次配置或添加新域名：

```bash
# 首次运行 - 设置向导
sudo ./setup_certificate.sh

# 添加新域名
sudo ./setup_certificate.sh --add-domain

# 列出所有已配置域名
./setup_certificate.sh --list

# 删除域名配置
./setup_certificate.sh --remove
```

### 手动创建证书

```bash
# 更新单个域名
python cert_manager.py --domain example.com

# 更新所有域名
python cert_manager.py

# 指定配置文件
python cert_manager.py --config /path/to/config.yaml --domain example.com
```

### 自动更新证书

```bash
# 更新单个域名
./update_certificate.sh --domain example.com

# 更新所有域名
./update_certificate.sh --all

# 为单个域名设置 cron（每 90 天更新）
echo "0 3 1 */3 * root /path/to/update_certificate.sh --domain example.com" | sudo tee /etc/cron.d/cert_update_example.com
```

## 证书存储结构

```
/etc/cert/
└── example.com/
    └── www.example.com/
        ├── example.com.www.example.com.crt
        ├── example.com.www.example.com.key
        └── example.com.www.example.com.fingerprint
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `cert_manager.py` | 核心 Python 模块 |
| `setup_certificate.sh` | 交互式设置向导 |
| `update_certificate.sh` | 证书更新脚本 |
| `config.example.yaml` | 配置文件模板 |
| `config.yaml` | 实际配置文件 (gitignore) |

## 日志文件

脚本执行日志保存在 `/var/log/cert_update.log`

## 获取 Cloudflare Origin CA Key

1. 登录 Cloudflare 控制面板
2. 进入 "SSL/TLS" > "Origin Server"
3. 点击 "Create Certificate"
4. 在页面底部，找到 "Origin CA Key"
5. 点击 "View" 查看或生成新的 Key

## 错误排查

1. 检查配置文件：
   ```bash
   cat config.yaml
   ```

2. 检查日志：
   ```bash
   tail -n 50 /var/log/cert_update.log
   ```

3. 检查证书目录：
   ```bash
   ls -la /etc/cert/
   ls -la /etc/cert/example.com/
   ```

4. 如果遇到 SSL 证书验证错误：
   ```bash
   pip install --upgrade certifi
   pip install pip-system-certs
   ```
