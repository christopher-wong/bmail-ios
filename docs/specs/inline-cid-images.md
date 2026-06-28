# Spec: Inline `cid:` image support (Content-ID)

Status: proposed
Owners: server (worker) + iOS client (this repo)
Related: PR #3 (client now blanks unrenderable `cid:` images instead of showing broken boxes)

## Problem

Corporate signatures (Outlook/Exchange) embed their logo as an **inline MIME
part referenced by Content-ID** — the HTML body contains
`<img src="cid:image001.png@01DA...">` and the bytes ride along as a separate
attachment part whose MIME header is `Content-ID: <image001.png@01DA...>`.

Today the client can't render these:

1. The attachment list (`GET /api/messages/{id}/attachments` →
   `AttachmentView`) carries **no Content-ID**, so there's no way to map a
   `cid:` reference to the attachment that holds its bytes.
2. The sandboxed renderer's CSP is `img-src data:`, so a raw `cid:` URL is
   blocked → previously a broken-image box, now (PR #3) blanked to a
   transparent pixel.

Result: signature logos and other inline images render as empty space. HEY and
every native mail client show them.

**These images are not a privacy risk** — the bytes live in our own
end-to-end-encrypted store, not on a remote server. So inline `cid:` images
should load **automatically**, independent of the remote-image gate (which
exists only to defeat tracking pixels / IP leaks from `http(s)` images).

## Goal

Let the client resolve `cid:` references to locally-stored encrypted
attachment bytes and inline them into the message body as `data:` URIs, while
hiding those inline parts from the visible "Attachments" list.

Scope: **inbound display** only. Composing/sending inline images is a separate
follow-up (see [Out of scope](#out-of-scope)).

---

## Server changes (worker repo)

### 1. Data model (attachments table)

Add two nullable columns:

| column            | type    | notes                                                              |
| ----------------- | ------- | ----------------------------------------------------------------- |
| `content_id_ct`   | blob    | The part's Content-ID, **sealed-to-self** (same scheme as filename). Null when the part had no Content-ID. |
| `is_inline`       | boolean | True when the part is `Content-Disposition: inline` **or** has a Content-ID referenced by a `cid:` in the body. Default false. |

Migration: additive, both nullable/defaulted. Existing rows get
`content_id_ct = NULL`, `is_inline = false` → old messages keep current
behavior (client blanks the image). No backfill required.

### 2. Ingestion (inbound MIME parse)

The worker already parses inbound MIME to split out attachments and seal
subject/body/snippet/filename. Extend that pass:

- For each part, read the `Content-ID` header. **Normalize**: strip the
  surrounding angle brackets, trim whitespace. Store the normalized value
  sealed to the recipient's public key (same X25519 sealed-box used for
  `filename_ct`), as `content_id_ct`.
- Set `is_inline = true` when the part is `Content-Disposition: inline`, or
  when its (normalized) Content-ID appears as a `cid:` target anywhere in the
  HTML body. Otherwise false.
- No change to how bytes are stored — inline parts are sealed and stored in R2
  exactly like regular attachments.

**Why seal the Content-ID?** It can embed the original filename
(`image001.png@…`) and we keep the server zero-knowledge for message
internals, consistent with `filename_ct`. If the team decides cid tokens are
non-sensitive, a plaintext `content_id` column is an acceptable simpler
variant — but the client decrypt path is trivial either way, so prefer
sealing.

### 3. API contract (`openapi.json`)

Extend `components.schemas.AttachmentView` with two optional fields (the list
endpoint `attachments_list_for_message` returns these; no new endpoints, no
new required fields):

```jsonc
"AttachmentView": {
  "type": "object",
  "required": ["id", "r2_key", "mime", "size_bytes", "created_at"],
  "properties": {
    // …existing fields…
    "content_id_ct_b64": { "type": ["string", "null"] },
    "is_inline":         { "type": "boolean", "default": false }
  }
}
```

- `content_id_ct_b64`: base64url of the sealed Content-ID (mirrors
  `filename_ct_b64`). Null when absent.
- `is_inline`: not in `required`; absent/false for old servers and old rows.

Download is unchanged: the client still fetches sealed bytes from
`GET /api/attachments/{attachment_id}` and seal-opens them locally.

---

## Client changes (this repo)

All additive; gated on the new fields being present.

1. **`bmail/Net/Models.swift`** — add to `AttachmentRow`:
   ```swift
   let content_id_ct_b64: String?
   let is_inline: Bool?   // optional for back-compat with old servers
   ```
   (Regenerate `bmail/Net/Generated/Types.swift` from the updated
   `openapi.json`.)

2. **`bmail/Views/ThreadView.swift`** — `DecodedAttachment` / `loadAttachments`:
   decrypt `content_id_ct_b64` with `app.priv` (same call as filename:
   `Crypto.openSealedString`) into a `contentID: String?`, carry `isInline`,
   and build a `cid → attachmentID` map per message. Pass it into
   `MessageBodyView`.

3. **`bmail/Views/Components/RemoteImages.swift`** — when rewriting `<img>`,
   resolve a `cid:` src against the map:
   - normalize the reference (strip `cid:` prefix, percent-decode, drop any
     `<>`, lowercase) and compare to the normalized decrypted Content-ID;
   - on hit, leave a placeholder the body view fills with the fetched
     `data:` URI; on miss, keep current behavior (blank pixel).

4. **`bmail/Views/Components/MessageBodyView.swift`** — fetch + inline cid
   bytes **eagerly and unconditionally** (no privacy gate): for each matched
   cid attachment, `AttachmentService.shared.download(id:)` →
   `Crypto.openSealedBox(raw, priv:)` (the same seal-open used in
   `ThreadView.downloadAndShare`) → `data:<mime>;base64,…`. Run this in the
   same `withTaskGroup` that handles remote-image proxying. cid images are
   local, so they load on open regardless of the "Load images" setting.

5. **`ThreadView.MessageCard`** — exclude `is_inline` attachments from the
   visible "Attachments" chip list so the signature logo doesn't also show as
   a downloadable file.

### cid matching normalization (both sides must agree)

- Strip `< >` from the MIME `Content-ID` before sealing (server) and before
  comparing (client).
- On the client, for `src="cid:TOKEN"`: drop the `cid:` scheme,
  percent-decode, strip any stray `<>`, compare **case-insensitively** to the
  decrypted Content-ID.
- Fallback: if exactly one inline image part exists and exactly one
  unresolved `cid:` remains, map them 1:1 (handles malformed/missing
  Content-IDs). Otherwise leave unresolved → blank.

---

## Backward compatibility

- New `AttachmentView` fields are optional → old clients ignore them; new
  clients treat absent `is_inline` as false and absent `content_id_ct_b64` as
  "no cid" (current blank behavior).
- Pre-migration messages have null Content-ID → unchanged behavior.
- No change to the download or upload paths.

## Edge cases

- **Large inline images**: data-URI base64 inflates ~33%. Cap inlining at a
  sane size (e.g. ≤ 2 MB decoded); above it, fall back to blank + leave it in
  the attachment list. Signatures are tiny, so this only guards abuse.
- **cid referenced but part missing** (forwarded/stripped mail): no map hit →
  blank pixel.
- **Same cid referenced multiple times**: fetch once, reuse the data URI.
- **Non-image inline parts**: only inline `image/*` MIME types; others stay in
  the attachment list.

## Testing

- Server: unit-test MIME parse extracts + normalizes Content-ID and sets
  `is_inline` for `disposition: inline` and for cid-referenced parts; round
  trip a real Outlook signature fixture.
- Client: snapshot/integration test that a body with `cid:` + a matching
  inline attachment renders the logo and omits it from the attachment list;
  that an unmatched `cid:` blanks cleanly; that remote `http(s)` images still
  honor the privacy gate.

## Out of scope

- **Sending inline images** from Compose. Would extend `AttachmentRef` in
  `SendReq` with `content_id` + inline disposition and have the worker emit
  `Content-ID`/`Content-Disposition: inline` parts. Separate spec.
- Changing the remote (`http(s)`) image privacy model — unchanged; see PR #3
  discussion (proxy hides IP/location but block-by-default still defeats
  read-receipt pixels).
