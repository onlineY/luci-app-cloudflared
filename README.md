# luci-app-cloudflared

一款 OpenWrt/iStoreOS 上的 **Cloudflare Tunnel** 本地可视化管理插件。

## 📌 项目介绍

- 首选`Cloudflare`后台面板可以对隧道可视化管理
- 每次登录或者换设备太麻烦了,所以有了本项目,通过本地使用`config.yml`的方式控制隧道
- 目前只支持单域名，单通道

> **支持协议**：目前已测试 **HTTP / HTTPS**。其他协议需额外配置，请在额外配置好以后自行测试。

---

## 🚀 安装

### 1️⃣ 安装 Cloudflare Tunnel（已安装可跳过）

**新手推荐**：运行一键安装脚本直接在路由器上进行：

```bash
wget -O /tmp/setup.sh https://github.com/onlineY/luci-app-cloudflared/raw/main/tools/setup.sh
sh /tmp/setup.sh
```

脚本会自动：
- 下载对应的 cloudflared 二进制
- 引导完成 Cloudflare 账号授权（获取证书）
- 创建隧道并保存凭据到安装目录

### 2️⃣ 安装 LuCI 管理插件

从 [Releases](../../releases) 下载最新 `.ipk` 文件，在路由器上运行：

```bash
opkg install luci-app-cloudflared_*_all.ipk
```

安装后刷新 LuCI，进入 **服务 → Cloudflared** 完成配置。


## ⚙️ 使用指南

## 🔑 获取 Cloudflare API Token

为了实现 DNS 记录的自动同步，需要配置一个 Cloudflare API Token：

1. 访问 [Cloudflare 控制面板 - API Tokens](https://dash.cloudflare.com/profile/api-tokens)
2. 点击 **创建 Token** 按钮
3. 选择 **Edit zone DNS** 预设模板
4. 在 **Zone Resources** 中选择你要管理的域名
5. 点击创建，复制生成的 Token
6. 粘贴到 LuCI 页面的 **Cloudflare API 令牌** 字段

完成后点击 **保存并应用**，插件会自动同步 DNS 记录。

## 截图
![示例图片](./img/image.png)

