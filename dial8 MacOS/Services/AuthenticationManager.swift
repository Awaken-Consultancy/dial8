import Foundation
import SwiftUI
import os

/// Manages user authentication state (simplified - no backend auth required)
@MainActor
class AuthenticationManager: NSObject, ObservableObject {
    static let shared = AuthenticationManager()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.dial8", category: "AuthenticationManager")

    @Published var currentUser: UserProfile?
    @Published var isAuthenticated = true  // Always authenticated
    @Published var accountStatus: AccountStatus?

    @AppStorage("isFirstTimeUser") var isFirstTimeUser = true

    override init() {
        super.init()
        // Set default account status (unlimited pro)
        self.accountStatus = AccountStatus(
            type: "pro",
            subscription_status: "active",
            current_usage: 0,
            limit: nil,
            period_start: nil,
            period_end: nil,
            last_sync: nil
        )
        logger.info("AuthenticationManager initialized (account feature disabled)")
    }

    // MARK: - Computed Properties

    var isSubscriptionActive: Bool {
        return true  // Always active
    }

    var remainingUsage: Int {
        return Int.max  // Unlimited
    }

    var usagePercentage: Double {
        return 0  // No limit
    }
}

// MARK: - Models (kept for compatibility)

struct TokenResponse: Codable {
    let access_token: String
    let refresh_token: String
    let token_type: String
    let expires_in: Int
    let refresh_token_expires_in: Int
    let user_id: Int
    let account_status: AccountStatus?
}

struct UserProfile: Codable {
    let id: Int
    let email: String
    let username: String
    let provider: String
    let provider_id: String
    let created_at: String
    let last_login: String?
    let preferences: String?
}

struct AccountStatus: Codable {
    let type: String
    let subscription_status: String
    let current_usage: Int
    let limit: Int?
    let period_start: String?
    let period_end: String?
    let last_sync: String?
}
