# The Promptly vault

This document specifies how Promptly stores and synchronises your data. It is written so that someone other than Promptly could implement a compatible reader or writer. That is the point: the format is open, so your data is never locked in.

## 1. Goals

1. **Works on dumb storage.** The only operations a backend must support are list, read, write a new file, and delete. No locks, no compare-and-swap, no server-side logic. This is what lets iCloud Drive, a WebDAV share and an S3 bucket all work.
2. **No write conflicts, ever.** Two devices must never need to write the same file. Cloud file systems resolve conflicts by duplicating files with "(conflicted copy)" names, which would be a disaster for a database. The design makes it impossible.
3. **Zero knowledge.** The storage provider sees only ciphertext and opaque file names. Vault contents, including host names, never leave the device unencrypted.
4. **Tolerant of eventual consistency.** Cloud listings can lag by minutes. The design converges regardless of order or delay.
5. **Small.** A vault with hundreds of hosts and dozens of keys stays well under a megabyte.
6. **Recoverable.** One file (any device's newest snapshot) plus the passphrase is enough to rebuild everything.

## 2. Mental model

The vault is a folder. Every enrolled device owns a sub-folder inside it and only ever writes there. Each device appends its changes as small, numbered, write-once files. Reading the vault means reading everyone's files and merging them with simple, deterministic rules. Because the merge is deterministic, every device ends up with the same picture no matter which order the files arrive in.

Think of it as each device keeping a diary, and everyone reading everyone's diaries.

## 3. Folder layout

```
Promptly Vault/
  vault.json                              plaintext manifest, no secrets
  devices/
    7f3a9c.../                            one folder per device, named by device id
      000001.seg                          encrypted batch of operations
      000002.seg
      000003.seg
      000003.snap                         encrypted full snapshot as of seq 3
      000004.seg
    b21e04.../
      000001.seg
      ...
```

- **Device id**: 16 random bytes, hex encoded, generated at enrolment. It is the only folder a device ever writes under.
- **Segment** (`NNNNNN.seg`): a batch of operations this device produced, numbered sequentially per device starting at 1. Write-once; never modified.
- **Snapshot** (`NNNNNN.snap`): the complete merged state this device knew at the moment it had written segment NNNNNN. Also write-once. After writing a snapshot, a device deletes its own segments numbered at or below NNNNNN and its own older snapshots. It never touches another device's folder.
- **Manifest** (`vault.json`): format version, vault id, key derivation parameters and wrapped keys. Nothing in it needs secrecy. Written once at creation and rewritten only on a passphrase or recovery key change, by whichever device does that. Such changes are rare and user-initiated, and a lost race is detected and the user asked to retry.

Readers tolerate files appearing out of order and files that vanish between listing and reading (a compaction happened); they simply list again.

## 4. Manifest

```json
{
  "format": 1,
  "vault_id": "8d4b4a1e-....",
  "created_at": "2026-10-15T20:12:04Z",
  "kdf": {
    "alg": "argon2id",
    "salt": "base64...",
    "memory_kib": 65536,
    "iterations": 3,
    "parallelism": 1
  },
  "keys": [
    { "kind": "passphrase", "nonce": "base64...", "wrapped_dek": "base64..." },
    { "kind": "recovery",   "nonce": "base64...", "wrapped_dek": "base64...", "hint": "R7Q2" }
  ]
}
```

- The `dek` (data encryption key) is 32 random bytes generated once per vault. It is what actually encrypts the data.
- The passphrase entry wraps the `dek` with a key derived by Argon2id from the passphrase and the salt.
- The recovery entry wraps the `dek` with a key derived from a 160-bit recovery code shown once at setup, formatted as eight groups of four Crockford base32 characters (so `O`, `I` and `L` are read as the digits they resemble when typed back). `hint` is its first four characters so the user can tell which written-down code belongs to which vault.
- Changing the passphrase rewrites only the passphrase entry. The vault's data is untouched.

## 5. File encryption

Every `.seg` and `.snap` file has the same envelope:

```
bytes 0..4    magic "PVLT"
byte  4       envelope version, currently 1
bytes 5..29   24-byte random nonce
bytes 29..    XChaCha20-Poly1305 ciphertext followed by its 16-byte tag
```

- Key: the vault `dek`.
- Associated data (authenticated but not encrypted): the UTF-8 string `vault_id + "/" + device_id + "/" + file_name`. This binds a file to its place. A file copied into another device's folder or renamed will fail to open, so nobody can replay or shuffle files.
- The plaintext is the JSON described below, compressed with zstd before encryption. JSON compresses roughly five to ten times, so the vault stays tiny.

A decryption failure means the file is corrupt, tampered with, or not yet fully copied by the storage. The reader records the file name, skips it, and shows a quiet warning in the sync status. It does not stop syncing other files: later files from the same device still apply. The skipped file is read again on every pull until it opens or a snapshot from its device replaces it (section 9), so a file that was only half synced loses nothing.

## 6. Operations

Decrypted segment content is a JSON object:

```json
{
  "format": 1,
  "device": "7f3a9c...",
  "seq": 4,
  "ops": [
    { "op": "put", "col": "hosts", "id": "0192f3...", "ts": [812, "7f3a9c..."], "at": "2026-10-15T20:12:04Z",
      "fields": { "label": "web-1", "hostname": "10.0.0.11", "port": 22 } },
    { "op": "del", "col": "snippets", "id": "0192e1...", "ts": [813, "7f3a9c..."], "at": "2026-10-15T20:12:09Z" }
  ]
}
```

- `col` is the collection: `hosts`, `groups`, `identities`, `secrets`, `snippets`, `known_hosts`, `themes`, `settings`, `devices`.
- `put` carries only the fields that changed. A new record is a `put` with all fields.
- `del` is a tombstone for the whole record.
- `ts` is a logical timestamp: a Lamport counter plus the device id as a tiebreaker. The device id makes every timestamp in the system unique, so ordering is total and deterministic.
- `at` is wall-clock time for display only ("edited on iPhone, 2 minutes ago"). It never influences merging.

### Logical clock rules

Each device keeps one counter. Before producing an operation it increments the counter and uses the result. Whenever it reads an operation from any device it sets its counter to the larger of its own value and the one it read. This guarantees that an edit made after seeing another device's edit always sorts after it.

## 7. Merge rules

State is a map from (collection, record id) to a record. Each field remembers the `ts` that last set it, and each record remembers the `ts` of its deletion, if any.

Applying an operation:

- `put`: for each field, if the operation's `ts` is greater than the field's stored `ts`, replace the value and store the new `ts`. If the record was deleted with a `ts` lower than this `put`, the record comes back to life with these fields.
- `del`: if the operation's `ts` is greater than the record's deletion `ts`, mark the record deleted at that `ts`. Fields with a lower `ts` are hidden; fields set later resurrect the record.

Because every rule is "higher ts wins" and timestamps are unique, applying the same operation twice, or applying operations in any order, produces the same result. This is what makes snapshots from several devices safe to apply on top of each other: duplicates are harmless.

Two devices editing the same host at the same time: field by field, the later logical edit wins. Editing different fields of the same host on two devices merges cleanly, which is the common case (rename on the laptop, change the port on the phone).

Record-level conflicts that matter to the user (both devices renamed the same host while offline) are rare enough that no conflict UI is planned. The last edit wins, and the `at` timestamps make it visible in a future history view.

### Records kept on one device

A host or key whose `sync` is `local_only` stays on the device that has it, and so do hardware keys, the secrets these refer to (a host's saved password, a key's private half and its saved passphrase) and any secret marked `local_only` itself. The device works out this set before every sync and keeps it, with a tombstone timestamp for each record: the record's newest `ts` when it was first kept.

- Its operations on these records are never pushed. Its snapshots carry only a tombstone for each, at that timestamp, so a record that was in the vault before disappears from the other devices, and nothing of what is in it now leaves the device.
- Whatever other devices write about these records is not applied here. The local copy is the only one that counts.
- A snapshot goes out as soon as a record joins the set, carrying its tombstone.
- When a record leaves the set (the user switched it back to sync), the device deletes it and writes it again in full straight away. Every field is then newer than the tombstone, so the whole record arrives on the other devices.

## 8. Snapshots

A snapshot is the full merged state as the writing device knew it:

```json
{
  "format": 1,
  "device": "7f3a9c...",
  "seq": 3,
  "clock": 812,
  "records": [
    { "col": "hosts", "id": "0192f3...", "deleted": null,
      "fields": { "label": ["web-1", [812, "7f3a9c..."]], "hostname": ["10.0.0.11", [640, "b21e04..."]] } },
    { "col": "snippets", "id": "0192e1...", "deleted": [813, "7f3a9c..."], "fields": {} }
  ]
}
```

Every field keeps its `ts` and tombstones are kept, so a snapshot is simply a pre-merged bag of operations. Readers apply it with the same rules as segments. A field hidden by the record's deletion (set before it) is left out: it can never show again, and leaving it out means a deleted record's old values do not travel on in every snapshot.

A device writes a snapshot when it has more than 20 segments or its segments total more than 256 KiB, and always after enrolling, so a new device immediately provides a complete copy. After writing `NNNNNN.snap` it deletes its own `.seg` files numbered at or below NNNNNN and any of its own older `.snap` files.

A new device, or any device reading from scratch, reads every device's newest snapshot plus every segment numbered above that snapshot, applies everything, and is up to date.

Tombstones are kept indefinitely. They are a few dozen bytes each; the simplicity is worth more than the space.

## 9. Sync algorithm

Each device stores locally, per other device, the snapshot it last applied, the number below which every segment has been applied, and the segments above that number it has applied already.

**Check the manifest** before anything else, every time. It is one small read.

- Missing: the vault folder, or its manifest, was deleted. Stop without writing anything, because writing would leave a folder no device can join, and offer to set the vault up again (section 14).
- A newer `format`: stop and ask the user to update the app.
- Another `vault_id`: a different vault now lives here. Stop and offer to join it.
- The wrapped keys changed since this device last unlocked (a passphrase change, a new recovery code or a new `dek`): stop and ask for the passphrase. If it unwraps the same `dek`, carry on as before; otherwise join afresh.

**Pull**

1. List `devices/`.
2. For each device folder other than our own: list it, find the newest `.snap` (if any) and all `.seg` files numbered above the last one applied. If a snapshot is newer than what was applied, apply it first.
3. Download, verify, decrypt and apply each segment not applied yet. Merging does not depend on order, so a segment that cannot be read (damaged, still being copied, or not arrived: a mirror can deliver files out of order) is skipped with a warning and the ones after it still apply. The marker only moves past numbers that have all been applied, so the skipped one is tried again next time; once it, or a snapshot covering it, is applied, the marker catches up.
4. Files from a removed device (section 11) numbered above its cut-off are not applied, and a snapshot of its numbered above the cut-off is not applied either. The cut-offs are worked out from everything read in this pull, before anything is applied, so a removal and the files written after it can arrive together. What a device writes about its own removal is ignored.
5. Listing is cheap and file reads happen only for new files, so a steady-state pull is one list call per device folder.

A device that finds its own record marked removed stops syncing at once, before it writes anything, and says so. Everything on it stays and keeps working.

**Push**

1. If local operations are pending, write them as the next numbered segment into our own folder.
2. On success, mark them flushed. On failure keep them pending; the next push retries with the same number.

**Compact** as in section 8, after a successful push.

**When**: after any local change, debounced by two seconds; when the app comes to the foreground (at most once every twenty seconds, since a desktop window does that on every focus); on pull-to-refresh; and every thirty seconds while the app is open (a listing is one cheap call per device folder). Platform background fetch on phones is not done yet. A failed sync is retried after ten seconds, then with the wait doubling after each failure, up to an hour; a successful sync, or one the user asks for, starts the wait over. Failures show as a small notice. They never interrupt the user.

**Offline**: everything works offline. Changes queue as pending operations and go out when a backend is reachable.

## 10. Backends

A backend implements four operations:

```rust
trait Backend {
    async fn list(&self, dir: &str) -> Result<Vec<Entry>>;          // name, size, optional etag
    async fn get(&self, path: &str) -> Result<Vec<u8>>;
    async fn put_new(&self, path: &str, bytes: &[u8]) -> Result<()>; // must not overwrite
    async fn delete(&self, path: &str) -> Result<()>;
    async fn replace(&self, path: &str, bytes: &[u8]) -> Result<()>; // the manifest only
}
```

`replace` is used only for `vault.json`, when the passphrase changes or the vault gets a new `dek`. It writes the new file under a temporary name and renames it over the old one where it can, so the folder always holds one whole manifest. Before replacing, the writer reads the manifest again and gives up if it changed since this device last saw it.

`put_new` is the only subtle one. Where the backend supports it, a conditional write is used (`If-None-Match: *` on S3 and WebDAV, a rename that refuses to replace on SFTP). On a filesystem the file is written under a temporary name and hard-linked into place, which fails if the name exists; where hard links are not supported it is created with `O_EXCL` instead, so an existing file is never replaced either way. Where a backend offers no condition at all, the per-device naming already guarantees there is no other writer, so a plain write is safe; the condition is belt and braces.

A backend that knows of a file it cannot hand over yet lists it anyway and reports it as not downloaded when read. The reader treats it like any other file it cannot read yet: skipped for now, read again next time, never stepped over.

| Backend | How | Credentials | Notes |
|---|---|---|---|
| Local folder | Filesystem | None | Desktop only. Lets Syncthing, rsync, the Dropbox desktop client or anything else do the transport. |
| iCloud Drive | Platform channel to the ubiquity container; appears to the engine as a local folder | Signed-in Apple ID | Recommended default on Apple. A file iCloud has not downloaded yet is a hidden `.NAME.icloud` placeholder; the local folder lists it as NAME and reports it as not downloaded. On a Mac, reading one asks iCloud to fetch it (`brctl download`); iOS has no such command, so there the file waits until the system downloads it. Today a mirrored iCloud folder works through the local folder backend; the platform channel is still to do. |
| Google Drive | REST API, the hidden `appDataFolder` scope or a visible folder | OAuth | Recommended default on Android. |
| SFTP | `russh-sftp` over an existing Promptly host | An identity already in the vault | "Sync to a server you already have." Zero new accounts. A key with a passphrase needs its passphrase saved (as a `key_passphrase` secret that follows the key), since sync cannot ask. |
| Dropbox | HTTP API, app-folder scope | OAuth | |
| OneDrive | Graph API, approot | OAuth | |
| WebDAV | PROPFIND, GET, PUT, DELETE | Username and password or app password | Nextcloud, Synology, Fastmail and many others. |
| S3-compatible | SigV4 via the `object_store` crate | Access key pair | AWS S3, Cloudflare R2, Backblaze B2, MinIO, Garage. The free tiers of R2 and B2 are far larger than a vault will ever need. |
| Git repository | `gix`, pure-Rust git | SSH identity or token | A private GitHub or Gitea repo. Each push is a commit, so history comes free. |
| Device to device | Local network, mDNS discovery, TLS pinned via QR | None | For people who want no cloud at all. A one-shot transfer of the current snapshot. |

Backend credentials themselves (an S3 key, a WebDAV password) are stored as `local_only` secrets in the device keychain, never in the vault, because the vault cannot bootstrap itself from a secret that lives inside it.

The first four backends ship in M2. The rest are additive; each is a few hundred lines because the interface is so small.

## 11. Enrolling a new device

Two ways, both ending with the new device holding the `dek` and knowing where the vault is.

**Passphrase.** The user picks the backend on the new device, signs in to it if needed, and types the vault passphrase. The device reads `vault.json`, derives the wrapping key, unwraps the `dek` and pulls. This always works and needs nothing from other devices.

**Join code.** An existing device shows a QR code, the join code, containing the vault id, the backend type and path, the `dek`, and a fingerprint of the manifest's wrapped keys (its KDF salt and each wrapping's nonce). The new device signs in to the backend if the backend needs it (iCloud and Drive do; the code cannot carry that), takes the code, and pulls. It refuses a code for another vault, and a code whose fingerprint no longer matches `vault.json`: after a passphrase change or a new `dek` the code is out of date and a new one has to be shown.

The code is shown over a dimmed screen with a visible countdown, and closes by itself after sixty seconds, or at once when the app goes to the background, so it is not left up or caught in the app switcher's picture. A reminder says that whoever photographs or copies it can read the vault. Scanning is not in the apps yet, so the code can be copied as text and pasted into the new device's join step. It is a convenience for two devices in the same hand, not a sharing mechanism.

On enrolment the new device writes a `devices` record (name, platform, enrolled time) and, once its first pull completes, a snapshot, so from then on it is as good a source of truth as any other.

**Removing a device.** From any device, the user marks a device removed. This syncs first, then writes a `put` on its `devices` record with two fields: `removed_at` (wall-clock time, for display) and `removed_after`, the number of the last of its files the removing device had applied. From then on every device ignores its files numbered above that cut-off (section 9). Only other devices can set these fields; what a device writes about its own removal is ignored, so it cannot put itself back.

Its folder is tidied up later, not at once: a device writing a snapshot deletes a removed device's folder when it has applied every one of that device's files up to the cut-off, because its snapshot then holds everything that counted. Files it could not read yet hold the folder back until they can be read.

The removed device notices its record on its next sync and stops, telling the user. Its data stays on it. To sync it again, the user disconnects it and joins the vault again, and it joins as a new device, with a new folder and a new device id, kept from then on. Whatever it changed in the meantime goes in with it.

**A new data key.** Removing a device does not take the `dek` away from it, and changing the passphrase does not either: the `dek` stays the same. For a lost or stolen device, the user also gives the vault a new key, from the remove dialog (*Remove and re-key*) or on its own. The device doing it:

1. syncs, so it holds everything every device wrote;
2. generates a new `dek`, wraps it under a passphrase the user picks now and a new recovery code, and replaces `vault.json` (giving up if the manifest changed since it last looked);
3. keeps the new `dek` on the device, encrypts every secret again under it, and writes a snapshot under it, which also deletes its own files under the old key. If that write fails, the next sync writes it.

From then on nothing written can be read with the old key, by a removed device or anyone else who has it. The other devices see the changed keys on their next sync and ask for the passphrase (the same prompt as after a passphrase change). It unwraps the new `dek`. They keep what they have already read, encrypt their secrets again, and write a snapshot under the new key, which replaces their old files. Files under the old key still waiting in another device's folder are reported as unreadable until that device catches up.

## 12. Sharing (teams)

A shared vault is just a second vault in a folder that several people can access: a shared Drive folder, a team bucket, a shared Nextcloud folder. Each person enrols their devices into it with its passphrase. Promptly shows records from each vault with a small badge and lets the user pick which vault a new host goes into. There is no permission system beyond what the storage provides, and that is a feature, because it is one the team already understands. Per-record permissions, if ever wanted, are a later design.

## 13. Export, import and the CLI

`promptly-cli` reads a vault folder and a passphrase and can, as a device of its own (it keeps records marked `local_only` to itself and stops if another device removes it):

- `inspect`: list devices, segment counts, clock values and warnings.
- `export --json`: produce a single plaintext JSON document of the merged state, including secrets only if `--with-secrets` is passed, with a loud warning.
- `import`: merge a JSON document in as new operations.
- `sync`: run a pull and push against any backend from a script.
- `change-passphrase`: wrap the same `dek` under a new passphrase.
- `rotate-dek`: give the vault a new `dek`, under a new passphrase and recovery code, as in section 11.
- `devices list`: every device, with when it joined and was last seen, and whether it was removed. Folders with no record (older copies of the CLI, which keeps no record of its own) are listed too.
- `devices remove <id or name>`, with `--rekey` to run `rotate-dek` straight after: mark a device removed, as in section 11.
- `ssh-config`: emit an OpenSSH `config` file from the vault, so the same hosts work in a plain terminal.

Its own records are encrypted with a key made from the `dek`. When another device gives the vault a new `dek`, its next run asks for the passphrase it last used (or reads it from `PROMPTLY_PREVIOUS_PASSPHRASE`), opens its records with the copies of the manifest it keeps beside them (the current one and the one before), and encrypts them, and the secrets in them, again under the new key, so nothing it kept to itself is lost.

The JSON export format is the natural one: the data model from DESIGN.md section 6, one array per collection. It is also how Promptly imports from other apps.

## 14. Failure modes considered

| Situation | What happens |
|---|---|
| Upload cut off mid-file | Cloud APIs upload atomically, so partial files do not appear. On a plain filesystem the writer writes to a temporary name and links it into place. If a partial file ever does appear (a mirror still copying it, or a filesystem without links), it fails authentication on read and is skipped with a warning, and read again on the next pull until it is whole. |
| Listing lags by minutes | Nothing breaks; the data arrives when the listing catches up. |
| Two devices both compact | Each compacts only its own folder. |
| Device clock wrong | Irrelevant; ordering uses logical clocks. |
| Same record edited on two offline devices | Field-by-field last-writer-wins on reconnect. |
| Backend credentials expire | Sync pauses with a notice; everything else works. |
| Manifest rewritten by two devices at once (a passphrase change race) | A writer that finds the manifest changed since it last read it aborts and asks the user to retry. A plain folder cannot tell two writes at the same moment apart, so then the last one stands, and the other device finds the keys changed on its next sync and asks for the passphrase, as below. |
| Passphrase changed on another device | Every other device notices the rewrapped keys on its next sync, pauses, and asks for the new passphrase. The same `dek` comes out, so it carries on where it was. |
| New `dek` made on another device | Every other device notices the changed keys and asks for the passphrase, as above. A different `dek` for the same vault comes out: the device keeps what it has read, encrypts its secrets again, and writes a snapshot under the new key. |
| A removed device keeps writing | Its files above its cut-off are ignored by every device; once it syncs it sees it was removed and stops. If it still has the old `dek` it can read what was written before a new `dek` was made, never after. |
| Passphrase forgotten | Recovery key. Failing that, the data is unrecoverable by design. The app says this at setup, twice. |
| Vault folder deleted on the provider | Sync pauses and nothing is written, so the folder is not half recreated without its manifest. Every device still has the full state locally and offers to set the vault up again: a new manifest for the same `vault_id` and `dek`, wrapped under a passphrase the user picks, with a new recovery code, and a full snapshot beside it. The other devices then see changed keys and ask for that passphrase. |
| Old app version meets a newer format | The manifest `format` number gates reading, on every sync; the app asks the user to update and keeps working locally. |

## 15. Size budget

A host record is about 300 bytes of JSON before compression, a key about 1 KiB, a snippet about 200 bytes. A vault with 300 hosts, 20 keys, 100 snippets, 300 known hosts and full tombstone history comes to roughly 250 KiB of plaintext, around 50 KiB after compression. The free tier of every supported backend exceeds this by several orders of magnitude, which is the whole point.
