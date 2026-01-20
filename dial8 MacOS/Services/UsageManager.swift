/// UsageManager tracks user word usage locally.
///
/// This singleton service provides local usage tracking functionality:
///
/// Core Features:
/// - Weekly word usage tracking
/// - Unlimited usage (no limits)
/// - Automatic weekly usage reset
///
/// Implementation Details:
/// - Local storage using UserDefaults
/// - Maintains usage across app restarts
///
/// Usage:
/// ```swift
/// let manager = UsageManager.shared
///
/// // Add words to usage count
/// manager.addWords(100)
///
/// // Check current usage
/// let currentUsage = manager.currentWeekUsage
/// ```

import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dial8", category: "UsageManager")

class UsageManager: ObservableObject {
    static let shared = UsageManager()

    @Published var currentWeekUsage: Int = 0
    @Published var weeklyLimit: Int = Int.max  // Unlimited
    @Published var accountType: String = "pro"  // Always pro (unlimited)

    private let defaults = UserDefaults.standard
    private let weeklyUsageKey = "weeklyWordUsage"
    private let lastResetDateKey = "lastUsageResetDate"

    init() {
        currentWeekUsage = defaults.integer(forKey: weeklyUsageKey)
        checkAndResetWeeklyUsage()
    }

    @MainActor
    func addWords(_ count: Int) {
        let previousUsage = currentWeekUsage

        currentWeekUsage += count
        defaults.set(currentWeekUsage, forKey: weeklyUsageKey)
        defaults.set(Date(), forKey: lastResetDateKey)

        logger.debug("Word count update: \(previousUsage) + \(count) = \(self.currentWeekUsage)")
    }

    private func checkAndResetWeeklyUsage() {
        guard let lastResetDate = defaults.object(forKey: lastResetDateKey) as? Date else {
            resetUsage()
            return
        }

        let calendar = Calendar.current
        let currentWeek = calendar.component(.weekOfYear, from: Date())
        let lastWeek = calendar.component(.weekOfYear, from: lastResetDate)

        if currentWeek != lastWeek {
            resetUsage()
        }
    }

    private func resetUsage() {
        currentWeekUsage = 0
        defaults.set(currentWeekUsage, forKey: weeklyUsageKey)
        defaults.set(Date(), forKey: lastResetDateKey)
    }
}
