# Cloud saves

nx can keep each device's save in your own storage bucket and start every game with the newest save of it, whichever
device it's from. Any S3-compatible storage works: Backblaze B2, Cloudflare R2, AWS S3, a MinIO server at home. It
works on macOS and iOS / iPadOS for now (the code is portable; other platforms need an HTTPS transport).

## How it works

- **Each device has its own file per game** in the bucket: `<game>/<device>.nxsave` (`acnh/iPhone-3fa2.nxsave`): the
  save's folders as one tar compressed with zstd, with the device's name, when it was saved, the game's version and
  a SHA-256 of the save as the file's metadata. A device only ever writes its own file, so two devices can't
  overwrite each other's save.
- **Uploads** happen 30 seconds after the game saves (a save is several writes), at most once every 10 minutes while
  playing, and at once when you open the menu, switch the app to the background, restart, switch game or quit. Only a
  save that changed is uploaded.
- **When a game starts** (the loading screen says "Checking the cloud saves"), nx lists the game's files. If one is
  newer than the save here and from the same version of the game, it's downloaded, its checksum checked, the save
  here is backed up (`save/<game>/backups/<date> - before the save from <device>/`) and replaced. A save from another
  version of the game is never used, since a newer version's save can crash an older one.
- **Played offline on two devices?** The newest save wins when each one starts. The other is in that device's file in
  the bucket, and in the backups of any device it was replaced on: nothing is deleted. The menu's Saves tab also lists
  every device's save, with *Use this save* to take one (it downloads it, backs up the save here and restarts the game).
- Restoring an ordinary backup makes it the newest save: it's uploaded, and the other devices take it when they start.

## Setting it up with Backblaze B2

1. **Create a bucket.** In Backblaze, under *B2 Cloud Storage > Buckets*, choose *Create a Bucket*:
   - a name (unique across all of B2, for example `nx-saves-<something>`);
   - *Files in Bucket*: **Private**;
   - *Default Encryption*: Enable, optionally (free, encrypts the files on Backblaze's disks);
   - *Object Lock*: Disable.
2. **Note its endpoint.** The bucket's card shows it, for example `s3.eu-central-003.backblazeb2.com`.
3. **Limit old versions.** B2 keeps every version of a file by default, and each upload replaces a device's file (23 MB
   for Animal Crossing). In the bucket's *Lifecycle Settings*, pick *Keep prior versions for this number of days*: 7.
   You can still recover any save from the past week in Backblaze's file browser, and the bucket stays at a few hundred
   MB per device.
4. **Make an application key for each device.** Under *Application Keys > Add a New Application Key*:
   - a name (`nx-iphone`, `nx-mac-mini`, ...);
   - *Allow access to Bucket(s)*: only the bucket above;
   - *Type of Access*: Read and Write;
   - the rest left as they are.

   Copy the *keyID* and *applicationKey* straight away: Backblaze shows the application key only once.

   A key per device means a lost or retired device can be cut off (delete its key) without touching the others. nx
   never deletes files. To make keys that can't delete anything either, create them with Backblaze's command line tool
   instead: `b2 key create --bucket <bucket> nx-iphone listBuckets,listFiles,readFiles,writeFiles`.
5. **Write each device's connection line:**

   ```
   s3://<keyID>:<applicationKey>@<endpoint>/<bucket>
   ```

   for example `s3://0051a2b3c4d5e6f0000000002:K005abcdefghijklmnopqrstuvwxyz0@s3.eu-central-003.backblazeb2.com/nx-saves-nathan`.
   A folder in the bucket can follow the bucket's name (`.../nx-saves-nathan/nx`).
6. **On each device**, open the menu (*Saves*, then *Cloud saves*), copy the line, tap *Paste*, then *Connect*.
   Universal Clipboard copies text from a Mac to an iPhone or iPad. The card then shows the bucket, this device's
   name (change it there) and each device's save of the game.

Backblaze's free tier (10 GB stored, and a daily allowance of requests) covers this comfortably.

## Where things are kept

- `nx.ini`: `cloud_sync`, `cloud_endpoint`, `cloud_bucket`, `cloud_folder`, `cloud_key_id`, `cloud_device` (the name
  other devices show), `cloud_device_id` (the device's file name, made once), `cloud_mobile_data` (iOS).
- The application key's secret: the iOS Keychain (this app only, this device only, not synced to iCloud). On macOS,
  `cloud.secret` in the data folder, readable only by your user.
- `save/<game>/.cloud`: which save was last uploaded or downloaded, and when it was saved.

*Disconnect* in the card forgets the key on that device; the bucket's files stay.

## Testing

`LARECOMP_CLOUD=<connection line>` uses that bucket without storing anything (`s3+http://` for a server without
HTTPS), and `LARECOMP_CLOUD_DEVICE=<name>` acts as another device. A local S3 server works:
`moto_server -p 5055` (Python's `moto[server]`), then `LARECOMP_CLOUD=s3+http://test:test@127.0.0.1:5055/<bucket>`.
