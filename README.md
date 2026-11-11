# 云吞插件模板

开发流程见[插件开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)。

这是一个能安装的示例插件 `app.example.hello`：使用 nginx 官方镜像显示问候页，经网关的 `sso: proxy` 注入用户名，页面显示“你好，<用户名>”。示例没有应用账号、持久化数据或 MCP 工具。

## 示例文件

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 示例清单、nginx 服务和三个 `configs` |
| `web/default.conf.template` | nginx 配置，启用 SSI 回显用户名并提供健康检查入口；只放行来自核心地址（`${WONTON_CORE_ADDRESS}`）的请求，其余来源 403 |
| `web/index.html` | 问候页 |
| `web/tokens.css` | 页面主题变量的后备值 |
| `tabs/` | 示例主页的应用页面图标 |
| `screenshots/home.png` | 商店详情页的示例截图 |
| `scripts/smoke-probes.sh` | 检查真实页面和网关注入身份的插件探针 |

从模板创建自己的插件后，替换示例清单、网页和素材；具体步骤见[写插件](https://github.com/wontonapp/wonton-docs/blob/main/develop.md#写插件)。

## 对着别的栈跑探针

`probes`、`api`、`session` 按 `.wonton/.env` 的 `WONTON_BASE_DOMAIN` 拼核心地址，`up` 起的栈自己写这个键。插件装进别人的栈、或者对着已有环境排查时，把那套栈的基础域名写进 `.wonton/.env`，不要只按实例名猜地址：实例名只是资源名前缀，网关按 Host 认域名，拼错了会回“没有安装”。

```bash
WONTON_BASE_DOMAIN=wonton.localhost
```

## 核心镜像

检查和冒烟默认用套件里的核心镜像（`ghcr.io/wontonapp/wonton-core:main`）；要固定别的核心镜像，在仓库 Settings → Variables 设 `WONTON_CORE_IMAGE`，手动触发“检查”时填的 `core-image` 输入优先。

## 更新开发套件

```bash
scripts/dev.sh kit-update
```

在从模板新建的插件仓库中更新套件；本仓库是套件源头，执行时只提示并退出。版本、可选引用和自定义脚本约定见[开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md#更新开发套件)。

## 图标

`icon.svg` 是本仓库原创线条图标，按本仓库 MIT 许可证分发，见 [NOTICE](NOTICE)。
