import AINotepadCore

/// Üst satırdaki dil metni: kilitli dil, sabit seçim ya da otomatik algılama durumu. Saf fonksiyondur.
public func languageText(locked: MeetingLanguage?, mode: LanguageMode, isRecording: Bool) -> String {
    if let locked {
        return languageName(language: locked)
    }
    switch mode {
    case .fixed(let language):
        return languageName(language: language)
    case .automatic:
        return isRecording ? String(localized: "Dil algılanıyor…") : String(localized: "Dil: Otomatik")
    }
}

/// Bayraklı dil adı.
public func languageName(language: MeetingLanguage) -> String {
    switch language {
    case .finnish: "🇫🇮 " + meetingLanguageName(language: language)
    case .english: "🇬🇧 " + meetingLanguageName(language: language)
    }
}
