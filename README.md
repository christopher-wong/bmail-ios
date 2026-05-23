# bmail — iOS client for cfemail

Native SwiftUI client for the cfemail backend at `https://mail.middleseat.vc`. End-to-end encrypted, passkey-only.

## What's implemented

- **Passkey sign-in with WebAuthn PRF** (`ASAuthorizationPlatformPublicKeyCredentialProvider` + `ASAuthorizationPublicKeyCredentialPRFAssertionInput`). PRF output → HKDF-SHA256 → AES-GCM unwrap of the X25519 private key. Mirrors `web/src/lib/webauthn.ts`.
- **Invite enrollment**: paste invite token → register passkey → generate fresh X25519 keypair → AES-GCM-wrap with both PRF and Argon2id derived keys → reveal 12-word recovery phrase exactly once.
- **Recovery-phrase login**: handle + BIP-39 phrase → Argon2id(entropy, server's stored params) → unwrap priv → open sealed proof → /recovery/verify.
- **Add additional passkey** from Settings (re-wraps the in-memory priv with the new passkey's PRF key).
- **Attachments**: file-picker upload with sealed-to-self filenames, per-message attachment listing, sealed-box decryption on download, save-to-temp + iOS share sheet.
- **Draft resume**: tapping a row in Drafts re-opens Compose with the decrypted subject/body/addresses bound to the same draftID, so autosave updates in place.
- **Passkey management**: list `/api/me/passkeys`, per-row REMOVE (server refuses the last one and we surface the 409).
- **Realtime / WebSocket** (`Net/RealtimeClient.swift`): `wss://mail.middleseat.vc/api/realtime` opened through the same `URLSession` as the API (cookie piggybacks the upgrade). 25s "ping" / 75s pong-timeout watchdog, exponential-backoff reconnect (1/2/4/8/16/30s + jitter). Inbox, Drafts and Thread subscribe and refresh on relevant events.
- **Sealed-box decryption** (`Crypto.openSealedBox`). Pure-Swift port of the noble-ciphers construction:
  - X25519 ECDH → HKDF-SHA256(shared, info=`cfemail/sealed-box/v1`) → 32-byte AEAD key
  - XChaCha20-Poly1305 (HChaCha20 subkey derivation in `Crypto/HChaCha20.swift` + CryptoKit `ChaChaPoly`)
  - Wire format: `ephemeral_pub (32) ‖ nonce (24) ‖ ciphertext+tag`
- **Seal-to-self** for draft autosave (deterministic nonce = `SHA512(eph_pub ‖ recipient_pub)[..24]`).
- **BIP-39** 12-word mnemonic gen/parse (pure Swift, English wordlist, SHA-256 checksum) — bit-exact with `@scure/bip39` so phrases round-trip with the web client.
- **API client** (`Net/APIClient.swift`) with shared cookie session, typed errors, async/await.
- **Mailbox shell**: NavigationSplitView with Inbox / Drafts / Sent / Labels / Settings / Admin sections.
- **Read flows**: inbox + thread view decrypt subjects and bodies on the fly.
- **Send flows**: compose with autosaved draft (sealed-to-self) and plaintext send.
- **Admin**: invite creation, user + invite list.

## Dependencies

| package | why |
| --- | --- |
| [tmthecoder/Argon2Swift](https://github.com/tmthecoder/Argon2Swift) (main) | Argon2id recovery wrap, parallelism=4. libsodium's public API pins p=1, which would produce a different key than the web client's `@noble/hashes/argon2` (p=4) — so libsodium isn't usable here. Argon2Swift wraps the canonical [P-H-C/phc-winner-argon2](https://github.com/P-H-C/phc-winner-argon2) reference implementation. |

Everything else (X25519, AES-GCM, HKDF, SHA-256/512, ChaChaPoly) is built on Apple's `CryptoKit`. XChaCha20-Poly1305 = local 30-LOC `HChaCha20` + `CryptoKit.ChaChaPoly`.

## Not yet implemented

- **Push notifications**. The backend has no APNs / push-registration endpoints (only `/api/realtime` over WebSocket), so there's nothing to register against. Native push would require backend work first.

## Manual setup remaining

1. **Apple App Site Association.** Host this file at `https://mail.middleseat.vc/.well-known/apple-app-site-association` (served as `application/json`, no extension):

   ```json
   {
     "webcredentials": {
       "apps": ["L6678C3HLZ.middleseat.bmail"]
     }
   }
   ```

   Without this the system will refuse to create or use a passkey for RP ID `mail.middleseat.vc`. The Cloudflare Worker at `worker/src/router.rs` is a natural place to serve it.

2. **Xcode capability.** The `bmail/bmail.entitlements` file is wired into both Debug and Release configs (CODE_SIGN_ENTITLEMENTS). On first build to a real device, Xcode may prompt you to add the "Associated Domains" capability in Signing & Capabilities; accept it. Simulator runs fine without provisioning changes.

## Layout

```
bmail/
  App/        Theme tokens, AppModel (@Observable), date formatting
  Auth/       PasskeyCoordinator (ASAuthorizationController bridge), AuthService
  Crypto/     CryptoKit-backed crypto layer + HChaCha20/XChaCha20-Poly1305
  Net/        APIClient + Codable models
  Util/       Base64URL, Keychain
  Views/      SwiftUI screens
  bmail.entitlements
  bmailApp.swift  @main entry point
```

## Build

Open `bmail.xcodeproj` in Xcode 16+ and run. Deployment target is iOS 26.5, which gives us the full PRF API surface in `AuthenticationServices`. The Xcode project uses a file-system-synchronized group, so any file added under `bmail/` is picked up automatically.

`xcodebuild -scheme bmail -destination 'generic/platform=iOS Simulator' build` from the repo root works headless.
