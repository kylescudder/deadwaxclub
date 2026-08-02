import {
  AppleVerificationError,
  validateVerifiedAppleTransaction,
} from "./apple-transaction-verification.ts";

const accountToken = "a9459887-b37d-45d7-b1c8-3eb71f1c70a8";

function verifiedPayload(): Record<string, unknown> {
  return {
    appAccountToken: accountToken,
    bundleId: "com.deadwaxclub.app",
    productId: "club.deadwax.supporter.monthly",
    transactionId: "2000001234567890",
    originalTransactionId: "2000001234567890",
    signedDate: Date.now(),
    environment: "sandbox",
    expiresDate: Date.now() + 60_000,
  };
}

function expectVerificationRejection(
  payload: Record<string, unknown>,
  environment: "sandbox" | "production" = "sandbox",
): void {
  try {
    validateVerifiedAppleTransaction(payload, environment);
  } catch (error) {
    if (error instanceof AppleVerificationError) return;
    throw error;
  }
  throw new Error("Expected Apple verification-policy rejection");
}

Deno.test("accepts the one Deadwax product after cryptographic verification", () => {
  const transaction = validateVerifiedAppleTransaction(
    verifiedPayload(),
    "sandbox",
  );
  if (
    transaction.appAccountToken !== accountToken ||
    transaction.transactionId !== "2000001234567890"
  ) {
    throw new Error("Verified transaction fields were not preserved");
  }
});

Deno.test("rejects forged or mismatched verified-payload claims", () => {
  const wrongBundle = verifiedPayload();
  wrongBundle.bundleId = "com.attacker.otherapp";
  expectVerificationRejection(wrongBundle);

  const wrongProduct = verifiedPayload();
  wrongProduct.productId = "club.deadwax.supporter.yearly";
  expectVerificationRejection(wrongProduct);

  const mismatchedEnvironment = verifiedPayload();
  expectVerificationRejection(mismatchedEnvironment, "production");

  const unsignedMetadata = verifiedPayload();
  delete unsignedMetadata.signedDate;
  expectVerificationRejection(unsignedMetadata);
});
