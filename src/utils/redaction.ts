import { listSecrets, getSecret } from '../storage/secrets-store.js';

export interface RedactionResult {
  content: string;
  redacted: boolean;
  redactedSecrets: string[];
}

/**
 * Scan content for any secret values and replace them with [REDACTED:SECRET_NAME]
 */
export async function redactSecrets(content: string): Promise<RedactionResult> {
  const secrets = await listSecrets();
  let result = content;
  const redactedSecrets: string[] = [];

  for (const secret of secrets) {
    const value = await getSecret(secret.name);
    if (!value) continue;

    // Only redact if the value is substantial enough to be meaningful
    // Avoid false positives from very short values
    if (value.length < 6) continue;

    if (result.includes(value)) {
      result = result.replaceAll(value, `[REDACTED:${secret.name}]`);
      redactedSecrets.push(secret.name);
    }
  }

  return {
    content: result,
    redacted: redactedSecrets.length > 0,
    redactedSecrets
  };
}

/**
 * Redact a specific secret value from content
 */
export function redactValue(content: string, value: string, secretName: string): string {
  if (value.length < 6) return content;
  return content.replaceAll(value, `[REDACTED:${secretName}]`);
}
