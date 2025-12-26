import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Security)
import Security
#endif

#if canImport(FirebaseCore)
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
// Optional Google Sign-In (SPM: GoogleSignIn)
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

class FirebaseManager: ObservableObject {
    static let shared = FirebaseManager()

    private init() {}

    @Published var isConfigured = false

    @Published var currentUser: User?

    // Short name 'db' is common, but prefer a clearer name
    var firestore: Firestore?

    private func logAuthEvent(level: String = "DEBUG", _ message: String) {
        SyncLogService.shared.logEvent(
            tag: "auth",
            level: level,
            message: "[\(AppConstants.currentVersion)] \(message)"
        )
        SyncLogService.shared.logAuth(level: level, message: "[\(AppConstants.currentVersion)] \(message)")
    }

    private func entitlementValue(for key: String) -> Any? {
        #if canImport(Security)
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        #else
        return nil
        #endif
    }

    private func resolvedKeychainAccessGroup() -> String? {
        let entitlementKeys = ["keychain-access-groups", "com.apple.security.keychain-access-groups"]
        for key in entitlementKeys {
            if let entGroups = entitlementValue(for: key) as? [String],
               let first = entGroups.first,
               !first.isEmpty {
                return first
            }
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "?"
        if let prefix = Bundle.main.infoDictionary?["AppIdentifierPrefix"] as? String {
            return "\(prefix)\(bundleId)"
        }
        return bundleId
    }

    private func keychainAccessGroupHint() -> String {
        resolvedKeychainAccessGroup() ?? (Bundle.main.bundleIdentifier ?? "?")
    }

    private func isoTimestamp(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return ISO8601DateFormatter().string(from: date)
    }

    private func logAuthFailure(_ error: Error, context: String) {
        let nsError = error as NSError
        var parts: [String] = [
            "context=\(context)",
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "description=\(nsError.localizedDescription)"
        ]
        if let reason = nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
            parts.append("reason=\(reason)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=\(underlying.domain)#\(underlying.code) \(underlying.localizedDescription)")
        }
        if nsError.domain == AuthErrorDomain,
           AuthErrorCode.Code(rawValue: nsError.code) == .keychainError {
            parts.append("keychainGroup=\(keychainAccessGroupHint())")
            parts.append("keychainHint=Ensure a signed build with keychain entitlement; allow access if prompted")
        }
        logAuthEvent(level: "ERROR", parts.joined(separator: " | "))
    }

    #if canImport(GoogleSignIn)
    private func tokenSummary(_ token: GIDToken?, label: String) -> String {
        guard let token else { return "\(label)=missing" }
        let expires = isoTimestamp(token.expirationDate)
        return "\(label)=len:\(token.tokenString.count) exp:\(expires)"
    }
    #endif

    func configureIfNeeded() {
        guard !isConfigured else { return }
        logAuthEvent(
            level: "INFO",
            "Configuring Firebase (bundle=\(Bundle.main.bundleIdentifier ?? "?") keychainGroup=\(keychainAccessGroupHint()))"
        )
        FirebaseApp.configure()
        if let accessGroup = resolvedKeychainAccessGroup() {
            do {
                try Auth.auth().useUserAccessGroup(accessGroup)
                logAuthEvent(level: "INFO", "Using Firebase Auth keychain group \(accessGroup)")
            } catch {
                logAuthFailure(error, context: "Set Firebase Auth keychain group")
            }
        } else {
            logAuthEvent(level: "WARN", "No keychain access group found; using default keychain scope")
        }
        // Enable verbose Firebase logging so we can diagnose SDK/transport
        FirebaseConfiguration.shared.setLoggerLevel(.debug)
        firestore = Firestore.firestore()
        SyncLogService.shared.logEvent(
            tag: "firebase",
            level: "INFO",
            message: "Configured Firebase (project=\(FirebaseApp.app()?.options.projectID ?? "?") debug=ON)"
        )
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            let email = user?.email ?? "nil"
            let uid = user?.uid ?? "nil"
            let providerIds = user?.providerData.map { $0.providerID }.joined(separator: ",") ?? "none"
            self.logAuthEvent(
                level: "DEBUG",
                "Auth state changed uid=\(uid) email=\(email) isAnonymous=\(user?.isAnonymous ?? false) providers=\(providerIds)"
            )
            DispatchQueue.main.async { self.currentUser = user }
        }
        isConfigured = true
    }

    func signIn(withCustomToken token: String) async throws {
        configureIfNeeded()
        logAuthEvent(level: "DEBUG", "Attempting custom token sign-in (length=\(token.count))")
        do {
            let result = try await Auth.auth().signIn(withCustomToken: token)
            let user = result.user
            logAuthEvent(level: "INFO", "Custom token sign-in succeeded uid=\(user.uid) email=\(user.email ?? "nil")")
        } catch {
            logAuthFailure(error, context: "Custom token sign-in")
            throw error
        }
    }

    func signInAnonymously() async throws {
        configureIfNeeded()
        logAuthEvent(level: "DEBUG", "Attempting anonymous sign-in")
        do {
            let result = try await Auth.auth().signInAnonymously()
            logAuthEvent(level: "INFO", "Anonymous sign-in succeeded uid=\(result.user.uid)")
        } catch {
            logAuthFailure(error, context: "Anonymous sign-in")
            throw error
        }
    }

    func signOut() throws {
        logAuthEvent(level: "INFO", "Signing out current Firebase session")
        do {
            try Auth.auth().signOut()
            logAuthEvent(level: "INFO", "Firebase sign-out completed")
        } catch {
            logAuthFailure(error, context: "Firebase sign-out")
            throw error
        }
    }

    #if canImport(GoogleSignIn)
    @MainActor
    func signInWithGoogle(presenting window: NSWindow) async throws {
        logAuthEvent(
            level: "INFO",
            "Starting Google Sign-In (windowKey=\(window.isKeyWindow) visible=\(window.isVisible) keychainGroup=\(keychainAccessGroupHint()))"
        )
        configureIfNeeded()
        // Prefer new API; fallback to configuration if required
        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            logAuthEvent(level: "DEBUG", "Configured GoogleSignIn with clientID length=\(clientID.count)")
        } else {
            logAuthEvent(level: "WARN", "Firebase options missing clientID; Google Sign-In may fail")
        }

        if let existing = Auth.auth().currentUser {
            logAuthEvent(
                level: "DEBUG",
                "Existing Firebase user before Google flow uid=\(existing.uid) email=\(existing.email ?? "nil")"
            )
        } else {
            logAuthEvent(level: "DEBUG", "No Firebase user before Google flow")
        }

        let result: GIDSignInResult
        do {
            result = try await GIDSignIn.sharedInstance.signIn(withPresenting: window)
        } catch {
            logAuthFailure(error, context: "Google web flow")
            throw error
        }

        let googleUser = result.user
        let scopes = googleUser.grantedScopes?.joined(separator: ",") ?? "none"
        let email = googleUser.profile?.email ?? "unknown"
        let userId = googleUser.userID ?? "nil"
        let tokenDetails = "\(tokenSummary(googleUser.accessToken, label: "access")) \(tokenSummary(googleUser.idToken, label: "id"))"
        logAuthEvent(
            level: "INFO",
            "Google flow finished email=\(email) userId=\(userId) scopes=\(scopes) \(tokenDetails)"
        )

        if let serverAuthCode = result.serverAuthCode {
            logAuthEvent(level: "DEBUG", "serverAuthCode length=\(serverAuthCode.count)")
        } else {
            logAuthEvent(level: "DEBUG", "serverAuthCode missing")
        }

        guard let idToken = googleUser.idToken?.tokenString else {
            logAuthEvent(level: "ERROR", "Google returned no ID token; cannot build Firebase credential")
            let err = NSError(
                domain: "GoogleAuth",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Missing ID token"]
            )
            throw err
        }
        let accessToken = googleUser.accessToken.tokenString
        logAuthEvent(
            level: "DEBUG",
            "Preparing Firebase credential (idTokenLength=\(idToken.count) accessTokenLength=\(accessToken.count))"
        )
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        do {
            let authData = try await Auth.auth().signIn(with: credential)
            let user = authData.user
            let providers = user.providerData.map { $0.providerID }.joined(separator: ",")
            logAuthEvent(
                level: "INFO",
                "Firebase sign-in via Google succeeded uid=\(user.uid) email=\(user.email ?? "nil") providers=\(providers)"
            )
        } catch {
            logAuthFailure(error, context: "Firebase sign-in exchange")
            throw error
        }
    }

    @MainActor
    func googleSignOut() {
        logAuthEvent(level: "DEBUG", "Signing out from Google session")
        GIDSignIn.sharedInstance.signOut()
    }
    #else
    func signInWithGoogle(presenting window: NSWindow) async throws {
        // Satisfy SwiftLint async-without-await while keeping the async signature used by callers
        await Task.yield()
        let err = NSError(
            domain: "GoogleSignInMissing",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "GoogleSignIn SDK not available"]
        )
        throw err
    }
    func googleSignOut() { }
    #endif
}

#else

// Fallback stubs when Firebase SDK is not present
class FirebaseManager: ObservableObject {
    static let shared = FirebaseManager()

    private init() {}

    @Published var isConfigured = false

    @Published var currentUser: Any?

    func configureIfNeeded() { }
    func signIn(withCustomToken token: String) async throws {
        await Task.yield()
        let err = NSError(
            domain: "FirebaseMissing",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Firebase SDK not available"]
        )
        throw err
    }
    func signInAnonymously() async throws {
        await Task.yield()
        let err = NSError(
            domain: "FirebaseMissing",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Firebase SDK not available"]
        )
        throw err
    }
    func signOut() throws { }

    // Provide stubs so UI compiles even without GoogleSignIn/Firebase
    @MainActor
    func signInWithGoogle(presenting presenter: NSViewController) async throws {
        await Task.yield()
        let err = NSError(
            domain: "FirebaseMissing",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Google Sign-In not available"]
        )
        throw err
    }

    @MainActor
    func googleSignOut() { }
}

#endif
