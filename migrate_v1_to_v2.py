#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Cloudflare 证书管理工具迁移脚本 (v1 -> v2)
将旧版环境变量配置迁移到新版 YAML 配置
"""

import os
import sys
import shutil
from pathlib import Path

try:
    import yaml
    import questionary
except ImportError as e:
    print(f"错误: 缺少必要的库 - {e}")
    print("运行: pip install pyyaml questionary")
    sys.exit(1)


# 配置
SCRIPT_DIR = Path(__file__).parent.resolve()
OLD_ENV_FILE = Path("/etc/cloudflare/env")
NEW_CONFIG_FILE = SCRIPT_DIR / "config.yaml"
OLD_CRON_FILE = Path("/etc/cron.d/cert_update")
CERT_BASE_DIR = Path("/etc/cert")

DRY_RUN = "--dry-run" in sys.argv or "--test" in sys.argv


def print_header(msg):
    """打印标题"""
    print("\n" + "=" * 50)
    print(f"  {msg}")
    print("=" * 50)


def print_step(msg):
    """打印步骤"""
    print(f"\n[+] {msg}")


def print_success(msg):
    """打印成功信息"""
    print(f"[✓] {msg}")


def print_warning(msg):
    """打印警告信息"""
    print(f"[!] {msg}")


def print_info(msg):
    """打印提示信息"""
    print(f"[i] {msg}")


def print_error(msg):
    """打印错误信息"""
    print(f"[✗] {msg}")


def check_root():
    """检查 root 权限"""
    if os.geteuid() != 0:
        print_error("此脚本需要 root 权限，请使用 sudo 运行")
        sys.exit(1)


def parse_old_config():
    """解析旧版配置文件"""
    print_header("解析旧版配置")

    if not OLD_ENV_FILE.exists():
        print_error(f"旧配置文件不存在: {OLD_ENV_FILE}")
        return None

    # 读取 env 文件
    env_vars = {}
    with open(OLD_ENV_FILE, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                env_vars[key.strip()] = value.strip()

    # 验证必要配置
    required_keys = ['CLOUDFLARE_ORIGIN_CA_KEY', 'CERT_DOMAIN', 'CERT_HOSTNAME']
    for key in required_keys:
        if key not in env_vars or not env_vars[key]:
            print_error(f"未找到 {key}")
            return None

    print_success(f"旧配置解析成功")
    print(f"  域名: {env_vars['CERT_DOMAIN']}")
    print(f"  主机名: {env_vars['CERT_HOSTNAME']}")

    return {
        'domain': env_vars['CERT_DOMAIN'],
        'hostnames': env_vars['CERT_HOSTNAME'].split(),
        'origin_ca_key': env_vars['CLOUDFLARE_ORIGIN_CA_KEY'],
        'zone_id': env_vars.get('CF_ZONE_ID', ''),
        'notification_email': env_vars.get('NOTIFICATION_EMAIL', ''),
    }


def configure_smtp():
    """交互式配置 SMTP"""
    print_header("配置邮件通知")

    if not questionary.confirm("是否配置 SMTP 邮件服务器用于发送证书更新通知？").ask():
        print_success("跳过 SMTP 配置")
        return None

    print()

    smtp_host = questionary.text(
        "SMTP 服务器地址",
        validate=lambda x: len(x) > 0 or "不能为空"
    ).ask()

    smtp_port = questionary.text(
        "SMTP 端口",
        default="587",
        validate=lambda x: x in ['465', '587'] or "请输入 465 或 587"
    ).ask()

    smtp_sender = questionary.text(
        "发件人邮箱 / 用户名",
        validate=lambda x: len(x) > 0 and '@' in x or "请输入有效的邮箱地址"
    ).ask()

    smtp_password = questionary.password(
        "密码或 App Password"
    ).ask()

    print()

    # 根据端口自动设置加密方式
    if smtp_port == "465":
        print(f"加密方式: SSL (自动匹配 465 端口)")
        smtp_use_ssl = True
    else:
        print(f"加密方式: STARTTLS (自动匹配 587 端口)")
        smtp_use_ssl = False

    print_success("SMTP 配置完成")

    return {
        'host': smtp_host,
        'port': int(smtp_port),
        'sender': smtp_sender,
        'username': smtp_sender,
        'password': smtp_password,
        'use_ssl': smtp_use_ssl,
    }


def create_config(old_config, smtp_config):
    """创建新的配置文件"""
    print_step("创建配置文件")

    if DRY_RUN:
        preview_config(old_config, smtp_config)
        return

    # 检查是否已有配置
    if NEW_CONFIG_FILE.exists():
        print_warning(f"配置文件已存在: {NEW_CONFIG_FILE}")
        if not questionary.confirm("是否覆盖？").ask():
            print_success("跳过配置创建")
            return
        backup_file = NEW_CONFIG_FILE.with_suffix(f".backup.{os.popen('date +%Y%m%d%H%M%S').read().strip()}")
        shutil.copy(NEW_CONFIG_FILE, backup_file)
        print_success(f"已备份旧配置: {backup_file}")

    # 构建配置
    config = {
        'default': {
            'origin_ca_key': old_config['origin_ca_key'],
            'cert_type': 'origin-rsa',
            'validity_days': 90,
            'base_cert_dir': '/etc/cert',
            'enable_cron': True,
            'notification_email': old_config.get('notification_email', ''),
        },
        'domains': {}
    }

    # 添加 SMTP 配置
    if smtp_config:
        config['default']['smtp'] = {
            'host': smtp_config['host'],
            'port': smtp_config['port'],
            'sender': smtp_config['sender'],
            'username': smtp_config['username'],
            'password': smtp_config['password'],
            'use_ssl': smtp_config['use_ssl'],
        }

    # 添加域名配置
    config['domains'][old_config['domain']] = {
        'origin_ca_key': None,
        'hostnames': old_config['hostnames'],
        'zone_id': old_config.get('zone_id', ''),
        'enable_cron': True,
        'notification_email': old_config.get('notification_email', ''),
    }

    # 写入配置
    with open(NEW_CONFIG_FILE, 'w', encoding='utf-8') as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

    os.chmod(NEW_CONFIG_FILE, 0o600)
    print_success(f"已创建配置文件: {NEW_CONFIG_FILE}")


def preview_config(old_config, smtp_config):
    """预览配置内容"""
    print("[预览] 配置文件内容:")

    hostnames_yaml = ""
    for h in old_config['hostnames']:
        hostnames_yaml += f"      - {h}\n"

    smtp_section = ""
    if smtp_config:
        smtp_section = f"""  smtp:
    host: "{smtp_config['host']}"
    port: {smtp_config['port']}
    sender: "{smtp_config['sender']}"
    username: "{smtp_config['username']}"
    password: "{smtp_config['password']}"
    use_ssl: {str(smtp_config['use_ssl']).lower()}
"""
    else:
        smtp_section = """  # SMTP 邮件服务器配置 (可选)
  # smtp:
  #   host: "smtp.example.com"
  #   port: 465
  #   sender: "your-email@example.com"
  #   username: "your-email@example.com"
  #   password: "your-password"
  #   use_ssl: true
"""

    config_content = f"""# Cloudflare 证书管理配置

default:
  origin_ca_key: "{old_config['origin_ca_key']}"
  cert_type: "origin-rsa"
  validity_days: 90
  base_cert_dir: "/etc/cert"
  enable_cron: true
  notification_email: "{old_config.get('notification_email', '')}"
{smtp_section}domains:
  {old_config['domain']}:
    origin_ca_key: null
    hostnames:
{hostnames_yaml.rstrip()}    zone_id: "{old_config.get('zone_id', '')}"
    enable_cron: true
    notification_email: "{old_config.get('notification_email', '')}"
"""
    print(config_content)


def files_are_identical(path1, path2):
    """比较两个文件内容是否相同"""
    if not path1.exists() or not path2.exists():
        return False
    try:
        with open(path1, 'rb') as f1, open(path2, 'rb') as f2:
            return f1.read() == f2.read()
    except Exception:
        return False


def migrate_cert_dir(old_config):
    """迁移证书目录结构"""
    print_header("迁移证书目录结构")

    print(f"旧结构: /etc/cert/{{hostname}}/")
    print(f"新结构: /etc/cert/{{domain}}/{{hostname}}/")
    print(f"目标域名: {old_config['domain']}")

    if not CERT_BASE_DIR.exists():
        print_warning("证书目录不存在")
        return

    if not questionary.confirm("是否迁移现有证书到新结构？").ask():
        print_success("跳过证书迁移")
        return

    migrated = False
    skipped = False

    # 查找旧结构目录
    for hostname_dir in CERT_BASE_DIR.iterdir():
        if hostname_dir.is_dir() and hostname_dir.name not in ['..', '.']:
            print(f"\n处理: {hostname_dir.name}")

            # 迁移所有文件类型
            for ext in ['crt', 'key', 'fingerprint']:
                for old_file in hostname_dir.glob(f"*.{ext}"):
                    if old_file.is_file():
                        # 创建新目录结构
                        new_dir = CERT_BASE_DIR / old_config['domain'] / hostname_dir.name
                        new_dir.mkdir(parents=True, exist_ok=True)

                        # 新文件名
                        new_filename = f"{old_config['domain']}.{hostname_dir.name}.{ext}"
                        new_file = new_dir / new_filename

                        if DRY_RUN:
                            print(f"  [预览] {old_file.name} -> {new_filename}")
                        else:
                            if new_file.exists():
                                # 检查文件内容是否相同
                                if files_are_identical(old_file, new_file):
                                        print(f"  [跳过] {new_filename} (已存在且内容相同)")
                                        skipped = True
                                        migrated = True
                                        continue
                                    else:
                                        print(f"  [存在] {new_filename}")
                                        if not questionary.confirm(f"    覆盖已存在的文件？"):
                                            print(f"    跳过 {old_file.name}")
                                            continue
                            shutil.copy(old_file, new_file)
                            print(f"  {old_file.name} -> {new_filename}")
                            migrated = True

    if migrated:
        if not DRY_RUN:
            print_success("证书迁移完成")
        if skipped:
            print_info("部分文件因已存在且内容相同而跳过")
        print_warning("建议在验证新证书正常后删除旧目录 /etc/cert/*/")
    else:
        print_warning("未找到需要迁移的证书文件")


def migrate_cron(old_config):
    """迁移 cron 任务"""
    print_header("迁移 Cron 任务")

    # 备份/删除旧 cron
    if OLD_CRON_FILE.exists():
        print_success(f"找到旧版 cron: {OLD_CRON_FILE}")
        backup_file = OLD_CRON_FILE.with_suffix(f".backup.{os.popen('date +%Y%m%d%H%M%S').read().strip()}")

        if DRY_RUN:
            print(f"  [预览] 备份: {OLD_CRON_FILE} -> {backup_file}")
            print(f"  [预览] 删除: {OLD_CRON_FILE}")
        else:
            shutil.copy(OLD_CRON_FILE, backup_file)
            print_success("已备份旧版 cron")
            OLD_CRON_FILE.unlink()
            print_success("已删除旧版 cron")
    else:
        print_success("未找到旧版 cron 文件")

    if not questionary.confirm("是否为所有域名设置新的独立 cron 任务？").ask():
        print_success("跳过 cron 设置")
        return

    # 为每个域名创建 cron
    domain = old_config['domain']
    cron_file = Path(f"/etc/cron.d/cert_update_{domain}")

    cron_content = f"""# 每 90 天更新 {domain} 证书（在每月 1 日的凌晨 3:00 执行）
# 由迁移脚本创建
0 3 1 */3 * root {SCRIPT_DIR}/update_certificate.sh --domain {domain}
"""

    if DRY_RUN:
        print(f"  [预览] 创建: {cron_file}")
    else:
        # 检查文件是否已存在且内容相同
        if cron_file.exists():
            try:
                with open(cron_file, 'r') as f:
                    existing_content = f.read()
                if existing_content == cron_content:
                    print_success(f"cron 文件已存在且内容相同，跳过: {cron_file}")
                    return
            except Exception:
                pass
            print_warning(f"cron 文件已存在: {cron_file}")
            if not questionary.confirm("是否覆盖？"):
                print_success("跳过 cron 创建")
                return
        with open(cron_file, 'w') as f:
            f.write(cron_content)
        print_success(f"已创建 cron: {cron_file}")


def verify_config():
    """验证新配置"""
    print_header("验证新配置")

    if not NEW_CONFIG_FILE.exists():
        print_error(f"配置文件不存在: {NEW_CONFIG_FILE}")
        return False

    try:
        with open(NEW_CONFIG_FILE, 'r') as f:
            config = yaml.safe_load(f)
    except Exception as e:
        print_error(f"配置文件格式错误: {e}")
        return False

    print_success("配置验证通过")
    print("\n已配置的域名:")
    if 'domains' in config:
        for domain, domain_config in config['domains'].items():
            hostnames = domain_config.get('hostnames', [])
            print(f"  {domain}: {' '.join(hostnames)}")
    else:
        print("  (无)")

    return True


def main():
    print()
    print("=" * 50)
    print("  Cloudflare 证书管理工具迁移 (v1 -> v2)")
    print("=" * 50)

    if DRY_RUN:
        print("\n模式: DRY-RUN (测试运行)")
        print("不会修改任何现有文件")

    # 检查 root 权限
    check_root()

    # 解析旧配置
    old_config = parse_old_config()
    if not old_config:
        sys.exit(1)

    # 配置 SMTP
    smtp_config = None
    if not DRY_RUN:
        smtp_config = configure_smtp()

    # 创建新配置
    create_config(old_config, smtp_config)

    # 迁移证书目录
    migrate_cert_dir(old_config)

    # 迁移 cron
    migrate_cron(old_config)

    # 验证
    if DRY_RUN:
        print_header("验证配置 (预览)")
        print_success("配置格式验证通过")
    else:
        verify_config()

    # 显示摘要
    print_header("迁移摘要")

    if DRY_RUN:
        print("\n以上显示的所有操作仅是预览")
        print("实际执行时才会修改文件")
        print("\n运行以下命令进行实际迁移:")
        print(f"  sudo {sys.argv[0]}")
    else:
        print(f"\n配置文件: {NEW_CONFIG_FILE}")
        print("\n后续步骤:")
        print("  1. 验证配置: ./setup_certificate.sh --list")
        print("  2. 测试证书: python cert_manager.py --domain <domain>")
        print("  3. 检查 cron: ls -la /etc/cron.d/cert_update_*")


if __name__ == "__main__":
    main()
