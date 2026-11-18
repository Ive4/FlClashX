import Cocoa
import FlutterMacOS
import window
import LaunchAtLogin

class MainFlutterWindow: NSWindow {
    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: true)
        
        FlutterMethodChannel(
            name: "launch_at_startup", binaryMessenger: flutterViewController.engine.binaryMessenger
        )
        .setMethodCallHandler { (_ call: FlutterMethodCall, result: @escaping FlutterResult) in
            switch call.method {
            case "launchAtStartupIsEnabled":
                result(LaunchAtLogin.isEnabled)
            case "launchAtStartupSetEnabled":
                if let arguments = call.arguments as? [String: Any] {
                    LaunchAtLogin.isEnabled = arguments["setEnabledValue"] as! Bool
                }
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        FlutterMethodChannel(
            name: "com.follow.clash/app", binaryMessenger: flutterViewController.engine.binaryMessenger
        )
        .setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
            guard call.method == "getApplicationIcon" else {
                result(FlutterMethodNotImplemented)
                return
            }
            guard let path = call.arguments as? String, path.hasPrefix("/"),
                  (path as NSString).pathExtension.lowercased() == "app" else {
                result(nil)
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let png = autoreleasepool { () -> Data? in
                    guard FileManager.default.fileExists(atPath: path) else { return nil }
                    let icon = NSWorkspace.shared.icon(forFile: path)
                    var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
                    guard let cgImage = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                    else { return nil }
                    return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
                }
                DispatchQueue.main.async {
                    result(png.map { FlutterStandardTypedData(bytes: $0) })
                }
            }
        }
        
        RegisterGeneratedPlugins(registry: flutterViewController)
        super.awakeFromNib()
    }
    override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        hiddenWindowAtLaunch()
    }
}
