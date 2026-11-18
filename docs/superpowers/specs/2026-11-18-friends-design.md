# Friends: travel together (design)

Date: 2026-11-18 · Status: approved to build (the user asked to build everything overnight and review in the morning; open questions settled with the recommended picks below)

## Intent

Haltewekker is a commute app for students. The user wants to travel *with* friends: see which friends are on
their way right now and where, plan trips together (same ride, or meet halfway and take the same train), send each
other trips, compare class timetables to find days you can ride together, and find each other on the train.

Who: the user and their student friends, each on their own iPhone with Haltewekker sideloaded (SideStore / free
Apple ID). Friends may live in different towns (e.g. Veghel and Tilburg) and go to the same or different schools.

## Goals

1. **Accounts and friends.** A simple account (a display name, no email or password). Add a friend by scanning their
   QR code in person, or by a link sent through any chat app. Remove a friend at any time.
2. **Traveling now.** While you're on a trip, the friends you allow see that you're travelling, on what (bus 305,
   IC 3512), where you are on the map, and when you arrive. Nothing is shared when no trip is running.
3. **Where I sit.** On a train you can mark your coach in the train drawing (e.g. "coach 3 of 6, front"). Friends
   who will board see it, with which end of the platform to wait at when that can be known.
4. **Send a trip.** Send a friend a ride ("take the 07:41 with me?") or a planned trip for a date ("Thursday: be at
   BUas by 09:00, this way"). They tap it and it becomes their plan, adjusted to their own start where needed.
5. **Messages.** Short messages between friends and in groups, with quick replies ("On the 305", "Running 5 min late", "Save me a
   seat"). One-to-one and groups (see Added by the user).
6. **Compare timetables.** Friends share their **full class timetable** (classes, rooms, start and end times; the
   user chose this over sharing travel times only). The app shows, per day this week and next, both timetables side by
   side and the days and times you can travel together, to school and home.
7. **Meet halfway.** For two friends with different starts (and possibly different schools), find a train you can
   both be on: where each of you boards (e.g. you in Eindhoven, your friend in Tilburg), or a station to meet at
   first, and the rides each of you needs to get there on time. Works from the compare view and from "send a trip".

## Non-goals

- No push notifications: a free Apple ID can't receive them. Messages and requests show when the app is open, when
  it's awake during a trip, or at a background refresh. The UI must say this plainly (e.g. "Arrives when Sam opens
  the app").
- No Sign in with Apple, no email, no phone numbers, no searching for people by name, no public profiles.
- No Android, no web app.

## Anti-goals (a failure even if it works)

- Anyone who isn't your friend can see your location, timetable, messages or trips — including the server.
- Location is shared outside a running trip, or after you turned it off.
- It drains battery or data noticeably (the 0.20.7 battery work and `Thrift` rules must hold).
- It makes the trip, alarm, wake-at-stop or Live Activity less reliable.
- It nags: friend features are opt-in and stay out of the way for someone who never adds a friend.

## Constraints

- **Free Apple ID / sideloaded:** no push, no CloudKit, no Sign in with Apple, no new entitlements.
- **Server:** the existing Cloudflare Worker relay (`relay/worker.js`, deployed by Cloudflare from GitHub main via
  `relay/wrangler.jsonc`, `keep_vars: true`). Storage must need no manual setup by the user: Durable Objects with
  SQLite storage declared in `wrangler.jsonc` (class + binding + migration). The builder must confirm this works on the
  account's plan and with the GitHub deploy before relying on it; fallback is a KV namespace the user creates once
  (then say exactly which click to make).
- **Privacy: end-to-end encrypted.** The server only ever stores locked boxes and can't read any of it.
- **Battery/data:** no new always-on loops. Friend polling piggybacks on the existing ride network tick during trips,
  runs on screen while a friends screen is open, and at the existing background refresh.
- iOS 17 minimum, SwiftUI, new look (DS tokens), XcodeGen project, CI on GitHub Actions is the only compiler. Pure
  logic in Foundation-only files with unit tests (explicit `sources` list in `ios/project.yml`).
- Works for any student (the 0.22–0.24 profile/roles work), not just the Veghel ⇄ BUas corridor.

## Approaches considered

1. **Own relay + end-to-end encrypted mailboxes (chosen by the user).** Durable Objects on the existing relay store
   encrypted blobs addressed to a recipient. All logic (matching, meet halfway, timetable compare) runs on the
   phones. Free, nothing to set up, the most private. Cost: more client work; losing the phone loses the account
   unless a backup code was saved.
2. **Supabase.** Accounts, database and realtime ready-made; faster to build. But a new account, the server can read
   locations and timetables, and free projects pause after a week idle.
3. **Firebase.** Like Supabase, plus a large SDK and a Google account; no help with push.

## Design decisions (made with the user)

- Server approach 1. Full timetable sharing (B). One-to-one messages. Meet halfway included. Coach picker included.

## Proposed design (my calls; the user can correct)

### Identity and keys
- On first use of Friends, the phone makes a random account id and two key pairs with CryptoKit: a signing key
  (Curve25519 signing) and an agreement key (Curve25519 key agreement). Private keys stay in the Keychain
  (this-device-only).
- The server knows only: account id, public keys, and the encrypted boxes. The display name travels only inside
  boxes to friends (and inside the QR/link).
- Requests to the relay are signed (account id + timestamp + body hash), so only the owner can read their mailbox or
  update their shared state. The relay rejects old timestamps (replay).
- **Backup code:** Settings › Friends shows a code (words) that restores the keys on a new phone. Without it, a new
  phone means re-adding friends. Say this once, clearly, when the account is made.

### Adding friends
- "My code" shows a QR (and a share link `haltewekker://friend?...` that also works as a https link to a small page
  telling people to install the app). It carries: account id, both public keys, display name.
- Scanning or opening it sends that person an encrypted **friend request** (containing your own id, keys, name). They
  see it next time their app checks in, and accept or decline. Accepting sends an encrypted "accepted" back. Both
  sides now hold each other's keys.
- Removing a friend deletes their keys locally and tells the relay to drop any boxes between you.

### What gets shared (all encrypted per friend)
- **Traveling now** (only while a trip runs, only to friends with "Show my trips" on, default on per friend once
  added, with a global pause): every ~60 s and on each leg change: the leg (mode, line, vehicle id), from/to stop
  names, live position, ETA at the end, and the chosen coach if set. The relay keeps only the latest one per
  friend, with a short expiry (a few minutes after the last update; deleted when the trip ends).
- **Timetable:** the next two weeks of classes from the user's timetable source (calendar or manual week): day,
  start, end, title, room. Updated when it changes, at most a few times a day. Plus the **start area** needed for
  meet-halfway and ride matching: home's nearest stops and station, and the school (name + coordinates) — not the
  home address. (My call; the user may want to share less.)
- **Messages and trips:** mailbox items, deleted from the relay once fetched, or after 30 days.

### Relay (Durable Objects)
- One Durable Object per account (its mailbox + its shared "latest state" boxes), addressed by account id.
- Routes (names are the builder's call): register keys; post a box to someone; fetch my boxes (since a cursor);
  put/replace my state box for a friend; get the state boxes friends left for me; delete.
- Limits: box size caps (e.g. 64 KB, timetable maybe more), a per-account rate limit, expiry on everything.
  No logs of contents.

### App screens (new look)
- **Friends tab/sheet** (entry from the home and from Settings; the builder picks the cleanest spot): the friend list
  with who's travelling now on top ("Sam · IC 3512 to Breda · arrives 08:43"), a map of travelling friends, "Add
  friend", requests waiting.
- **A friend:** their trip right now (on the map, with coach), the chat, "Compare timetables", "Plan a trip together".
- **Compare timetables:** a week view, both timetables side by side, the days you can travel together highlighted,
  and per day the suggested shared ride there and back (or "meet in Eindhoven at 07:35").
- **Plan together / meet halfway:** pick a day and time (or from compare), see options: same ride from the same stop;
  same train boarding at different stations; meet at a station first. Each option shows both people's rides. "Send
  to Sam" sends it as a trip.
- **Received trip:** a card in the chat: "Take this trip", which becomes their plan (via the existing ChosenRide /
  Be there by plans) and can wake them as usual.
- **Coach picker:** on a train leg (ride screen, the NS train drawing that already exists), tap your coach. Shown to
  friends in their view of your trip and in "Plan together" when both take that train.
- **Messages:** a simple chat with quick replies. Unread count on the Friends entry. In-app banner when one arrives
  while the app is open (existing in-app notice banner).

### Matching logic (on the phone, pure and tested)
- **Same ride:** for a day, both plans' legs are compared by trip id (or line + departure + stop): same vehicle on any
  leg = ride together from where the second one boards.
- **Meet halfway:** given my origin/destination and theirs, and arrival deadlines from both timetables: take my
  candidate train legs; for each station on them, ask whether the friend can reach that station in time to board the
  same train (an arrive-by plan to that station), and that the train still gets both to their destination in time
  (or one changes off it). Rank by least total waiting and fewest changes. Uses Transitous through the existing
  limiter and cache; computed on demand, cached per day.
- **Timetable compare:** per day: both first-class starts and last-class ends; travel-together suggestions to school
  and home with the matching above; free time overlaps as a bonus line.

## Calls made after the builder check (my calls; the user can correct)

- **Same-times-every-week timetables:** the manual week gets an end time per day (optional title), so compare and
  "home together" work for those students too. Calendar users share their real classes. (Small change to
  `ManualWeek`, the setup step and `SetupBackup` keys.)
- **Which trips are shared:** only once you're confirmed on board (the app matched your bus/train, or you started the
  trip yourself / tapped "I'm on it"). An auto-started trip that hasn't matched a vehicle isn't shared. Adding the
  first friend shows a one-time screen saying what friends will see and when, with the switch right there.
- **Backup code:** a short word seed from which both keys are derived. With it a new phone gets your identity *and*
  your friend list back (the list is kept on the relay, encrypted with a key from the same seed). One phone at a time:
  restoring on a new phone signs the old one out.
- **Checking the relay:** 0.25 starts with a relay-only change (new routes added next to the NS ones, nothing about
  them changed). After it deploys from main, the builder checks it from here with test requests to the live relay
  (the NS routes too) before any app work depends on it. If Durable Objects can't be used, the fallback is a KV
  namespace, and the user gets the exact click to make.

- **Server metadata (user left it to the recommended pick):** the relay may see which accounts exchange boxes and
  when, never contents. No sealed-sender / anonymous mailboxes in this project.
- **Start area (recommended pick):** friends see home's nearest stops and station plus the school, never the home
  address.

## Added by the user (2026-11-18, late)

- **Names and profile pictures:** you pick your display name and a profile picture (from Photos, cropped square,
  sent small, e.g. 256 px JPEG, as an encrypted box to each friend; updated when you change it). Friends see them in
  the list, chat, map and compare views. (0.25)
- **Group chats:** groups of friends (everyone in a group must be friends with the creator; members see each other's
  names and pictures in the group). Each message is encrypted separately for every member (fan-out), so the relay
  still sees only boxes. Group name and picture; add/remove members; leave. Quick replies and trip cards work in
  groups too ("take the 07:41 with us?"). (0.27)
- **Compare timetables with more people:** compare 3 (or more) friends at once, e.g. from a group: the week view shows
  every timetable side by side and the rides all of you (or most of you) can share; meet halfway works for 3 starts.
  (0.28)

## Releases (proposed split)

1. **0.25 — Accounts and friends:** keys, backup code, QR/link add, requests, friend list, relay mailboxes. No
   location yet.
2. **0.26 — Traveling now + coach:** live trip sharing to friends, map, coach picker.
3. **0.27 — Messages and sending trips:** chat, quick replies, trip cards, "Take this trip".
4. **0.28 — Timetables, compare and meet halfway.**

Each release ships on its own and leaves trips/alarms untouched.

## Left to the builder

- Exact relay routes, box formats (versioned), crypto construction details within CryptoKit (e.g. a per-box
  ephemeral key agreement + ChaChaPoly/AES-GCM with the sender signature inside).
- Where the Friends entry sits in the home UI; screen layouts within the new look.
- Polling intervals within the battery rules; cursor/expiry numbers.
- How the coach position maps to the platform, given what NS data offers (if no platform position, show "coach 3
  from the front").
- How received trips map onto the existing plan types.

## As built (0.25)

What 0.25.0 (build 109) actually ships, so 0.26–0.28 can build on it.

### Relay (`relay/friends.js`, live since 2026-11-18)
- Storage: one Durable Object per account (class `Friends`, SQLite storage, binding `FRIENDS`, migration `v1`
  `new_sqlite_classes`), addressed `idFromName("a:" + account)`. Tables: `meta` (signKey, device, lastSeen, vault),
  `boxes` (id, sender, slot, at, exp, size, data), `seen` (nonces), `rate`, `blocked`. An alarm deletes expired boxes,
  and the whole account after 400 days unused. No logs of anything.
- Account id: first 16 bytes of SHA-256("haltewekker-account-v1" ‖ Ed25519 public key), hex (32). The relay checks
  the id against the key at register, so ids can't be squatted.
- Every route but `GET /f/v1/status` and `GET /add` is a signed POST with JSON. Headers `X-HW-Account`,
  `X-HW-Device` (32 hex, random per phone), `X-HW-Time` (unix s, ±300 s), `X-HW-Nonce` (16–64 of `[A-Za-z0-9_-]`,
  never reused), `X-HW-Signature` (base64url Ed25519) over
  `"HW1\nPOST\n" + path + "\n" + account + "\n" + device + "\n" + time + "\n" + nonce + "\n" + hex(SHA-256(body))`.
- Routes: `register {signKey}` (same key, another device = the account moves; the old device then gets 409
  `signed_out`), `send {boxes:[{to, data, slot?, ttl?}]}` (≤ 20 boxes per request to any mix of mailboxes, each ≤ 64 KB
  decoded, ttl 60 s–30 days, default 30 days; a `slot` replaces the sender's previous box in that slot),
  `inbox {after, limit}` → `{boxes:[{id, from, slot, at, exp, data}], cursor, more}` (ids only grow; a replaced slot
  box gets a new id), `ack {ids}`, `drop {peer}` (boxes between two accounts, both ways), `block {peer, on}` (quietly
  refused), `vault/put {data}` (≤ 128 KB) / `vault/get`, `leave`.
- Limits: 1 MB per request, 60 requests/min and 600 boxes/hour per account, inbox ≤ 1000 boxes / 8 MB and ≤ 200 per
  sender, 20 registers/hour per network address (hashed). `relay/test-friends.mjs` tests all of it locally
  (node:sqlite) or against a running relay (`node relay/test-friends.mjs <url>`; it makes and deletes two accounts).
- `/add#v=1&k=…&n=…`: a page that opens `haltewekker://friend?…` (the fields stay after the #).

### Keys (`FriendKeys.swift`)
- Backup code: 12 BIP-39 English words for 16 random bytes (checksum in the last word; four letters per word are
  enough). From the seed, HKDF-SHA256 (salt "haltewekker-seed-v1") with info "sign" → Ed25519, "agree" → X25519,
  "vault" → ChaChaPoly key. Seed and device id in the Keychain (`nl.haltewekker.friends`,
  AfterFirstUnlockThisDeviceOnly); the list in Application Support/Friends (excluded from backup).
- Friend card = both public keys; links carry `k` = base64url(sign ‖ agree) and `n` = name.

### Boxes (`FriendBox.swift`)
- Bytes: `0x01 | ephemeral X25519 pub (32) | ChaChaPoly combined`; key = HKDF-SHA256(X25519(eph, recipient agree),
  salt "haltewekker-box-v1", info eph ‖ recipient pub); AAD = recipient account id. Inside: Ed25519 signature (64) over
  `"HWBOX1\n" + recipient account + "\n" + payload`, then the payload JSON
  `{"v":1,"k":kind,"f":sender,"t":unix s,"n":random id,"g":group id (optional),"b":body}`.
- Kinds in 0.25: `request` and `accept` ({card, name, note?}: the only kinds a stranger may send; the card must match
  the sender), `unfriend`, `profile` ({name}), `picture` ({jpeg}: 256 px square, ≤ 40 KB, sent in slot `picture`).
- Adding a kind: a `FriendMessage` case, a body struct, a line in `payload`/`parse`, `FriendMessage.known`, and bump
  `FriendMessage.kindsVersion`. Older apps leave unknown kinds unacknowledged on the relay (until they expire), and an
  app with a higher kindsVersion reads its mailbox from the start once, so nothing sent early is lost.
- Groups (0.27): put the group id in `g` and post one box per member in a single `/f/v1/send` (≤ 20 per request).
  Latest-state kinds (0.26 `travel`, 0.28 `timetable`/`area`) use a slot and a short ttl.
- Vault: `0x01 | ChaChaPoly(vault key, AAD "hw-vault-v1\n" + account)` of `FriendVaultContents {book, picture}`.

### App
- `FriendBook` (list, incoming, outgoing; each change returns effects: send / drop / block), `FriendInbox.process`
  (a batch of relay boxes → book, acks, kept boxes, pictures, news), `FriendStore` (keychain, file, pending queue that
  survives restarts, sync), `FriendRelay` (signed requests through `Net`, no retries: a nonce is single-use).
- Decline is silent (optionally "Decline and block"). Both sides asking = friends. Removing drops the relay boxes
  both ways, then sends `unfriend` so the other app forgets you.
- Checks: app to the front (≤ every 20 s), every 30 s while the Friends screen is open, at the school alarm's
  background refresh. No other loop.
- Entry: Next trip first's bottom bar (Friends replaced Search; the top field still opens Plan), a round button under
  Your week on Live around you, Settings › Friends. Badges count waiting requests. The Friends screen follows the
  phone's light or dark.
- Not yet: friends' pictures aren't in the vault (after a restore they come back when a friend changes theirs).
