import Foundation

enum DomainMatcher {
    /// Check if a domain matches an allowed pattern.
    /// Supports exact match and wildcard subdomain (`*.example.com` matches `sub.example.com` but not `example.com`).
    static func matchesDomain(_ domain: String, pattern: String) -> Bool {
        let domain = domain.lowercased()
        let pattern = pattern.lowercased()

        if domain == pattern {
            return true
        }

        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(1)) // ".example.com"
            return domain.hasSuffix(suffix) && domain.count > suffix.count
        }

        return false
    }

    /// Check if a domain is allowed by any pattern in the list.
    static func isDomainAllowed(_ domain: String, allowedDomains: [String]) -> Bool {
        allowedDomains.contains { matchesDomain(domain, pattern: $0) }
    }

    /// Extract the host from a URL string.
    static func extractDomain(from urlString: String) -> String? {
        URL(string: urlString)?.host
    }
}
