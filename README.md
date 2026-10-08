# VPSKit · 服务器工具箱

版本：1.1.0。上传目标：`Alsyok/vpskit`，分支 `main`。

## 主菜单

1. ARGO · 隧道与节点管理
2. Singbox 一键安装
3. Xray 一键安装
4. 订阅链接安装
5. Tools · BBR / VPS 清理
6. 退出

ARGO 保留原 1–15；BBR 移入 Tools，独立 Singbox 和证书管理移入 Singbox。Xray 使用相同的安装、查询、证书、修改和卸载流程。子菜单选择返回后，回到上一级。

## 怎么使用

### 上传 GitHub 后

将解压后 `vpskit` 文件夹**里面的全部文件和目录**上传到仓库根目录。根目录应直接能看到 `vpskit.sh`、`manifest.sha256`、`lib`、`modules` 和 `installers`，不要在 GitHub 再套一层 `vpskit` 文件夹，也不要只上传入口脚本。

```bash
bash <(curl -fLsS https://raw.githubusercontent.com/Alsyok/vpskit/main/vpskit.sh)
```

远程入口下载完整文件、核对 SHA-256 清单后，安装到 `/usr/local/lib/vpskit`。下载失败或内容与清单不符时，不替换已有工具箱。首次下载成功后，可直接打开：

```bash
vpskit
```

再次运行上面的远程命令，可以更新工具箱文件；更新入口不会自动升级正在运行的节点核心。

Alpine 若尚未安装 Bash 和 curl，先执行：

```sh
apk add --no-cache bash curl ca-certificates
```

Debian / Ubuntu 若缺少 curl，先执行：

```bash
apt-get update && apt-get install -y curl ca-certificates
```

### 暂不上 GitHub，在 VPS 本地使用

将完整 ZIP 上传到 `/root`，解压，执行：

```bash
unzip /root/vpskit.zip -d /root
bash /root/vpskit/vpskit.sh
```

本地使用也必须保留完整目录。本地解压启动不自动创建 `vpskit` 快捷命令。

## 支持范围

| 模块 | 支持系统 | 说明 |
|---|---|---|
| ARGO | Debian / Ubuntu、Alpine | 保留原隧道和节点功能 |
| 独立 Singbox | Debian / Ubuntu、Alpine | TLS、Reality、Hysteria2 按现有安装器提供 |
| 独立 Xray | Alpine / OpenRC | 当前两种安装器均为 VLESS TCP TLS |
| 订阅服务 | Debian / Ubuntu / systemd | Nginx HTTPS + 本地 Python API |
| Tools | 按各工具的检测结果 | BBR 和 VPS 清理 |

主入口支持 AMD64、ARM64；各安装器沿用原有版本兼容要求。需要 root 和正常运行的 systemd / OpenRC，不能把无 init 的容器当作完整 VPS 使用。

## 节点文件与订阅

| 节点来源 | 保存路径 |
|---|---|
| CF 隧道分享链接 | `/etc/nodes/argo/links.txt` |
| CF 隧道详细信息 | `/etc/nodes/argo/info.txt` |
| 独立 Singbox | `/etc/nodes/sing-box/links.txt` |
| 独立 Xray | `/etc/nodes/xray/links.txt` |
| 合并订阅 | `/etc/nodes/subscription.txt` |

核心 JSON 仍使用原路径：独立 Singbox 是 `/etc/sing-box/config.json`，独立 Xray 是 `/etc/xray/config.json`；ARGO 核心仍使用 `/etc/vps-node`。Xray 二进制仍是 `/usr/local/bin/xray`。

安装器不再写入 `/root/singbox_nodes.txt` 或 `/etc/sing-box/v2rayn_links.txt`。已有旧文件不会被自动删除，但本工具不再读取它们。`subscription_api.py` 由订阅安装器生成，无需另行上传或运行。

各组链接由当前有效配置生成，合并时加锁、去重、原子替换。未加载的新配置、未监听的节点和生成失败不会覆盖上次有效链接。通过管理菜单修改后，先校验、重启，再更新链接；后台同步继续保留。

**订阅是单独安装的服务。** 未安装时，节点照常生成分享链接，界面提示从首页 4 安装。安装成功后，保存 `/etc/nodes/subscription.json`，查询节点及完成修改时显示固定订阅网址。订阅读取合并文件，不再读取旧路径；生成新节点不自动安装 Nginx 或订阅服务。

不要把 `subscription.txt` 当作长期手动编辑文件：它会随各组发布重新生成。修改节点应使用管理菜单或核心配置后，通过受管启动方式重新加载并确认同步。Xray 可使用菜单的“重启并同步节点”。

## 证书与失败恢复

共享证书入口支持已有证书、自签证书、acme.sh 和 lego。现有证书不会被强行接管续签；新申请证书的续签设置由管理器保存。手动 DNS 验证仍需人工更新 TXT。

订阅证书扫描按证书指纹归并相同证书，优先显示常见申请工具目录；修改时间只作为次要排序依据，不能证明申请来源。支持补充扫描目录。未知或自定义目录可能需要手动输入，不能保证扫描到所有软件的任意自定义路径。

Xray 修改先校验临时配置，再保存、重启和同步；失败时恢复旧配置和元数据。安装采用清理后全新安装，不备份、不迁移旧参数；失败或取消时清理未完成的新安装，不恢复旧节点。新管理入口为 Xray 添加 OpenRC 自启服务 `vpskit-xray`，继续保留每分钟的节点同步。

证书管理器更新被节点使用的证书时，会校验并重载相关核心，失败恢复旧证书。订阅证书每 6 小时同步，先检查有效期、域名和密钥配对；Nginx 检查或重载失败时恢复原证书。

订阅重新安装或更换域名会备份其专用文件和服务状态，失败时恢复。已有其他用途的同名 Nginx 配置不会被覆盖。

卸载独立核心只移除该组节点并重算合并订阅；保留其他组与共享证书。卸载订阅保留所有节点、证书和 Nginx 软件。

## 日志

保留原日志维护方案：每分钟检查，单个受管文件日志达到 5 MiB 后轮转，最多保留 3 份旧日志；超过 15 天的旧日志删除，当前日志保留。涵盖 ARGO、独立节点同步、Xray 文件日志及证书管理日志；不修改全局 journald 设置。

轮转使用 copytruncate 保持写入文件的 inode。高并发写入时，复制与截断之间可能丢失少量日志；这是该方案的限制。5 MiB 是检查阈值，不是实时硬上限。

## 文件职责与调用方式

| 文件 / 目录 | 职责 |
|---|---|
| `vpskit.sh` | 主菜单、本地启动和远程下载入口 |
| `modules/CFtunnel.sh` | ARGO 原 1–15 |
| `modules/singbox-manager.sh` | 两种系统的独立 Singbox 管理 |
| `modules/xray-manager.sh` | Alpine Xray 安装、查询、修改、重启和卸载 |
| `modules/subscription-manager.sh` | 订阅安装、查询、修改、日志和卸载 |
| `modules/cert-manager.sh` | 共享证书申请、查看与续签 |
| `modules/tools.sh` | BBR 和远程 VPS 清理 |
| `lib/common.sh` | 颜色、输入、系统检测与返回处理 |
| `lib/node-services.sh` | 部署公共发布程序、升级已安装同步程序、日志维护 |
| `lib/node-files.py` | 所有节点组共用的加锁、保存、去重、订阅汇总与失败恢复 |
| `lib/standalone.sh` | 本地安装器调用及 Python 管理器部署 |
| `lib/node-manager.py` | 节点修改、证书管理和回滚 |
| `lib/subscription-manager.py` | 订阅备份、恢复和卸载 |
| `lib/subscription-cert-sync.py` | 订阅证书配对校验与同步 |
| `lib/bbr.sh` | 原 BBR 功能 |
| `installers/` | 五个实际安装脚本 |
| `tests/` | 隔离文件系统和模拟服务的测试 |
| `scripts/build-manifest.py` | 修改代码后重建下载校验清单 |

可直接调用管理操作，例如：

```bash
bash vpskit.sh singbox info
bash vpskit.sh singbox edit
bash vpskit.sh xray info
bash vpskit.sh xray edit
bash vpskit.sh xray restart
bash vpskit.sh subscription info
bash vpskit.sh tools bbr
```

ARGO、Singbox、Xray、订阅入口提供 `menu / install / info / edit / uninstall`。Xray 另有 `restart / certificates`；订阅另有 `restart / logs`；Tools 使用 `menu / bbr / clean`；证书入口使用 `menu / info / renew`。

增加功能优先增加独立模块，再由主菜单调用，避免把新功能塞回 ARGO 文件。模块默认进入 `menu`，返回用 `return` 或模块退出，主入口负责继续显示上级菜单。

## 测试与后续修改

```bash
python3 tests/test_vpskit.py
python3 scripts/build-manifest.py
```

修改脚本后，先测试，再更新 `manifest.sha256`，最后把改过的文件与清单一起上传；否则远程下载会拒绝更新。

当前完成语法检查和 21 项离线测试，覆盖菜单返回、下载校验、分享链接、加载保护、节点汇总、配置修改回滚、全新安装成功/失败清理、证书同步、卸载范围与日志轮转。测试使用模拟服务，**没有在真实 VPS 上完成联网安装验证**。GitHub 下载、DNS、证书申请、端口与真实服务启动由部署环境决定。

VPS 清理继续调用你提供的地址：`https://raw.githubusercontent.com/Alsyok/argo/main/VPSclean.sh`，下载和语法检查成功后才执行。核心与证书工具下载沿用现有外部来源；代码中不包含实际账号令牌、私钥或真实节点链接。

## 1.1.0 公共发布更新

四个独立安装器、内置 Singbox 同步程序与 ARGO 现在使用同一个公共发布程序。每个同步程序只保留配置解析、加载检查和链接生成；更新规则时主要修改 `lib/node-files.py`。新增协议仍须由对应核心支持，并补充该核心的配置和链接生成规则。

发布在同步程序的同一个 Python 进程内执行，不另起 Python 子进程，不增加常驻发布服务。`musl-Xray.sh` 保留 Alpine 小内存 NAT 机用途；**64M / 128M 下的安装峰值与运行稳定性尚未实机验证**，此版本不宣称保证这些内存规格可用。

## 1.2.0 全新安装

启动工具箱只准备公共发布入口，不扫描、迁移或改写旧同步程序。旧程序不再阻挡菜单。

选择安装独立 sing-box 或 Xray，会停止所选核心的服务与同步任务，清理常见配置目录、二进制、同步程序和对应节点链接，再按首次安装流程设置新参数。不创建旧安装备份，失败不恢复旧安装。ARGO、另一个核心、共享证书和其它节点分组保留。配置修改的失败恢复与订阅安装事务仍然保留。

清理识别常见独立核心服务名、配置路径、服务启动命令，以及 sing-box / xray 进程；不盲目删除全盘文件。第三方自定义改名的二进制、任意目录和间接启动任务无法保证自动识别，需要按实际部署补充清理规则。

旧安装需从安装菜单执行全新安装；管理入口不接管未知旧同步程序。

`installers/` 中的安装器现在依赖工具箱预先部署的公共发布程序，请通过管理入口安装。不要把本包的单个安装器替换到旧的独立一键安装地址。之前独立脚本的兼容更新需要另行接入公共依赖。

更新 GitHub 时，将这个完整包里的文件覆盖到仓库根目录，保留 `.github/workflows/update-manifest.yml` 与新的校验清单。随后在 VPS 重新运行远程一键命令。仅输入已安装的 `vpskit` 不会自动从 GitHub 下载新版本。

## 1.2.1 Xray 自签证书指纹

两个 Xray 安装器的自签 VLESS-TLS 链接会导出 `pcs=<叶子证书 DER 的 SHA256>` 和 `allowInsecure=0`，供支持此参数的 Xray 客户端验证证书。正常正式证书继续走 CA 验证，不固定易随续期变化的指纹。每次生成自签链接会读取配置中当前证书，证书更换后重新计算；读取失败则保留旧链接。新自签证书显式设置 CA:FALSE 与 serverAuth。该兼容修复针对客户端 Xray 核心，不代表 sing-box 客户端会识别 pcs。

已安装旧 Xray 同步程序不会自动迁移，需选择安装新版后获取新的节点链接；全新安装会删除旧参数。

1.2.2：数字菜单忽略空行、CRLF 与首尾空格；Xray 安装方式无效输入原处重选；普通参数回车默认值行为保留。手机 SSH 实际键盘行为仍需用户验证。
