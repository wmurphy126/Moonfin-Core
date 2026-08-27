import Flutter
import GameController
import UIKit

@MainActor
final class AppleTvSystemChannel: NSObject, UITextFieldDelegate {
    private let channel: FlutterMethodChannel
    private weak var gamepadHost: GCEventViewController?
    private let textField = UITextField(frame: .zero)
    private var textInputActive = false

    init(messenger: FlutterBinaryMessenger, gamepadHost: GCEventViewController) {
        channel = FlutterMethodChannel(
            name: "moonfin/appletv_system", binaryMessenger: messenger)
        self.gamepadHost = gamepadHost
        super.init()
        textField.delegate = self
        textField.returnKeyType = .done
        textField.enablesReturnKeyAutomatically = false
        gamepadHost.view.addSubview(textField)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setIdleTimerDisabled":
            let disabled = (call.arguments as? Bool) ?? false
            UIApplication.shared.isIdleTimerDisabled = disabled
            result(nil)
        case "setGamepadNavigationEnabled":
            gamepadHost?.controllerUserInteractionEnabled = (call.arguments as? Bool) ?? false
            result(nil)
        case "showTextInput":
            guard let arguments = call.arguments as? [String: Any] else {
                result(false)
                return
            }
            textField.text = arguments["text"] as? String ?? ""
            textField.placeholder = arguments["hint"] as? String
            textField.isSecureTextEntry = arguments["obscureText"] as? Bool ?? false
            textField.keyboardType = keyboardType(for: arguments["purpose"] as? String)
            textInputActive = true
            let shown = textField.becomeFirstResponder()
            if !shown {
                textInputActive = false
            }
            result(shown)
        case "hideTextInput":
            textInputActive = false
            textField.resignFirstResponder()
            result(nil)
        case "exitApp":
            result(nil)
            exit(0)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func keyboardType(for purpose: String?) -> UIKeyboardType {
        switch purpose {
        case "url":
            return .URL
        case "email":
            return .emailAddress
        case "numeric":
            return .numberPad
        default:
            return .default
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        guard textInputActive else { return }
        textInputActive = false
        channel.invokeMethod("systemTextInputSubmitted", arguments: textField.text ?? "")
    }
}
