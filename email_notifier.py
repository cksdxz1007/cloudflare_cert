#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
邮件通知模块
用于在证书更新成功后发送邮件通知
"""

import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.header import Header
import logging

logger = logging.getLogger(__name__)


class EmailNotifier:
    """邮件通知器"""

    def __init__(self, smtp_config):
        """
        初始化邮件通知器

        Args:
            smtp_config: SMTP 配置字典，包含:
                - host: 邮件服务器地址
                - port: 端口
                - sender: 发件人邮箱
                - username: 用户名
                - password: 密码
                - use_ssl: 是否使用 SSL (True=465, False=587+STARTTLS)
        """
        self.host = smtp_config.get('host')
        self.port = smtp_config.get('port', 465)
        self.sender = smtp_config.get('sender')
        self.username = smtp_config.get('username')
        self.password = smtp_config.get('password')
        self.use_ssl = smtp_config.get('use_ssl', True)

        # 验证必要配置
        if not all([self.host, self.port, self.sender, self.username, self.password]):
            raise ValueError("SMTP 配置不完整，需要: host, port, sender, username, password")

    def send_cert_renewal_notification(self, domain, cert_info, recipients):
        """
        发送证书更新成功通知

        Args:
            domain: 域名
            cert_info: 证书信息字典，包含:
                - hostname: 主机名
                - cert_path: 证书文件路径
                - key_path: 私钥文件路径
                - fingerprint: 证书指纹
                - expires_at: 过期时间
            recipients: 收件人邮箱列表
        """
        if not recipients:
            logger.info("未配置收件人邮箱，跳过邮件通知")
            return True

        hostname = cert_info.get('hostname', 'N/A')
        cert_path = cert_info.get('cert_path', 'N/A')
        fingerprint = cert_info.get('fingerprint', 'N/A')
        expires_at = cert_info.get('expires_at', 'N/A')

        # 构建邮件内容
        subject = f"[证书更新] {domain} 证书更新成功"

        body = f"""证书更新成功！

域名: {domain}
主机名: {hostname}
证书路径: {cert_path}
私钥路径: {cert_info.get('key_path', 'N/A')}
指纹: {fingerprint}
过期时间: {expires_at}

--
由 Cloudflare 证书管理工具自动发送
"""

        try:
            self._send_email(subject, body, recipients)
            logger.info(f"证书更新通知已发送到: {', '.join(recipients)}")
            return True
        except Exception as e:
            logger.error(f"发送邮件通知失败: {e}")
            return False

    def _send_email(self, subject, body, recipients):
        """
        发送邮件

        Args:
            subject: 邮件主题
            body: 邮件正文
            recipients: 收件人列表
        """
        # 创建邮件对象
        msg = MIMEMultipart()
        msg['From'] = self.sender
        msg['To'] = ', '.join(recipients)
        msg['Subject'] = Header(subject, 'utf-8')

        # 添加正文
        msg.attach(MIMEText(body, 'plain', 'utf-8'))

        server = None
        try:
            # 连接服务器并发送
            if self.use_ssl:
                server = smtplib.SMTP_SSL(self.host, self.port)
            else:
                server = smtplib.SMTP(self.host, self.port)
                server.starttls()

            server.login(self.username, self.password)
            server.sendmail(self.sender, recipients, msg.as_string())
        except smtplib.SMTPAuthenticationError as e:
            logger.error(f"SMTP 认证失败: {e}")
            raise
        finally:
            if server:
                server.quit()


def create_email_notifier_from_config(config):
    """
    从配置创建邮件通知器

    Args:
        config: 配置字典 (来自 config.yaml 的 default 部分)

    Returns:
        EmailNotifier 实例或 None (如果配置不完整)
    """
    smtp_config = config.get('smtp')

    if not smtp_config:
        logger.debug("未配置 SMTP，跳过邮件通知")
        return None

    # 检查 SMTP 是否已配置（不是占位符）
    if smtp_config.get('host') == 'smtp.example.com':
        logger.debug("SMTP 使用默认占位符，跳过邮件通知")
        return None

    try:
        return EmailNotifier(smtp_config)
    except ValueError as e:
        logger.warning(f"邮件通知器初始化失败: {e}")
        return None
