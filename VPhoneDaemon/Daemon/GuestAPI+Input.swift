import CoreFoundation
import Foundation
import IcliKit

// MARK: - Buttons, Text, Gestures

extension GuestAPI {
    /// Runs the input and hands it to the harvest recorder: a host that records
    /// a session wants the full sequence, and the screen after the gesture that
    /// ended it. The recorder decides which inputs end a gesture; keys and text
    /// are logged and only restart its silence window.
    static func executeInput(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        guard let result = try performInput(method, params) else { return nil }
        reportInput(method, params)
        return result
    }

    /// The one recorder call every input entry point uses. `GuestAPI.execute`
    /// serves the digitizer paths itself, so those cases call this too; no path
    /// logs twice because each method has exactly one handler. The
    /// `{"t":"tap"}`/`{"t":"swipe"}` socket shorthands are translated to these
    /// method names before they reach vphoned, so the log names the method that
    /// ran. With no harvest running the call is a gate check and returns
    /// without touching a queue.
    static func reportInput(_ method: String, _ params: [String: Any]) {
        GuestHarvestRecorder.guest.noteInput(method, params)
    }

    /// Gesture coordinates are screen points, as `device.screen` reports them.
    private static func performInput(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "input.button":
            return try pressButton(string(params, "name"))
        case "input.key":
            return try pressKey(string(params, "name"))
        case "input.type":
            return try typeText(string(params, "text"), delayMS: number(params, "delay_ms", default: 30))
        case "input.paste":
            return try pasteText(string(params, "text"))
        case "input.tap":
            return try tap(x: requiredNumber(params, "x"), y: requiredNumber(params, "y"))
        case "input.double_tap":
            return try doubleTap(
                x: requiredNumber(params, "x"),
                y: requiredNumber(params, "y"),
                interval: number(params, "interval", default: 0.1),
            )
        case "input.long_press":
            return try longPress(
                x: requiredNumber(params, "x"),
                y: requiredNumber(params, "y"),
                seconds: number(params, "seconds", default: 1),
            )
        case "input.swipe":
            return try swipe(
                x1: requiredNumber(params, "x1"),
                y1: requiredNumber(params, "y1"),
                x2: requiredNumber(params, "x2"),
                y2: requiredNumber(params, "y2"),
                seconds: number(params, "seconds", default: 0.3),
                steps: (params["steps"] as? NSNumber)?.intValue ?? 20,
            )
        case "input.drag":
            guard let rows = params["points"] as? [[NSNumber]], rows.count >= 2,
                  rows.allSatisfy({ $0.count == 2 })
            else {
                throw GuestAPIError.invalidRequest("points must be at least two [x, y] pairs")
            }
            return try drag(
                points: rows.map { ($0[0].doubleValue, $0[1].doubleValue) },
                seconds: number(params, "seconds", default: 0.5),
                hold: number(params, "hold", default: 0.5),
                steps: (params["steps"] as? NSNumber)?.intValue ?? 20,
            )
        case "input.touch_sequence":
            guard let events = params["events"] as? [[String: Any]] else {
                throw GuestAPIError.invalidRequest("events must be an array of {phase, x, y, delay_ms}")
            }
            let json = try String(decoding: JSONSerialization.data(withJSONObject: events), as: UTF8.self)
            return try touchSequence(
                TouchEvent.list(fromJSON: json),
                normalized: bool(params, "normalized", default: true),
            )
        default:
            return nil
        }
    }

    // MARK: - Accessibility and OCR

    static func executeInterface(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        interfaceLock.lock()
        defer { interfaceLock.unlock() }
        switch method {
        case "ui.tree", "accessibility.tree":
            if let value = params["nested"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw GuestAPIError.invalidRequest("nested must be a boolean")
                }
            }
            if bool(params, "nested") {
                return try nestedHierarchy(params)
            }
            return try uiElements(
                maxElements: (params["max_elements"] as? NSNumber)?.intValue ?? 500,
                visibleOnly: bool(params, "visible_only", default: true),
                clickableOnly: bool(params, "clickable_only"),
                limit: (params["limit"] as? NSNumber)?.intValue,
            )
        case "ui.element_at":
            return try elementAt(x: requiredNumber(params, "x"), y: requiredNumber(params, "y"))
        case "ui.tap_element":
            return try tapElement(selector(params))
        case "ui.wait", "ui.wait_gone":
            return try waitForElement(
                selector(params),
                appear: method == "ui.wait",
                timeout: number(params, "timeout", default: 10),
            )
        case "ui.ocr":
            try requireTextRecognition()
            return try recognizeScreen(
                languages: params["languages"] as? [String] ?? ["en-US"],
                minConfidence: Float(number(params, "min_confidence", default: 0.3)),
            )
        case "ui.describe":
            try requireTextRecognition()
            return try describeScreen()
        default:
            return nil
        }
    }

    /// IcliKit's OCR is Vision's, which watchOS does not ship: vphoned links
    /// it weakly, so its classes are nil on a watch.
    private static func requireTextRecognition() throws {
        guard NSClassFromString("VNRecognizeTextRequest") != nil else {
            throw GuestAPIError.operationFailed("Text recognition needs Vision, which this guest does not have")
        }
    }

    private static func selector(_ params: [String: Any]) throws -> ElementSelector {
        try ElementSelector(
            text: optionalString(params, "text"),
            identifier: optionalString(params, "identifier"),
            role: optionalString(params, "role"),
            match: optionalString(params, "match") ?? "contains",
            index: (params["index"] as? NSNumber)?.intValue ?? 0,
        )
    }
}
