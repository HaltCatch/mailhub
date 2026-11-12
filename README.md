# MailHub

[中文](README.md) · [English](README.en.md)

把多个 IMAP 邮箱集中到一个收件箱。MailHub 用 Fetchmail 持续收取远端邮件，交给 Stalwart 保存，再通过 Bulwark Webmail 统一阅读、检索与管理，适合自托管的个人邮件工作台。

## 功能

- 多账号收件：按账号配置 IMAP，支持持续收取新邮件和可选的首次历史导入。
- 统一邮箱：Collector 经内部 SMTP 投递到 Stalwart，使用同一 Webmail 管理。
- 初始化：邮箱身份、管理员、内部投递信任与超时参数可配置。
- 垃圾邮件反馈：训练服务与规则更新入口，形成分类后的反馈流程。
- 可选认证与投递：Authentik/OIDC 登录及 SMTP Relay 配置。
- 持久化部署：Docker Compose 管理服务，邮件数据与账号配置放在指定宿主机目录。

## 快速开始

Docker Engine 与 Compose，远端 IMAP 账号，以及用于 Webmail 的域名和 HTTPS 反向代理。

```sh
cp .env.example .env
cp accounts/custom.example.env accounts/personal.env
# Fill .env and the account file before starting.
docker compose up -d --build
docker compose ps
```

## 配置

| 配置项 | 说明 |
| --- | --- |
| `DATA_ROOT` | 邮件与服务运行数据根目录。 |
| `MAIL_HUB_HOSTNAME / HUB_DOMAIN` | 外部服务域名与本地邮箱域。 |
| `STALWART_ADMIN_PASSWORD` | Stalwart 管理员口令。 |
| `BULWARK_SESSION_SECRET` | Webmail 独立随机会话密钥。 |
| `accounts/*.env` | 各远端邮箱的地址、服务器与授权凭据。 |
| `MAIL_HUB_OIDC_*` | 可选 OIDC 配置；邮箱身份声明应映射到本地邮箱。 |

## 使用

配置完成后，通过反向代理打开 Webmail。默认仅收取新邮件；如需历史邮件，请确认各账号的首次全量导入选项。服务端口和转发关系以 `compose.yaml` 为准。

## 项目结构

- `collector/` — 邮件收取
- `stalwart/` — 邮件服务与初始化
- `bulwark/` — Webmail 配置
- `trainer/` — 垃圾邮件训练

## 许可

[PolyForm Noncommercial 1.0.0](LICENSE)。原创部分与第三方组件的适用范围见 [LICENSE_SCOPE.md](LICENSE_SCOPE.md)；各第三方版权和许可见相应声明文件。
