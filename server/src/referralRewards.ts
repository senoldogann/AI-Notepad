import type Stripe from "stripe";
import { callStripe, paymentTargetOf, storedCustomerId, stripeClient } from "./billing";
import type { Config } from "./config";
import { type SubscriptionState, subscriptionState } from "./entitlements";
import { errorName, log } from "./log";
import type { Platform } from "./platform";
import { type ReferralVoidReason, recentRewardCount, referralRewardsPerYear, sharesDevice, usdCents } from "./referrals";

/**
 * Davet ödülü: davet edilenin ilk gerçek ödemesi `referralHoldMs` boyunca iade ya da itiraz almadıysa (`qualified`,
 * `reward_due_at` geçmiş) davet edenin Stripe müşterisine bir aylık fiyat kadar (USD) müşteri bakiyesi alacağı yazılır;
 * Stripe bunu sonraki faturalarından kendiliğinden düşer.
 *
 * Neden müşteri bakiyesi (tek seferlik %100 kupon değil): planı ne olursa olsun (aylıkta bir ay, yıllıkta yenilemeden
 * 5,99 $) aynı değeri verir; birden çok ödül üst üste birikir (aynı faturaya iki %100 kupon yalnızca bir ay eder);
 * aboneliği değiştirmez (abonelik olayı tetiklemez); tek bir idempotent çağrıdır ve Stripe'ta `metadata` ile
 * izlenebilir. Fiyatlar USD'dir; Adaptive Pricing yerel parayla ödetse de fatura para birimi USD kalır.
 *
 * Çift ödül olmaz: satır `qualified` değilse işlenmez, Stripe çağrısı ödül kimliğiyle idempotent'tir ve çağrıdan önce
 * müşterinin bakiye hareketlerinde aynı ödül (`metadata.referral_redemption_id`) aranır (yanıt yolda kaybolup satır
 * yazılamadıysa ertesi gün yeniden yaratılmaz).
 */

/** Bir Cron çalışmasında en çok işlenen ödül (kalanlar ertesi gün). */
export const referralRewardBatchSize: number = 50;

/** Bakiye hareketinin işareti. */
const rewardPurpose: string = "referral_reward";

/** Ödül bekleyen satır. */
interface DueReward {
  readonly id: string;
  readonly referrer_user_id: string | null;
  readonly referred_user_id: string | null;
  readonly stripe_subscription_id: string;
  readonly qualifying_invoice_id: string;
}

/** Satırın sonucu. */
type RewardOutcome = "granted" | "capped" | ReferralVoidReason;

/** Cron raporu: sonuç başına satır sayısı ve başarısız satırlar. */
export interface ReferralRewardReport {
  readonly processed: number;
  readonly granted: number;
  readonly capped: number;
  readonly voided: number;
  readonly failed: number;
}

/** Bir ya da daha çok ödül Stripe ya da D1 hatasıyla yazılamadı (ertesi gün yeniden denenir). */
export class ReferralRewardFailedError extends Error {
  override readonly name: string = "ReferralRewardFailedError";
  readonly failed: number;

  constructor(failed: number) {
    super(`${failed} davet ödülü yazılamadı; ertesi Cron çalışmasında yeniden denenecek.`);
    this.failed = failed;
  }
}

/** Faturanın ödemelerinden biri iade (kısmi dahil) ya da itiraz almış mı. */
async function invoiceRefundedOrDisputed(stripe: Stripe, platform: Platform, invoiceId: string, userId: string | null): Promise<boolean> {
  const payments: Stripe.ApiList<Stripe.InvoicePayment> = await callStripe(platform, "invoicePayments.list", userId, () =>
    stripe.invoicePayments.list({ invoice: invoiceId, limit: 100 }),
  );
  for (const payment of payments.data) {
    const target: { payment_intent: string } | { charge: string } | null = paymentTargetOf(payment);
    if (target === null) {
      continue;
    }
    const charges: Stripe.Charge[] =
      "payment_intent" in target
        ? (await callStripe(platform, "charges.list", userId, () => stripe.charges.list({ payment_intent: target.payment_intent, limit: 100 }))).data
        : [await callStripe(platform, "charges.retrieve", userId, () => stripe.charges.retrieve(target.charge))];
    if (charges.some((charge: Stripe.Charge): boolean => charge.amount_refunded > 0 || charge.disputed)) {
      return true;
    }
  }
  return false;
}

/** Müşterinin bu ödül için zaten yazılmış bakiye hareketi; yoksa null. */
async function existingRewardTransaction(stripe: Stripe, platform: Platform, customer: string, rewardId: string, userId: string): Promise<string | null> {
  const transactions: Stripe.ApiList<Stripe.CustomerBalanceTransaction> = await callStripe(platform, "customers.listBalanceTransactions", userId, () =>
    stripe.customers.listBalanceTransactions(customer, { limit: 100 }),
  );
  const found: Stripe.CustomerBalanceTransaction | undefined = transactions.data.find(
    (transaction: Stripe.CustomerBalanceTransaction): boolean => transaction.metadata?.["referral_redemption_id"] === rewardId,
  );
  return found?.id ?? null;
}

/** Satırı sonuçlandıran ifade: yalnızca hâlâ `qualified` ise yazılır. */
async function settle(db: D1Database, reward: DueReward, outcome: RewardOutcome, transactionId: string | null, nowMs: number): Promise<void> {
  const status: string = outcome === "granted" || outcome === "capped" ? outcome : "void";
  await db
    .prepare(
      `UPDATE referral_redemptions SET status = ?1, void_reason = ?2, rewarded_at = ?3, stripe_balance_transaction_id = ?4, updated_at = ?5
       WHERE id = ?6 AND status = 'qualified'`,
    )
    .bind(status, status === "void" ? outcome : null, outcome === "granted" ? nowMs : null, transactionId, nowMs, reward.id)
    .run();
}

/** Ödülü engelleyen durum (sırayla: aynı cihaz, iade ya da itiraz, yıllık sınır); engel yoksa null. */
async function rewardRefusal(db: D1Database, stripe: Stripe, platform: Platform, reward: DueReward, referrer: string, nowMs: number): Promise<RewardOutcome | null> {
  if (reward.referred_user_id !== null && (await sharesDevice(db, referrer, reward.referred_user_id))) {
    return "self_referral";
  }
  if (await invoiceRefundedOrDisputed(stripe, platform, reward.qualifying_invoice_id, referrer)) {
    return "refunded";
  }
  return (await recentRewardCount(db, referrer, nowMs)) >= referralRewardsPerYear ? "capped" : null;
}

/**
 * Tek ödülü sonuçlandırır. Sıra: davet eden silinmiş → `referrer_deleted`; davet edenin ücretsiz erişimi var
 * (`complimentary.ts`; bakiye yazılacak bir Stripe aboneliği yok) → `referrer_complimentary`, Stripe çağrılmaz; iki
 * hesap aynı cihazı paylaşıyor →
 * `self_referral`; ödeme iade ya da itiraz almış → `refunded`; son 365 günde 12 ödül → `capped`; davet edenin Stripe
 * müşterisi yok → `referrer_no_customer`; değilse bakiye alacağı yazılır → `granted`.
 */
async function settleReward(db: D1Database, stripe: Stripe, platform: Platform, config: Config, reward: DueReward, nowMs: number): Promise<RewardOutcome> {
  const referrer: string | null = reward.referrer_user_id;
  if (referrer === null) {
    await settle(db, reward, "referrer_deleted", null, nowMs);
    return "referrer_deleted";
  }
  const referrerSubscription: SubscriptionState | null = await subscriptionState(db, referrer);
  if (referrerSubscription !== null && referrerSubscription.complimentary) {
    await settle(db, reward, "referrer_complimentary", null, nowMs);
    log("info", "referral_reward_skipped_complimentary", { rewardId: reward.id, referrerUserId: referrer });
    return "referrer_complimentary";
  }
  const refusal: RewardOutcome | null = await rewardRefusal(db, stripe, platform, reward, referrer, nowMs);
  if (refusal !== null) {
    await settle(db, reward, refusal, null, nowMs);
    return refusal;
  }
  const customer: string | null = await storedCustomerId(db, referrer);
  if (customer === null) {
    await settle(db, reward, "referrer_no_customer", null, nowMs);
    return "referrer_no_customer";
  }
  const transactionId: string =
    (await existingRewardTransaction(stripe, platform, customer, reward.id, referrer)) ??
    (
      await callStripe(platform, "customers.createBalanceTransaction", referrer, () =>
        stripe.customers.createBalanceTransaction(
          customer,
          {
            amount: -usdCents(config.priceUsdMonthly),
            currency: "usd",
            description: "Gistsmith invite reward: one month free",
            metadata: { purpose: rewardPurpose, referral_redemption_id: reward.id, referred_subscription_id: reward.stripe_subscription_id },
          },
          { idempotencyKey: `referral-reward-${reward.id}` },
        ),
      )
    ).id;
  await settle(db, reward, "granted", transactionId, nowMs);
  return "granted";
}

/**
 * Günü gelmiş ödülleri (`qualified`, `reward_due_at <= now`; en çok `referralRewardBatchSize`) sonuçlandırır. Satırlar
 * birbirinden bağımsızdır: biri başarısız olursa alarm yazılır, diğerleri sürer; sonunda başarısız varsa
 * `ReferralRewardFailedError` (satır `qualified` kalır, ertesi gün yeniden denenir). Program kapalıyken
 * (`REFERRAL_POLICY=off`) de hak kazanılmış ödüller verilir.
 */
export async function grantDueReferralRewards(db: D1Database, platform: Platform, config: Config, now: Date): Promise<ReferralRewardReport> {
  const nowMs: number = now.getTime();
  const due: D1Result<DueReward> = await db
    .prepare(
      `SELECT id, referrer_user_id, referred_user_id, stripe_subscription_id, qualifying_invoice_id FROM referral_redemptions
       WHERE status = 'qualified' AND reward_due_at <= ? ORDER BY reward_due_at LIMIT ?`,
    )
    .bind(nowMs, referralRewardBatchSize)
    .all<DueReward>();
  const counts: Record<"granted" | "capped" | "voided" | "failed", number> = { granted: 0, capped: 0, voided: 0, failed: 0 };
  if (due.results.length === 0) {
    return { processed: 0, ...counts };
  }
  const stripe: Stripe = stripeClient(platform, config);
  for (const reward of due.results) {
    try {
      const outcome: RewardOutcome = await settleReward(db, stripe, platform, config, reward, nowMs);
      if (outcome === "granted" || outcome === "capped") {
        counts[outcome] += 1;
      } else {
        counts.voided += 1;
      }
      log("info", "referral_reward_settled", { rewardId: reward.id, referrerUserId: reward.referrer_user_id, outcome });
    } catch (error: unknown) {
      counts.failed += 1;
      log("alert", "referral_reward_failed", { rewardId: reward.id, referrerUserId: reward.referrer_user_id, error: errorName(error) });
    }
  }
  const report: ReferralRewardReport = { processed: due.results.length, ...counts };
  log("info", "referral_rewards_done", { ...report });
  if (counts.failed > 0) {
    throw new ReferralRewardFailedError(counts.failed);
  }
  return report;
}
