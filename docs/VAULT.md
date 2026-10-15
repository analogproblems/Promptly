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
- The recovery entry wraps the `dek` with a key derived from a 128-bit recovery code shown once at setup, formatted in groups of letters and digits for writing down. `hint` is its first four characters so the user can tell which written-down code belongs to which vault.
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

A decryption failure means the file is corrupt or tampered with. The reader records the file name, skips it, and shows a quiet warning in the sync status. It does not stop syncing other files.

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

Every field keeps its `ts` and tombstones are kept, so a snapshot is simply a pre-merged bag of operations. Readers apply it with the same rules as segments.

A device writes a snapshot when it has more than 20 segments or its segments total more than 256 KiB, and always after enrolling, so a new device immediately provides a complete copy. After writing `NNNNNN.snap` it deletes its own `.seg` files numbered at or below NNNNNN and any of its own older `.snap` files.

A new device, or any device reading from scratch, reads every device's newest snapshot plus every segment numbered above that snapshot, applies everything, and is up to date.

Tombstones are kept indefinitely. They are a few dozen bytes each; the simplicity is worth more than the space.

## 9. Sync algorithm

Each device stores locally, per other device, the highest segment number it has applied and the snapshot it last applied.

**Pull**

1. List `devices/`.
2. For each device folder other than our own: list it, find the newest `.snap` (if any) and all `.seg` files numbered above the last one applied. If a snapshot is newer than what was applied, apply it first.
3. Download, verify, decrypt and apply each in order. Advance the local markers.
4. Listing is cheap and file reads happen only for new files, so a steady-state pull is one list call per device folder.

**Push**

1. If local operations are pending, write them as the next numbered segment into our own folder.
2. On success, mark them flushed. On failure keep them pending; the next push retries with the same number.

**Compact** as in section 8, after a successful push.

**When**: after any local change, debounced by two seconds; when the app comes to the foreground; on pull-to-refresh; every fifteen minutes while the app is open; and via platform background fetch where the OS offers it. A failed sync is retried with exponential backoff up to an hour and shown as a small, dismissible notice. It never interrupts the user.

**Offline**: everything works offline. Changes queue as pending operations and go out when a backend is reachable.

## 10. Backends

A backend implements four operations:

```rust
trait Backend {
    async fn list(&self, dir: &str) -> Result<Vec<Entry>>;          // name, size, optional etag
    async fn get(&self, path: &str) -> Result<Vec<u8>>;
    async fn put_new(&self, path: &str, bytes: &[u8]) -> Result<()>; // must not overwrite
    async fn delete(&self, path: &str) -> Result<()>;
}
```

`put_new` is the only subtle one. Where the backend supports it, a conditional write is used (`If-None-Match: *` on S3 and WebDAV, `O_EXCL` on a filesystem). Where it does not, the per-device naming already guarantees there is no other writer, so a plain write is safe; the condition is belt and braces.

| Backend | How | Credentials | Notes |
|---|---|---|---|
| Local folder | Filesystem | None | Desktop only. Lets Syncthing, rsync, the Dropbox desktop client or anything else do the transport. |
| iCloud Drive | Platform channel to the ubiquity container; appears to the engine as a local folder | Signed-in Apple ID | Recommended default on Apple. The platform side must request download of placeholder files before the engine reads them. |
| Google Drive | REST API, the hidden `appDataFolder` scope or a visible folder | OAuth | Recommended default on Android. |
| SFTP | `russh-sftp` over an existing Promptly host | An identity already in the vault | "Sync to a server you already have." Zero new accounts. |
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

**QR code.** An existing device shows a QR code containing the vault id, the backend type and path, and the `dek`. The new device scans it, signs in to the backend if the backend needs it (iCloud and Drive do; the QR cannot carry that), and pulls. The code is shown for sixty seconds over a dimmed screen, with a reminder that whoever photographs it can read the vault. It is a convenience for two devices in the same hand, not a sharing mechanism.

On enrolment the new device writes a `devices` record (name, platform, enrolled time) and, once its first pull completes, a snapshot, so from then on it is as good a source of truth as any other.

**Removing a device.** From any device, the user marks a device removed. This writes a `del` on its `devices` record. The removed device's folder is deleted by the next device to write a snapshot that already contains everything from it. If the removed device was stolen, the user should also rotate the vault: Promptly generates a new `dek`, rewrites all of this device's data as a fresh snapshot under the new key, writes a new manifest, and deletes the old files. Other legitimate devices see the manifest change and ask for the passphrase again.

## 12. Sharing (teams)

A shared vault is just a second vault in a folder that several people can access: a shared Drive folder, a team bucket, a shared Nextcloud folder. Each person enrols their devices into it with its passphrase. Promptly shows records from each vault with a small badge and lets the user pick which vault a new host goes into. There is no permission system beyond what the storage provides, and that is a feature, because it is one the team already understands. Per-record permissions, if ever wanted, are a later design.

## 13. Export, import and the CLI

`promptly-cli` reads a vault folder and a passphrase and can:

- `inspect`: list devices, segment counts, clock values and warnings.
- `export --json`: produce a single plaintext JSON document of the merged state, including secrets only if `--with-secrets` is passed, with a loud warning.
- `import`: merge a JSON document in as new operations.
- `sync`: run a pull and push against any backend from a script.
- `rotate-passphrase` and `rotate-dek`: as described above.
- `ssh-config`: emit an OpenSSH `config` file from the vault, so the same hosts work in a plain terminal.

The JSON export format is the natural one: the data model from DESIGN.md section 6, one array per collection. It is also how Promptly imports from other apps.

## 14. Failure modes considered

| Situation | What happens |
|---|---|
| Upload cut off mid-file | Cloud APIs upload atomically, so partial files do not appear. On a plain filesystem the writer writes to a temporary name and renames. If a partial file ever does appear, it fails authentication on read and is skipped with a warning; the writer retries the same segment number. |
| Listing lags by minutes | Nothing breaks; the data arrives when the listing catches up. |
| Two devices both compact | Each compacts only its own folder. |
| Device clock wrong | Irrelevant; ordering uses logical clocks. |
| Same record edited on two offline devices | Field-by-field last-writer-wins on reconnect. |
| Backend credentials expire | Sync pauses with a notice; everything else works. |
| Manifest rewritten by two devices at once (a passphrase change race) | The second writer notices the manifest changed under it, aborts, and asks the user to retry. |
| Passphrase forgotten | Recovery key. Failing that, the data is unrecoverable by design. The app says this at setup, twice. |
| Vault folder deleted on the provider | Every device still has the full state locally and offers to recreate the vault with one tap. |
| Old app version meets a newer format | The manifest `format` number gates reading; the app asks the user to update and keeps working locally. |

## 15. Size budget

A host record is about 300 bytes of JSON before compression, a key about 1 KiB, a snippet about 200 bytes. A vault with 300 hosts, 20 keys, 100 snippets, 300 known hosts and full tombstone history comes to roughly 250 KiB of plaintext, around 50 KiB after compression. The free tier of every supported backend exceeds this by several orders of magnitude, which is the whole point.
