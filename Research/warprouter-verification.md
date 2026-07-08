# WarpRouter 脉冲代理验证记录

**日期**: 2026-07-08
**目标**: 验证通过亚洲代理节点让 Cloudflare WARP 到达 NRT/SIN 而非 LAX，并实现"脉冲代理"（断开代理后连接保持）

---

## 背景问题

从中国大陆直连 Cloudflare WARP，BGP 路由默认到 LAX（洛杉矶），延迟高。用户发现通过 Shadowrocket 路由到日本/新加坡节点可以让 WARP 到达 NRT/SIN，延迟显著降低。

**核心问题**: 能否自动化这个过程，让工具"脉冲"一次建立连接后断开代理，利用 QUIC 连接迁移保持亚洲机房？

---

## 验证内容

### 1. WARP 路由机制分析

**结论**:
- WARP 使用 MASQUE (HTTP/3 over QUIC/UDP) 或 WireGuard (UDP)
- 连接 anycast IP (如 `162.159.192.0/24`)
- 实际机房选择由 BGP 最短路径决定，不是客户端直接选择
- **改变 WARP 机房的本质是改变 WARP UDP 包的网络出口路径**

**验证方法**: 研究文档 + trace 测试

---

### 2. mihomo masque + dialerProxy 链式转发

**方案**: mihomo 自身实现 MASQUE 协议，通过 `dialer-proxy` 链式转发到亚洲节点

**配置**:
```yaml
proxies:
  - name: "JP-Hysteria2"
    type: hysteria2
    server: 203.10.99.51
    port: 50000
    # ...

  - name: "WARP-via-JP"
    type: masque
    server: 162.159.198.2
    port: 8443
    dialer-proxy: "JP-Hysteria2"  # 关键：链式转发
    # ...
```

**验证结果**: ✅ **成功** (15:02)
- 通过 mihomo HTTP 代理访问 trace → `colo=NRT`
- 链路: 用户流量 → mihomo masque → Hysteria2 日本 → WARP NRT

**限制**:
- mihomo 持有 WARP 连接，不是 warp-cli
- 切换 proxy-group select 会重建连接，不是 QUIC 连接迁移
- 脉冲代理需要其他方案

---

### 3. warp-cli proxy 模式 + mihomo TUN

**方案**:
- `warp-cli mode proxy` → 不创建 utun，只开 SOCKS5 端口 (127.0.0.1:40000)
- warp-cli 的 UDP 包正常走系统路由
- mihomo TUN 接管系统路由，把 WARP anycast IP (162.159.x.x) 路由到 Hysteria2 日本
- 结果: warp-cli UDP → mihomo TUN → 日本 → WARP NRT

**验证结果**: ✅ **脉冲成功** (16:57)
- 基线: warp-cli 直连 → `colo=SJC` (San Jose)
- 脉冲: 启动 mihomo TUN + warp-cli 重连 → `colo=NRT` (东京)
- 链路: warp-cli UDP → mihomo TUN → Hysteria2 日本 → WARP NRT

**连接迁移验证**: ❌ **失败**
- 断开 mihomo TUN 后 WARP 连接断开
- 原因: `http=http/2` (H2 模式)
- **H2 (TCP) 不支持 QUIC 连接迁移**

**后续尝试**: 强制 H3-only
```bash
warp-cli tunnel masque-options set h3-only
```
- H3 (QUIC/UDP) 支持连接迁移
- 但 mihomo TUN 的 gvisor stack 对 UDP 转发可能有问题
- 未验证（需要 sudo）

---

### 4. HTTP_PROXY 环境变量方法

**假设**: warp-cli 的 MASQUE H2 模式走 TCP，可能 respect `HTTP_PROXY` 环境变量

**验证方法**: 通过 `launchctl setenv` 设置 warp daemon 的环境变量

**验证结果**: ❌ **失败**
- SIP (System Integrity Protection) 阻止: `Operation not permitted while System Integrity Protection is engaged`
- 即使成功，二进制分析显示 `HTTP_PROXY` 只用于 Sentry 上报和 API 请求，不影响 MASQUE 隧道连接

---

## 关键发现

### QUIC 连接迁移的必要条件

| 条件 | 状态 | 说明 |
|------|------|------|
| H3 (QUIC/UDP) | 必需 | H2 (TCP) 不支持连接迁移 |
| QUIC Connection ID 保持 | 必需 | 连接迁移依赖 Connection ID 不变 |
| 网络出口变化 | 触发条件 | 从代理出口切换到直连出口 |

### mihomo proxy-group 切换行为

- 切换 proxy-group 的 select 会重建 masque outbound 连接
- **不是 QUIC 连接迁移**
- 脉冲代理需要其他实现方式

### warp-cli proxy 模式优势

- 不创建 utun，不接管系统路由
- 与 mihomo TUN 不冲突
- QUIC 连接由 warp-cli 持有，连接迁移由 warp-cli 自己完成
- 工具只需编排代理环境

---

## 技术方案对比

| 方案 | 优点 | 缺点 | 验证状态 |
|------|------|------|----------|
| mihomo masque + dialerProxy | 不依赖 warp-cli，纯 mihomo | 切换重建连接，不支持迁移 | ✅ 链路成功，❌ 迁移失败 |
| warp-cli proxy + mihomo TUN | QUIC 连接由 warp-cli 持有，支持迁移 | 需要 sudo，H3 UDP 转发未验证 | ✅ 脉冲成功，❌ 迁移失败(H2) |
| HTTP_PROXY 环境变量 | 不需要 TUN | SIP 阻止，隧道不读环境变量 | ❌ 不可行 |
| Shadowrocket TUN | 你日常使用，已验证 | 不是自动化工具 | ✅ 日常可行 |

---

## 下一步

### 方案 1: 验证 warp-cli proxy + mihomo TUN + H3-only

**步骤**:
1. `warp-cli tunnel masque-options set h3-only` (强制 H3)
2. 启动 mihomo TUN (需要 sudo)
3. warp-cli 重连 → 验证 colo=NRT
4. 停 mihomo TUN → 验证 colo 保持 (连接迁移)
5. 监控保持时长

**风险**: H3 UDP 在中国可能被 QoS，连接不稳定

### 方案 2: 探索 sing-box 的 dialerProxy 切换

sing-box 的 dialerProxy 切换行为可能与 mihomo 不同，可能支持连接迁移。

### 方案 3: 直接集成 Shadowrocket API

Shadowrocket 已验证可行，探索其 API 是否支持自动化控制。

---

## 工具脚本

| 脚本 | 功能 | 状态 |
|------|------|------|
| `warp-pulse-verify.sh` | mihomo masque + dialerProxy 测速 | ✅ 完成 |
| `warp-pulse-dialer-verify.sh` | mihomo dialerProxy 切换验证 | ✅ 完成 |
| `warp-pulse-proxy-tun-verify.sh` | warp-cli proxy + mihomo TUN 验证 | ✅ 完成 |
| `warp-set-proxy.sh` | 设置 warp daemon HTTP_PROXY | ❌ SIP 阻止 |

---

## 参考资料

- WARP PRD: `/Users/peanut996/WarpRouter-PRD.md`
- mihomo 配置: `/tmp/warp-pulse-test/config.yaml`
- mihomo 二进制: `/tmp/warp-pulse-test/mihomo-darwin-arm64-alpha-cbd11db`
- Hysteria2 节点: 用户订阅链接
