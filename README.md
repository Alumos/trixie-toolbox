# trixie-toolbox

为 **Debian 13 (trixie)** 准备的 VPS 常用脚本合集。

| 脚本 | 说明 |
| --- | --- |
| [vps-init.sh](vps-init.sh) | VPS 初始化：安装基础依赖 + nftables 接管防火墙 + 终端菜单管理 |

---

## 一键运行

要求：Debian 13、root 权限。

### 方式一：一条命令（推荐）

```bash
curl -fsSL -o /tmp/vps-init.sh https://raw.githubusercontent.com/Alumos/trixie-toolbox/main/vps-init.sh && bash /tmp/vps-init.sh
```

### 方式二：网络不好时走镜像加速

```bash
curl -fsSL -o /tmp/vps-init.sh https://gh-proxy.com/https://raw.githubusercontent.com/Alumos/trixie-toolbox/main/vps-init.sh && bash /tmp/vps-init.sh
```

> `gh-proxy.com` 是第三方 GitHub 加速服务，只做转发。不放心源文件的话，可以用方式三先下载后自己看一眼。

### 方式三：先下载再执行（最稳）

```bash
# 官方源
curl -fsSL -o /tmp/vps-init.sh https://raw.githubusercontent.com/Alumos/trixie-toolbox/main/vps-init.sh

# 官方源拉不动就换成镜像
# curl -fsSL -o /tmp/vps-init.sh https://gh-proxy.com/https://raw.githubusercontent.com/Alumos/trixie-toolbox/main/vps-init.sh

sudo bash /tmp/vps-init.sh
```

没有 curl 的话：

```bash
apt-get update && apt-get install -y curl
```

或者用 wget：

```bash
wget -qO /tmp/vps-init.sh https://gh-proxy.com/https://raw.githubusercontent.com/Alumos/trixie-toolbox/main/vps-init.sh
sudo bash /tmp/vps-init.sh
```

> ⚠️ **不要**写成 `curl ... | sudo bash`：脚本是交互式菜单，管道会占用 stdin，菜单会按不动。
>
> ⚠️ 也**不建议**写成 `bash <(curl ...)`：进程替换在部分系统上会因 `sudo` 缺失或脚本提前退出而断开管道，curl 报 `(23) Failure writing output to destination`。
> 先下载到 `/tmp` 再执行最稳，失败也不会跑半截。

---

## 它做了什么

1. 安装 `curl` / `wget` / `sudo` / `nftables`
2. 检测并停用冲突的 ufw / firewalld（会先询问）
3. 用 nftables 接管本机防火墙
4. 防火墙**默认不启用**，需要手动开启
5. 提供终端菜单，第一项就是「防火墙管理」

## 菜单

主菜单：

```
1) 防火墙管理
2) 基础环境 / 依赖安装
3) 查看系统信息
4) 使用帮助
q) 退出
```

防火墙管理：

```
1) 启用防火墙
2) 关闭防火墙
3) 查看当前规则
4) 放行新端口
5) 删除放行端口
6) 查看已配置端口
7) 恢复默认放行端口
b) 返回主菜单
```

放行新端口的流程：输入端口号（支持 `8080,8443` 多端口）→ 选择 TCP / UDP / Both → 填写备注（可选，直接回车跳过）。

---

## 默认放行端口

防火墙**首次启用**时写入以下端口，之后可以在菜单里增删：

| 端口 | 协议 | 服务 | 说明 |
| --- | --- | --- | --- |
| 20 | TCP | FTP 数据传输 | FTP 主动模式的数据端口 |
| 21 | TCP | FTP 控制 | FTP 命令通道 |
| 22 | TCP | SSH | 远程登录；SFTP / SCP 也复用此端口 |
| 80 | TCP | HTTP | 明文网页 |
| 443 | TCP + UDP | HTTPS | TCP 用于常规 HTTPS，UDP 用于 QUIC / HTTP3 |
| 3389 | TCP + UDP | Windows RDP | 远程桌面；UDP 用于 RDP 的 UDP 传输通道 |
| 3306 | TCP | MySQL / MariaDB | 数据库默认端口 |
| 5432 | TCP | PostgreSQL | 数据库默认端口 |
| 6379 | TCP | Redis | 内存数据库默认端口 |

> 图上没有出现的端口一律不放行。

---

## 防火墙行为说明

- **默认关闭**：nftables 服务不启用，没有加载任何规则，所有端口均可访问。
- **开启后**：`input` 链策略为 `drop`，只放行：配置表里的端口、已建立的连接（`ct state established,related`）、ICMP（ping 等）、本地回环。
- `forward` 与 `output` 为 `accept`，避免误伤 Docker 等需要转发的场景。
- 规则持久化在 `/etc/trixie-toolbox/trixie-toolbox.nft`，开机由 `nftables.service` 自动加载。
- 每次启用 / 重载规则前会自动备份当前的 `nftables.conf` 和规则集到 `/etc/trixie-toolbox/backups/`。

## SSH 断连保护

- 启用防火墙前会检测 `sshd` 实际监听端口（`ss` + `sshd_config` 双重检测），如果不在放行列表里会提示自动加入。
- 通过 SSH 会话启用防火墙时，会启动 **30 秒自动回滚**：30 秒内没有输入 `y` 确认，规则自动撤销并关闭防火墙，避免把自己锁在门外。
- 想跳过这个保护：`TTB_NO_ROLLBACK=1 sudo -E bash vps-init.sh`

---

## 文件位置

| 路径 | 说明 |
| --- | --- |
| `/etc/trixie-toolbox/ports.db` | 放行端口配置（`端口\|协议\|备注`） |
| `/etc/trixie-toolbox/trixie-toolbox.nft` | 自动生成的 nftables 规则 |
| `/etc/trixie-toolbox/firewall.state` | 防火墙状态记录 |
| `/etc/trixie-toolbox/backups/` | 每次操作的规则 / 配置备份 |
| `/etc/nftables.conf` | 由脚本接管，开机加载 |
| `/var/log/trixie-toolbox.log` | 操作日志 |

---

## 常见问题

### 开启防火墙后 SSH 连不上了

- 如果是通过 SSH 开的，等 30 秒会自动回滚。
- 如果已经断连，用 VPS 控制台 / VNC 登录后执行：

```bash
nft flush ruleset
systemctl disable --now nftables
```

然后重新进菜单，把 SSH 端口加进放行列表再开启。

### 我改过 SSH 端口

脚本启用时会自动检测 `sshd` 实际监听端口，检测不到时会提示，确认即可自动加入。

### 我用了 Docker / 容器

`forward` 链是 `accept`，一般不受影响。如果容器网络异常，先检查 Docker 自己写的 iptables 规则，必要时用 `iptables -S` 对比。

### 想手工加端口

```bash
# 格式：端口|协议|备注
echo "8080|tcp|我的服务" >> /etc/trixie-toolbox/ports.db
# 重载
systemctl restart nftables
```

或者直接进菜单「防火墙管理 → 放行新端口」。

### 怎么彻底关掉

菜单里「关闭防火墙」，或者在命令行：

```bash
systemctl disable --now nftables
nft flush ruleset
```

### 能重复运行吗

可以。脚本是幂等的，重复运行只会重新检查依赖和进入菜单，不会重置已有端口配置。

---

## 安全建议

- `3306` / `5432` / `6379` 默认对公网放行，只适合演示。生产环境建议从菜单里删掉，改走内网或 SSH 隧道。
- SSH 建议改端口 + 只用密钥登录：`PasswordAuthentication no`。
- 开防火墙前先确认 VPS 面板的「安全组」也放行了对应端口，两个地方都要放行。

---

## 更新日志

### v1.0.0

- 初始版本
- 依赖安装 / ufw·firewalld 接管
- nftables 防火墙菜单
- 默认放行端口 + 自定义端口增删
- SSH 30 秒自动回滚保护

## License

[MIT](LICENSE)
