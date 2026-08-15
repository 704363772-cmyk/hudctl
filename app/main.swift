import UIKit
import Darwin

// ============================================================
// HUDControl JB 直连版 v2.1（plist 深度探测）- 单按钮 toggle（启动 HUD ⇄ 关闭 HUD）
// 越狱 no-sandbox 环境：所有动作直连，无 daemon 依赖
//   start: posix_spawn(<自动探测的 ComicReader 路径>, ["-hud"], environ)  // 镜像 C5 argv
//   stop : notify_post("com.test.notification.hud.dismissal") + kill(pid, SIGKILL) 兜底
//   状态 : sysctl KERN_PROC_ALL + KERN_PROCARGS2 匹配 argv 含 "-hud" 的 ComicReader 进程
//   验证 : plist 深度探测（系统路径 → 容器路径自动探测）
//
// v2（诊断）: errno 持久行 / 二进制路径自动探测 / plist 容器扫描
// v2.1（plist 深度探测，2026-08-15）:
//   1. 每次刷新显示 plist 完整状态：实际路径 / 属主 uid / 权限 mode / 大小 / mtime
//   2. code 键双通道探测：直读文件（NSDictionary）+ cfprefsd 视角（CFPreferences）各试一次
//   3. 刷新间差异行（▲）：大小/mtime/属主/权限/code 存在性/cfprefsd 变化当场可见，
//      点按钮前后 plist 怎么变一目了然（判别"重验翻转" vs "首次启动触发翻转"）
//   4. 捕获到 code 值自动备份 /var/mobile/hudctl_codes.txt（去重，供 v3 回填用）
// ============================================================

let kComicExePrimary = "/Applications/ComicReader.app/ComicReader"
let kContainerBundleRoots = ["/var/containers/Bundle/Application", "/var/mobile/Applications"]
let kContainerDataRoots = ["/var/mobile/Containers/Data/Application", "/var/mobile/Applications"]
let kPrefsPlistPrimary = "/var/mobile/Library/Preferences/com.DFMvios.plist"
let kDismissalNotify = "com.test.notification.hud.dismissal"
let kCodeBackupFile = "/var/mobile/hudctl_codes.txt"

// notify.h 的 notify_post 在 iOS SDK 的 Swift 模块中未导出（macOS 上可过、iOS 目标报错），
// 用 @_silgen_name 直接绑定 libsystem_notify 符号，T15 实锤 C1 发布侧用的就是原生 notify_post。
@_silgen_name("notify_post")
private func notify_post(_ name: UnsafePointer<CChar>) -> UInt32

// plist 探测快照（每次 refresh 生成一份，与上一次比较产生差异行）
private struct PlistProbe {
    var path = ""
    var exists = false
    var readable = false
    var size: Int64 = 0
    var perms = "-"
    var owner = "-"
    var mtime = "-"
    var codeDirect = false
    var codeValDesc = "-"
    var cfVal = "nil"          // cfprefsd 视角：nil 或值摘要
    var changed = ""           // 与上次相比的变化（空 = 无变化）
}

final class ViewController: UIViewController {

    private let button = UIButton(type: .system)
    private let stateLabel = UILabel()
    private let plistLabel = UILabel()
    private let diagLabel = UILabel()
    private let pathLabel = UILabel()
    private let hintLabel = UILabel()
    private var timer: Timer?
    private var prevProbe: PlistProbe?

    // 探测结果缓存 + 最近一次动作诊断（refresh 不覆盖）
    private var comicExe: String?
    private var comicExeSource = ""
    private var lastDiag = "诊断：--"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        button.titleLabel?.font = .systemFont(ofSize: 28, weight: .bold)
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 18
        button.layer.masksToBounds = true
        button.addTarget(self, action: #selector(tapButton), for: .touchUpInside)
        view.addSubview(button)

        stateLabel.font = .systemFont(ofSize: 16, weight: .medium)
        stateLabel.textAlignment = .center
        view.addSubview(stateLabel)

        plistLabel.font = .systemFont(ofSize: 12)
        plistLabel.textAlignment = .center
        plistLabel.numberOfLines = 0
        view.addSubview(plistLabel)

        diagLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        diagLabel.textColor = .systemOrange
        diagLabel.textAlignment = .center
        diagLabel.numberOfLines = 0
        view.addSubview(diagLabel)

        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabel
        pathLabel.textAlignment = .center
        pathLabel.numberOfLines = 0
        view.addSubview(pathLabel)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.text = "越狱直连版 v2.1（plist 深度探测）\nstart: posix_spawn -hud | stop: dismissal 通知 + kill 兜底\n2 秒自动刷新；▲行 = 探测变化；code 值自动备份到 /var/mobile/hudctl_codes.txt"
        view.addSubview(hintLabel)

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width
        button.frame     = CGRect(x: 32, y: 120, width: w - 64, height: 100)
        stateLabel.frame = CGRect(x: 32, y: 232, width: w - 64, height: 22)
        plistLabel.frame = CGRect(x: 32, y: 258, width: w - 64, height: 118)
        diagLabel.frame  = CGRect(x: 32, y: 380, width: w - 64, height: 50)
        pathLabel.frame  = CGRect(x: 32, y: 434, width: w - 64, height: 52)
        hintLabel.frame  = CGRect(x: 32, y: 490, width: w - 64, height: 100)
    }

    // ---- 路径探测：系统域 → 容器域（App Store 版）----
    private func resolveComicExe() -> String? {
        if FileManager.default.fileExists(atPath: kComicExePrimary) {
            comicExeSource = "系统域 /Applications"
            return kComicExePrimary
        }
        for root in kContainerBundleRoots {
            guard let subs = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for sub in subs {
                let appDir = root + "/" + sub + "/ComicReader.app"
                let exe = appDir + "/ComicReader"
                if FileManager.default.fileExists(atPath: exe) {
                    comicExeSource = "容器 " + root + "/" + sub
                    return exe
                }
            }
        }
        comicExeSource = ""
        return nil
    }

    private func ensureComicExe() {
        if let exe = comicExe, FileManager.default.fileExists(atPath: exe) { return }
        comicExe = resolveComicExe()
    }

    // ---- plist 路径探测：系统路径 → 容器路径 ----
    private func resolvePlist() -> (path: String, exists: Bool) {
        if FileManager.default.fileExists(atPath: kPrefsPlistPrimary) {
            return (kPrefsPlistPrimary, true)
        }
        for root in kContainerDataRoots {
            guard let subs = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for sub in subs {
                let p = root + "/" + sub + "/Library/Preferences/com.DFMvios.plist"
                if FileManager.default.fileExists(atPath: p) {
                    return (p, true)
                }
            }
        }
        return (kPrefsPlistPrimary, false)
    }

    // ---- 抓到 code 值自动备份（去重追加）----
    private func captureCode(_ v: String) {
        let existing = (try? String(contentsOfFile: kCodeBackupFile, encoding: .utf8)) ?? ""
        if existing.contains(v) { return }
        let line = v + "  captured=" + Date().description + "\n"
        if let h = FileHandle(forWritingAtPath: kCodeBackupFile) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(toFile: kCodeBackupFile, atomically: true, encoding: .utf8)
        }
    }

    // ---- plist 深度探测（直读 + cfprefsd 双通道 + 差异行）----
    private func probePlist(prev: PlistProbe?) -> PlistProbe {
        let (pPath, pExists) = resolvePlist()
        var pr = PlistProbe()
        pr.path = pPath
        pr.exists = pExists
        if pExists {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: pPath) {
                if let sz = attrs[.size] as? NSNumber { pr.size = sz.int64Value }
                if let pm = attrs[.posixPermissions] as? NSNumber { pr.perms = String(pm.intValue, radix: 8) }
                if let uid = attrs[.ownerAccountID] as? NSNumber { pr.owner = "uid=" + uid.stringValue }
                if let mt = attrs[.modificationDate] as? Date {
                    let f = DateFormatter()
                    f.dateFormat = "HH:mm:ss"
                    pr.mtime = f.string(from: mt)
                }
            }
            if let d = NSDictionary(contentsOfFile: pPath) {
                pr.readable = true
                if let v = d.object(forKey: "code") {
                    pr.codeDirect = true
                    let s = String(describing: v)
                    pr.codeValDesc = s.count <= 24 ? s : String(s.prefix(16)) + "…(" + String(s.count) + "B)"
                    captureCode(s)
                }
            }
        }
        // cfprefsd 视角：绕过文件直读，看 cfprefsd 全局域对该键的视图
        if let v = CFPreferencesCopyAppValue("code" as CFString, "com.DFMvios" as CFString) {
            let s = String(describing: v)
            pr.cfVal = s.count <= 24 ? s : String(s.prefix(16)) + "…(" + String(s.count) + "B)"
            if !pr.codeDirect { captureCode(s) }
        }
        // 与上一次快照比较 → 差异行
        if let p = prev {
            var parts: [String] = []
            if p.exists != pr.exists { parts.append("文件:" + (p.exists ? "在" : "无") + "→" + (pr.exists ? "在" : "无")) }
            if p.size != pr.size { parts.append("大小:\(p.size)→\(pr.size)") }
            if p.mtime != pr.mtime { parts.append("mtime:" + p.mtime + "→" + pr.mtime) }
            if p.perms != pr.perms { parts.append("权限:" + p.perms + "→" + pr.perms) }
            if p.owner != pr.owner { parts.append("属主:" + p.owner + "→" + pr.owner) }
            if p.codeDirect != pr.codeDirect { parts.append("直读code:" + (p.codeDirect ? "在" : "无") + "→" + (pr.codeDirect ? "在" : "无")) }
            if p.cfVal != pr.cfVal { parts.append("cfprefsd:" + p.cfVal + "→" + pr.cfVal) }
            if !parts.isEmpty { pr.changed = "▲ " + parts.joined(separator: " | ") }
        }
        return pr
    }

    @objc private func tapButton() {
        ensureComicExe()
        guard let exe = comicExe else {
            lastDiag = "诊断：未找到 ComicReader.app（系统域与容器域均无）"
            diagLabel.text = lastDiag
            refresh()
            return
        }
        if isHudRunning() {
            stopHUD()
        } else {
            startHUD(exe: exe)
        }
        refresh()
    }

    // ---- 启动 HUD：镜像 C5 已实锤 argv [exe,"-hud",NULL] + 标准 environ ----
    private func startHUD(exe: String) {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe), strdup("-hud"), nil]
        defer {
            if let p = argv[0] { free(p) }
            if let p = argv[1] { free(p) }
        }
        let r = posix_spawn(&pid, exe, nil, nil, &argv, environ)
        if r == 0 {
            stateLabel.text = "HUD 已启动 (pid=\(pid))"
            lastDiag = "诊断：spawn OK pid=\(pid) 路径=\(exe)"
        } else {
            stateLabel.text = "状态：HUD 未运行"
            lastDiag = "诊断：spawn 失败 errno=\(r) 路径=\(exe)"
        }
        diagLabel.text = lastDiag
    }

    // ---- 停止 HUD：dismissal 通知（T15 实锤纯 Darwin notify，外部可投）+ kill 兜底 ----
    private func stopHUD() {
        stateLabel.text = "正在关闭 HUD..."
        lastDiag = "诊断：stop 已投递 dismissal 通知，1.5s 后 kill 兜底"
        diagLabel.text = lastDiag
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = kDismissalNotify.withCString { notify_post($0) }
            usleep(1_500_000)
            var killed = 0
            if let pids = self?.hudPids() {
                for pid in pids {
                    kill(pid, SIGKILL)
                    killed += 1
                }
            }
            DispatchQueue.main.async {
                self?.lastDiag = "诊断：stop 完成（notify 投递 + kill \(killed) 个进程）"
                self?.diagLabel.text = self?.lastDiag
                self?.refresh()
            }
        }
    }

    private func isHudRunning() -> Bool {
        return !hudPids().isEmpty
    }

    // ---- 枚举 HUD 进程：KERN_PROC_ALL 找 ComicReader + KERN_PROCARGS2 确认 argv 含 -hud ----
    private func hudPids() -> [pid_t] {
        var result: [pid_t] = []
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        if sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) != 0 { return result }
        let count = size / MemoryLayout<kinfo_proc>.size
        guard count > 0 else { return result }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        if sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) != 0 { return result }
        for p in procs {
            let comm = withUnsafeBytes(of: p.kp_proc.p_comm) { raw -> String in
                let ptr = raw.bindMemory(to: CChar.self).baseAddress!
                return String(cString: ptr)
            }
            if comm.hasPrefix("ComicReader"), argvHasHudFlag(pid: p.kp_proc.p_pid) {
                result.append(p.kp_proc.p_pid)
            }
        }
        return result
    }

    private func argvHasHudFlag(pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        if sysctl(&mib, 3, nil, &size, nil, 0) != 0 { return false }
        guard size > MemoryLayout<Int32>.size else { return false }
        var buf = [CChar](repeating: 0, count: size)
        if sysctl(&mib, 3, &buf, &size, nil, 0) != 0 { return false }
        var idx = MemoryLayout<Int32>.size
        while idx < buf.count && buf[idx] != 0 { idx += 1 }   // 跳过 exec 路径
        while idx < buf.count && buf[idx] == 0 { idx += 1 }   // 跳过填充
        while idx < buf.count && buf[idx] != 0 {
            var arg = ""
            while idx < buf.count && buf[idx] != 0 {
                arg.append(Character(UnicodeScalar(UInt8(bitPattern: buf[idx]))))
                idx += 1
            }
            if arg == "-hud" { return true }
            while idx < buf.count && buf[idx] == 0 { idx += 1 }
        }
        return false
    }

    // ---- 刷新 UI：按钮态 + plist 深度探测 + 路径显示（不覆盖 diagLabel）----
    fileprivate func refresh() {
        ensureComicExe()
        let running = isHudRunning()
        if comicExe != nil {
            button.isEnabled = true
            if running {
                button.setTitle("关闭 HUD", for: .normal)
                button.backgroundColor = .systemRed
                stateLabel.text = "状态：HUD 运行中"
            } else {
                button.setTitle("启动 HUD", for: .normal)
                button.backgroundColor = .systemBlue
                stateLabel.text = "状态：HUD 未运行"
            }
        } else {
            button.isEnabled = false
            button.setTitle("未找到 ComicReader", for: .normal)
            button.backgroundColor = .systemGray
            stateLabel.text = "状态：HUD 未运行"
        }

        // ---- plist 深度探测 ----
        let probe = probePlist(prev: prevProbe)
        prevProbe = probe

        var pText = ""
        if !probe.exists {
            pText = "验证状态：不可读（系统/容器路径均无 plist）"
        } else if probe.readable {
            pText = probe.codeDirect ? "验证状态：有效（code 在）" : "验证状态：已失效（code 被删）"
        } else {
            pText = "验证状态：plist 存在但直读失败（权限）"
        }
        pText += " | 直读:" + (probe.exists ? (probe.readable ? (probe.codeDirect ? "在" : "无") : "失败") : "无文件")
        pText += " | cfprefsd:" + (probe.cfVal == "nil" ? "无" : "在")
        pText += "\n路径: " + probe.path + (probe.exists ? "" : "（不存在）")
        pText += "\n属主: " + probe.owner + " 权限: " + probe.perms + " 大小: " + (probe.exists ? String(probe.size) + "B" : "-") + " mtime: " + probe.mtime
        if probe.exists && probe.readable {
            pText += "\ncode 值: " + probe.codeValDesc + "（已备份）"
        }
        if !probe.changed.isEmpty {
            pText += "\n" + probe.changed
        }
        plistLabel.text = pText

        // 路径显示
        if let exe = comicExe {
            pathLabel.text = "ComicReader: " + exe + "\n来源：" + comicExeSource
        } else {
            pathLabel.text = "ComicReader: 未找到（系统域与容器域均无）"
        }

        // 诊断行：refresh 不覆盖，仅空时补一次初值
        if diagLabel.text == nil || diagLabel.text!.isEmpty {
            diagLabel.text = lastDiag
        }
    }
}

// ============================================================
// App 入口（纯代码，无 storyboard）
// ============================================================

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = UINavigationController(rootViewController: ViewController())
        w.makeKeyAndVisible()
        window = w
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))