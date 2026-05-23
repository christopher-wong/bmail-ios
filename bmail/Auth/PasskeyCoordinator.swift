import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Bridges Apple's ASAuthorizationController callback API into async/await,
/// and exposes the WebAuthn PRF extension output (iOS 18+).
@MainActor
final class PasskeyCoordinator: NSObject {
    enum Failure: Error, LocalizedError {
        case cancelled
        case prfUnavailable
        case missingPRFOutput
        case unexpectedCredentialType
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "passkey ceremony was cancelled"
            case .prfUnavailable: return "this device does not support the WebAuthn PRF extension"
            case .missingPRFOutput: return "passkey returned no PRF output"
            case .unexpectedCredentialType: return "unexpected credential type"
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    struct AssertionResult {
        let credentialID: Data
        let clientDataJSON: Data
        let authenticatorData: Data
        let signature: Data
        let prfFirst: Data
    }

    struct RegistrationResult {
        let credentialID: Data
        let clientDataJSON: Data
        let attestationObject: Data
        let prfFirst: Data?
    }

    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var controller: ASAuthorizationController?
    private let presentationAnchor = PresentationAnchor()

    // MARK: - Public flows

    func assert(rpID: String, challenge: Data, prfSalt: Data) async throws -> AssertionResult {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpID)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.userVerificationPreference = .required
        request.prf = .inputValues(.saltInput1(prfSalt))

        let auth = try await perform(request: request)
        guard let cred = auth.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw Failure.unexpectedCredentialType
        }
        guard let key = cred.prf?.first else { throw Failure.missingPRFOutput }
        let prfData = key.withUnsafeBytes { Data($0) }
        return AssertionResult(
            credentialID: cred.credentialID,
            clientDataJSON: cred.rawClientDataJSON,
            authenticatorData: cred.rawAuthenticatorData,
            signature: cred.signature,
            prfFirst: prfData
        )
    }

    func register(
        rpID: String,
        rpName: String,
        userID: Data,
        userName: String,
        userDisplayName: String,
        challenge: Data,
        prfSalt: Data,
        excludeCredentialIDs: [Data] = []
    ) async throws -> RegistrationResult {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpID)
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge, name: userName, userID: userID
        )
        request.displayName = userDisplayName
        request.userVerificationPreference = .required
        request.prf = .inputValues(.saltInput1(prfSalt))
        if !excludeCredentialIDs.isEmpty {
            request.excludedCredentials = excludeCredentialIDs.map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
            }
        }

        let auth = try await perform(request: request)
        guard let cred = auth.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw Failure.unexpectedCredentialType
        }
        let prfData = cred.prf?.first.map { $0.withUnsafeBytes { Data($0) } }
        return RegistrationResult(
            credentialID: cred.credentialID,
            clientDataJSON: cred.rawClientDataJSON,
            attestationObject: cred.rawAttestationObject ?? Data(),
            prfFirst: prfData
        )
    }

    // MARK: - ASAuthorizationController bridge

    private func perform(request: ASAuthorizationRequest) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ASAuthorization, Error>) in
            self.continuation = cont
            let ctrl = ASAuthorizationController(authorizationRequests: [request])
            ctrl.delegate = self
            ctrl.presentationContextProvider = presentationAnchor
            self.controller = ctrl
            ctrl.performRequests()
        }
    }
}

extension PasskeyCoordinator: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            self.continuation?.resume(returning: authorization)
            self.continuation = nil
            self.controller = nil
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            let mapped: Error
            if let e = error as? ASAuthorizationError, e.code == .canceled {
                mapped = Failure.cancelled
            } else {
                mapped = Failure.underlying(error)
            }
            self.continuation?.resume(throwing: mapped)
            self.continuation = nil
            self.controller = nil
        }
    }
}

private final class PresentationAnchor: NSObject, ASAuthorizationControllerPresentationContextProviding {
    @MainActor
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let win = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return win }
        // No key window yet — pick any window scene and make a transient anchor.
        // In practice this never fires (the system shows the sheet on top of
        // whatever window owns the active scene by the time this is called).
        return UIWindow(windowScene: scenes.first ?? UIApplication.shared.connectedScenes.first as! UIWindowScene)
    }
}
