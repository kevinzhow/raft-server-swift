import Foundation

/// Domain failure for the native notification routes. Every case is one
/// published refusal; the default `{"error": …, "code": …}` body is the
/// published order.
public enum NativeNotificationsError: DomainError, Equatable {
    /// The kill switch is off.
    case notFound
    case sessionFamilyRequired
    case authRequired
    case invalidEnrollmentRequest
    case desktopAttestationRequired
    case invalidEnrollmentExchange
    case enrollmentExchangeDenied
    case deviceNotFound
    case credentialInvalid
    case credentialProofInvalid
    case replayCursorUnavailable
    case replayWindowExceeded

    public var status: UInt {
        switch self {
        case .notFound, .deviceNotFound: 404
        case .sessionFamilyRequired, .authRequired, .credentialInvalid: 401
        case .invalidEnrollmentRequest, .invalidEnrollmentExchange: 400
        case .desktopAttestationRequired, .enrollmentExchangeDenied, .credentialProofInvalid: 403
        case .replayCursorUnavailable, .replayWindowExceeded: 409
        }
    }

    public var errorMessage: String {
        switch self {
        case .notFound: "Not found"
        case .sessionFamilyRequired: "A live normal session family is required"
        case .authRequired: "Unauthorized"
        case .invalidEnrollmentRequest, .invalidEnrollmentExchange: "Invalid enrollment exchange"
        case .desktopAttestationRequired: "Desktop application attestation is required"
        case .enrollmentExchangeDenied: "Enrollment exchange denied"
        case .deviceNotFound: "Notification device not found"
        case .credentialInvalid: "Invalid native notification credential"
        case .credentialProofInvalid: "Invalid native notification credential proof"
        case .replayCursorUnavailable: "Replay cursor is unavailable"
        case .replayWindowExceeded: "Replay window exceeded"
        }
    }

    public var errorCode: String? {
        switch self {
        case .notFound: "not_found"
        case .sessionFamilyRequired: "session_family_required"
        case .authRequired: "auth_required"
        case .invalidEnrollmentRequest: "invalid_enrollment_request"
        case .desktopAttestationRequired: "desktop_attestation_required"
        case .invalidEnrollmentExchange: "invalid_enrollment_exchange"
        case .enrollmentExchangeDenied: "enrollment_exchange_denied"
        case .deviceNotFound: "notification_device_not_found"
        case .credentialInvalid: "native_credential_invalid"
        case .credentialProofInvalid: "native_credential_proof_invalid"
        case .replayCursorUnavailable: "replay_cursor_unavailable"
        case .replayWindowExceeded: "replay_window_exceeded"
        }
    }
}
