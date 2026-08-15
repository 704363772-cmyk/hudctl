# HUDControl — HUD 一键控制 App（越狱直连版）

主界面一个按钮：显示「启动 HUD」→ 点击后变「关闭 HUD」（红色）→ 再点变回。
**越狱环境（iOS 15.3.1）**：app 以 no-sandbox 运行，所有动作直连，**无 daemon 依赖**。

## 架构（vs 沙箱版）

```
HUDControl.app (/Applications, no-sandbox, mobile)
   ├─ start: posix_spawn("/Applications/ComicReader.app/ComicReader", ["-hud", NULL], environ)
   │         （镜像 C5 已实锤 argv，同 uid 同用户，无 persona 段）
   ├─ stop : notify_post("com.test.notification.hud.dismissal")   ← T15 实锤纯 Darwin notify
   │         + 1.5s 后 kill(pid, SIGKILL) 兜底（同 uid 可杀，sysctl 枚举 -hud 进程）
   └─ 状态 : sysctl KERN_PROC_ALL + KERN_PROCARGS2 匹配 argv 含 "-hud"；2 秒定时刷新
             验证状态直读 /var/mobile/Library/Preferences/com.DFMvios.plist 的 code 键
```

- 不碰 ComicReader 本体，与原版 / c4 / c4b / t14s1 全兼容
- entitlements: `platform-application` + `com.apple.private.security.no-sandbox`（ldid 签名）

## 构建（二选一）

### A. GitHub Actions（推荐，无 Mac 也行，免费）
1. 把这个目录推到 GitHub 仓库（main 分支）
2. Actions → build-hudcontrol-jb → Run workflow（或 push 自动触发）
3. 下载 artifact `HUDControl-jb-deb` → 得到 `pkg/hudcontrol_jb.deb`

### B. 本机 Mac（一条命令）
```bash
bash package/build_all.sh     # 需要 Xcode + ldid（brew install ldid）
# 产物: pkg/hudcontrol_jb.deb
```

## 安装（设备，Sileo/Zebra）
1. 装 `pkg/hudcontrol_jb.deb`（Sileo 打开 → Install；postinst 自动 `uicache` 刷新图标）
2. **桌面直接出现「HUD控制」app，无需重启**
3. 打开 → 点「启动 HUD」→ 按钮变「关闭 HUD」

## 行为细节
- 启动：`posix_spawn` 直启 HUD 分身（C5 同款 argv），成功显示 pid
- 关闭：先投 dismissal 通知（HUD 自己走关闭流程），1.5 秒后枚举 `-hud` 进程 kill 兜底
- 按钮态是真实回读：每 2 秒 sysctl 扫描，HUD 死了按钮自动变回「启动 HUD」
- 状态标签显示 plist 的 `code` 键在/不在（验证有效/已失效）

## 文件结构
```
app/main.swift                  # 全部 UI + 直连逻辑（纯代码，无 storyboard）
app/Info.plist / entitlements.plist
package/postinst                # uicache 刷新图标
package/build_all.sh            # 一键构建（macOS）
package/pack_deb.py             # deb 打包（纯标准库，可跨平台冒烟）
.github/workflows/build.yml     # GitHub Actions 云构建
legacy/                         # 旧 daemon 版源码备份（hudctl.deb 后备不删）
```

## 已知边界
- 外部进程 spawn 的 HUD 窗口可达性（UIKit 呈现）未实测——但原 app 自己就是 posix_spawn 起的 HUD，机制同源，预期正常；不行再切 setuid-root 方案（Cydia 先例）
- Windows 无 iOS 编译链，产物需在 Mac / GitHub Actions 上构建
- 旧 daemon 版（v2.0.0）如已安装，升级 v3 后 daemon 残留无害（无人再发 com.ctf.hudctl.* 通知）