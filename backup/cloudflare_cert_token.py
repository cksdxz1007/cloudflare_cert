#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import json
import requests
import argparse
import subprocess
import tempfile
from datetime import datetime
import re

class CloudflareAPI:
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
    
    def get_zone_id(self):
        """获取域名的 Zone ID"""
        if self.zone_id:
            print(f"使用 zoneID: {self.zone_id}")
            return self.zone_id
        else:
            print("未提供 zoneID，请检查参数或环境变量 CF_ZONE_ID")
            return None
    
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
    
    def save_to_cert_dir(self, hostname, cert_content, key_content, fingerprint, cert_dir_base="/etc/cert"):
        """将证书和密钥保存到指定目录 (基础目录/主机名/)"""
        # 构建特定于主机名的目录路径
        host_specific_dir = os.path.join(cert_dir_base, hostname)

        # 如果目录不存在，则创建
        if not os.path.exists(host_specific_dir):
            try:
                os.makedirs(host_specific_dir, exist_ok=True)
                print(f"创建目录: {host_specific_dir}")
            except PermissionError:
                print(f"无权限创建目录: {host_specific_dir}")
                print("尝试使用 sudo 创建目录...")
                try:
                    # 同时创建父目录 /etc/cert (如果它也不存在)
                    subprocess.run(["sudo", "mkdir", "-p", host_specific_dir], check=True)
                    print(f"成功创建目录: {host_specific_dir}")
                except subprocess.CalledProcessError:
                    print(f"无法创建目录: {host_specific_dir}")
                    return False
        
        # 保存证书
        cert_path = os.path.join(host_specific_dir, f"{hostname}.crt")
        try:
            with open(cert_path, "w") as f:
                f.write(cert_content)
        except PermissionError:
            print(f"无权限写入文件: {cert_path}")
            print("尝试使用 sudo 写入文件...")
            try:
                with tempfile.NamedTemporaryFile(mode='w+', delete=False) as temp_file:
                    temp_file.write(cert_content)
                    temp_file_path = temp_file.name
                subprocess.run(["sudo", "cp", temp_file_path, cert_path], check=True)
                os.unlink(temp_file_path)
                print(f"成功写入文件: {cert_path}")
            except (subprocess.CalledProcessError, OSError):
                print(f"无法写入文件: {cert_path}")
                return False
        
        # 保存密钥
        key_path = os.path.join(host_specific_dir, f"{hostname}.key")
        try:
            with open(key_path, "w") as f:
                f.write(key_content)
        except PermissionError:
            print(f"无权限写入文件: {key_path}")
            print("尝试使用 sudo 写入文件...")
            try:
                with tempfile.NamedTemporaryFile(mode='w+', delete=False) as temp_file:
                    temp_file.write(key_content)
                    temp_file_path = temp_file.name
                subprocess.run(["sudo", "cp", temp_file_path, key_path], check=True)
                os.unlink(temp_file_path)
                print(f"成功写入文件: {key_path}")
            except (subprocess.CalledProcessError, OSError):
                print(f"无法写入文件: {key_path}")
                return False
        
        # 保存指纹，确保没有额外字符
        fingerprint_path = os.path.join(host_specific_dir, f"{hostname}.fingerprint")
        try:
            with open(fingerprint_path, "w") as f:
                f.write(fingerprint)  # 已经在 get_certificate_fingerprint 中清理过了
        except PermissionError:
            print(f"无权限写入文件: {fingerprint_path}")
            print("尝试使用 sudo 写入文件...")
            try:
                with tempfile.NamedTemporaryFile(mode='w+', delete=False) as temp_file:
                    temp_file.write(fingerprint)  # 已经在 get_certificate_fingerprint 中清理过了
                    temp_file_path = temp_file.name
                subprocess.run(["sudo", "cp", temp_file_path, fingerprint_path], check=True)
                os.unlink(temp_file_path)
                print(f"成功写入文件: {fingerprint_path}")
            except (subprocess.CalledProcessError, OSError):
                print(f"无法写入文件: {fingerprint_path}")
                return False
        
        print(f"证书已保存到: {cert_path}")
        print(f"密钥已保存到: {key_path}")
        print(f"指纹已保存到: {fingerprint_path}")
        
        return True

def main():
    parser = argparse.ArgumentParser(description="使用 Cloudflare Origin CA Key 创建证书")
    parser.add_argument("--origin-ca-key", help="Cloudflare Origin CA Key")
    parser.add_argument("--domain", required=True, help="域名")
    parser.add_argument("--hostnames", nargs="+", required=True, help="证书包含的主机名列表")
    parser.add_argument("--validity", type=int, default=90, help="证书有效期 (天数)")
    parser.add_argument("--type", choices=["origin-rsa", "origin-ecc"], default="origin-rsa", help="证书类型")
    parser.add_argument("--cert_dir", default="/etc/cert", help="证书保存的基础目录 (实际保存路径为: cert_dir/hostname/)")
    parser.add_argument("--zone_id", help="Cloudflare Zone ID，可选，优先于环境变量 CF_ZONE_ID")
    
    args = parser.parse_args()
    
    # 从环境变量中获取 Origin CA Key
    origin_ca_key = args.origin_ca_key or os.environ.get("CLOUDFLARE_ORIGIN_CA_KEY")
    # 获取 zone_id，优先参数，否则环境变量
    zone_id = args.zone_id or os.environ.get("CF_ZONE_ID")
    
    # 检查是否提供了 Origin CA Key
    if not origin_ca_key:
        print("错误: 必须提供 --origin-ca-key 参数或设置 CLOUDFLARE_ORIGIN_CA_KEY 环境变量")
        sys.exit(1)
    
    cf = CloudflareAPI(origin_ca_key, args.domain, zone_id)
    
    print(f"为主机名 {', '.join(args.hostnames)} 创建新的 {args.type} 证书...")
    cert = cf.create_origin_certificate(args.hostnames, args.validity, args.type)
    if cert:
        print("证书创建成功:")
        print(json.dumps(cert, indent=2))
        
        # 获取证书指纹
        fingerprint = cf.get_certificate_fingerprint(cert.get("certificate", ""))
        if fingerprint:
            print(f"证书指纹: {fingerprint}")
        
        # 将证书和密钥保存到指定目录
        if "private_key" in cert and fingerprint:
            hostname = args.hostnames[0]
            cf.save_to_cert_dir(
                hostname,
                cert.get("certificate", ""),
                cert.get("private_key", ""),
                fingerprint,
                args.cert_dir  # 这里传递的是基础目录
            )

if __name__ == "__main__":
    main() 