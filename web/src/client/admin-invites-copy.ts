// Yönetim panelinin davet programı metinleri (İngilizce; yalnızca yönetici görür): liste rozeti ve kesimi, kullanıcı
// ayrıntısındaki "Invited by" ve "Invites" kartları, davet zaman çizelgesi olayları, içgörülerdeki davet özeti ve huni
// adımı. Sayfa (admin.astro) ve betikler (admin-users.ts, admin-insights.ts) aynı nesneyi kullanır; DOM'a dokunmaz.

/** Davet satırının durumu (sunucu `referral_redemptions.status`). */
export type InviteStatus = "checkout" | "joined" | "qualified" | "granted" | "capped" | "void";

/** Davet zaman çizelgesi olayları (sunucu `AdminTimelineKind`'in davet kısmı). */
export type InviteTimelineKind =
  | "invite_checkout"
  | "invite_joined"
  | "invite_first_payment"
  | "invite_reward_due"
  | "invite_rewarded"
  | "invite_voided"
  | "invite_friend_joined"
  | "invite_friend_rewarded";

/** Davet programı metinleri. `{ad}` yer tutucuları değerlerle doldurulur. */
export interface AdminInviteCopy {
  /** Kullanıcı listesindeki ve ayrıntıdaki rozetler. */
  readonly pills: { readonly invited: string; readonly freeMonth: string };
  /** Kullanıcı listesinin davet kesimi. */
  readonly segment: string;
  readonly invitedByTitle: string;
  readonly invitedByFields: {
    readonly referrer: string;
    readonly code: string;
    readonly status: string;
    readonly freeMonth: string;
    readonly card: string;
    readonly dates: string;
  };
  readonly invitesTitle: string;
  readonly invitesFields: { readonly code: string; readonly counts: string; readonly nextReward: string; readonly rewardsLeft: string };
  /** `{joined}`, `{pending}`, `{rewarded}`, `{voided}`. */
  readonly countsLine: string;
  /** `{left}`, `{perYear}`. */
  readonly rewardsLeftLine: string;
  readonly friendColumns: { readonly friend: string; readonly status: string; readonly joined: string; readonly firstPayment: string; readonly reward: string };
  readonly noFriends: string;
  readonly friendsNote: string;
  readonly deletedAccount: string;
  readonly noCode: string;
  readonly noRewardPending: string;
  readonly yes: string;
  readonly no: string;
  readonly cardChecked: string;
  readonly cardNotChecked: string;
  readonly notJoined: string;
  /** `{checkout}`, `{joined}`, `{paid}`. */
  readonly datesLine: string;
  /** `{date}`: ödül verildi. */
  readonly rewardGranted: string;
  /** `{date}`: ödül tarihi. */
  readonly rewardDue: string;
  readonly statuses: Readonly<Record<InviteStatus, string>>;
  readonly voidReasons: Readonly<Record<string, string>>;
  /** `{reason}`. */
  readonly statusWithReason: string;
  /** `{detail}`: arkadaşın kısa kimliği ya da düşme nedeni. */
  readonly timeline: Readonly<Record<InviteTimelineKind, string>>;
  readonly funnelStep: string;
  readonly insightsTitle: string;
  readonly insightsRows: {
    readonly checkouts: string;
    readonly joined: string;
    readonly firstPayments: string;
    readonly granted: string;
    readonly inFreeMonth: string;
  };
  readonly insightsColumns: { readonly measure: string; readonly count: string };
  /** `{list}`: nedene göre düşen davetler. */
  readonly insightsVoided: string;
  readonly insightsNoVoided: string;
  readonly topReferrersTitle: string;
  /** `{joined}`, `{pending}`, `{granted}`, `{voided}`. */
  readonly topReferrerMeta: string;
  readonly noReferrers: string;
}

export const adminInviteCopy: AdminInviteCopy = {
  pills: { invited: "Invite", freeMonth: "Free month" },
  segment: "Joined with an invite",
  invitedByTitle: "Invited by",
  invitedByFields: {
    referrer: "Referrer",
    code: "Code",
    status: "Invite status",
    freeMonth: "In the free invite month",
    card: "Card check",
    dates: "Dates",
  },
  invitesTitle: "Invites",
  invitesFields: { code: "Invite code", counts: "Friends", nextReward: "Next reward", rewardsLeft: "Rewards left this year" },
  countsLine: "{joined} joined · {pending} waiting · {rewarded} rewarded · {voided} voided",
  rewardsLeftLine: "{left} of {perYear}",
  friendColumns: { friend: "Friend", status: "Status", joined: "Joined", firstPayment: "First payment", reward: "Reward" },
  noFriends: "No friend has used this code yet.",
  friendsNote: "Newest first, up to 50. A friend becomes a reward once their first paid invoice has gone 30 days without a refund or dispute.",
  deletedAccount: "Deleted account",
  noCode: "No code yet",
  noRewardPending: "Nothing waiting",
  yes: "Yes",
  no: "No",
  cardChecked: "Card checked",
  cardNotChecked: "Not checked (no card on the subscription)",
  notJoined: "Not joined yet",
  datesLine: "Checkout {checkout} · joined {joined} · first payment {paid}",
  rewardGranted: "Granted {date}",
  rewardDue: "Due {date}",
  statuses: {
    checkout: "At checkout",
    joined: "Joined, free first month",
    qualified: "Paid, reward waiting",
    granted: "Reward granted",
    capped: "Yearly reward cap reached",
    void: "Void",
  },
  voidReasons: {
    refunded: "refunded",
    disputed: "disputed",
    self_referral: "same device as the referrer",
    referrer_deleted: "referrer deleted their account",
    referrer_no_customer: "referrer has no Stripe customer",
    referrer_complimentary: "referrer has free access",
    card_reused: "card already used for an invite",
    self_card: "referrer's own card",
    canceled_before_payment: "cancelled before the first payment",
    capped: "yearly reward cap",
  },
  statusWithReason: "Void: {reason}",
  timeline: {
    invite_checkout: "Took an invite code to checkout",
    invite_joined: "Subscribed with an invite",
    invite_first_payment: "First paid invoice after the invite",
    invite_reward_due: "Referrer's reward due",
    invite_rewarded: "Referrer was rewarded",
    invite_voided: "Invite voided ({detail})",
    invite_friend_joined: "Invited friend subscribed ({detail})",
    invite_friend_rewarded: "Reward granted for a friend ({detail})",
  },
  funnelStep: "Subscribed with an invite",
  insightsTitle: "Invites, last 30 days",
  insightsRows: {
    checkouts: "Codes taken to checkout",
    joined: "Subscribed with a code",
    firstPayments: "First paid invoices",
    granted: "Rewards granted",
    inFreeMonth: "In the free invite month now",
  },
  insightsColumns: { measure: "Invites", count: "Count" },
  insightsVoided: "Voided: {list}",
  insightsNoVoided: "No invite voided in the last 30 days.",
  topReferrersTitle: "Top referrers",
  topReferrerMeta: "{joined} joined · {pending} waiting · {granted} rewarded · {voided} voided",
  noReferrers: "No one has brought a subscriber with a code yet.",
};

/** Düşme nedeninin adı (bilinmeyen neden olduğu gibi). Saf fonksiyondur. */
export function inviteVoidReasonLabel(reason: string): string {
  return adminInviteCopy.voidReasons[reason] ?? reason;
}
