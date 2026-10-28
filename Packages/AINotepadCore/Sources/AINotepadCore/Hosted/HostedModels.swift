import Foundation

/// `POST /v1/auth/apple`, `/v1/auth/email/verify` ve `/v1/auth/refresh` yanıtı.
public struct HostedSessionResponse: Decodable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let tokenType: String
    /// Erişim jetonunun ömrü (saniye).
    public let expiresIn: Int
    public let userId: String
}

/// Anahtar Zinciri'nde saklanan oturum.
public struct HostedTokens: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    /// Erişim jetonunun bittiği an (yanıtın alındığı andan `expiresIn` sonra).
    public let accessExpiresAt: Date
    public let userId: String

    public init(accessToken: String, refreshToken: String, accessExpiresAt: Date, userId: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessExpiresAt = accessExpiresAt
        self.userId = userId
    }
}

/// Oturum yanıtından saklanacak jetonlar. Saf fonksiyondur.
public func hostedTokens(response: HostedSessionResponse, receivedAt: Date) -> HostedTokens {
    HostedTokens(
        accessToken: response.accessToken, refreshToken: response.refreshToken,
        accessExpiresAt: receivedAt.addingTimeInterval(Double(response.expiresIn)), userId: response.userId
    )
}

/// Kullanıcının planı.
public enum HostedPlan: String, Decodable, Sendable, Equatable {
    case trial
    case subscription
}

/// Aboneliğin erişim durumu: ödenmiş dönem, ödeme gecikmesinde ek süre ya da erişim yok.
public enum HostedSubscriptionAccess: String, Decodable, Sendable, Equatable {
    case active
    case grace
    case none
}

/// Stripe aboneliğinin özeti (webhook'tan yazılır).
public struct HostedSubscription: Decodable, Sendable, Equatable {
    /// Stripe durumu (`active`, `past_due`, `canceled`…).
    public let status: String
    public let currentPeriodEnd: Date
    public let access: HostedSubscriptionAccess
    /// Ek sürenin bittiği an; ek süre yoksa nil.
    public let graceEndsAt: Date?
}

/// `GET /v1/me` yanıtı: plan, deneme hakkı, aylık kullanım ve abonelik.
public struct HostedEntitlements: Decodable, Sendable, Equatable {
    public let userId: String
    public let plan: HostedPlan
    public let trialMeetingsTotal: Int
    /// Etkin kalan deneme (hesap ve doğrulanmış cihazın küçüğü).
    public let trialMeetingsLeft: Int
    public let accountTrialMeetingsLeft: Int
    public let deviceTrialMeetingsLeft: Int?
    public let monthlyHoursUsed: Double
    public let monthlyHoursCap: Double
    public let subscription: HostedSubscription?
}

/// `POST /v1/meetings/start` yanıtı.
public struct HostedStartedMeeting: Decodable, Sendable, Equatable {
    public let meetingId: String
    /// `trial` ya da `subscription`.
    public let kind: String
    public let tokenBudget: Int
    public let maxDurationMinutes: Int
    public let expiresAt: Date
    /// Deneme toplantısında kalan deneme; abonelikte nil.
    public let trialMeetingsLeft: Int?
}

/// `POST /v1/meetings/{id}/end` yanıtı.
public struct HostedEndedMeeting: Decodable, Sendable, Equatable {
    public let meetingId: String
    public let minutes: Int?
    public let tokensUsed: Int
    public let audioSeconds: Double
}

/// Ödeme ve portal uçlarının yanıtı.
struct HostedURLResponse: Decodable {
    let url: URL
}

/// `POST /v1/device/challenge` yanıtı.
public struct HostedDeviceChallenge: Decodable, Sendable, Equatable {
    public let challenge: String
    public let expiresInSeconds: Int
}

/// `POST /v1/meetings/start` ile gönderilen App Attest onayı (alanlar base64).
public struct HostedDeviceAssertion: Encodable, Sendable, Equatable {
    public let keyId: String
    public let assertion: String
    /// `{"action":"meetings.start","challenge":…}` JSON'unun base64'ü.
    public let clientData: String

    public init(keyId: String, assertion: String, clientData: String) {
        self.keyId = keyId
        self.assertion = assertion
        self.clientData = clientData
    }
}

/// Sunucu yanıtlarının çözücüsü: tarihler kesirli saniyeli ISO 8601 (`toISOString`).
func hostedJSONDecoder() -> JSONDecoder {
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { (decoder: any Decoder) throws -> Date in
        let container: any SingleValueDecodingContainer = try decoder.singleValueContainer()
        let text: String = try container.decode(String.self)
        do {
            return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
        } catch {
            return try Date.ISO8601FormatStyle().parse(text)
        }
    }
    return decoder
}

/// Hesabın arayüzde gösterilen durumu.
public enum HostedPlanStatus: Sendable, Equatable {
    /// Deneme: kalan ve toplam ücretsiz toplantı.
    case trial(left: Int, total: Int)
    /// Abonelik etkin; dönem sonu.
    case subscribed(renewsAt: Date)
    /// Ödeme gecikti; erişim ek süre boyunca sürer.
    case grace(endsAt: Date)
}

/// Hak yanıtından arayüz durumu: erişimi olan abonelik önce gelir, yoksa deneme. Saf fonksiyondur.
public func hostedPlanStatus(entitlements: HostedEntitlements) -> HostedPlanStatus {
    if let subscription = entitlements.subscription {
        switch subscription.access {
        case .active:
            return .subscribed(renewsAt: subscription.currentPeriodEnd)
        case .grace:
            return .grace(endsAt: subscription.graceEndsAt ?? subscription.currentPeriodEnd)
        case .none:
            break
        }
    }
    return .trial(left: entitlements.trialMeetingsLeft, total: entitlements.trialMeetingsTotal)
}
