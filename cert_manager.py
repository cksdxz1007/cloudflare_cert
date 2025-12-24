#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Cloudflare Certificate Manager
支持多域名证书管理，每个域名独立配置
"""

import os
import sys
import json
import argparse
import subprocess
import tempfile
import re
from datetime import datetime
from pathlib import Path

try:
    import yaml
except ImportError:
    print("错误: 需要安装 pyyaml 库")
    print("运行: pip install pyyaml")
    sys.exit(1)


class ConfigLoader:
    """配置加载器"""

    DEFAULT_CONFIG_PATH = "config.yaml"

    def __init__(self, config_path=None):
        self.config_path = config_path or self.DEFAULT_CONFIG_PATH
        self.config = None

    def load(self):
        """加载配置文件"""
        if not os.path.exists(self.config_path):
            return None

        with open(self.config_path, 'r', encoding='utf-8') as f:
            self.config = yaml.safe_load(f)

        return self.config

    def get_domain_config(self, domain):
        """获取指定域名的完整配置，合并默认值"""
        if not self.config or 'domains' not in self.config:
            return None

        domain_config = self.config['domains'].get(domain)
        if not domain_config:
            return None

        # 合并默认配置
        default_config = self.config.get('default', {})
        merged_config = default_config.copy()
        merged_config.update(domain_config)

        # 处理 null 值，使用默认值
        for key in ['origin_ca_key', 'cert_type', 'validity_days', 'enable_cron', 'notification_email']:
            if merged_config.get(key) is None:
                merged_config[key] = default_config.get(key)

        return merged_config

    def list_domains(self):
        """列出所有已配置的域名"""
        if not self.config or 'domains' not in self.config:
            return []

        return list(self.config['domains'].keys())


class CloudflareAPI:
    """Cloudflare API 交互类"""

    def __init__(self, origin_ca_key, domain, zone_id=None):
        self.origin_ca_key = origin_ca_key
        self.domain = domain
        self.zone_id = zone_id
        self.base_url = "https://api.cloudflare.com/client/v4"

        # 设置 Origin CA Key 的请求头
        self.headers = {
            "Content-Type": "application/json",
            "X-Auth-User-Service-Key": self.origin_ca_key
        }

    def generate_csr(self, hostnames):
        """生成 CSR (证书签名请求)"""
        print("生成 CSR...")

        # 创建临时目录
        with tempfile.TemporaryDirectory() as temp_dir:
            # 生成私钥
            key_path = os.path.join(temp_dir, "private.key")
            subprocess.run(
                ["openssl", "genrsa", "-out", key_path, "2048"],
                check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )

            # 创建 CSR 配置文件
            config_path = os.path.join(temp_dir, "csr.conf")
            with open(config_path, "w") as f:
                f.write("[req]\n")
                f.write("distinguished_name = req_distinguished_name\n")
                f.write("req_extensions = v3_req\n")
                f.write("prompt = no\n")
                f.write("[req_distinguished_name]\n")
                f.write(f"CN = {hostnames[0]}\n")
                f.write("[v3_req]\n")
                f.write("keyUsage = keyEncipherment, dataEncipherment\n")
                f.write("extendedKeyUsage = serverAuth\n")
                f.write("subjectAltName = @alt_names\n")
                f.write("[alt_names]\n")
                for i, hostname in enumerate(hostnames):
                    f.write(f"DNS.{i+1} = {hostname}\n")

            # 生成 CSR
            csr_path = os.path.join(temp_dir, "request.csr")
            subprocess.run(
                ["openssl", "req", "-new", "-key", key_path, "-out", csr_path, "-config", config_path],
                check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )

            # 读取 CSR 和私钥
            with open(csr_path, "r") as f:
                csr = f.read()

            with open(key_path, "r") as f:
                private_key = f.read()

            return csr, private_key

    def create_origin_certificate(self, hostnames, validity_days=90, request_type="origin-rsa"):
        """创建新的 Origin CA 证书"""
        import requests

        url = f"{self.base_url}/certificates"

        # 生成 CSR 和私钥
        csr, private_key = self.generate_csr(hostnames)

        # 构建请求数据
        data = {
            "hostnames": hostnames,
            "requested_validity": validity_days,
            "request_type": request_type,
            "csr": csr
        }

        response = requests.post(url, headers=self.headers, json=data)
        if response.status_code != 200:
            print(f"创建证书失败: {response.text}")
            return None

        data = response.json()
        if not data["success"]:
            print(f"创建证书失败: {data['errors']}")
            return None

        # 将私钥添加到结果中
        result = data["result"]
        result["private_key"] = private_key

        return result

    def get_certificate_fingerprint(self, cert_content):
        """获取证书的指纹"""
        with tempfile.NamedTemporaryFile(mode='w+', suffix='.crt', delete=False) as temp_file:
            temp_file.write(cert_content)
            temp_file_path = temp_file.name

        try:
            result = subprocess.run(
                ["openssl", "x509", "-in", temp_file_path, "-fingerprint", "-sha256", "-noout"],
                check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
            )
            # 提取指纹并去除可能的额外字符
            fingerprint_line = result.stdout.strip()
            if "=" in fingerprint_line:
                fingerprint = fingerprint_line.split("=")[-1].strip()
            else:
                fingerprint = fingerprint_line.strip()

            # 使用正则表达式确保只保留有效的指纹字符
            fingerprint = re.sub(r'[^A-F0-9:]', '', fingerprint.upper())
            return fingerprint
        except subprocess.CalledProcessError as e:
            print(f"获取证书指纹失败: {e}")
            return None
        finally:
            os.unlink(temp_file_path)

    def save_to_cert_dir(self, domain, hostname, cert_content, key_content, fingerprint, cert_dir_base="/etc/cert"):
        """将证书和密钥保存到指定目录 (基础目录/域名/主机名/)"""
        # 构建目录路径: cert_dir_base/domain/hostname/
        host_specific_dir = os.path.join(cert_dir_base, domain, hostname)

        # 如果目录不存在，则创建
        if not os.path.exists(host_specific_dir):
            try:
                os.makedirs(host_specific_dir, exist_ok=True)
                print(f"创建目录: {host_specific_dir}")
            except PermissionError:
                print(f"无权限创建目录: {host_specific_dir}")
                print("尝试使用 sudo 创建目录...")
                try:
                    subprocess.run(["sudo", "mkdir", "-p", host_specific_dir], check=True)
                    print(f"成功创建目录: {host_specific_dir}")
                except subprocess.CalledProcessError:
                    print(f"无法创建目录: {host_specific_dir}")
                    return False

        # 文件名: domain.hostname.crt
        file_prefix = f"{domain}.{hostname}"

        # 保存证书
        cert_path = os.path.join(host_specific_dir, f"{file_prefix}.crt")
        if not self._write_file(cert_path, cert_content):
            return False

        # 保存密钥
        key_path = os.path.join(host_specific_dir, f"{file_prefix}.key")
        if not self._write_file(key_path, key_content):
            return False

        # 保存指纹
        fingerprint_path = os.path.join(host_specific_dir, f"{file_prefix}.fingerprint")
        if not self._write_file(fingerprint_path, fingerprint):
            return False

        print(f"证书已保存到: {cert_path}")
        print(f"密钥已保存到: {key_path}")
        print(f"指纹已保存到: {fingerprint_path}")

        return True

    def _write_file(self, file_path, content):
        """写文件，支持 sudo 回退"""
        try:
            with open(file_path, "w") as f:
                f.write(content)
            return True
        except PermissionError:
            print(f"无权限写入文件: {file_path}")
            print("尝试使用 sudo 写入文件...")
            try:
                with tempfile.NamedTemporaryFile(mode='w+', delete=False) as temp_file:
                    temp_file.write(content)
                    temp_file_path = temp_file.name
                subprocess.run(["sudo", "cp", temp_file_path, file_path], check=True)
                os.unlink(temp_file_path)
                print(f"成功写入文件: {file_path}")
                return True
            except (subprocess.CalledProcessError, OSError):
                print(f"无法写入文件: {file_path}")
                return False


def main():
    parser = argparse.ArgumentParser(description="Cloudflare 证书管理工具")
    parser.add_argument("--config", default="config.yaml", help="配置文件路径")
    parser.add_argument("--domain", help="指定域名 (可选，默认使用 config 中的所有域名)")
    parser.add_argument("--hostnames", nargs="+", help="指定主机名列表 (可选)")
    parser.add_argument("--validity", type=int, help="证书有效期 (天数)")
    parser.add_argument("--type", choices=["origin-rsa", "origin-ecc"], help="证书类型")
    parser.add_argument("--cert_dir", help="证书保存基础目录")
    parser.add_argument("--zone_id", help="Cloudflare Zone ID")

    args = parser.parse_args()

    # 加载配置
    config_loader = ConfigLoader(args.config)
    config = config_loader.load()

    if not config:
        print(f"错误: 配置文件 {args.config} 不存在")
        print("请先复制 config.example.yaml 为 config.yaml 并配置")
        sys.exit(1)

    # 确定要处理的域名
    if args.domain:
        domains = [args.domain]
    else:
        domains = config_loader.list_domains()
        if not domains:
            print("错误: 配置文件中没有配置任何域名")
            sys.exit(1)

    print(f"配置加载成功，共 {len(domains)} 个域名")

    success_count = 0
    fail_count = 0

    for domain in domains:
        domain_config = config_loader.get_domain_config(domain)
        if not domain_config:
            print(f"警告: 域名 {domain} 配置不存在")
            fail_count += 1
            continue

        # 获取配置
        origin_ca_key = domain_config.get('origin_ca_key')
        hostnames = args.hostnames or domain_config.get('hostnames', [])
        cert_type = args.type or domain_config.get('cert_type', 'origin-rsa')
        validity_days = args.validity or domain_config.get('validity_days', 90)
        cert_dir_base = args.cert_dir or domain_config.get('base_cert_dir', '/etc/cert')
        zone_id = args.zone_id or domain_config.get('zone_id')

        if not origin_ca_key:
            print(f"错误: 域名 {domain} 未配置 origin_ca_key")
            fail_count += 1
            continue

        if not hostnames:
            print(f"错误: 域名 {domain} 未配置 hostnames")
            fail_count += 1
            continue

        print(f"\n{'='*50}")
        print(f"处理域名: {domain}")
        print(f"主机名: {', '.join(hostnames)}")
        print(f"证书类型: {cert_type}")
        print(f"有效期: {validity_days} 天")
        print(f"{'='*50}")

        cf = CloudflareAPI(origin_ca_key, domain, zone_id)

        print(f"为主机名 {', '.join(hostnames)} 创建新的 {cert_type} 证书...")
        cert = cf.create_origin_certificate(hostnames, validity_days, cert_type)

        if cert:
            print("证书创建成功")
            print(f"证书ID: {cert.get('id', 'N/A')}")
            print(f"过期时间: {cert.get('expires_at', 'N/A')}")

            # 获取证书指纹
            fingerprint = cf.get_certificate_fingerprint(cert.get("certificate", ""))
            if fingerprint:
                print(f"证书指纹: {fingerprint}")

            # 保存证书
            if "private_key" in cert and fingerprint:
                # 为每个主机名保存证书
                for hostname in hostnames:
                    cf.save_to_cert_dir(
                        domain,
                        hostname,
                        cert.get("certificate", ""),
                        cert.get("private_key", ""),
                        fingerprint,
                        cert_dir_base
                    )
            success_count += 1
        else:
            fail_count += 1

    print(f"\n{'='*50}")
    print(f"完成: 成功 {success_count}, 失败 {fail_count}")
    print(f"{'='*50}")


if __name__ == "__main__":
    main()
