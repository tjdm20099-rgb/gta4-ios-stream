import UIKit
import Darwin

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        signal(SIGPIPE, SIG_IGN)
        application.isIdleTimerDisabled = true
        LocalGameServer.shared.start()

        let win = UIWindow(frame: UIScreen.main.bounds)
        win.backgroundColor = .black
        win.rootViewController = StreamViewController()
        win.makeKeyAndVisible()
        self.window = win
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return .landscape
    }
}
