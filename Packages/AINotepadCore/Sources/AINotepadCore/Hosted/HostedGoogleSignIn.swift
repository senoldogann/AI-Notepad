import Foundation

// Google ile giriş (abonelik sürümü): Google arayüzü sitededir. Uygulama her deneme için rastgele ham nonce üretir,
// yalnızca bellekte tutar ve `<site>/sign-in?app=1&nonce=<sha256hex(ham)>` sayfasını tarayıcıda açar. Kullanıcı hesabını
// seçince site uygulamayı `com.senoldogan.ainotepad.hosted://auth/google#idToken=<JWT>` ile açar; uygulama
// `POST /v1/auth/google` ile `{identityToken, nonce: ham}` gönderir. Sunucu jetonun `nonce` iddiasının
// `sha256hex(ham)` olduğunu denetler.

/// Google ile giriş denemesinin geçerlilik süresi (saniye): bundan sonra gelen dönüş reddedilir.
public let hostedGoogleSignInLifetimeSec: Double = 600

/// Kabul edilen en uzun kimlik jetonu (Google ID jetonları 1–2 KB).
private let googleIDTokenMaxLength: Int = 8192

/// Başlatılmış, dönüşü beklenen Google ile giriş denemesi. Ham nonce yalnızca bellekte durur, tek kullanımlıktır.
public struct HostedGoogleSignInAttempt: Sendable, Equatable {
    public let rawNonce: String
    public let startedAt: Date

    public init(rawNonce: String, startedAt: Date) {
        self.rawNonce = rawNonce
        self.startedAt = startedAt
    }
}

/// Doğrulanmış dönüş: sunucuya gidecek kimlik jetonu ve denemenin ham nonce'u.
public struct HostedGoogleSignInCallback: Sendable, Equatable {
    public let identityToken: String
    public let rawNonce: String
}

/// Google ile giriş dönüşünün reddedilme nedeni.
public enum HostedGoogleSignInError: Error, Sendable, Equatable {
    /// Bekleyen deneme yok: giriş bu uygulamadan başlatılmamış ya da dönüş ikinci kez geldi.
    case noPendingAttempt
    /// Deneme süresi (`hostedGoogleSignInLifetimeSec`) geçti.
    case attemptExpired
    /// Dönüş adresi beklenen biçimde değil; neden hata ayıklama içindir (jeton yazılmaz).
    case invalidCallback(reason: String)
    /// Jetonun nonce'u bekleyen denemenin nonce'u değil (başka bir denemeden dönmüş).
    case nonceMismatch
}

/// Yeni deneme: CSPRNG ile 32 baytlık ham nonce (onaltılık). Rastgele bayt üretilemezse `KeychainError`.
public func makeHostedGoogleSignInAttempt(now: Date) throws -> HostedGoogleSignInAttempt {
    HostedGoogleSignInAttempt(rawNonce: try makeHostedNonce(), startedAt: now)
}

/// Sitedeki Google giriş sayfası: `<site>/sign-in?app=1&nonce=<sha256hex(ham nonce)>`. Saf fonksiyondur.
public func hostedGoogleSignInPage(siteBase: URL, nonceHash: String) -> URL {
    siteBase.appending(path: "sign-in").appending(queryItems: [
        URLQueryItem(name: "app", value: "1"),
        URLQueryItem(name: "nonce", value: nonceHash),
    ])
}

/// Dönüş adresindeki kimlik jetonu: `<şema>://auth/google#idToken=<JWT>`. Şema, ana bilgisayar, yol, sorgu ve parça
/// sıkı denetlenir: parçada yalnızca `idToken` olmalı, değeri üç base64url bölümlü bir JWT olmalı. Uymazsa
/// `invalidCallback`. Saf fonksiyondur.
public func hostedGoogleIDToken(url: URL) throws -> String {
    guard url.scheme?.lowercased() == hostedURLScheme else {
        throw HostedGoogleSignInError.invalidCallback(reason: "şema: \(url.scheme ?? "-")")
    }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.host == "auth", components.path == "/google",
          components.user == nil, components.password == nil, components.port == nil, components.query == nil else {
        throw HostedGoogleSignInError.invalidCallback(reason: "adres: \(url.host() ?? "-")\(url.path())")
    }
    guard let fragment = components.percentEncodedFragment, !fragment.isEmpty else {
        throw HostedGoogleSignInError.invalidCallback(reason: "parça yok")
    }
    let pairs: [Substring] = fragment.split(separator: "&", omittingEmptySubsequences: false)
    guard pairs.count == 1, pairs[0].hasPrefix("idToken=") else {
        throw HostedGoogleSignInError.invalidCallback(reason: "parçada yalnızca idToken olmalı")
    }
    let token: String = String(pairs[0].dropFirst("idToken=".count))
    guard isJWTShaped(token: token) else {
        throw HostedGoogleSignInError.invalidCallback(reason: "idToken JWT biçiminde değil, uzunluk: \(token.count)")
    }
    return token
}

/// JWT biçimi: üç boş olmayan base64url bölümü, makul uzunlukta. Saf fonksiyondur.
private func isJWTShaped(token: String) -> Bool {
    let parts: [Substring] = token.split(separator: ".", omittingEmptySubsequences: false)
    return token.count <= googleIDTokenMaxLength && parts.count == 3 && parts.allSatisfy { (part: Substring) -> Bool in
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
        throw HostedGoogleSignInError.invalidCallback(reason: "jeton gövdesi base64url değil")
    }
    let claims: Claims
    do {
        claims = try JSONDecoder().decode(Claims.self, from: payload)
    } catch {
        throw HostedGoogleSignInError.invalidCallback(reason: "jeton gövdesi JSON değil: \(error)")
    }
    guard let nonce = claims.nonce, !nonce.isEmpty else {
        throw HostedGoogleSignInError.invalidCallback(reason: "jetonda nonce yok")
    }
    return nonce
}

/// base64url (dolgusuz) metni çözer; geçersizse nil. Saf fonksiyondur.
private func base64URLDecoded(text: String) -> Data? {
    let standard: String = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let padded: String = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
    return Data(base64Encoded: padded)
}

/// Dönüşü bekleyen denemeyle eşleştirir: deneme yoksa `noPendingAttempt`, süresi geçtiyse `attemptExpired`, adres
/// bozuksa `invalidCallback`, jetonun nonce'u denemeninkinin SHA-256'sı değilse `nonceMismatch`. Çağıran denemeyi
/// sonuç ne olursa olsun düşürür (tek kullanımlık; ikinci dönüş `noPendingAttempt` alır). Saf fonksiyondur.
public func resolveHostedGoogleCallback(
    url: URL, pending: HostedGoogleSignInAttempt?, now: Date, lifetimeSec: Double
) throws -> HostedGoogleSignInCallback {
    guard let pending else {
        throw HostedGoogleSignInError.noPendingAttempt
    }
    guard now.timeIntervalSince(pending.startedAt) <= lifetimeSec else {
        throw HostedGoogleSignInError.attemptExpired
    }
    let token: String = try hostedGoogleIDToken(url: url)
    guard try hostedIDTokenNonce(identityToken: token) == hostedNonceHash(nonce: pending.rawNonce) else {
        throw HostedGoogleSignInError.nonceMismatch
    }
    return HostedGoogleSignInCallback(identityToken: token, rawNonce: pending.rawNonce)
}

/// Google ile giriş hatasının kullanıcıya gösterilen metni. Saf fonksiyondur.
public func hostedGoogleSignInMessage(error: HostedGoogleSignInError) -> String {
    switch error {
    case .noPendingAttempt:
        String(localized: "Bu Google girişi uygulamadan başlatılmamış ya da zaten kullanılmış. \"Google ile devam et\"e yeniden bas.")
    case .attemptExpired:
        String(localized: "Google ile giriş 10 dakika içinde tamamlanmadı. \"Google ile devam et\"e yeniden bas.")
    case .invalidCallback:
        String(localized: "Google girişinden dönen bağlantı geçersiz. \"Google ile devam et\"e yeniden bas.")
    case .nonceMismatch:
        String(localized: "Google girişi başka bir denemeden döndü. \"Google ile devam et\"e yeniden bas.")
    }
}
