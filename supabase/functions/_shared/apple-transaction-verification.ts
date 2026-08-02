// Apple-signed StoreKit transaction and App Store Server Notification checks.
//
// The Apple App Store Server Library verifies the JWS signature and certificate
// chain (including online revocation checks). Only its decoded output is ever
// used to update `iap_entitlements`.

import { Buffer } from "node:buffer";
import {
  Environment,
  SignedDataVerifier,
} from "npm:@apple/app-store-server-library@3.1.0";

// This is deliberately a product-policy contract, rather than accepting every
// product configured in App Store Connect. The SQL entitlement writer enforces
// these same values again at the database boundary.
export const DEADWAX_ENTITLEMENT_POLICY = {
  bundleID: "com.deadwaxclub.app",
  productIDs: ["club.deadwax.supporter.monthly"],
  environments: ["sandbox", "production"],
  verificationSources: [
    "storekit_transaction",
    "app_store_server_notification",
  ],
} as const;

type AcceptedEnvironment =
  (typeof DEADWAX_ENTITLEMENT_POLICY.environments)[number];

function configuredBundleID(): string {
  const configured = Deno.env.get("APPLE_BUNDLE_ID");
  if (configured && configured !== DEADWAX_ENTITLEMENT_POLICY.bundleID) {
    throw new AppleVerificationError(
      "APPLE_BUNDLE_ID does not match the Deadwax bundle",
    );
  }
  return DEADWAX_ENTITLEMENT_POLICY.bundleID;
}

export class AppleVerificationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AppleVerificationError";
  }
}

export interface VerifiedAppleTransaction {
  appAccountToken: string;
  bundleId: string;
  productId: string;
  transactionId: string;
  originalTransactionId: string;
  signedAt: number;
  expiresDate: number | undefined;
  revocationDate: number | undefined;
  environment: AcceptedEnvironment;
}

interface AppleNotification {
  notificationType?: string;
  data?: { signedTransactionInfo?: string };
}

function requiredSecret(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new AppleVerificationError(`Missing ${name} configuration`);
  return value;
}

function appleRootCertificates(): Buffer[] {
  let encodedRoots: unknown;
  try {
    encodedRoots = JSON.parse(requiredSecret("APPLE_ROOT_CERTIFICATES_BASE64"));
  } catch {
    throw new AppleVerificationError(
      "APPLE_ROOT_CERTIFICATES_BASE64 must be a JSON array",
    );
  }
  if (
    !Array.isArray(encodedRoots) || encodedRoots.length === 0 ||
    encodedRoots.some((root) => typeof root !== "string" || root.length === 0)
  ) {
    throw new AppleVerificationError(
      "No Apple root certificates are configured",
    );
  }
  return encodedRoots.map((root) => Buffer.from(root, "base64"));
}

function verifier(environment: Environment): SignedDataVerifier {
  const appAppleId = environment === Environment.PRODUCTION
    ? Number(requiredSecret("APPLE_APPLE_ID"))
    : undefined;
  if (
    environment === Environment.PRODUCTION && !Number.isSafeInteger(appAppleId)
  ) {
    throw new AppleVerificationError(
      "APPLE_APPLE_ID must be a valid App Store numeric ID",
    );
  }
  return new SignedDataVerifier(
    appleRootCertificates(),
    true,
    environment,
    configuredBundleID(),
    appAppleId,
  );
}

function normalizeUUID(value: unknown, label: string): string {
  if (
    typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(value)
  ) {
    throw new AppleVerificationError(`${label} must be a UUID`);
  }
  return value.toLowerCase();
}

export function validateVerifiedAppleTransaction(
  payload: Record<string, unknown>,
  environment: AcceptedEnvironment,
): VerifiedAppleTransaction {
  if (payload.bundleId !== DEADWAX_ENTITLEMENT_POLICY.bundleID) {
    throw new AppleVerificationError(
      "Transaction bundle ID does not match this app",
    );
  }
  if (
    typeof payload.productId !== "string" ||
    !DEADWAX_ENTITLEMENT_POLICY.productIDs.some((productID) =>
      productID === payload.productId
    )
  ) {
    throw new AppleVerificationError("Transaction product ID is not supported");
  }
  const declaredEnvironment = String(payload.environment ?? "").toLowerCase();
  if (declaredEnvironment !== environment) {
    throw new AppleVerificationError(
      "Transaction environment does not match its verifier",
    );
  }
  const transactionId = payload.transactionId;
  if (typeof transactionId !== "string" || transactionId.length === 0) {
    throw new AppleVerificationError(
      "Transaction is missing its transaction ID",
    );
  }
  const originalTransactionId = payload.originalTransactionId;
  if (
    typeof originalTransactionId !== "string" ||
    originalTransactionId.length === 0
  ) {
    throw new AppleVerificationError(
      "Transaction is missing its original transaction ID",
    );
  }
  const signedAt = numericMillis(payload.signedDate);
  if (signedAt == null) {
    throw new AppleVerificationError("Transaction is missing its signed date");
  }
  return {
    appAccountToken: normalizeUUID(
      payload.appAccountToken,
      "Transaction appAccountToken",
    ),
    bundleId: DEADWAX_ENTITLEMENT_POLICY.bundleID,
    productId: payload.productId,
    transactionId,
    originalTransactionId,
    signedAt,
    expiresDate: numericMillis(payload.expiresDate),
    revocationDate: numericMillis(payload.revocationDate),
    environment,
  };
}

function numericMillis(value: unknown): number | undefined {
  if (value == null) return undefined;
  const numeric = typeof value === "string" ? Number(value) : value;
  return typeof numeric === "number" && Number.isFinite(numeric)
    ? numeric
    : undefined;
}

async function verifyWithEnvironment<T>(
  verify: (candidate: SignedDataVerifier) => Promise<T>,
): Promise<{ value: T; environment: AcceptedEnvironment }> {
  const candidates: Array<[Environment, AcceptedEnvironment]> = [
    [Environment.PRODUCTION, "production"],
    [Environment.SANDBOX, "sandbox"],
  ];
  let lastError: unknown;
  for (const [appleEnvironment, environment] of candidates) {
    try {
      return { value: await verify(verifier(appleEnvironment)), environment };
    } catch (error) {
      lastError = error;
    }
  }
  console.error("Apple signed data verification failed", lastError);
  throw new AppleVerificationError(
    "Apple could not verify the signed transaction",
  );
}

export async function verifyAppleTransaction(
  signedTransactionInfo: unknown,
): Promise<VerifiedAppleTransaction> {
  if (
    typeof signedTransactionInfo !== "string" ||
    signedTransactionInfo.split(".").length !== 3
  ) {
    throw new AppleVerificationError(
      "signedTransactionInfo must be a compact JWS",
    );
  }
  const result = await verifyWithEnvironment((candidate) =>
    candidate.verifyAndDecodeTransaction(signedTransactionInfo)
  );
  return validateVerifiedAppleTransaction(
    result.value as Record<string, unknown>,
    result.environment,
  );
}

export async function verifyAppleNotification(signedPayload: unknown): Promise<{
  notificationType: string | undefined;
  transaction: VerifiedAppleTransaction;
}> {
  if (
    typeof signedPayload !== "string" || signedPayload.split(".").length !== 3
  ) {
    throw new AppleVerificationError("signedPayload must be a compact JWS");
  }
  const result = await verifyWithEnvironment((candidate) =>
    candidate.verifyAndDecodeNotification(signedPayload)
  );
  const notification = result.value as AppleNotification;
  const signedTransactionInfo = notification.data?.signedTransactionInfo;
  if (!signedTransactionInfo) {
    throw new AppleVerificationError(
      "Verified notification does not contain transaction information",
    );
  }

  // Verify the nested transaction separately. The outer notification and the
  // transaction must agree on the verified environment.
  const transaction = await verifyAppleTransaction(signedTransactionInfo);
  if (transaction.environment !== result.environment) {
    throw new AppleVerificationError(
      "Notification and transaction environments differ",
    );
  }
  return { notificationType: notification.notificationType, transaction };
}

export function entitlementStatus(
  expiresAt: string | null,
  revokedAt: string | null,
  notificationType?: string,
): "active" | "expired" | "revoked" {
  if (
    revokedAt || notificationType === "REFUND" || notificationType === "REVOKE"
  ) return "revoked";
  if (notificationType === "EXPIRED") return "expired";
  if (expiresAt && new Date(expiresAt).getTime() <= Date.now()) {
    return "expired";
  }
  return "active";
}

export function dateFromMillis(value: number | undefined): string | null {
  return value == null ? null : new Date(value).toISOString();
}
