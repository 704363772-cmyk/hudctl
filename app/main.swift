import UIKit
import Darwin

// ============================================================
// HUDControl JB 直连版 v3（许可证自愈）- 单按钮 toggle（启动 HUD ⇄ 关闭 HUD）
// 越狱 no-sandbox 环境：所有动作直连，无 daemon 依赖
//   start: posix_spawn(<自动探测的 ComicReader 路径>, ["-hud"], environ)  // 镜像 C5 argv
//   stop : notify_post("com.test.notification.hud.dismissal") + kill(pid, SIGKILL) 兜底
//   状态 : sysctl KERN_PROC_ALL + KERN_PROCARGS2 匹配 argv 含 "-hud" 的 ComicReader 进程
//   验证 : plist 深度探测（系统路径 → 容器路径自动探测）
//
// v2（诊断）: errno 持久行 / 二进制路径自动探测 / plist 容器扫描
// v2.1（plist 深度探测）: uid/mode/size/mtime / 直读+cfprefsd 双通道 / ▲差异行 / code 自动备份
// v3（许可证自愈，2026-08-15）:
//   背景: T13 实锤 LIC_B(0x100036d70) 用 dictionaryWithContentsOfFile 直读文件 +
//         objectForKey:@"code"（键存在即放行）; FUNC_B(0x10003dd54) 删 code 键 +
//         writeToFile:atomically: 直写。@x 实测"过期后第一次能起、后续失效" =
//         code 键被 FUNC_B 删除。T13 三态模拟: plist=nil → 清零写; code 在 → 启用路径。
//   方案（零补丁，不动 ComicReader）: 自愈回填 code 键 —— 与 FUNC_A 自家写码同机制
//         (dictionaryWithContentsOfFile + setObject + writeToFile:atomically:)：
//   1. 捕获 code 值双备份: UserDefaults(类型保真) + /var/mobile/hudctl_state.txt(人类可读)
//   2. code 缺失（含文件不存在）→ 自动回填（备份值优先，无备份用合成值 "hudctl-refill"）;
//      节流 10s 防与后台重验 FUNC_B 对刷; 写后重读确认
//   3. spawn 前强制回填一次（对抗删除竞态）再 posix_spawn
//   4. 写回前查文件可写性，失败把 errno 显示在诊断行
// ============================================================

let kComicExePrimary = "/Applications/ComicReader.app/ComicReader"
let kContainerBundleRoots = ["/var/containers/Bundle/Application", "/var/mobile/Applications"]
let kContainerDataRoots = ["/var/mobile/Containers/Data/Application", "/var/mobile/Applications"]
let kPrefsPlistPrimary = "/var/mobile/Library/Preferences/com.DFMvios.plist"
let kDismissalNotify = "com.test.notification.hud.dismissal"
let kCodeBackupFile = "/var/mobile/hudctl_state.txt"
let kHealSyntheticCode = "hudctl-refill"
let kLastCodeKey = "hudctl_last_code"
let kRefillThrottle: TimeInterval = 10.0

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

    // v3 自愈状态
    private var lastRefill: Date?
    private var healLast = "自愈：--"

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
        hintLabel.text = "越狱直连版 v3（许可证自愈）\nstart: posix_spawn -hud | stop: dismissal 通知 + kill 兜底\ncode 缺失自动回填（备份值/合成值），spawn 前强制回填；2 秒自动刷新"
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
        diagLabel.frame  = CGRect(x: 32, y: 380, width: w - 64, height: 62)
        pathLabel.frame  = CGRect(x: 32, y: 446, width: w - 64, height: 52)
        hintLabel.frame  = CGRect(x: 32, y: 502, width: w - 64, height: 110)
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

    // ---- 抓到 code 值自动备份（去重追加，人类可读）----
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

    private func fileOwner(_ p: String) -> String {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
           let uid = attrs[.ownerAccountID] as? NSNumber {
            return "uid=" + uid.stringValue
        }
        return "?"
    }

    // ---- v3 许可证自愈：回填 code 键 ----
    // T13 实锤：LIC_B 用 dictionaryWithContentsOfFile 直读文件 + objectForKey:@"code"，
    // 键存在即放行（@x 实测过期旧值也能过门，值不校验）；FUNC_B 删键 + writeToFile 直写。
    // 因此回填 = 与 FUNC_A 同机制的写文件即可，cfprefsd 不在关键链路上（不依赖它）。
    @discardableResult
    private func refillCode(force: Bool) -> Bool {
        if !force, let lr = lastRefill, Date().timeIntervalSince(lr) < kRefillThrottle {
            return false   // 节流中：防与后台重验 FUNC_B 对刷
        }
        let (pPath, pExists) = resolvePlist()
        // 写回前查可写性（FileHandle 打开失败 = 权限问题，errno 可见）
        if pExists {
            let fh = FileHandle(forWritingAtPath: pPath)
            if fh == nil {
                healLast = "自愈：写失败（无法打开 errno=\(errno)，属主=\(fileOwner(pPath))）"
                lastRefill = Date()
                return false
            }
            try? fh?.close()
        }
        // 取值优先级：UserDefaults 备份（类型保真）→ txt 备份 → 合成值
        var val: Any = kHealSyntheticCode
        var valSrc = "合成值"
        if let saved = UserDefaults.standard.object(forKey: kLastCodeKey) {
            val = saved
            valSrc = "备份值"
        } else if let txt = try? String(contentsOfFile: kCodeBackupFile, encoding: .utf8) {
            let first = txt.components(separatedBy: .newlines).first { !$0.isEmpty }
            if let v = first?.components(separatedBy: "  captured=").first, !v.isEmpty {
                val = v
                valSrc = "txt备份"
            }
        }
        // 与 FUNC_A/FUNC_B 同机制：dictionaryWithContentsOfFile + setObject + writeToFile:atomically:
        let dict = (pExists ? NSMutableDictionary(contentsOfFile: pPath) : nil) ?? NSMutableDictionary()
        dict.setObject(val, forKey: "code" as NSString)
        let ok = dict.write(toFile: pPath, atomically: true)
        lastRefill = Date()
        if ok {
            // 写后重读确认
            if let rd = NSDictionary(contentsOfFile: pPath), rd.object(forKey: "code") != nil {
                healLast = "自愈：已回填 code（\(valSrc)，写后重读确认 ✓）"
                return true
            }
            healLast = "自愈：已写入但重读无 code（可能被对刷）"
            return false
        }
        healLast = "自愈：writeToFile 失败 errno=\(errno)（属主=\(fileOwner(pPath))）"
        return false
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
                    // v3：类型保真备份（UserDefaults），供自愈回填
                    UserDefaults.standard.set(v, forKey: kLastCodeKey)
                    UserDefaults.standard.synchronize()
                    healLast = "自愈：已捕获 code（len=\(s.count)，类型 \(String(describing: type(of: v as Any)))）"
                }
            }
        }
        // cfprefsd 视角：绕过文件直读，看 cfprefsd 全局域对该键的视图
        if let v = CFPreferencesCopyAppValue("code" as CFString, "com.DFMvios" as CFString) {
            let s = String(describing: v)
            pr.cfVal = s.count <= 24 ? s : String(s.prefix(16)) + "…(" + String(s.count) + "B)"
            if !pr.codeDirect {
                captureCode(s)
                UserDefaults.standard.set(s, forKey: kLastCodeKey)
                UserDefaults.standard.synchronize()
            }
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
        // v3：spawn 前强制回填一次（对抗 FUNC_B 删除竞态）
        let healed = refillCode(force: true)
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe), strdup("-hud"), nil]
        defer {
            if let p = argv[0] { free(p) }
            if let p = argv[1] { free(p) }
        }
        let r = posix_spawn(&pid, exe, nil, nil, &argv, environ)
        if r == 0 {
            stateLabel.text = "HUD 已启动 (pid=\(pid))"
            lastDiag = "诊断：spawn OK pid=\(pid) 路径=\(exe) | " + (healed ? "回填✓" : healLast)
        } else {
            stateLabel.text = "状态：HUD 未运行"
            lastDiag = "诊断：spawn 失败 errno=\(r) 路径=\(exe) | " + healLast
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

    // ---- 刷新 UI：按钮态 + plist 深度探测 + 路径显示 + 自愈（不覆盖 diagLabel）----
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

        // ---- v3 自愈：code 缺失（含文件不存在）→ 节流自动回填 ----
        if !probe.codeDirect {
            _ = refillCode(force: false)
        }

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
        // v3：自愈状态行
        pText += "\n" + healLast
        if !probe.codeDirect, let lr = lastRefill, Date().timeIntervalSince(lr) < kRefillThrottle {
            pText += "（10s 节流中）"
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