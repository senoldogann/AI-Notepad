import { type LogFields, errorName, log } from "./log";
import type { RequestContext } from "./platform";

/**
 * İşi istemci bağlantısı koptuğunda da sürdürür: söz `waitUntil`'e kaydedilir (Workers isteği iptal etse de iş biter)
 * ve aynı söz döndürülür (istek onu bekler). İş üst servis çağrısını ve kesinleştirmeyi (kullanım ve harcama yazımı)
 * birlikte taşımalıdır; böylece istemci koparsa da harcama yazılır. İşin hatası istemciye ulaşmayabileceği için burada
 * `alert` olarak loglanır (muhasebe kaybı insan müdahalesi ister); bekleyen istek aynı hatayı ayrıca alır.
 */
export function continueAfterDisconnect<T>(context: RequestContext, task: Promise<T>, failureEvent: string, fields: LogFields): Promise<T> {
  context.waitUntil(
    task.then(
      (): void => undefined,
      (error: unknown): void => {
        log("alert", failureEvent, { ...fields, error: errorName(error) });
      },
    ),
  );
  return task;
}
