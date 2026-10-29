import Foundation

/// `POST /v1/auth/apple`, `/v1/auth/google` ve `/v1/auth/refresh` yanıtı.
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
    /// İptal edilmiş aboneliğin biteceği an (yenilenmez); yenilenecekse nil.
    public let cancelAt: Date?
    public let access: HostedSubscriptionAccess
    /// Ek sürenin bittiği an; ek süre yoksa nil.
    public let graceEndsAt: Date?
}

/// `GET /v1/me` yanıtı: plan, deneme hakkı, aylık kullanım ve abonelik.
public struct HostedEntitlements: Decodable, Sendable, Equatable {
    public let userId: String
    public let plan: HostedPlan
    public let trialMeetingsTotal: Int
    /// Denemenin süresi (gün; ilk deneme toplantısından başlar); alanı bilmeyen eski sunucuda nil.
    public let trialDays: Int?
    /// Etkin kalan deneme (hesap ve doğrulanmış cihazın küçüğü).
    public let trialMeetingsLeft: Int
    public let accountTrialMeetingsLeft: Int
    public let deviceTrialMeetingsLeft: Int?
    /// Deneme süresinin bittiği an (ilk deneme toplantısı + deneme günleri); deneme başlamadıysa, abonelikte ya da
    /// alanı bilmeyen eski sunucuda nil.
    public let trialEndsAt: Date?
    public let monthlyHoursUsed: Double
    public let monthlyHoursCap: Double
    public let subscription: HostedSubscription?
    /// Yeni toplantının canlı metin motoru (`deepgram` ya da `whisperkit`); bkz. `hostedLiveEngine(entitlements:)`.
    /// Alanı bilmeyen eski sunucuda nil.
    public let liveEngine: String?
    /// Toplantı dışı yapay zekâ hakkı (Sor, not düzenleme…): dönemde sayılan token, sınır, dönem (`month` abonede,
    /// `day` denemede) ve sıfırlanma anı. Alanları bilmeyen eski sunucuda nil (kullanım göstergesi gizlenir).
    public let accountTokensUsed: Int?
    public let accountTokensCap: Int?
    public let accountTokensPeriod: String?
    public let accountTokensResetsAt: Date?
    /// Aylık sınırların sıfırlandığı an (sonraki UTC ayının başı); eski sunucuda nil.
    public let monthlyResetsAt: Date?
    /// Şimdi açılacak toplantının en çok süresi ve ses hakkı (dakika; abonede aylık kalanla sınırlı); eski sunucuda nil.
    public let meetingMaxMinutes: Int?
}

/// Abonelik sürümünde canlı metni üreten motor.
public enum HostedLiveEngine: String, Sendable, Equatable {
    /// Bulut (Deepgram); jeton her bağlantıda sunucudan alınır.
    case deepgram
    /// Mac'te (WhisperKit).
    case whisperKit = "whisperkit"
}

/// Sunucunun yeni toplantı için önerdiği canlı motor. Alanı bilmeyen eski sunucu Deepgram jetonu da vermez, tanınmayan
/// değer de Deepgram'ı açmaz: ikisinde de Mac'te (WhisperKit). Saf fonksiyondur.
public func hostedLiveEngine(entitlements: HostedEntitlements) -> HostedLiveEngine {
    entitlements.liveEngine.flatMap { HostedLiveEngine(rawValue: $0) } ?? .whisperKit
}

/// `POST /v1/live/deepgram-token` yanıtı: tek bağlantılık kısa ömürlü Deepgram jetonu. Jeton saklanmaz ve loglanmaz.
public struct HostedDeepgramGrant: Decodable, Sendable {
    /// Deepgram JWT'si (`Authorization: Bearer`); yalnızca bağlantı kurulurken geçerli olmalı.
    public let accessToken: String
    /// Jetonun kalan ömrü (saniye).
    public let expiresIn: Double
    /// Akış modeli (ör. `nova-3`).
    public let model: String
    /// Bu toplantıda kalan jeton.
    public let grantsLeft: Int
}

/// Abonelik sürümünün akış seçenekleri: model sunucunun jetonundan; model geliştirme programından her zaman çıkılır
/// (`mip_opt_out=true`: Deepgram ses ve metni yalnızca işlerken tutar, eğitimde kullanmaz; gizlilik metni bunu söyler).
/// Saf fonksiyondur.
public func hostedDeepgramListenOptions(grant: HostedDeepgramGrant) -> DeepgramListenOptions {
    DeepgramListenOptions(model: grant.model, optOutOfModelImprovement: true)
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

/// `POST /v1/meetings/{id}/reprocess` yanıtı.
public struct HostedReprocessedMeeting: Decodable, Sendable, Equatable {
    public let meetingId: String
    public let usableUntil: Date
    public let reprocessesLeft: Int
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
    /// Abonelik etkin; dönem sonunda yenilenir.
    case subscribed(renewsAt: Date)
    /// Abonelik iptal edildi; erişim bu ana dek sürer, yenilenmez.
    case ending(endsAt: Date)
    /// Ödeme gecikti; erişim ek süre boyunca sürer.
    case grace(endsAt: Date)
    /// Abonelik sona erdi (iptal edildi ya da ödenmedi) ve deneme hakkı kalmadı: yeni kayıt için yeniden abone olunmalı.
    case expired(endedAt: Date)
}

/// Hak yanıtından arayüz durumu: erişimi olan abonelik önce gelir, yoksa deneme. Saf fonksiyondur.
public func hostedPlanStatus(entitlements: HostedEntitlements) -> HostedPlanStatus {
    if let subscription = entitlements.subscription {
        switch subscription.access {
        case .active:
            if let cancelAt = subscription.cancelAt {
                return .ending(endsAt: cancelAt)
            }
            return .subscribed(renewsAt: subscription.currentPeriodEnd)
        case .grace:
            return .grace(endsAt: subscription.graceEndsAt ?? subscription.currentPeriodEnd)
        case .none:
            // Eski abone: deneme hakkı kalmadıysa "deneme bitti" değil "abonelik sona erdi".
            if entitlements.trialMeetingsLeft == 0 {
                return .expired(endedAt: subscription.cancelAt ?? subscription.currentPeriodEnd)
            }
        }
    }
    return .trial(left: entitlements.trialMeetingsLeft, total: entitlements.trialMeetingsTotal)
}
