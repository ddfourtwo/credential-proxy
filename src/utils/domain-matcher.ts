/**
 * Check if a domain matches an allowed pattern
 * Supports:
 * - Exact match: "api.linear.app"
 * - Wildcard subdomain: "*.linear.app" (matches any subdomain, but not the root)
 */
export function matchesDomain(domain: string, pattern: string): boolean {
  // Normalize to lowercase
  domain = domain.toLowerCase();
  pattern = pattern.toLowerCase();

  // Exact match
  if (domain === pattern) {
    return true;
  }

  // Wildcard match
  if (pattern.startsWith('*.')) {
    const suffix = pattern.slice(1); // ".linear.app"
    return domain.endsWith(suffix) && domain.length > suffix.length;
  }

  return false;
}

/**
 * Check if a domain is allowed by any pattern in the list
 */
export function isDomainAllowed(domain: string, allowedDomains: string[]): boolean {
  return allowedDomains.some(pattern => matchesDomain(domain, pattern));
}

/**
 * Extract domain from a URL
 */
export function extractDomain(url: string): string {
  try {
    const parsed = new URL(url);
    return parsed.hostname;
  } catch {
    throw new Error(`Invalid URL: ${url}`);
  }
}
