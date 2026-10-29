// Davet sayfası: adresteki `?code=` geçerli biçimdeyse bu tarayıcıda saklanır (hesap sayfası abone olurken onu doldurur)
// ve kod kutusu görünür; adreste kod yoksa önceden saklanmış kod gösterilir. Kodun geçerliliğini sunucu abone olurken
// denetler (`POST /v1/referral/validate`); bu sayfa sunucuya istek atmaz.
import { storeInviteCode, storedInviteCode } from "./checkout-choice";
import { dataValue, element } from "./dom";
import { normalizedInviteCode } from "../lib/plans";

/** Sayfayı başlatır. */
function main(): void {
  const root: HTMLElement = element("invite-page", HTMLElement);
  const raw: string | null = new URLSearchParams(window.location.search).get("code");
  const fromLink: string | null = raw === null ? null : normalizedInviteCode(raw);
  if (fromLink !== null) {
    storeInviteCode(fromLink);
  }
  const code: string | null = fromLink ?? storedInviteCode();
  if (code === null) {
    return;
  }
  element("invite-code", HTMLElement).textContent = code;
  element("invite-subscribe", HTMLAnchorElement).href = `${dataValue(root, "accountPath")}?code=${encodeURIComponent(code)}`;
  element("invite-code-box", HTMLElement).classList.remove("hidden");
}

main();
