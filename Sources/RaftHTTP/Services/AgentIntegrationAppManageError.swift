import Foundation

/// Domain failures of the agent integration-app management routes.
///
/// The four routes publish three different authority sentences (manage, logo,
/// rotate, transfer), each with the same `APP_MANAGE_AUTHORITY_REQUIRED` code,
/// and the state machine refusals of the manage action.
public enum AgentIntegrationAppManageError: DomainError, Equatable {
    case clientKeyRequired
    case clientKeyAndTargetRequired
    case integrationAppNotFound
    case manageAuthorityRequired(message: String)
    case noLogoFile
    case descriptionRequired
    case publishNotRequestable
    case unpublishNotPublished
    case shareLinkNotCreatable
    case shareLinkNotFound
    case deletePublished
    case targetAgentNotFound

    public var status: UInt {
        switch self {
        case .clientKeyRequired, .clientKeyAndTargetRequired, .noLogoFile, .descriptionRequired:
            400
        case .integrationAppNotFound, .targetAgentNotFound, .shareLinkNotFound:
            404
        case .manageAuthorityRequired:
            403
        case .publishNotRequestable, .unpublishNotPublished, .shareLinkNotCreatable, .deletePublished:
            409
        }
    }

    public var errorMessage: String {
        switch self {
        case .clientKeyRequired:
            "clientKey is required"
        case .clientKeyAndTargetRequired:
            "clientKey and targetAgent are required"
        case .integrationAppNotFound:
            "Integration app not found"
        case .manageAuthorityRequired(let message):
            message
        case .noLogoFile:
            "No logo file provided"
        case .descriptionRequired:
            "description is required before requesting marketplace review"
        case .publishNotRequestable:
            "Integration app cannot request Marketplace review in its current state"
        case .unpublishNotPublished:
            "Integration app is not currently published"
        case .shareLinkNotCreatable:
            "Integration app cannot create a private share link in its current state"
        case .shareLinkNotFound:
            "Integration app share link not found"
        case .deletePublished:
            "Published integration apps must request Marketplace removal before deletion"
        case .targetAgentNotFound:
            "Target agent not found"
        }
    }

    public var errorCode: String? {
        switch self {
        case .manageAuthorityRequired:
            "APP_MANAGE_AUTHORITY_REQUIRED"
        case .clientKeyRequired, .clientKeyAndTargetRequired, .integrationAppNotFound, .noLogoFile,
             .descriptionRequired, .publishNotRequestable, .unpublishNotPublished,
             .shareLinkNotCreatable, .shareLinkNotFound, .deletePublished, .targetAgentNotFound:
            nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .manageAuthorityRequired(let message):
            .object([
                OrderedJSONField("error", message),
                OrderedJSONField("errorCode", "APP_MANAGE_AUTHORITY_REQUIRED"),
            ])
        case .clientKeyRequired, .clientKeyAndTargetRequired, .integrationAppNotFound, .noLogoFile,
             .descriptionRequired, .publishNotRequestable, .unpublishNotPublished,
             .shareLinkNotCreatable, .shareLinkNotFound, .deletePublished, .targetAgentNotFound:
            nil
        }
    }
}
