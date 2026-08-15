import UIKit
import Darwin

// ============================================================
// HUDControl JB 直连版 - 单按钮 toggle（启动 HUD ⇄ 关闭 HUD）
// 越狱 no-sandbox 环境：所有动作直连，无 daemon 依赖
//   start: posix_spawn("/Applications/ComicReader.app/ComicReader", ["-hud"], environ)  // 镜像 C5 argv
//   stop : notify_post("com.test.notification.hud.dismissal") + kill(pid, SIGKILL) 兜底
//   状态 : sysctl KERN_PROC_ALL + KERN_PROCARGS2 匹配 argv 含 "-hud" 的 ComicReader 进程
//   验证 : 直读 /var/mobile/Library/Preferences/com.DFMvios.plist 的 code 键
// ============================================================

let kComicExe = "/Applications/ComicReader.app/ComicReader"
let kDismissalNotify = "com.test.notification.hud.dismissal"
let kPrefsPlist = "/var/mobile/Library/Preferences/com.DFMvios.plist"

// notify.h 的 notify_post 在 iOS SDK 的 Swift 模块中未导出（macOS 上可过、iOS 目标报错），
// 用 @_silgen_name 直接绑定 libsystem_notify 符号，T15 实锤 C1 发布侧用的就是原生 notify_post。
@_silgen_name("notify_post")
private func notify_post(_ name: UnsafePointer<CChar>) -> UInt32

final class ViewController: UIViewController {

    private let button = UIButton(type: .system)
    private let stateLabel = UILabel()
    private let plistLabel = UILabel()
    private let hintLabel = UILabel()
    private var timer: Timer?

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

        plistLabel.font = .systemFont(ofSize: 14)
        plistLabel.textAlignment = .center
        plistLabel.numberOfLines = 2
        view.addSubview(plistLabel)

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.text = "越狱直连版（no-sandbox）\nstart: posix_spawn -hud | stop: dismissal 通知 + kill 兜底\n2 秒自动刷新真实状态"
        view.addSubview(hintLabel)

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width
        button.frame     = CGRect(x: 32, y: 180, width: w - 64, height: 130)
        stateLabel.frame = CGRect(x: 32, y: 332, width: w - 64, height: 24)
        plistLabel.frame = CGRect(x: 32, y: 364, width: w - 64, height: 44)
        hintLabel.frame  = CGRect(x: 32, y: 420, width: w - 64, height: 80)
    }

    @objc private func tapButton() {
        if isHudRunning() {
            stopHUD()
        } else {
            startHUD()
        }
        refresh()
    }

    // ---- 启动 HUD：镜像 C5 已实锤 argv [exe,"-hud",NULL] + 标准 environ ----
    private func startHUD() {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(kComicExe), strdup("-hud"), nil]
        defer {
            if let p = argv[0] { free(p) }
            if let p = argv[1] { free(p) }
        }
        let r = posix_spawn(&pid, kComicExe, nil, nil, &argv, environ)
        if r == 0 {
            stateLabel.text = "HUD 已启动 (pid=\(pid))"
        } else {
            stateLabel.text = "spawn 失败 errno=\(r)"
        }
    }

    // ---- 停止 HUD：dismissal 通知（T15 实锤纯 Darwin notify，外部可投）+ kill 兜底 ----
    private func stopHUD() {
        stateLabel.text = "正在关闭 HUD..."
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = kDismissalNotify.withCString { notify_post($0) }
            usleep(1_500_000)
            if let pids = self?.hudPids() {
                for pid in pids {
                    kill(pid, SIGKILL)
                }
            }
            DispatchQueue.main.async { self?.refresh() }
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

    // ---- 刷新 UI：按钮态 + plist 验证状态 ----
    fileprivate func refresh() {
        let running = isHudRunning()
        if running {
            button.setTitle("关闭 HUD", for: .normal)
            button.backgroundColor = .systemRed
            stateLabel.text = "状态：HUD 运行中"
        } else {
            button.setTitle("启动 HUD", for: .normal)
            button.backgroundColor = .systemBlue
            stateLabel.text = "状态：HUD 未运行"
        }
        if let d = NSDictionary(contentsOfFile: kPrefsPlist) {
            if d.object(forKey: "code") != nil {
                plistLabel.text = "验证状态：有效（code 在）"
            } else {
                plistLabel.text = "验证状态：已失效（code 被删）"
            }
        } else {
            plistLabel.text = "验证状态：plist 不可读"
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