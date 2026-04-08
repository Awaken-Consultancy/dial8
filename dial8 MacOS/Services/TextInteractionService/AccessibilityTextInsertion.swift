import Foundation
import AppKit
import ApplicationServices  // Add this for AX constants
import os

/// Responsible for inserting text via accessibility APIs
class AccessibilityTextInsertion {
    
    private let logger = Logger(subsystem: "com.dial8", category: "AccessibilityTextInsertion")
    
    private let directTextInsertion: DirectTextInsertion
    private let clipboardTextInsertion: ClipboardTextInsertion
    
    init(directTextInsertion: DirectTextInsertion, clipboardTextInsertion: ClipboardTextInsertion) {
        self.directTextInsertion = directTextInsertion
        self.clipboardTextInsertion = clipboardTextInsertion
    }
    
    // Add a property to track applications known to block accessibility
    private let knownRestrictedApps = ["Cursor", "CursorEditor", "Mail"]
    
    /// Prints debugging information about the focused element
    /// - Returns: Whether debugging info was successfully retrieved and printed
    func printFocusedElementDebugInfo() -> Bool {
        // First, check if the app has accessibility permissions
        guard checkAccessibilityPermissions() else {
            logger.warning("Cannot debug - missing accessibility permissions")
            return false
        }
        
        // Create a system-wide AX element
        let systemElement = AXUIElementCreateSystemWide()
        
        // Get the focused application
        var appElement: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(systemElement, kAXFocusedApplicationAttribute as CFString, &appElement)
        
        guard appResult == .success, let appElement = appElement else {
            logger.warning("Debug: Could not get focused application (AXError = \(appResult.rawValue, privacy: .public))")
            return false
        }
        
        let appAX = appElement as! AXUIElement
        
        // Get app info
        var appPID: pid_t = 0
        AXUIElementGetPid(appAX, &appPID)
        let runningApp = NSRunningApplication(processIdentifier: appPID)
        logger.debug("Debug: Focused app: \(runningApp?.localizedName ?? "Unknown", privacy: .public) (PID: \(appPID, privacy: .public))")
        
        // Get the focused UI element of that app
        var focusedElement: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(appAX, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        guard focusedResult == .success, let focusedElement = focusedElement else {
            logger.warning("Debug: No focused UI element found (AXError = \(focusedResult.rawValue, privacy: .public))")
            return false
        }
        
        let focusedAX = focusedElement as! AXUIElement
        
        // Get all attributes of the focused element
        var attributeNames: CFArray?
        let attrResult = AXUIElementCopyAttributeNames(focusedAX, &attributeNames)
        
        if attrResult == .success, let attributeNames = attributeNames as? [String] {
            logger.debug("Debug: Focused element has \(attributeNames.count, privacy: .public) attributes:")
            for attributeName in attributeNames {
                var value: CFTypeRef?
                let valueResult = AXUIElementCopyAttributeValue(focusedAX, attributeName as CFString, &value)
                
                if valueResult == .success, let value = value {
                    let valueStr: String
                    
                    if let stringValue = value as? String {
                        valueStr = "\"\(stringValue)\""
                    } else if CFGetTypeID(value) == AXUIElementGetTypeID() {
                        valueStr = "AXUIElement"
                    } else if let arrayValue = value as? [AnyObject] {
                        valueStr = "Array with \(arrayValue.count) items"
                    } else if let numValue = value as? NSNumber {
                        valueStr = numValue.stringValue
                    } else {
                        valueStr = String(describing: value)
                    }
                    
                    logger.debug("  \(attributeName, privacy: .public): \(valueStr, privacy: .public)")
                } else {
                    logger.debug("  \(attributeName, privacy: .public): <error: \(valueResult.rawValue, privacy: .public)>")
                }
            }
            
            // Specifically check for role attribute
            var roleValue: CFTypeRef?
            let roleResult = AXUIElementCopyAttributeValue(focusedAX, kAXRoleAttribute as CFString, &roleValue)
            
            if roleResult == .success, let role = roleValue as? String {
                logger.debug("Debug: Element role is: \(role, privacy: .public)")
                
                // Check if it's a text field, text area, or text view
                let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXTextView"]
                if textRoles.contains(role) {
                    logger.info("Debug: This is a text field and should be accessible")
                } else {
                    logger.warning("Debug: This is NOT a text field. Text operations may not work.")
                }
            }
            
            return true
        } else {
            logger.warning("Debug: Could not get element attributes (AXError = \(attrResult.rawValue, privacy: .public))")
            return false
        }
    }
    
    /// Checks if the app has accessibility permissions and optionally prompts the user
    /// - Parameter shouldPrompt: Whether to show the permission dialog
    /// - Returns: Whether the app has accessibility permissions
    func checkAccessibilityPermissions(shouldPrompt: Bool = true) -> Bool {
        if !AXIsProcessTrusted() {
            logger.warning("App does not have Accessibility permissions")
            
            if shouldPrompt {
                // Prompt the user to grant accessibility permissions
                let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                AXIsProcessTrustedWithOptions(options)
                
                PermissionManager.shared.openAccessibilitySettings()
                
                logger.info("Opening System Settings to enable Accessibility permissions")
            }
            
            return false
        }
        
        return true
    }
    
    /// Gets the focused text field using the proper Accessibility API sequence
    /// - Returns: The focused UI element if it's a text field, nil otherwise
    private func getFocusedTextField() -> AXUIElement? {
        // First, check if the app has accessibility permissions
        guard checkAccessibilityPermissions() else {
            logger.warning("Please enable Accessibility permissions in System Settings > Privacy & Security > Accessibility")
            return nil
        }
        
        // Create a system-wide AX element
        let systemElement = AXUIElementCreateSystemWide()
        
        // Get the focused application
        var appElement: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(systemElement, kAXFocusedApplicationAttribute as CFString, &appElement)
        
        guard appResult == .success, let appElement = appElement else {
            // Use the raw error code values since the constants aren't found
            if appResult.rawValue == -25200 {  // kAXErrorNotTrusted = -25200
                logger.warning("App is not trusted for Accessibility. Please check System Settings > Privacy & Security > Accessibility.")
                // Try to prompt for permissions again
                _ = checkAccessibilityPermissions(shouldPrompt: true)
            } else if appResult.rawValue == -25204 {  // kAXErrorCannotComplete = -25204
                logger.warning("Cannot complete the operation. This may happen if your app is sandboxed. Remove sandbox for this feature to work.")
            } else {
                logger.warning("Could not get focused application (AXError = \(appResult.rawValue, privacy: .public))")
            }
            return nil
        }
        
        let appAX = appElement as! AXUIElement
        
        // Get the focused UI element of that app
        var focusedElement: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(appAX, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        guard focusedResult == .success, let focusedElement = focusedElement else {
            logger.warning("No focused UI element found (AXError = \(focusedResult.rawValue, privacy: .public))")
            return nil
        }
        
        let focusedAX = focusedElement as! AXUIElement
        
        // Get the role of the focused element to verify it's a text field
        var roleValue: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(focusedAX, kAXRoleAttribute as CFString, &roleValue)
        
        if roleResult == .success, let role = roleValue as? String {
            logger.debug("Focused element role: \(role, privacy: .public)")
            
            // Check if it's a text field, text area, or text view
            let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXTextView"]
            if textRoles.contains(role) {
                logger.info("Found text field with role: \(role, privacy: .public)")
                return focusedAX
            } else {
                logger.warning("Focused element is not a text field (role: \(role, privacy: .public))")
                return nil
            }
        } else {
            logger.warning("Failed to get role of focused element (AXError = \(roleResult.rawValue, privacy: .public))")
            return nil
        }
    }
    
    /// Inserts text using accessibility APIs
    /// - Parameters:
    ///   - text: The text to insert
    ///   - isTemporary: Whether this is a temporary transcription
    ///   - finalizedText: The finalized text to preserve
    ///   - streamingInsertedText: Currently streaming text being inserted
    ///   - onFinalizedTextUpdated: Callback to update finalized text
    ///   - onStreamingStateUpdated: Callback to update streaming state
    /// - Returns: Whether the insertion was successful
    func insertText(
        _ text: String,
        isTemporary: Bool = false,
        finalizedText: String,
        streamingInsertedText: String,
        onFinalizedTextUpdated: @escaping (String) -> Void,
        onStreamingStateUpdated: @escaping (Int, Int) -> Void
    ) -> Bool {
        logger.debug("Accessibility: Temporarily using clipboard paste for all text insertion until text field identification is improved")
        
        // Format text appropriately
        let formattedText = formatTextWithCapitalization(text, isTemp: isTemporary, finalizedText: finalizedText)
        
        // For non-temporary text, update the finalized text
        if !isTemporary {
            var updatedFinalizedText = finalizedText
            if finalizedText.isEmpty {
                updatedFinalizedText = formattedText
            } else {
                updatedFinalizedText += " " + formattedText
            }
            onFinalizedTextUpdated(updatedFinalizedText)
            logger.debug("Updated finalized text: \"\(updatedFinalizedText, privacy: .public)\"")
        }
        
        // Always use clipboard insertion for now
        return clipboardTextInsertion.insertText(formattedText, preserveClipboard: true)
    }
    
    /// Special handling for apps that restrict read access but allow write access
    /// - Parameters:
    ///   - text: The text to insert
    ///   - element: The accessibility element to insert text into
    ///   - isTemporary: Whether this is temporary text
    ///   - finalizedText: The finalized text to preserve
    ///   - onFinalizedTextUpdated: Callback to update finalized text
    /// - Returns: Whether the insertion was successful
    private func insertTextWithRestrictedReadAccess(
        _ text: String,
        element: AXUIElement,
        isTemporary: Bool,
        finalizedText: String,
        onFinalizedTextUpdated: @escaping (String) -> Void
    ) -> Bool {
        logger.debug("Attempting fallback for apps with restricted read access...")
        
        // Format text with appropriate capitalization
        let formattedText = formatTextWithCapitalization(text, isTemp: isTemporary, finalizedText: finalizedText)
        logger.debug("Using \(isTemporary ? "temporary" : "final", privacy: .public) text directly with capitalization: \"\(formattedText, privacy: .public)\"")
        
        // For temporary text, we usually don't update the finalized text
        if !isTemporary {
            // Update finalized text tracking
            var updatedFinalizedText = finalizedText
            if finalizedText.isEmpty {
                updatedFinalizedText = formattedText
            } else {
                updatedFinalizedText += " " + formattedText
            }
            onFinalizedTextUpdated(updatedFinalizedText)
            logger.debug("Updated finalized text: \"\(updatedFinalizedText, privacy: .public)\"")
        }
        
        // Try to directly write to the element without reading its current value
        logger.debug("Attempting to set text via accessibility API despite read error: \"\(formattedText, privacy: .public)\"")
        
        // Determine what value to set based on whether this is temporary or final text
        let valueToSet: String
        
        if !finalizedText.isEmpty && !isTemporary {
            // For final text with existing finalized text, append the new text
            // Only add a space if finalizedText doesn't end with whitespace and formattedText doesn't start with whitespace
            let needsSpace = !finalizedText.hasSuffix(" ") && !formattedText.hasPrefix(" ")
            let space = needsSpace ? " " : ""
            valueToSet = finalizedText + space + formattedText
        } else {
            // For temporary text or when there's no finalized text, just use the text directly
            valueToSet = formattedText
        }
        
        // APPROACH 1: Try using kAXValueAttribute (most common)
        let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, valueToSet as CFTypeRef)
        
        if setResult == .success {
            logger.info("Successfully wrote text despite being unable to read current value")
            return true
        } else {
            logger.warning("Failed to set text with kAXValueAttribute (Error = \(setResult.rawValue, privacy: .public))")
            
            // APPROACH 2: Try using AXSelectedTextAttribute instead
            logger.debug("Trying alternate attribute: AXSelectedText")
            let setSelectedResult = AXUIElementSetAttributeValue(element, "AXSelectedText" as CFString, valueToSet as CFTypeRef)
            
            if setSelectedResult == .success {
                logger.info("Successfully wrote text using AXSelectedText attribute")
                return true
            } else {
                logger.warning("Failed to set text with AXSelectedText (Error = \(setSelectedResult.rawValue, privacy: .public))")
                
                // APPROACH 3: Try to perform press action on the element first
                logger.debug("Trying to press element before setting text")
                AXUIElementPerformAction(element, "AXPress" as CFString)
                
                // Try once more to set the value after pressing
                let secondSetResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, valueToSet as CFTypeRef)
                
                if secondSetResult == .success {
                    logger.info("Successfully wrote text after pressing element")
                    return true
                }
                
                logger.error("Failed to write text after all attempts (Error = \(secondSetResult.rawValue, privacy: .public))")
                return false
            }
        }
    }
    
    /// Helper function to get the application element of the frontmost app
    /// - Returns: The application element, or nil if it couldn't be obtained
    private func getApplicationElement() -> AXUIElement? {
        // Create a system-wide AX element
        let systemElement = AXUIElementCreateSystemWide()
        
        // Get the focused application
        var appElement: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(systemElement, kAXFocusedApplicationAttribute as CFString, &appElement)
        
        guard appResult == .success, let appElement = appElement else {
            logger.warning("Could not get focused application (AXError = \(appResult.rawValue, privacy: .public))")
            return nil
        }
        
        return unsafeBitCast(appElement, to: AXUIElement.self)
    }
    
    /// Helper function to get an element with the AXFocused attribute set to true
    /// - Parameter element: The parent element to search in
    /// - Returns: The focused element, or nil if none was found
    private func getElementWithFocusedAttribute(_ element: AXUIElement) -> AXUIElement? {
        var focusedElement: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focusedElement)
        
        guard focusedResult == .success, let focusedElement = focusedElement else {
            return nil
        }
        
        let focusedAX = focusedElement as! AXUIElement
        
        // Verify this element is actually focused
        var isFocusedRef: CFTypeRef?
        let isFocusedResult = AXUIElementCopyAttributeValue(focusedAX, kAXFocusedAttribute as CFString, &isFocusedRef)
        
        if isFocusedResult == .success, let isFocused = isFocusedRef as? Bool, isFocused {
            logger.info("Found element with AXFocused = true")
            return focusedAX
        }
        
        return nil
    }
    
    /// Helper function to get the main window of an application
    /// - Parameter appElement: The application element
    /// - Returns: The main window element, or nil if it couldn't be obtained
    private func getMainWindow(_ appElement: AXUIElement) -> AXUIElement? {
        // Try to get the focused window first
        var windowElement: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowElement)
        
        if windowResult == .success, let windowElement = windowElement {
            return unsafeBitCast(windowElement, to: AXUIElement.self)
        }
        
        // If that fails, try to get the first window from the windows array
        var windowsRef: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        
        if windowsResult == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty {
            return windows[0]
        }
        
        return nil
    }
    
    /// Helper function to find the first text field in an element
    /// - Parameter element: The parent element to search in
    /// - Returns: The text field element, or nil if none was found
    private func findFirstTextFieldInElement(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 10) -> AXUIElement? {
        // Stop recursion if we've exceeded the maximum depth
        if depth >= maxDepth {
            logger.warning("findFirstTextFieldInElement reached max depth (\(maxDepth, privacy: .public)), stopping recursion")
            return nil
        }

        // Get the role of the element
        var roleValue: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        
        if roleResult == .success, let role = roleValue as? String {
            // Check if this element is a text field
            let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXTextView"]
            if textRoles.contains(role) {
                return element
            }
            
            // If not, check if it has the editable attribute
            var isEditableRef: CFTypeRef?
            let editableResult = AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &isEditableRef)
            
            if editableResult == .success, let isEditable = isEditableRef as? Bool, isEditable {
                return element
            }
        }
        
        // If not found, check all children
        var childrenRef: CFTypeRef?
        let childrenResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        
        if childrenResult == .success, let children = childrenRef as? [AXUIElement] {
            for child in children {
                if let textField = findFirstTextFieldInElement(child, depth: depth + 1, maxDepth: maxDepth) {
                    return textField
                }
            }
        }
        
        return nil
    }
    
    /// Helper function to format text with appropriate capitalization
    /// - Parameters:
    ///   - text: The text to format
    ///   - isTemp: Whether this is temporary text
    ///   - finalizedText: The previously finalized text to check for sentence ending
    /// - Returns: The formatted text
    private func formatTextWithCapitalization(_ text: String, isTemp: Bool, finalizedText: String = "") -> String {
        // For temporary text, we usually don't need to modify it
        if isTemp {
            return text
        }
        
        // For final text, ensure it has proper capitalization
        if text.isEmpty {
            return text
        }
        
        // First, remove any trailing spaces from finalizedText to simplify our check
        let trimmedFinalText = finalizedText.trimmingCharacters(in: .whitespaces)
        
        // Check if the last text ends with sentence-ending punctuation
        let endsWithSentencePunctuation = trimmedFinalText.hasSuffix(".") || 
                                         trimmedFinalText.hasSuffix("!") || 
                                         trimmedFinalText.hasSuffix("?")
        
        // Get the first word of the new text for better context assessment
        let firstWord = text.components(separatedBy: " ").first ?? text
        
        // Determine if we should capitalize:
        // 1. If the text is empty (start of recording)
        // 2. If the previous text ended with sentence punctuation
        let shouldCapitalize = trimmedFinalText.isEmpty || endsWithSentencePunctuation
        
        // Special case for speech recognition quirks: commonly mid-sentence capitalized words
        let commonMidSentenceWords = ["I", "I'll", "I'd", "I'm", "I've"]
        let isCommonCapitalizedWord = commonMidSentenceWords.contains(firstWord)
        
        if shouldCapitalize && !isCommonCapitalizedWord {
            let firstChar = text.prefix(1).uppercased()
            let restOfText = text.dropFirst()
            logger.debug("💬 (Accessibility) Capitalized first letter: \"\(firstChar + restOfText)\" (previous ended with sentence punctuation)")
            return firstChar + restOfText
        } else if isCommonCapitalizedWord {
            // Preserve capitalization for words like "I"
            logger.debug("💬 (Accessibility) Preserved capitalization for common word: \"\(firstWord)\"")
            return text
        } else {
            // Force lowercase for the first letter unless it's at the start of a sentence
            if !text.isEmpty && text.prefix(1).uppercased() == text.prefix(1) {
                let firstChar = text.prefix(1).lowercased()
                let restOfText = text.dropFirst()
                logger.debug("💬 (Accessibility) Forced lowercase for first letter: \"\(firstChar + restOfText)\" (previous: \"\(trimmedFinalText)\")")
                return firstChar + restOfText
            } else {
                logger.debug("💬 (Accessibility) Keeping original case: \"\(text)\" (previous: \"\(trimmedFinalText)\")")
                return text
            }
        }
    }
    
    /// Finds any editable element that can receive text input
    /// - Returns: An editable accessibility element, or nil if none found
    private func findAnyEditableElement() -> AXUIElement? {
        // Create a system-wide AX element
        let systemElement = AXUIElementCreateSystemWide()
        
        // Get the focused application
        var appElement: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(systemElement, kAXFocusedApplicationAttribute as CFString, &appElement)
        
        guard appResult == .success, let appElement = appElement else {
            logger.warning("⚠️ Could not get focused application (AXError = \(appResult.rawValue))")
            return nil
        }
        
        let appAX = appElement as! AXUIElement
        
        // Get the focused UI element of that app
        var focusedElement: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(appAX, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        guard focusedResult == .success, let focusedElement = focusedElement else {
            logger.warning("⚠️ No focused UI element found (AXError = \(focusedResult.rawValue))")
            return nil
        }
        
        let focusedAX = focusedElement as! AXUIElement
        
        // Check if the element is editable
        var isEditableRef: CFTypeRef?
        let editableResult = AXUIElementCopyAttributeValue(focusedAX, "AXEditable" as CFString, &isEditableRef)
        
        if editableResult == .success, let isEditable = isEditableRef as? Bool, isEditable {
            logger.debug("✅ Found editable element")
            return focusedAX
        }
        
        // Check for value attribute
        var valueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(focusedAX, kAXValueAttribute as CFString, &valueRef)
        
        if valueResult == .success && valueRef != nil {
            logger.debug("✅ Found element with value attribute")
            return focusedAX
        }
        
        logger.warning("⚠️ No editable element found")
        return nil
    }
    
    /// Finds a text input within a web area (for browsers)
    /// - Returns: A text input element within a web area, or nil if none found
    private func findWebTextInput() -> AXUIElement? {
        logger.debug("🔍 Looking for text input within web content...")
        
        // Create a system-wide AX element
        let systemElement = AXUIElementCreateSystemWide()
        
        // Get the focused application
        var appElement: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(systemElement, kAXFocusedApplicationAttribute as CFString, &appElement)
        
        guard appResult == .success, let appElement = appElement else {
            logger.warning("⚠️ Could not get focused application (AXError = \(appResult.rawValue))")
            return nil
        }
        
        let appAX = appElement as! AXUIElement
        
        // Get the focused UI element of that app
        var focusedElement: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(appAX, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        guard focusedResult == .success, let focusedElement = focusedElement else {
            logger.warning("⚠️ No focused UI element found (AXError = \(focusedResult.rawValue))")
            return nil
        }
        
        let focusedAX = focusedElement as! AXUIElement
        
        // Check if the element is a web area
        var roleValue: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(focusedAX, kAXRoleAttribute as CFString, &roleValue)
        
        if roleResult == .success, let role = roleValue as? String {
            logger.debug("🔍 Focused element role: \(role)")
            
            if role == "AXWebArea" {
                logger.debug("✅ Found web area")
                
                // Look for a focused node within the web area
                var focusedNodeRef: CFTypeRef?
                let focusedNodeResult = AXUIElementCopyAttributeValue(focusedAX, kAXFocusedAttribute as CFString, &focusedNodeRef)
                
                if focusedNodeResult == .success, let focusedNodeRef = focusedNodeRef {
                    let focusedNodeElement = focusedNodeRef as! AXUIElement
                    
                    // Check the role of the focused node
                    var nodeRoleValue: CFTypeRef?
                    let nodeRoleResult = AXUIElementCopyAttributeValue(focusedNodeElement, kAXRoleAttribute as CFString, &nodeRoleValue)
                    
                    if nodeRoleResult == .success, let nodeRole = nodeRoleValue as? String {
                        logger.debug("🔍 Focused node role: \(nodeRole)")
                        
                        // Check for common text input roles in web content
                        let webTextRoles: Set<String> = ["AXTextField", "AXTextArea", "AXStaticText", "AXTextFieldWithCompletion"]
                        
                        if webTextRoles.contains(nodeRole) {
                            logger.debug("✅ Found text input in web area with role: \(nodeRole)")
                            return focusedNodeElement
                        }
                        
                        // Check if the node is editable regardless of role
                        var isEditableRef: CFTypeRef?
                        let editableResult = AXUIElementCopyAttributeValue(focusedNodeElement, "AXEditable" as CFString, &isEditableRef)
                        
                        if editableResult == .success, let isEditable = isEditableRef as? Bool, isEditable {
                            logger.debug("✅ Found editable element in web area")
                            return focusedNodeElement
                        }
                        
                        // Check if element has content-editable
                        var contentEditableRef: CFTypeRef?
                        let contentEditableResult = AXUIElementCopyAttributeValue(focusedNodeElement, "AXIsContentEditable" as CFString, &contentEditableRef)
                        
                        if contentEditableResult == .success, let isContentEditable = contentEditableRef as? Bool, isContentEditable {
                            logger.debug("✅ Found content-editable element in web area")
                            return focusedNodeElement
                        }
                    }
                }
                
                // If we couldn't find a text input through the focused node,
                // try to find any text input within the web area
                return findTextInputInChildren(focusedAX, depth: 0)
            }
        }
        
        logger.warning("⚠️ No web text input found")
        return nil
    }
    
    /// Recursively searches for a text input within an element's children
    /// - Parameter element: The parent element to search
    /// - Returns: A text input element, or nil if none found
    private func findTextInputInChildren(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 10) -> AXUIElement? {
        // Stop recursion if we've exceeded the maximum depth
        if depth >= maxDepth {
            logger.warning("⚠️ findTextInputInChildren reached max depth (\(maxDepth)), stopping recursion")
            return nil
        }

        // Get all children of the element
        var childrenRef: CFTypeRef?
        let childrenResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        
        guard childrenResult == .success, let children = childrenRef as? [AXUIElement] else {
            return nil
        }
        
        // Check each child
        for child in children {
            // Check if this child is a text input
            var roleValue: CFTypeRef?
            let roleResult = AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue)
            
            if roleResult == .success, let role = roleValue as? String {
                let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXStaticText", "AXTextFieldWithCompletion"]
                
                if textRoles.contains(role) {
                    // Check if this element has focus
                    var focusedRef: CFTypeRef?
                    let focusedResult = AXUIElementCopyAttributeValue(child, kAXFocusedAttribute as CFString, &focusedRef)
                    
                    if focusedResult == .success, let isFocused = focusedRef as? Bool, isFocused {
                        logger.debug("✅ Found focused text input in children with role: \(role)")
                        return child
                    }
                }
                
                // Check if this child is editable
                var isEditableRef: CFTypeRef?
                let editableResult = AXUIElementCopyAttributeValue(child, "AXEditable" as CFString, &isEditableRef)
                
                if editableResult == .success, let isEditable = isEditableRef as? Bool, isEditable {
                    // Check if this element has focus
                    var focusedRef: CFTypeRef?
                    let focusedResult = AXUIElementCopyAttributeValue(child, kAXFocusedAttribute as CFString, &focusedRef)
                    
                    if focusedResult == .success, let isFocused = focusedRef as? Bool, isFocused {
                        logger.debug("✅ Found focused editable element in children")
                        return child
                    }
                }
                
                // Check if element has content-editable
                var contentEditableRef: CFTypeRef?
                let contentEditableResult = AXUIElementCopyAttributeValue(child, "AXIsContentEditable" as CFString, &contentEditableRef)
                
                if contentEditableResult == .success, let isContentEditable = contentEditableRef as? Bool, isContentEditable {
                    // Check if this element has focus
                    var focusedRef: CFTypeRef?
                    let focusedResult = AXUIElementCopyAttributeValue(child, kAXFocusedAttribute as CFString, &focusedRef)
                    
                    if focusedResult == .success, let isFocused = focusedRef as? Bool, isFocused {
                        logger.debug("✅ Found focused content-editable element in children")
                        return child
                    }
                }
            }
            
            // Recursively check this child's children
            if let textInput = findTextInputInChildren(child, depth: depth + 1, maxDepth: maxDepth) {
                return textInput
            }
        }
        
        return nil
    }
    
    /// Insert text into an element using the AXValue attribute
    /// - Parameters:
    ///   - text: The text to insert
    ///   - element: The accessibility element to insert text into
    ///   - isTemporary: Whether this is temporary text
    ///   - finalizedText: The finalized text to preserve
    ///   - streamingInsertedText: Currently streaming text
    ///   - onFinalizedTextUpdated: Callback to update finalized text
    ///   - onStreamingStateUpdated: Callback to update streaming state
    /// - Returns: Whether the insertion was successful
    private func insertTextUsingValueAttribute(
        _ text: String,
        element: AXUIElement,
        isTemporary: Bool,
        finalizedText: String,
        streamingInsertedText: String,
        onFinalizedTextUpdated: @escaping (String) -> Void,
        onStreamingStateUpdated: @escaping (Int, Int) -> Void
    ) -> Bool {
        // Try to get the current value
        var currentValueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValueRef)
        
        if result == .success, let currentValueRef = currentValueRef {
            if let currentText = currentValueRef as? String {
                logger.debug("🔤 Current text from accessibility API: \"\(currentText)\"")
                
                let newText: String
                var updatedFinalizedText = finalizedText
                
                if isTemporary {
                    // For temporary text, preserve finalized text
                    if !finalizedText.isEmpty && currentText.hasPrefix(finalizedText) {
                        // Append temporary text to finalized text
                        // Only add a space if finalizedText doesn't end with whitespace and text doesn't start with whitespace
                        let needsSpace = !finalizedText.isEmpty && 
                                        !finalizedText.hasSuffix(" ") && 
                                        !text.hasPrefix(" ")
                        let space = needsSpace ? " " : ""
                        newText = finalizedText + space + text
                        logger.debug("🔄 Preserved finalized text and appended temporary text")
                    } else {
                        // Just append the text
                        // Only add a space if currentText is not empty, doesn't end with whitespace,
                        // and text doesn't start with whitespace
                        let needsSpace = !currentText.isEmpty && 
                                        !currentText.hasSuffix(" ") && 
                                        !text.hasPrefix(" ")
                        let space = needsSpace ? " " : ""
                        newText = currentText + space + text
                    }
                    
                    // Store streaming position
                    onStreamingStateUpdated(currentText.count, text.count)
                } else {
                    // For final text, update finalized text tracking
                    if finalizedText.isEmpty {
                        updatedFinalizedText = text
                        onFinalizedTextUpdated(updatedFinalizedText)
                        
                        // Just append the text
                        // Only add a space if currentText is not empty, doesn't end with whitespace,
                        // and text doesn't start with whitespace
                        let needsSpace = !currentText.isEmpty && 
                                        !currentText.hasSuffix(" ") && 
                                        !text.hasPrefix(" ")
                        let space = needsSpace ? " " : ""
                        newText = currentText + space + text
                    } else {
                        // Append to existing finalized text
                        // Only add a space if finalizedText doesn't end with whitespace and text doesn't start with whitespace
                        let needsSpace = !finalizedText.hasSuffix(" ") && !text.hasPrefix(" ")
                        let space = needsSpace ? " " : ""
                        updatedFinalizedText += space + text
                        onFinalizedTextUpdated(updatedFinalizedText)
                        
                        // If we have streaming text, try to replace it
                        if !streamingInsertedText.isEmpty && currentText.contains(streamingInsertedText) {
                            newText = currentText.replacingOccurrences(of: streamingInsertedText, with: text)
                        } else {
                            // Just append with space
                            // Only add a space if currentText is not empty, doesn't end with whitespace,
                            // and text doesn't start with whitespace
                            let needsSpace = !currentText.isEmpty && 
                                            !currentText.hasSuffix(" ") && 
                                            !text.hasPrefix(" ")
                            let space = needsSpace ? " " : ""
                            newText = currentText + space + text
                        }
                    }
                    
                    logger.debug("🔄 Updated finalized text: \"\(updatedFinalizedText)\"")
                }
                
                // Set the new value on the element
                let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newText as CFTypeRef)
                
                if setResult == .success {
                    logger.debug("✅ Successfully set text via accessibility API: \"\(newText)\"")
                    return true
                } else {
                    logger.warning("⚠️ Failed to set text via accessibility API (AXError = \(setResult.rawValue))")
                }
            }
        }
        
        return false
    }
    
    /// Completes text insertion using accessibility APIs
    /// - Parameters:
    ///   - finalizedText: The finalized text to preserve
    /// - Returns: Whether the completion was successful
    func completeTextInsertion(finalizedText: String) -> Bool {
        guard let focusedElement = getFocusedTextField() else {
            logger.warning("⚠️ No text field found for accessibility completion")
            return false
        }
        
        // Try to get the current value
        var currentValueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &currentValueRef)
        
        if result == .success, let currentValueRef = currentValueRef {
            if let currentText = currentValueRef as? String {
                logger.debug("🔤 Completing text insertion with current text: \"\(currentText)\"")
                
                // Check if we need to preserve finalized text
                if !finalizedText.isEmpty && !currentText.hasPrefix(finalizedText) {
                    // Try to preserve both finalized text and current text
                    // Only add a space if finalizedText doesn't end with whitespace and currentText doesn't start with whitespace
                    let needsSpace = !finalizedText.hasSuffix(" ") && !currentText.hasPrefix(" ")
                    let space = needsSpace ? " " : ""
                    let newText = finalizedText + space + currentText
                    logger.debug("🔤 Setting text via accessibility API: \"\(newText)\"")
                    let setResult = AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, newText as CFTypeRef)
                    return setResult == .success
                }
                
                // Current text already has finalized text, no need to change
                return true
            }
        }
        
        logger.warning("⚠️ Failed to get current value from accessibility API (Error = \(result.rawValue))")
        
        // Special handling for error -25212 (some apps restrict read access but allow write)
        if result.rawValue == -25212 && !finalizedText.isEmpty {
            logger.debug("🔄 Attempting fallback for apps with restricted read access during completion...")
            
            // Try setting just the finalized text
            logger.debug("🔤 Attempting to set finalized text via accessibility API despite read error: \"\(finalizedText)\"")
            let setResult = AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, finalizedText as CFTypeRef)
            
            if setResult == .success {
                logger.debug("✅ Successfully wrote finalized text despite being unable to read current value")
                return true
            } else {
                logger.error("❌ Failed to write finalized text (Error = \(setResult.rawValue))")
            }
        }
        
        return false
    }
    
    /// Simulates typing text by sending key press events for each character
    /// - Parameters:
    ///   - text: The text to type
    /// - Returns: Whether the typing simulation was successful
    private func simulateTypingText(_ text: String) -> Bool {
        logger.debug("📋 Using clipboard insertion instead of typing simulation for text: \"\(text)\"")
        
        // Use the ClipboardTextInsertion service instead of key simulation
        return clipboardTextInsertion.insertText(text, preserveClipboard: true)
    }
    
    /// Replaces temporary text with finalized text using accessibility APIs
    /// - Parameters:
    ///   - temporaryText: The temporary text to replace
    ///   - finalText: The finalized text to insert
    ///   - finalizedText: The finalized text to preserve
    ///   - onFinalizedTextUpdated: Callback to update finalized text
    /// - Returns: Whether the replacement was successful
    func replaceTemporaryText(
        _ temporaryText: String,
        with finalText: String,
        finalizedText: String,
        onFinalizedTextUpdated: @escaping (String) -> Void
    ) -> Bool {
        logger.debug("🔤 Accessibility: Attempting to replace temporary text via accessibility API")
        
        // First check if this is a known accessibility-restricted app like Cursor
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            let appName = frontmostApp.localizedName ?? "Unknown"
            
            // Check if this is a known restricted app like Cursor
            if knownRestrictedApps.contains(where: { appName.contains($0) }) || appName == "Cursor" {
                logger.warning("⚠️ Detected Cursor or other known restricted app: \(appName) for text replacement")
                
                // For text replacement in Cursor, use clipboard
                logger.debug("📋 Using clipboard strategy for \(appName)")
                
                return useClipboardForReplacement(
                    temporaryText: temporaryText,
                    finalText: finalText,
                    finalizedText: finalizedText,
                    onFinalizedTextUpdated: onFinalizedTextUpdated
                )
            }
        }
        
        // APPROACH 0: Handle apps that block accessibility API completely
        // Try the direct NSWorkspace approach first
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            logger.debug("📱 Using frontmost app direct approach for: \(frontmostApp.localizedName ?? "Unknown")")
            let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
            
            // Try getting focused element 
            var focusedElement: CFTypeRef?
            let focusedResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
            
            if focusedResult == .success, let focusedElement = focusedElement {
                // Successfully got focused element
                let element = focusedElement as! AXUIElement
                
                // Try direct write with the final text (simplest approach)
                logger.debug("✨ Attempting direct replacement with frontmost app's focused element")
                let directSuccess = insertTextWithRestrictedReadAccess(
                    finalText,
                    element: element,
                    isTemporary: false,
                    finalizedText: finalizedText,
                    onFinalizedTextUpdated: onFinalizedTextUpdated
                )
                
                if directSuccess {
                    return true
                }
            } else if focusedResult.rawValue == -25212 {
                // If we can't access focused element due to accessibility restrictions,
                // try our special clipboard fallback
                logger.warning("⚠️ App blocks access to focused element with error -25212, trying clipboard")
                
                // For apps with error -25212, try our specialized fallback that doesn't rely on accessibility API
                let success = useClipboardForReplacement(
                    temporaryText: temporaryText,
                    finalText: finalText, 
                    finalizedText: finalizedText,
                    onFinalizedTextUpdated: onFinalizedTextUpdated
                )
                
                if success {
                    return true
                }
            }
        }
        
        // APPROACH 1: Try to get a focused text field element
        if let focusedElement = getFocusedTextField() {
            logger.debug("✅ Found standard text field for replacement")
            
            // Get the current value
            var currentValueRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &currentValueRef)
            
            if result == .success, let currentValueRef = currentValueRef, let currentText = currentValueRef as? String {
                // Construct new text by finding and replacing the temporary part
                var newText = currentText
                
                // If there's finalized text, preserve it
                if !finalizedText.isEmpty && currentText.hasPrefix(finalizedText) {
                    let finalizedIndex = finalizedText.count
                    let remainingText = String(currentText.dropFirst(finalizedIndex))
                    
                    // Check if the remaining text starts with the temporary text (with potential space)
                    if remainingText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(temporaryText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        // Replace just the temporary part, keeping the finalized part
                        // Check if finalText already has a leading space or if finalizedText has a trailing space
                        if finalText.hasPrefix(" ") || finalizedText.hasSuffix(" ") {
                            newText = finalizedText + finalText
                        } else {
                            newText = finalizedText + " " + finalText
                        }
                    } else {
                        // Just append to the finalized text
                        // Check if finalText already has a leading space or if finalizedText has a trailing space
                        if finalText.hasPrefix(" ") || finalizedText.hasSuffix(" ") {
                            newText = finalizedText + finalText
                        } else {
                            newText = finalizedText + " " + finalText
                        }
                    }
                } else if currentText.contains(temporaryText) {
                    // If we can find the temporary text exactly, replace it
                    newText = currentText.replacingOccurrences(of: temporaryText, with: finalText)
                } else {
                    // As a fallback, just append the final text
                    // Only add a space if currentText is not empty and doesn't end with whitespace
                    // and finalText doesn't start with whitespace
                    let needsSpace = !currentText.isEmpty && 
                                    !currentText.hasSuffix(" ") && 
                                    !finalText.hasPrefix(" ")
                    let space = needsSpace ? " " : ""
                    newText = currentText + space + finalText
                }
                
                // Update the value attribute with our new text
                let setResult = AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, newText as CFTypeRef)
                
                if setResult == .success {
                    logger.debug("✅ Updated text via accessibility API: \"\(newText)\"")
                    
                    // Update the finalized text
                    var updatedFinalizedText = finalizedText
                    if finalizedText.isEmpty {
                        updatedFinalizedText = finalText
                    } else {
                        updatedFinalizedText += " " + finalText
                    }
                    onFinalizedTextUpdated(updatedFinalizedText)
                    
                    return true
                } else {
                    logger.warning("⚠️ Failed to set text via accessibility API (AXError = \(setResult.rawValue))")
                }
            } else if result.rawValue == -25212 {
                // Special case for apps that restrict reading but allow writing (like Messages)
                logger.warning("⚠️ Failed to get current value from accessibility API (Error = \(result.rawValue))")
                logger.debug("🔄 Attempting fallback for apps with restricted read access...")
                
                // Directly insert the final text
                return insertTextWithRestrictedReadAccess(
                    finalText,
                    element: focusedElement,
                    isTemporary: false,
                    finalizedText: finalizedText,
                    onFinalizedTextUpdated: onFinalizedTextUpdated
                )
            }
        }
        
        // APPROACH 2: If no text field found, try to find any editable element
        if let editableElement = findAnyEditableElement() {
            logger.debug("✅ Found editable element for replacement")
            
            // Try the direct write fallback for restricted access
            logger.warning("⚠️ Trying restricted access fallback for editable element...")
            let fallbackSuccess = insertTextWithRestrictedReadAccess(
                finalText,
                element: editableElement,
                isTemporary: false,
                finalizedText: finalizedText,
                onFinalizedTextUpdated: onFinalizedTextUpdated
            )
            
            if fallbackSuccess {
                return true
            }
        }
        
        // APPROACH 3: Try to find text input within a web area
        if let webTextElement = findWebTextInput() {
            logger.debug("✅ Found web text input for replacement")
            
            // Try the direct write fallback
            logger.warning("⚠️ Trying restricted access fallback for web element...")
            let fallbackSuccess = insertTextWithRestrictedReadAccess(
                finalText,
                element: webTextElement,
                isTemporary: false,
                finalizedText: finalizedText,
                onFinalizedTextUpdated: onFinalizedTextUpdated
            )
            
            if fallbackSuccess {
                return true
            }
        }
        
        // APPROACH 4: Try with the focused attribute
        if let appElement = getApplicationElement(),
           let focusedElement = getElementWithFocusedAttribute(appElement) {
            logger.debug("✅ Found element with AXFocused attribute for replacement")
            
            // Try the direct write fallback
            logger.warning("⚠️ Trying restricted access fallback for focused element...")
            let fallbackSuccess = insertTextWithRestrictedReadAccess(
                finalText,
                element: focusedElement,
                isTemporary: false,
                finalizedText: finalizedText,
                onFinalizedTextUpdated: onFinalizedTextUpdated
            )
            
            if fallbackSuccess {
                return true
            }
        }
        
        // If all approaches fail, fall back to inserting the text as new
        logger.warning("⚠️ Could not replace temporary text, inserting as new text")
        return insertText(
            finalText,
            isTemporary: false,
            finalizedText: finalizedText,
            streamingInsertedText: "",
            onFinalizedTextUpdated: onFinalizedTextUpdated,
            onStreamingStateUpdated: { _, _ in }
        )
    }
    
    /// Specialized fallback that uses clipboard for completely restricted apps
    /// - Parameters:
    ///   - text: The text to insert
    ///   - isTemporary: Whether this is a temporary transcription
    ///   - finalizedText: The finalized text to preserve
    ///   - onFinalizedTextUpdated: Callback to update finalized text
    /// - Returns: Whether the insertion was successful
    private func useClipboardFallback(
        _ text: String,
        isTemporary: Bool,
        finalizedText: String,
        onFinalizedTextUpdated: @escaping (String) -> Void
    ) -> Bool {
        logger.debug("📋 Using clipboard fallback for completely restricted app")
        
        // Format text appropriately
        let formattedText = formatTextWithCapitalization(text, isTemp: isTemporary, finalizedText: finalizedText)
        
        // For non-temporary text, update the finalized text
        if !isTemporary {
            // Update finalized text tracking
            var updatedFinalizedText = finalizedText
            if finalizedText.isEmpty {
                updatedFinalizedText = formattedText
            } else {
                updatedFinalizedText += " " + formattedText
            }
            onFinalizedTextUpdated(updatedFinalizedText)
            logger.debug("🔄 Updated finalized text: \"\(updatedFinalizedText)\"")
        }
        
        // Use clipboard insertion to paste the text
        return clipboardTextInsertion.insertText(formattedText, preserveClipboard: true)
    }
    
    /// Special replacement strategy for applications with completely restricted accessibility
    /// This method uses clipboard to replace temporary text with final text
    /// - Parameters:
    ///   - temporaryText: The temporary text to replace
    ///   - finalText: The finalized text to insert
    ///   - finalizedText: The complete finalized text to preserve
    ///   - onFinalizedTextUpdated: Callback to update finalized text
    /// - Returns: Whether the replacement was successful
    private func useClipboardForReplacement(
        temporaryText: String,
        finalText: String,
        finalizedText: String,
        onFinalizedTextUpdated: @escaping (String) -> Void
    ) -> Bool {
        logger.debug("📋 Using clipboard for text replacement in restricted app")
        
        // Format text appropriately
        let formattedText = formatTextWithCapitalization(finalText, isTemp: false, finalizedText: finalizedText)
        
        // 1. Select the temporary text
        if temporaryText.count > 0 {
            // Often in restricted apps, we can't select text programmatically
            // Try to do a select all and replace the entire content
            if let textToInsert = constructTextWithoutTemporary(temporaryText, replacedBy: formattedText, finalizedText: finalizedText) {
                // Use clipboard operation to replace all text
                let success = clipboardTextInsertion.updateEntireText(textToInsert, preserveClipboard: true)
                
                if success {
                    // Update finalized text tracking
                    var updatedFinalizedText = finalizedText
                    if finalizedText.isEmpty {
                        updatedFinalizedText = formattedText
                    } else {
                        updatedFinalizedText += " " + formattedText
                    }
                    onFinalizedTextUpdated(updatedFinalizedText)
                    logger.debug("🔄 Updated finalized text: \"\(updatedFinalizedText)\"")
                    return true
                }
            }
        }
        
        // Fallback to just inserting the final text at current position
        return useClipboardFallback(finalText, isTemporary: false, finalizedText: finalizedText, onFinalizedTextUpdated: onFinalizedTextUpdated)
    }
    
    /// Constructs text without the temporary portion, replacing it with final text
    /// - Parameters:
    ///   - temporaryText: The temporary text to replace
    ///   - replacementText: The text to replace it with
    ///   - finalizedText: The finalized text to preserve
    /// - Returns: The constructed text, or nil if construction failed
    private func constructTextWithoutTemporary(_ temporaryText: String, replacedBy replacementText: String, finalizedText: String) -> String? {
        // For apps with restricted access, we need to construct what the text would be
        // This is a best-effort attempt without being able to read the actual text
        
        // If we have finalized text, make sure we preserve it
        if !finalizedText.isEmpty {
            // Append the final text to the finalized text
            // Only add a space if finalizedText doesn't end with whitespace and replacementText doesn't start with whitespace
            let needsSpace = !finalizedText.hasSuffix(" ") && !replacementText.hasPrefix(" ")
            let space = needsSpace ? " " : ""
            return finalizedText + space + replacementText
        } else {
            // Without finalized text, just use the replacement
            return replacementText
        }
    }
} 