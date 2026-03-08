import { getSecret, getSecretMetadata, recordUsage } from '../storage/secrets-store.js';
import { extractDomain, isDomainAllowed } from '../utils/domain-matcher.js';
import { redactValue } from '../utils/redaction.js';
import { audit } from '../utils/audit-logger.js';
import type { SecretPlacement } from '../storage/types.js';

export interface ProxyRequestInput {
  method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  url: string;
  headers?: Record<string, string>;
  body?: string | Record<string, unknown>;
  timeout?: number;
}

export interface ProxyRequestOutput {
  status: number;
  statusText: string;
  headers: Record<string, string>;
  body: string;
  redacted: boolean;
}

export interface ProxyRequestError {
  error: 'SECRET_NOT_FOUND' | 'SECRET_DOMAIN_BLOCKED' | 'SECRET_PLACEMENT_BLOCKED' | 'REQUEST_FAILED';
  message: string;
  hint?: string;
  secret?: string;
  requestedDomain?: string;
  allowedDomains?: string[];
  requestedPlacement?: string;
  allowedPlacements?: string[];
  cause?: string;
}

export const proxyRequestTool = {
  name: 'proxy_request',
  description: 'Make an HTTP request with secure credential substitution. Use {{SECRET_NAME}} placeholders for credentials. The secret value is never exposed to you - it is substituted on the server side.',
  inputSchema: {
    type: 'object' as const,
    properties: {
      method: {
        type: 'string',
        enum: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
        description: 'HTTP method'
      },
      url: {
        type: 'string',
        description: 'Request URL'
      },
      headers: {
        type: 'object',
        additionalProperties: { type: 'string' },
        description: 'Request headers. Use {{SECRET_NAME}} for credentials, e.g., "Authorization": "Bearer {{API_KEY}}"'
      },
      body: {
        type: ['string', 'object'],
        description: 'Request body. Use {{SECRET_NAME}} if placement allows.'
      },
      timeout: {
        type: 'number',
        description: 'Timeout in milliseconds (default: 30000)'
      }
    },
    required: ['method', 'url']
  }
};

const PLACEHOLDER_REGEX = /\{\{([A-Z][A-Z0-9_]*)\}\}/g;

interface PlaceholderInfo {
  name: string;
  placement: SecretPlacement;
  fullMatch: string;
}

function findPlaceholders(input: ProxyRequestInput): PlaceholderInfo[] {
  const placeholders: PlaceholderInfo[] = [];

  // Check headers
  if (input.headers) {
    for (const [, value] of Object.entries(input.headers)) {
      let match;
      while ((match = PLACEHOLDER_REGEX.exec(value)) !== null) {
        placeholders.push({
          name: match[1],
          placement: 'header',
          fullMatch: match[0]
        });
      }
      PLACEHOLDER_REGEX.lastIndex = 0; // Reset regex state
    }
  }

  // Check body
  if (input.body) {
    const bodyStr = typeof input.body === 'string' ? input.body : JSON.stringify(input.body);
    let match;
    while ((match = PLACEHOLDER_REGEX.exec(bodyStr)) !== null) {
      placeholders.push({
        name: match[1],
        placement: 'body',
        fullMatch: match[0]
      });
    }
    PLACEHOLDER_REGEX.lastIndex = 0;
  }

  // Check URL query params
  try {
    const url = new URL(input.url);
    for (const value of url.searchParams.values()) {
      let match;
      while ((match = PLACEHOLDER_REGEX.exec(value)) !== null) {
        placeholders.push({
          name: match[1],
          placement: 'query',
          fullMatch: match[0]
        });
      }
      PLACEHOLDER_REGEX.lastIndex = 0;
    }
  } catch {
    // Invalid URL will be caught later
  }

  return placeholders;
}

async function validatePlaceholder(
  placeholder: PlaceholderInfo,
  targetDomain: string
): Promise<ProxyRequestError | null> {
  const metadata = await getSecretMetadata(placeholder.name);

  if (!metadata) {
    return {
      error: 'SECRET_NOT_FOUND',
      message: `Secret '${placeholder.name}' is not configured`,
      hint: `Use 'credential-proxy add ${placeholder.name}' to configure`
    };
  }

  if (!isDomainAllowed(targetDomain, metadata.allowedDomains)) {
    await audit.secretBlocked(placeholder.name, targetDomain, 'DOMAIN_NOT_ALLOWED');
    return {
      error: 'SECRET_DOMAIN_BLOCKED',
      message: `Secret '${placeholder.name}' cannot be used with domain '${targetDomain}'`,
      secret: placeholder.name,
      requestedDomain: targetDomain,
      allowedDomains: metadata.allowedDomains
    };
  }

  if (!metadata.allowedPlacements.includes(placeholder.placement)) {
    await audit.secretBlocked(placeholder.name, targetDomain, 'PLACEMENT_NOT_ALLOWED');
    return {
      error: 'SECRET_PLACEMENT_BLOCKED',
      message: `Secret '${placeholder.name}' cannot be used in '${placeholder.placement}'`,
      secret: placeholder.name,
      requestedPlacement: placeholder.placement,
      allowedPlacements: metadata.allowedPlacements
    };
  }

  return null;
}

async function substituteSecrets(
  content: string,
  secretValues: Map<string, string>
): Promise<string> {
  let result = content;
  for (const [name, value] of secretValues) {
    result = result.replaceAll(`{{${name}}}`, value);
  }
  return result;
}

export async function handleProxyRequest(
  input: ProxyRequestInput
): Promise<ProxyRequestOutput | ProxyRequestError> {
  const startTime = Date.now();

  // Extract target domain
  let targetDomain: string;
  try {
    targetDomain = extractDomain(input.url);
  } catch (error) {
    return {
      error: 'REQUEST_FAILED',
      message: 'Invalid URL',
      cause: error instanceof Error ? error.message : String(error)
    };
  }

  // Find all placeholders
  const placeholders = findPlaceholders(input);

  // Validate each placeholder
  for (const placeholder of placeholders) {
    const error = await validatePlaceholder(placeholder, targetDomain);
    if (error) {
      return error;
    }
  }

  // Load secret values
  const secretValues = new Map<string, string>();
  const secretNames = [...new Set(placeholders.map(p => p.name))];

  for (const name of secretNames) {
    const value = await getSecret(name);
    if (!value) {
      return {
        error: 'SECRET_NOT_FOUND',
        message: `Secret '${name}' could not be decrypted`,
        hint: 'The secret may be corrupted. Try rotating it.'
      };
    }
    secretValues.set(name, value);
  }

  // Substitute secrets in headers
  const headers: Record<string, string> = {};
  if (input.headers) {
    for (const [key, value] of Object.entries(input.headers)) {
      headers[key] = await substituteSecrets(value, secretValues);
    }
  }

  // Substitute secrets in body
  let body: string | undefined;
  if (input.body) {
    const bodyStr = typeof input.body === 'string' ? input.body : JSON.stringify(input.body);
    body = await substituteSecrets(bodyStr, secretValues);
  }

  // Substitute secrets in URL (for query params)
  const url = await substituteSecrets(input.url, secretValues);

  // Execute request
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), input.timeout ?? 30000);

    const response = await fetch(url, {
      method: input.method,
      headers,
      body: input.method !== 'GET' ? body : undefined,
      signal: controller.signal
    });

    clearTimeout(timeoutId);

    const duration = Date.now() - startTime;

    // Record usage for each secret
    for (const name of secretNames) {
      await recordUsage(name);
      await audit.secretUsed(name, targetDomain, input.method, response.status, duration);
    }

    // Get response body
    let responseBody = await response.text();

    // Redact any secret values that appear in response
    let redacted = false;
    for (const [name, value] of secretValues) {
      const originalLength = responseBody.length;
      responseBody = redactValue(responseBody, value, name);
      if (responseBody.length !== originalLength) {
        redacted = true;
        await audit.secretRedacted(name, originalLength, 1);
      }
    }

    // Convert headers to plain object
    const responseHeaders: Record<string, string> = {};
    response.headers.forEach((value, key) => {
      responseHeaders[key] = value;
    });

    return {
      status: response.status,
      statusText: response.statusText,
      headers: responseHeaders,
      body: responseBody,
      redacted
    };
  } catch (error) {
    return {
      error: 'REQUEST_FAILED',
      message: `Request to ${targetDomain} failed`,
      cause: error instanceof Error
        ? (error.name === 'AbortError' ? `timeout after ${input.timeout ?? 30000}ms` : error.message)
        : String(error)
    };
  }
}
