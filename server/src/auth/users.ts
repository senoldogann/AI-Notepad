import { randomId } from "../crypto";
import { insertUserFromLedgerStatement } from "../trialLedger";

/** Giriş sağlayıcısı. */
export type IdentityProvider = "apple" | "google";

/**
 * Kimliğin kullanıcısını bulur; yoksa yeni kullanıcı ve kimlik oluşturur. Eşzamanlı ilk girişte tek kullanıcı kalır.
 * Yeni kullanıcı, kimliğin deneme defterindeki (`identityHash`, bkz. `trialIdentityHash`) harcanan deneme sayısını ve
 * cihaz doğrulamasını devralır: hesabı silip aynı kimlikle yeniden açmak denemeyi sıfırlamaz.
 */
export async function findOrCreateUser(
  db: D1Database,
  provider: IdentityProvider,
  subject: string,
  identityHash: string,
  email: string | null,
  now: Date,
): Promise<string> {
  const existing: string | null = await findUserId(db, provider, subject);
  if (existing !== null) {
    return existing;
  }
  const userId: string = randomId();
  try {
    await db.batch([
      insertUserFromLedgerStatement(db, userId, identityHash, now),
      db
        .prepare("INSERT INTO auth_identities (provider, subject, user_id, email, created_at) VALUES (?, ?, ?, ?, ?)")
        .bind(provider, subject, userId, email, now.getTime()),
    ]);
    return userId;
  } catch (error: unknown) {
    // Aynı kimlik eşzamanlı oluşturulduysa toplu işlem geri alınır; kazananı döndür.
    const winner: string | null = await findUserId(db, provider, subject);
    if (winner === null) {
      throw error;
    }
    return winner;
  }
}

async function findUserId(db: D1Database, provider: IdentityProvider, subject: string): Promise<string | null> {
  const row: { user_id: string } | null = await db
    .prepare("SELECT user_id FROM auth_identities WHERE provider = ? AND subject = ?")
    .bind(provider, subject)
    .first<{ user_id: string }>();
  return row === null ? null : row.user_id;
}
