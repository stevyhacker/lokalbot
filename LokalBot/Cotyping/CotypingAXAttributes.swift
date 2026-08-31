import ApplicationServices
import Foundation

extension CotypingAXHelper {
    // MARK: - Attribute readers

    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func copyOpaqueAttribute(_ attribute: CFString, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    static func copyOpaqueParameterized(
        _ attribute: CFString,
        parameter: CFTypeRef,
        on element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value) == .success else {
            return nil
        }
        return value
    }

    static func attributeNames(on element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let names else {
            return []
        }
        return names as? [String] ?? []
    }

    static func parameterizedAttributeNames(on element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success,
              let names else {
            return []
        }
        return names as? [String] ?? []
    }

    static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    static func stringArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [String] {
        copyAttribute(element, attribute) as? [String] ?? []
    }

    static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copyAttribute(element, attribute) as? Bool
    }

    static func intAttribute(_ element: AXUIElement, _ attribute: String) -> Int? {
        if let value = copyAttribute(element, attribute) as? Int {
            return value
        }
        return (copyAttribute(element, attribute) as? NSNumber)?.intValue
    }

    static func childElements(of element: AXUIElement) -> [AXUIElement] {
        guard let values = copyAttribute(element, kAXChildrenAttribute as String) as? [AnyObject] else {
            return []
        }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    static func isCommandVMenuItem(_ item: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(item, 0.05)
        guard let cmdChar = stringAttribute(item, kAXMenuItemCmdCharAttribute as String),
              cmdChar.uppercased() == "V",
              let modifiers = intAttribute(item, kAXMenuItemCmdModifiersAttribute as String) else {
            return false
        }
        return modifiers == 0
    }

    static func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    /// The caret/selection as an NSRange (UTF-16). `length == 0` is a caret.
    static func selectionRange(_ element: AXUIElement) -> NSRange? {
        rangeAttribute(element, kAXSelectedTextRangeAttribute as String)
    }

    static func rangeAttribute(_ element: AXUIElement, _ attribute: String) -> NSRange? {
        guard let raw = copyAttribute(element, attribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
