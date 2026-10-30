import Foundation

// Sitede giriş (abonelik sürümü): sağlayıcı (Apple ya da Google) uygulamada seçilir, giriş sitede yapılır. Developer ID
// ile dağıtılan uygulama Apple ile girişi kendisi yapamaz (Apple bu yetkiyi yalnızca App Store uygulamalarına verir).
// Uygulama her deneme için rastgele ham nonce üretir, yalnızca bellekte tutar ve
// `<site>/sign-in?app=1&nonce=<sha256hex(ham)>&provider=<apple|google>` sayfasını uygulama içi giriş penceresinde
// (ASWebAuthenticationSession) açar. Site seçilen sağlayıcıya yönlendirir (açılır pencere yok), dönüşte
// `com.senoldogan.ainotepad.hosted://auth/<apple|google>#idToken=<JWT>` adresine gider; giriş penceresi bu adresi
// yakalar. Uygulama `POST /v1/auth/<sağlayıcı>` ile `{identityToken, nonce: ham}` gönderir. Sunucu jetonun `nonce`
// iddiasının `sha256hex(ham)` olduğunu denetler.

/// Sitede girişin sağlayıcısı: dönüş adresinin yolu (`/apple`, `/google`).
public enum HostedSignInProvider: String, Sendable, Equatable, CaseIterable {
    case apple
    case google
}

/// Giriş denemesinin geçerlilik süresi (saniye): bundan sonra gelen dönüş reddedilir.
public let hostedBrowserSignInLifetimeSec: Double = 600

/// Kabul edilen en uzun kimlik jetonu (Apple ve Google kimlik jetonları 1–2 KB).
private let identityTokenMaxLength: Int = 8192

/// Başlatılmış, dönüşü beklenen giriş denemesi. Ham nonce yalnızca bellekte durur, tek kullanımlıktır.
public struct HostedBrowserSignInAttempt: Sendable, Equatable {
    public let rawNonce: String
    public let startedAt: Date

    public init(rawNonce: String, startedAt: Date) {
        self.rawNonce = rawNonce
        self.startedAt = startedAt
    }
}

/// Doğrulanmış dönüş: sağlayıcı, sunucuya gidecek kimlik jetonu ve denemenin ham nonce'u.
public struct HostedBrowserSignInCallback: Sendable, Equatable {
    public let provider: HostedSignInProvider
    public let identityToken: String
    public let rawNonce: String
}

/// Dönüş adresinden okunan sağlayıcı ve kimlik jetonu.
public struct HostedBrowserIdentity: Sendable, Equatable {
    public let provider: HostedSignInProvider
    public let identityToken: String
}

/// Sitede girişin başarısız olma nedeni.
public enum HostedBrowserSignInError: Error, Sendable, Equatable {
    /// Uygulama içi giriş penceresi açılamadı ya da dönüşsüz kapandı (kullanıcının vazgeçmesi değil); neden hata
    /// ayıklama içindir.
    case sessionNotStarted(reason: String)
    /// Bekleyen deneme yok: giriş bu uygulamadan başlatılmamış ya da dönüş ikinci kez geldi.
    case noPendingAttempt
    /// Deneme süresi (`hostedBrowserSignInLifetimeSec`) geçti.
    case attemptExpired
    /// Dönüş adresi beklenen biçimde değil; neden hata ayıklama içindir (jeton yazılmaz).
    case invalidCallback(reason: String)
    /// Jetonun nonce'u bekleyen denemenin nonce'u değil (başka bir denemeden dönmüş).
    case nonceMismatch
}

/// Yeni deneme: CSPRNG ile 32 baytlık ham nonce (onaltılık). Rastgele bayt üretilemezse `KeychainError`.
public func makeHostedBrowserSignInAttempt(now: Date) throws -> HostedBrowserSignInAttempt {
    HostedBrowserSignInAttempt(rawNonce: try makeHostedNonce(), startedAt: now)
}

/// Sitedeki giriş sayfası: `<site>/sign-in?app=1&nonce=<sha256hex(ham nonce)>&provider=<apple|google>`. Sağlayıcı
/// uygulamada seçildiği için site ara sayfa göstermeden doğrudan Apple'a ya da Google'a yönlendirir. Saf fonksiyondur.
public func hostedBrowserSignInPage(siteBase: URL, nonceHash: String, provider: HostedSignInProvider) -> URL {
    siteBase.appending(path: "sign-in").appending(queryItems: [
        URLQueryItem(name: "app", value: "1"),
        URLQueryItem(name: "nonce", value: nonceHash),
        URLQueryItem(name: "provider", value: provider.rawValue),
    ])
}

/// Dönüş adresindeki sağlayıcı ve kimlik jetonu: `<şema>://auth/<apple|google>#idToken=<JWT>`. Şema, ana bilgisayar,
/// yol, sorgu ve parça sıkı denetlenir: parçada yalnızca `idToken` olmalı, değeri üç base64url bölümlü bir JWT olmalı.
/// Uymazsa `invalidCallback`. Saf fonksiyondur.
public func hostedBrowserIdentity(url: URL) throws -> HostedBrowserIdentity {
    guard url.scheme?.lowercased() == hostedURLScheme else {
        throw HostedBrowserSignInError.invalidCallback(reason: "şema: \(url.scheme ?? "-")")
    }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.host == "auth", components.path.hasPrefix("/"),
          let provider = HostedSignInProvider(rawValue: String(components.path.dropFirst())),
          components.user == nil, components.password == nil, components.port == nil, components.query == nil else {
        throw HostedBrowserSignInError.invalidCallback(reason: "adres: \(url.host() ?? "-")\(url.path())")
    }
    guard let fragment = components.percentEncodedFragment, !fragment.isEmpty else {
        throw HostedBrowserSignInError.invalidCallback(reason: "parça yok")
    }
    let pairs: [Substring] = fragment.split(separator: "&", omittingEmptySubsequences: false)
    guard pairs.count == 1, pairs[0].hasPrefix("idToken=") else {
        throw HostedBrowserSignInError.invalidCallback(reason: "parçada yalnızca idToken olmalı")
    }
    let token: String = String(pairs[0].dropFirst("idToken=".count))
    guard isJWTShaped(token: token) else {
        throw HostedBrowserSignInError.invalidCallback(reason: "idToken JWT biçiminde değil, uzunluk: \(token.count)")
    }
    return HostedBrowserIdentity(provider: provider, identityToken: token)
}

/// JWT biçimi: üç boş olmayan base64url bölümü, makul uzunlukta. Saf fonksiyondur.
private func isJWTShaped(token: String) -> Bool {
    let parts: [Substring] = token.split(separator: ".", omittingEmptySubsequences: false)
    return token.count <= identityTokenMaxLength && parts.count == 3 && parts.allSatisfy { (part: Substring) -> Bool in
        !part.isEmpty && part.allSatisfy { (character: Character) -> Bool in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }
}

/// Kimlik jetonunun gövdesindeki `nonce` iddiası (imza burada değil, sunucuda doğrulanır). Gövde çözülemezse ya da
/// `nonce` yoksa `invalidCallback`. Saf fonksiyondur.
public func hostedIDTokenNonce(identityToken: String) throws -> String {
    struct Claims: Decodable {
        let nonce: String?
    }
    let parts: [Substring] = identityToken.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let payload = base64URLDecoded(text: String(parts[1])) else {
        throw HostedBrowserSignInError.invalidCallback(reason: "jeton gövdesi base64url değil")
    }
    let claims: Claims
    do {
        claims = try JSONDecoder().decode(Claims.self, from: payload)
    } catch {
        throw HostedBrowserSignInError.invalidCallback(reason: "jeton gövdesi JSON değil: \(error)")
    }
    guard let nonce = claims.nonce, !nonce.isEmpty else {
        throw HostedBrowserSignInError.invalidCallback(reason: "jetonda nonce yok")
    }
    return nonce
}

/// Kimlik jetonundaki profil resmi (`picture`, yalnızca Google verir; Apple vermez): yalnızca https adresi kabul edilir.
/// Resim yoksa nil; gövde çözülemezse `invalidCallback`. Resim yalnızca bu Mac'te hesabın avatarı için saklanır,
/// sunucuya gönderilmez. Saf fonksiyondur.
public func hostedIDTokenPicture(identityToken: String) throws -> URL? {
    struct Claims: Decodable {
        let picture: String?
    }
    let parts: [Substring] = identityToken.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let payload = base64URLDecoded(text: String(parts[1])) else {
        throw HostedBrowserSignInError.invalidCallback(reason: "jeton gövdesi base64url değil")
    }
    let claims: Claims
    do {
        claims = try JSONDecoder().decode(Claims.self, from: payload)
    } catch {
        throw HostedBrowserSignInError.invalidCallback(reason: "jeton gövdesi JSON değil: \(error)")
    }
    guard let picture = claims.picture, let url = URL(string: picture), url.scheme == "https", url.host() != nil else {
        return nil
    }
    return url
}

/// base64url (dolgusuz) metni çözer; geçersizse nil. Saf fonksiyondur.
private func base64URLDecoded(text: String) -> Data? {
    let standard: String = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let padded: String = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
    return Data(base64Encoded: padded)
}

/// Dönüşü bekleyen denemeyle eşleştirir: deneme yoksa `noPendingAttempt`, süresi geçtiyse `attemptExpired`, adres
/// bozuksa `invalidCallback`, jetonun nonce'u denemeninkinin SHA-256'sı değilse `nonceMismatch`. Deneme kendi giriş
/// penceresine bağlıdır ve pencere kapanınca düşer (tek kullanımlık). Saf fonksiyondur.
public func resolveHostedBrowserCallback(
    url: URL, pending: HostedBrowserSignInAttempt?, now: Date, lifetimeSec: Double
) throws -> HostedBrowserSignInCallback {
    guard let pending else {
        throw HostedBrowserSignInError.noPendingAttempt
    }
    guard now.timeIntervalSince(pending.startedAt) <= lifetimeSec else {
        throw HostedBrowserSignInError.attemptExpired
    }
    let identity: HostedBrowserIdentity = try hostedBrowserIdentity(url: url)
    guard try hostedIDTokenNonce(identityToken: identity.identityToken) == hostedNonceHash(nonce: pending.rawNonce) else {
        throw HostedBrowserSignInError.nonceMismatch
    }
    return HostedBrowserSignInCallback(provider: identity.provider, identityToken: identity.identityToken, rawNonce: pending.rawNonce)
}

/// Giriş hatasının kullanıcıya gösterilen metni. Saf fonksiyondur.
public func hostedBrowserSignInMessage(error: HostedBrowserSignInError) -> String {
    switch error {
    case .sessionNotStarted:
        String(localized: "Giriş penceresi açılamadı. Uygulamayı öne getirip Apple ya da Google ile yeniden devam et.")
    case .noPendingAttempt:
        String(localized: "Bu giriş uygulamadan başlatılmamış ya da zaten kullanılmış. Apple ya da Google ile yeniden devam et.")
    case .attemptExpired:
        String(localized: "Giriş 10 dakika içinde tamamlanmadı. Apple ya da Google ile yeniden devam et.")
    case .invalidCallback:
        String(localized: "Girişten dönen bağlantı geçersiz. Apple ya da Google ile yeniden devam et.")
    case .nonceMismatch:
        String(localized: "Giriş başka bir denemeden döndü. Apple ya da Google ile yeniden devam et.")
    }
}
