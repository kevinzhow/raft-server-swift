import Crypto
import Foundation

public struct MobileAppEmailUnsubscribe: Sendable {
    let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) { self.directory = directory }

    static func isMobileUnsubscribeUserId(_ value: String) -> Bool {
        value.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.ignoresCase()) != nil
    }

    static func mobileAppUnsubscribeLocale(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if value == "zh-cn" || value == "zh" || value == "zh-hans" || value == "zh-hans-cn" { return "zh-cn" }
        if value == "en" || value.hasPrefix("en-") { return "en" }
        return "en"
    }

    static func mobileAppUnsubscribeSignature(payload: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let message = Data("mobile-app-email-unsubscribe:v1:\(payload)".utf8)
        return AuthTokenCodec.base64url(Data(HMAC<SHA256>.authenticationCode(for: message, using: key)))
    }

    static func mobileAppUnsubscribeCopy(_ locale: String) -> (htmlLang: String, confirmationTitle: String, confirmationHeading: String, confirmationBody: String, submit: String, successTitle: String, successHeading: String, successBody: String, invalidTitle: String, invalidHeading: String, invalidBody: String) {
        if locale == "zh-cn" {
            return (
                "zh-CN",
                "退订 Raft 移动端应用邮件",
                "要退订移动端应用邮件吗？",
                "Raft 将不再向你发送关于移动端应用的邮件。",
                "退订",
                "已退订",
                "你已退订。",
                "Raft 不会再向你发送移动端应用邮件。",
                "退订链接无效",
                "这个退订链接无效。",
                "请使用 Raft 原始邮件中的链接。"
            )
        }
        return (
            "en",
            "Unsubscribe from Raft mobile-app emails",
            "Unsubscribe from mobile-app emails?",
            "Raft will stop sending you emails about the mobile app.",
            "Unsubscribe",
            "Unsubscribed",
            "You are unsubscribed.",
            "Raft will no longer send you mobile-app emails.",
            "Invalid unsubscribe link",
            "This unsubscribe link is invalid.",
            "Please use the link from the original Raft email."
        )
    }

    static func mobileAppUnsubscribeInvalid() -> MobileAppEmailUnsubscribeOutcome {
        let copy = MobileAppEmailUnsubscribe.mobileAppUnsubscribeCopy("en")
        let body = "<h1 style=\"margin:0 0 12px;font-size:22px;\">\(copy.invalidHeading)</h1><p style=\"margin:0;line-height:1.5;\">\(copy.invalidBody)</p>"
        return .invalidLink(html: MobileAppEmailUnsubscribe.mobileAppUnsubscribeHTML(lang: copy.htmlLang, title: copy.invalidTitle, body: body))
    }

    static func mobileAppUnsubscribeHTML(lang: String, title: String, body: String) -> String {
        let page = """
        <!doctype html>
        <html lang="\(lang)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(title)</title>
        </head>
        <body style="margin:0;padding:40px 20px;background:#fffaf0;color:#141111;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
          <main style="box-sizing:border-box;max-width:520px;margin:0 auto;padding:28px;background:#fff;border:2px solid #141111;border-radius:16px;box-shadow:4px 4px 0 #141111;">
            \(body)
          </main>
        </body>
        </html>
        """
        return page
    }

    func verifyMobileAppEmailUnsubscribeToken(_ token: String) -> (userId: String, locale: String)? {
        guard !token.isEmpty, token.count <= 512 else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let expected = MobileAppEmailUnsubscribe.mobileAppUnsubscribeSignature(payload: parts[0], secret: directory.mobileAppEmailUnsubscribeSecret)
        guard parts[1] == expected else { return nil }
        guard let data = AuthTokenCodec.base64urlDecode(parts[0]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.sorted().joined(separator: ",") == "locale,sub,typ,v"
        else { return nil }
        let version = (object["v"] as? NSNumber)?.intValue ?? (object["v"] as? Int)
        guard version == 1,
              (object["typ"] as? String) == "mobile-app-email-unsubscribe",
              let userId = object["sub"] as? String,
              MobileAppEmailUnsubscribe.isMobileUnsubscribeUserId(userId),
              let locale = object["locale"] as? String,
              locale == "en" || locale == "zh-cn"
        else { return nil }
        return (userId, locale)
    }

    public func mobileAppEmailUnsubscribePage(token: String?) -> MobileAppEmailUnsubscribeOutcome {
        guard let token, let identity = verifyMobileAppEmailUnsubscribeToken(token) else {
            return MobileAppEmailUnsubscribe.mobileAppUnsubscribeInvalid()
        }
        let copy = MobileAppEmailUnsubscribe.mobileAppUnsubscribeCopy(identity.locale)
        let action = "/api/email/mobile-app/unsubscribe?token=\(FormPayload.urlQuery(token))&source=visible"
        let body = "<h1 style=\"margin:0 0 12px;font-size:22px;\">\(copy.confirmationHeading)</h1><p style=\"margin:0 0 20px;line-height:1.5;\">\(copy.confirmationBody)</p><form method=\"post\" action=\"\(action)\"><input type=\"hidden\" name=\"List-Unsubscribe\" value=\"One-Click\"><button type=\"submit\" style=\"cursor:pointer;padding:10px 16px;border:2px solid #141111;border-radius:8px;background:#fe7da8;color:#141111;font:inherit;font-weight:700;box-shadow:2px 2px 0 #141111;\">\(copy.submit)</button></form>"
        return .confirmation(html: MobileAppEmailUnsubscribe.mobileAppUnsubscribeHTML(lang: copy.htmlLang, title: copy.confirmationTitle, body: body))
    }

    public func mobileAppEmailUnsubscribeSubmit(token: String?, source: String?, body: String) -> MobileAppEmailUnsubscribeOutcome {
        guard let token, let identity = verifyMobileAppEmailUnsubscribeToken(token),
              FormPayload.formField(body, "List-Unsubscribe") == "One-Click"
        else { return MobileAppEmailUnsubscribe.mobileAppUnsubscribeInvalid() }
        recordMobileAppEmailOptOut(userId: identity.userId)
        let copy = MobileAppEmailUnsubscribe.mobileAppUnsubscribeCopy(identity.locale)
        if source == "visible" {
            let page = "<h1 style=\"margin:0 0 12px;font-size:22px;\">\(copy.successHeading)</h1><p style=\"margin:0;line-height:1.5;\">\(copy.successBody)</p>"
            return .unsubscribed(html: MobileAppEmailUnsubscribe.mobileAppUnsubscribeHTML(lang: copy.htmlLang, title: copy.successTitle, body: page))
        }
        return .oneClick
    }

    func recordMobileAppEmailOptOut(userId: String) {
        directory.lock.lock()
        guard let account = directory.accounts.values.first(where: { $0.id == userId }) else {
            directory.lock.unlock()
            return
        }
        let email = AccountNaming.normalize(account.email)
        guard !email.isEmpty else {
            directory.lock.unlock()
            return
        }
        let audienceId = "mobile-app-lifecycle"
        directory.mobileAppEmailContactsByKey["\(audienceId)\n\(email)"] = MobileAppEmailContact(
            userId: userId,
            email: email,
            audienceId: audienceId,
            status: "unsubscribed",
            optedOutAt: Date()
        )
        let emailIds = directory.storedMobileAppEmailJourneys.compactMap { row -> String? in
            guard row.journeyKey == "first_computer_mobile_app_48h",
                  row.day1Status == "scheduled",
                  let emailId = row.day1EmailId,
                  !emailId.isEmpty,
                  row.userId == userId || AccountNaming.normalize(row.email) == email
            else { return nil }
            return emailId
        }
        let cancel = directory.cancelMobileAppEmail
        directory.lock.unlock()
        for emailId in emailIds {
            cancel?(emailId)
        }
        guard !emailIds.isEmpty else { return }
        directory.lock.lock()
        let canceledAt = Date()
        for index in directory.storedMobileAppEmailJourneys.indices {
            let row = directory.storedMobileAppEmailJourneys[index]
            guard row.journeyKey == "first_computer_mobile_app_48h",
                  row.day1Status == "scheduled",
                  let emailId = row.day1EmailId,
                  emailIds.contains(emailId),
                  row.userId == userId || AccountNaming.normalize(row.email) == email
            else { continue }
            directory.storedMobileAppEmailJourneys[index].day1Status = "skipped"
            directory.storedMobileAppEmailJourneys[index].suppressedReason = "unsubscribed"
            directory.storedMobileAppEmailJourneys[index].canceledAt = canceledAt
        }
        directory.lock.unlock()
    }
}
