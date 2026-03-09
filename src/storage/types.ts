export type SecretSource = 
  | { type: 'encrypted'; encryptedValue: string }
  | { type: '1password'; ref: string };

export interface SecretMetadata {
  source: SecretSource;
  allowedDomains: string[];
  allowedPlacements: SecretPlacement[];
  allowedCommands?: string[];  // For exec proxy - glob patterns like "git *", "npm *"
  createdAt: string;
  lastUsed: string | null;
  usageCount: number;
}

// Legacy format for migration
export interface LegacySecretMetadata {
  encryptedValue: string;
  allowedDomains: string[];
  allowedPlacements: SecretPlacement[];
  createdAt: string;
  lastUsed: string | null;
  usageCount: number;
}

export type SecretPlacement = 'header' | 'body' | 'query' | 'url' | 'env' | 'arg';

export interface SecretsStore {
  version: number;
  secrets: Record<string, SecretMetadata>;
}

export interface SecretInfo {
  name: string;
  sourceType: 'encrypted' | '1password';
  allowedDomains: string[];
  allowedPlacements: SecretPlacement[];
  allowedCommands?: string[];
  configured: boolean;
  createdAt: string;
  lastUsed: string | null;
  usageCount: number;
}

export const CURRENT_VERSION = 2;
