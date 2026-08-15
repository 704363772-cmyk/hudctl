import UIKit
import Darwin

// ============================================================
// HUDControl - 单按钮 toggle app（启动 HUD ⇄ 关闭 HUD）
// 通道：Darwin 通知直连 hudctl daemon（沙箱 app 可 notify_post）
// ============================================================

let NOTIFY_START = "com.ctf.hudctl.start"
let NOTIFY_STOP  = "com.ctf.hudctl.stop"
let NOTIFY_QUERY = "com.ctf.hudctl.query"
let NOTIFY_STATE = "com.ctf.hudctl.state"

// 全局状态（notify C 回调不能捕获上下文，用全局变量桥接）
var g_stateToken: Int32 = 0
weak var g_current: ViewController?

final class ViewController: UIViewController {

    private let button = UIButton(type: .system)
    private let stateLabel = UILabel()
    private let hintLabel = UILabel()
    private(set) var running = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        g_current = self

        // --- 主按钮（toggle）---
        button.titleLabel?.font = .systemFont(ofSize: 28, weight: .bold)
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 18
        button.layer.masksToBounds = true
        button.addTarget(self, action: #selector(tapButton), for: .touchUpInside)
        view.addSubview(button)

        // --- 状态标签 ---
        stateLabel.font = .systemFont(ofSize: 16, weight: .medium)
        stateLabel.textAlignment = .center
        view.addSubview(stateLabel)

        // --- 提示 ---
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.text = "通过 Darwin 通知触发 hudctl daemon\n无需打开 ComicReader\n（需已安装 com.ctf.hudctl daemon）"
        view.addSubview(hintLabel)

        // --- 监听 daemon 状态回读 ---
        notify_register_dispatch(NOTIFY_STATE, &g_stateToken, DispatchQueue.main) { _ in
            var s: UInt64 = 0
            notify_get_state(g_stateToken, &s)
            g_current?.running = (s != 0)
            g_current?.refresh()
        }

        // 启动时主动查询一次（daemon 回 state）
        notify_post(NOTIFY_QUERY)
        refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width
        button.frame  = CGRect(x: 32, y: 200, width: w - 64, height: 130)
        stateLabel.frame = CGRect(x: 32, y: 352, width: w - 64, height: 24)
        hintLabel.frame  = CGRect(x: 32, y: 392, width: w - 64, height: 80)
    }

    @objc private func tapButton() {
        if running {
            notify_post(NOTIFY_STOP)   // -> daemon: dismissal 广播 + kill 兜底
            running = false            // 乐观更新，state 通知回来再校正
        } else {
            notify_post(NOTIFY_START)  // -> daemon: asuser 501 spawn -hud
            running = true
        }
        refresh()
    }

    fileprivate func refresh() {
        if running {
            button.setTitle("关闭 HUD", for: .normal)
            button.backgroundColor = .systemRed
            stateLabel.text = "状态：HUD 运行中"
        } else {
            button.setTitle("启动 HUD", for: .normal)
            button.backgroundColor = .systemBlue
            stateLabel.text = "状态：HUD 未运行"
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
