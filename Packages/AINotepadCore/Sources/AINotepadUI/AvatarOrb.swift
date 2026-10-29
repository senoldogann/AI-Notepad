import SwiftUI

/// Tohumdan sabit sayı (FNV-1a): aynı hesap her açılışta aynı küreyi görür (`hashValue` süreç başına değişir).
/// Saf fonksiyondur.
func avatarSeedNumber(seed: String) -> UInt64 {
    seed.unicodeScalars.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { ($0 ^ UInt64($1.value)) &* 0x100_0000_01B3 }
}

/// Hesabın küresinin renk ailesi (kapak gradyanlarıyla aynı pastel aileler). Saf fonksiyondur.
func avatarPalette(seed: String) -> FilmPalette {
    let palettes: [FilmPalette] = FilmPalette.allCases
    return palettes[Int(avatarSeedNumber(seed: seed) % UInt64(palettes.count))]
}

/// Resmi olmayan hesabın avatarı: ElevenLabs kürelerine benzer, hesaba özel renkli pastel küre ve üzerinde beyaz kişi
/// silueti. Durağandır (hareket ve bulanıklık yok: kenar çubuğunda sürekli çizilir); ışık sol üstte, kenar hafif koyu,
/// ince beyaz çizgi.
public struct AvatarOrb: View {
    let seed: String
    let size: CGFloat

    public init(seed: String, size: CGFloat) {
        self.seed = seed
        self.size = size
    }

    public var body: some View {
        let colors: (base: Color, clouds: [Color]) = avatarPalette(seed: seed).colors
        let blobs: [AvatarBlob] = avatarBlobs(seed: seed)
        Circle()
            .fill(colors.base)
            // Renk lekeleri: uç noktası olmayan yumuşak geçişler (sıvı gibi), yerleri hesaba göre sabit.
            .overlay {
                ZStack {
                    ForEach(Array(blobs.enumerated()), id: \.offset) { (item: (offset: Int, element: AvatarBlob)) in
                        let color: Color = colors.clouds[item.element.colorIndex]
                        Circle().fill(RadialGradient(
                            colors: [color.opacity(0.95), color.opacity(0)],
                            center: UnitPoint(x: item.element.x, y: item.element.y),
                            startRadius: 0,
                            endRadius: size * item.element.radius
                        ))
                    }
                }
            }
            // Işık: sol üstte krem parlaklık.
            .overlay(Circle().fill(RadialGradient(
                colors: [colors.clouds[1].opacity(0.9), colors.clouds[1].opacity(0)],
                center: UnitPoint(x: 0.3, y: 0.24),
                startRadius: 0,
                endRadius: size * 0.42
            )))
            // Kenar: hacim için hafif koyulaşma.
            .overlay(Circle().fill(RadialGradient(
                colors: [colors.clouds[3].opacity(0), colors.clouds[3].opacity(0.45)],
                center: .center,
                startRadius: size * 0.3,
                endRadius: size * 0.52
            )))
            // Kişi silueti: küre bir hesabı temsil ettiği belli olsun (beyaz, yarı saydam; omuzlar alttan taşar).
            .overlay(alignment: .bottom) {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.white.opacity(0.82))
                    .frame(width: size * 0.56, height: size * 0.56)
                    .offset(y: size * 0.1)
                    .shadow(color: colors.clouds[3].opacity(0.35), radius: size * 0.04, y: size * 0.02)
            }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 0.75))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Kürenin renk lekesi: merkez (0...1), yarıçap (kürenin boyuna oranla) ve ailedeki renk.
struct AvatarBlob: Equatable {
    let x: Double
    let y: Double
    let radius: Double
    let colorIndex: Int
}

/// Tohumdan sabit üç leke: derin ton alt yanda, karşıt pastel karşı yanda, açık ton arada. Saf fonksiyondur.
func avatarBlobs(seed: String) -> [AvatarBlob] {
    var state: UInt64 = avatarSeedNumber(seed: seed)
    let next: () -> Double = {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    let turn: Double = next() * 2 * Double.pi
    let place: (Double, Double, Double, Int) -> AvatarBlob = { (angle: Double, distance: Double, radius: Double, colorIndex: Int) -> AvatarBlob in
        AvatarBlob(x: 0.5 + cos(angle) * distance, y: 0.5 + sin(angle) * distance, radius: radius, colorIndex: colorIndex)
    }
    return [
        place(turn, 0.28 + next() * 0.08, 0.62, 3),
        place(turn + 2.3 + next() * 0.6, 0.3, 0.55, 2),
        place(turn + 4.2 + next() * 0.6, 0.22, 0.45, 0),
    ]
}

/// Hesabın avatarı: profil resmi varsa o (yüklenene ya da yüklenemezse küre), yoksa hesaba özel küre.
public struct ProfileAvatar: View {
    let imageURL: URL?
    let seed: String
    let size: CGFloat

    public init(imageURL: URL?, seed: String, size: CGFloat) {
        self.imageURL = imageURL
        self.seed = seed
        self.size = size
    }

    public var body: some View {
        if let imageURL {
            AsyncImage(url: imageURL) { (phase: AsyncImagePhase) in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Theme.line))
                default:
                    AvatarOrb(seed: seed, size: size)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else {
            AvatarOrb(seed: seed, size: size)
        }
    }
}
