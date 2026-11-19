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

What 0.25.0 (build 110) ships, written so 0.26–0.28 and an Android app can build on it byte for byte. Everything is
standard: Ed25519 (RFC 8032), X25519 (RFC 7748), HKDF-SHA256 (RFC 5869), ChaCha20-Poly1305 (RFC 8439, 12-byte nonce,
16-byte tag), SHA-256, BIP-39 English, UTF-8 JSON. No Apple-only format anywhere.

### Encodings
- **b64u** = base64url (RFC 4648 §5) **without** padding (decoders should accept padding too). **hex** = lowercase.
- **JSON**: UTF-8, any key order and whitespace on reading. Binary values are b64u strings; dates are unix seconds
  as a JSON number (may have a fraction). Unknown keys must be ignored; an optional key may be absent or `null`. Signatures are always over the exact bytes received, never over re-encoded JSON.

### Seed, keys and account id (`FriendKeys.swift`)
1. **Seed**: 16 random bytes. **Backup code**: the BIP-39 English mnemonic of the seed (12 words): the 128 bits,
   then the first 4 bits of SHA-256(seed), read as twelve 11-bit big-endian numbers indexing the standard 2048-word
   list. The app accepts any case, any separators, and the first four letters of a word.
2. `sign_seed  = HKDF-SHA256(ikm = seed, salt = "haltewekker-seed-v1", info = "sign",  L = 32)` → the Ed25519 private
   key seed (RFC 8032 32-byte secret). Its public key = **signKey** (32 bytes).
3. `agree_priv = HKDF-SHA256(seed, "haltewekker-seed-v1", "agree", 32)` → the X25519 private scalar (clamped as RFC
   7748 does). Its public key = **agreeKey** (32 bytes).
4. `vault_key  = HKDF-SHA256(seed, "haltewekker-seed-v1", "vault", 32)` → a ChaCha20-Poly1305 key.
5. **Account id** = hex(first 16 bytes of SHA-256("haltewekker-account-v1" ‖ signKey)) — 32 hex characters.
6. **Device id**: 16 random bytes in hex, made on each phone at create/restore (one phone at a time per account).
- On iOS the seed and device id are in the Keychain (service `nl.haltewekker.friends`, AfterFirstUnlockThisDeviceOnly);
  the list in Application Support/Friends (excluded from backups).

### Friend card, link and QR
- **Card** = {signKey, agreeKey}. In JSON: `{"s": b64u(signKey), "a": b64u(agreeKey)}`. Packed (links): `k` =
  b64u(signKey ‖ agreeKey) (64 bytes → 86 characters). The account id is always computed from signKey, never sent.
- **App link**: `haltewekker://friend?v=1&k=<k>&n=<name>`. **Share link and QR content**:
  `https://haltewekker-relay.tsfaw1.workers.dev/add#v=1&k=<k>&n=<name>` (the fields after `#` never reach the server;
  the page turns them into the app link). `n` is the UTF-8 name, percent-encoded except `A–Z a–z 0–9 - . _ ~`; readers
  also take `+` as a space. `v` other than 1: not understood. QR: error correction M, byte mode, the share link as text.
- **Names**: control characters removed, whitespace runs → one space, trimmed, at most 40 characters.

### Signed relay requests
- Base `https://haltewekker-relay.tsfaw1.workers.dev`. All routes below are `POST` with a JSON body and these headers:
  `X-HW-Account` (account id), `X-HW-Device` (device id), `X-HW-Time` (unix seconds, within ±300 s of the relay's
  clock), `X-HW-Nonce` (16–64 characters of `[A-Za-z0-9_-]`, never reused: the app uses b64u of 16 random bytes),
  `X-HW-Signature` (b64u of the 64-byte Ed25519 signature by the account's signing key) over the UTF-8 string
  `"HW1\n" + "POST" + "\n" + path + "\n" + account + "\n" + device + "\n" + time + "\n" + nonce + "\n" + hex(SHA-256(body bytes))`
  (`path` like `/f/v1/inbox`, no query). A nonce works once: a signed request must not be retried as is.
- Errors come as `{"error": code}`: 400 (bad input), 401 `clock` / `bad_signature` / `replay`, 404 `unknown_account`,
  409 `signed_out` (the account moved to another device: forget the keys locally and say so), 413, 429 `slow_down`,
  507 `inbox_full`.
- Routes (relay `relay/friends.js`, Durable Object per account with SQLite storage):
  - `/f/v1/register {"signKey": b64u}` → `{"account","created","moved"}`. Signed with that key; the id must match it.
    Another device id moves the account there (that's restore; the old device then gets 409).
  - `/f/v1/send {"boxes":[{"to": account, "data": b64u(box), "slot"?: [a-z0-9._-]{1,32}, "ttl"?: seconds}]}` →
    `{"results":[{"to","ok","id"?,"error"?}]}`. 1–20 boxes per request, to any mix of mailboxes (that's how a group
    message is fanned out); each box ≤ 64 KB decoded; ttl 60 s–30 days (default 30 days). A box with a slot replaces
    the sender's previous box in that slot in that mailbox.
  - `/f/v1/inbox {"after": id, "limit": 1–100}` → `{"boxes":[{"id","from","slot","at","exp","data"}],"cursor","more"}`,
    oldest first. Ids only grow (a replaced slot box gets a new id), so keep `cursor` and pass it as `after`.
  - `/f/v1/ack {"ids":[id]}` → `{"deleted"}`: boxes read go. `/f/v1/drop {"peer"}`: the boxes between you and peer, both
    ways. `/f/v1/block {"peer","on"}`: that account's boxes are refused quietly (sender still sees ok).
  - `/f/v1/vault/put {"data": b64u}` (≤ 128 KB) and `/f/v1/vault/get {}` → `{"data"|null,"at"}`. `/f/v1/leave {}`: the
    account and everything in it deleted. `GET /f/v1/status` → `{"ok":true,"v":1,"storage":true}` (unsigned).
- Limits: 1 MB per request; 60 requests/min and 600 boxes/hour per account; an inbox holds ≤ 1000 boxes / 8 MB, ≤ 200
  from one sender; 20 registers/hour per network address (hashed, kept an hour). Everything expires; an account
  unused for 400 days is deleted. The relay logs nothing of the contents. `node relay/test-friends.mjs [url]` checks it.

### Boxes (`FriendBox.swift`)
- **Payload** (JSON): `{"v":1, "k": kind, "f": sender account, "t": unix seconds, "n": random id (dedupe), "g"?: group
  id, "b": body}`. A `v` above 1: leave the box on the relay (a newer app will read it).
- **Inside** = `signature (64) ‖ payload bytes`, the Ed25519 signature by the sender over
  `"HWBOX1\n" + recipient account + "\n" + payload bytes`.
- **Box** = `0x01 ‖ ephPub (32) ‖ nonce (12) ‖ ChaCha20-Poly1305 ciphertext of the inside ‖ tag (16)`, where `ephPub`
  is a fresh X25519 key per box, the nonce is random, the AAD is the recipient's account id (ASCII), and the key is
  `HKDF-SHA256(ikm = X25519(eph_priv, recipient agreeKey), salt = "haltewekker-box-v1", info = ephPub ‖ recipient agreeKey, 32)`.
- **Opening**: decrypt; parse the payload; `f` must equal the relay's `from`; the signing key is the friend's known
  card — except for `request` and `accept`, which carry the sender's card (its account id must equal `f`); verify the
  signature; drop anything that fails (and ack it).
- **Kinds** (0.25): `request` and `accept` — `b = {"card": card, "name": string, "note"?: string}`; `unfriend` —
  `b = {}` (also takes back a request); `profile` — `b = {"name"}`; `picture` — `b = {"jpeg": b64u(JPEG)}`, a plain
  baseline JPEG, 256×256, ≤ 40 KB, sent with slot `picture` and ttl 30 days, to friends and along with a request or
  accept. A kind you don't know: don't ack it (it stays until it expires).
- **Flow**: scanning/opening a code sends `request` (+ `picture`). The other side accepts → `accept` (+ `picture`); both
  asking → friends. Decline is silent (optionally block). Remove = `drop`, then `unfriend`. A new name → `profile` to
  every friend.
- **Adding kinds** (0.26 `travel`, as built: through the state routes, see As built (0.26); 0.27 `message`, `trip`, groups with `g` and one
  box per member in one send; 0.28 `timetable`/`area` in slots): a case and body in `FriendMessage`, add it to
  `FriendMessage.known` and raise `FriendMessage.kindsVersion` (the app then reads its mailbox from the start once, so
  boxes an older version left unacked are read).
- **Vault** (your own backup on the relay) = `0x01 ‖ nonce (12) ‖ ChaCha20-Poly1305(vault_key, AAD = "hw-vault-v1\n" +
  account)(JSON) ‖ tag`, JSON `{"v":1, "book": {"v":1, "myName", "friends":[{"card","name","since"}],
  "incoming":[{"card","name","at"}], "outgoing":[…same…]}, "picture"?: b64u(JPEG)}`.

### Test vectors (made with Node's crypto from this text; checked in `ios/Tests/FriendVectorTests.swift`)
- Sam: seed `000102030405060708090a0b0c0d0e0f` → backup code `abandon amount liar amount expire adjust cage candy arch
  gather drum buyer`; signKey `3e299fe695cc0d9c74ddf561942c1a7d8f62ea29783f5caa3414644025b420c2`; agreeKey
  `e0191e9cfb5e4b2ccc859180133c42543b4f6ec6007e4b5c50608563f7fac134`; vault key `66cd8d6137776253f8c7b0e625a6fcfb23d7ce0498f85e22f5a2fd51a229e819`;
  account `3c157621a97cf055f5804a9826c6d1e1`; k `Pimf5pXMDZx03fVhlCwafY9i6il4P1yqNBRkQCW0IMLgGR6c-15LLMyFkYATPEJUO09uxgB-S1xQYIVj9_rBNA`.
- Lou: seed `101112131415161718191a1b1c1d1e1f`; signKey `8e8bd8b8e2fe90d2a870daf99b6646c8b744598a3ca840b12d19959bce0743ff`; agreeKey
  `98973049022a31db881258005785a2350c8d5ab34ef695e9726bb2feba3e1f5e`; account `65392c81aa86e697083b0960bf107afb`.
- A request box from Sam to Lou: payload (exact bytes)
  `{"b":{"card":{"a":"4BkenPteSyzMhZGAEzxCVDtPbsYAfktcUGCFY_f6wTQ","s":"Pimf5pXMDZx03fVhlCwafY9i6il4P1yqNBRkQCW0IMI"},"name":"Sam"},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"request","n":"vector-1","t":1800000000,"v":1}`; signature (b64u)
  `u7Zi2kaNq4eocGLTn5-8SvBDPzZpGq5HGqBOkGUVcvp7CdJWlP4ErXRiHUwz_a2QR8WyOHLWD-q2c0ASirOVDw`; eph_priv `202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f` (ephPub
  `358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254`); nonce `404142434445464748494a4b`; box key
  `391a5671a72c601c6dd34c849fc36070762b75c4199b0c4b7181414b6f3b4c8f`; box (b64u):
  `ATWActY2WIDRruoymt-RITg4Ue0hoo47dell0NLNFmJUQEFCQ0RFRkdISUpLhNjroAbjjIoeYOMe5kdazUPO6vUbw6CWi8bBVyPDycUHH100hP5LwyHNKs7M9kvkxy5hOoexAJL6GOvZ9Oi1kVwqOxYRggbgy-5ifJcMbXtaSibw7_JrtYzH1z5XYVbg3qcSmAAdHPDaeO01RZ4vBuq5t8w1bTo7Uaj1oh4xKD1WA1dPJ1VJJNELVrkBVcAbnYjQvG7p7x7x5uIYeGGvGPc-d5Ut9FdPapHC3Xp1lcrVPHA1F29V5tfYLzkOeQbGknEvQp6BCs150iuFeRBoI9x5WqtARgmWuN2de5qaKISfCyOpu-4knj48qm1aviXL97LBUkjJgLQ3d98wnug_TFK4O05Ns9nS8Ss6gJYLL5IT4tcPTiQOvf8Yw_5frIVF3-c187FoofV24Q`
- A signed request by Sam: body `{"after":0,"limit":100}`, device `00112233445566778899aabbccddeeff`, time `1800000000`,
  nonce `vector-nonce-0001` → signature (b64u, deterministic Ed25519)
  `Al3g11GCpgqXzYqJAH61A3JX_sSHiXIGqlOz5l_8bjR_VQe4R-VUQqXc5Q08xmJ_kGsRYmklpNUdKHXMRJbBBg`.
- Sam's vault: plain `{"book":{"friends":[],"incoming":[],"myName":"Sam","outgoing":[],"v":1},"v":1}`, nonce `505152535455565758595a5b` → (b64u)
  `AVBRUlNUVVZXWFlaW53946SaBXtO59uYSRBJF1zTgHIUdVubOEKiCPQ5MEnqVJhxImhJYxfVnyjS4w0TLI9xA_AKoX6RlIIvJ7G5PfhNK7konHLAQ40zqQx-Qhj8QDR6WwPW0HRNmTwNp40`.
- Ed25519 signing in CryptoKit is randomized (still standard); verifiers must not expect deterministic signatures.

### App (0.25)
- `FriendBook` (list, incoming, outgoing; each change returns effects: send / drop / block), `FriendInbox.process`
  (relay boxes → book, acks, kept boxes, pictures, news), `FriendStore` (keychain, file, a pending queue that survives
  restarts, sync), `FriendRelay` (signed requests through `Net`, no retries).
- Checks: app to the front (≤ every 20 s), every 30 s while the Friends screen is open, at the school alarm's
  background refresh. No other loop.
- Entry: Next trip first's bottom bar (Friends replaced Search; the top field still opens Plan), a round button under
  Your week on Live around you, Settings › Friends; badges count requests waiting. Follows the phone's light or dark.
- Not yet: friends' pictures aren't in the vault (after a restore they come back when a friend changes theirs).

## As built (0.26)

What 0.26.0 (build 112) adds: "Travelling now" and the coach. Everything in "As built (0.25)" holds unchanged; this
only adds a box kind, three relay routes and one field in the friend list.

### When a trip is shared (`FriendTravel.swift`, `TravelShareRules`)
- Only while a trip runs (riding, waiting at the first stop, or at a change; not after the last stop) and once you're
  **confirmed on board** for that trip: you started it yourself, or the app matched your bus/train (a vehicle, none
  left to choose between, not "by its timetable"), or you picked it / said "I'm on it" / "none of these". Once
  confirmed it stays so until the trip ends. Never the demo ride.
- Only after the **one-time screen** is answered (it comes up in Friends with the first friend, and on the ride screen
  as a note once you're on board): what friends see and when, with the switch right there (on by default; off = paused).
- To each friend whose **"Show my trips"** switch is on (the default) unless **paused for everyone** (Friends › Your
  trips). A switch turned off mid-trip takes the state back from that friend at the next send.
- Sent on the ride's existing 30 s network tick when 55 s have gone by since the last one, and at once (2 s after it
  settles) when the leg, the vehicle, the stage or the coach changes. No loop of its own; the trip, alarm, wake-at-stop,
  Live Activity and matching only get read. When the trip ends (or sharing goes off) the app calls
  `/f/v1/state/clear`; if that fails it tries again at the next check, and the relay drops it by itself anyway.
- On the same tick (at most once a minute, only with friends) it reads friends' states; also on every check of the
  relay (app to the front, every 30 s while Friends is open, the background refresh).

### The `travel` box
- A normal box (0.25 format), kind `travel`, sent only through the state routes below, never the mailbox (a `travel`
  box found in a mailbox is acknowledged and ignored). `FriendMessage.kindsVersion` is 2.
- Opened only from a **friend** (not a request); anything else is skipped.
- Body (`b`), every key but `state`, `mode`, `from`, `to` optional:
  - `state`: `"riding"` | `"waiting"` (the trip runs, still at the stop) | `"change"` (between two legs; `from`/`to`
    and the line are then the *next* leg's). An unknown value reads as `riding`.
  - `mode`: `"train"` | `"bus"` (a newer app may add `"tram"`, `"metro"`, `"ferry"`).
  - `line` (as shown: `"IC"`, `"SPR"`, `"306"`), `num` (a train's number, `"3512"`), `trip` (the vehicle's trip id as
    Transitous names it: the same id is the same vehicle).
  - `from`, `to`, `dest` (the trip's end when it isn't `to`): `{"name", "lat"?, "lon"?}`. Home is never sent as a
    place: it goes as `{"name":"Home"}` without coordinates.
  - `eta` (arrival at `to`), `end` (arrival at the trip's end): unix seconds.
  - `pos`: `{"lat","lon","acc"?,"at"}`, the phone's last GPS fix (5 decimals, at most 5 minutes old, accuracy under
    500 m), `at` in unix seconds.
  - `leg`, `legs`: this leg (1-based) of how many.
  - `coach`: `{"n","of","front","at"?}`: coach `n` of `of`; `front: true` = counted from the front (the direction the
    train goes, from NS's `rijrichting`), else counted from the left of NS's drawing at station `at` (NS code).
- Freshness (`TravelAge`): fresh while the box's time (`t`, but never later than the relay's `at`) is at most 150 s
  old; then shown greyed as "Last update 08:41"; gone after the relay's `exp`, 600 s, or 20 min past `end`/`eta`.

### Relay routes (signed like every 0.25 route; `relay/friends.js`)
- `/f/v1/state/put {"states":[{"to": account, "data": b64u(box), "ttl"?: seconds}]}` →
  `{"results":[{"to","ok","error"?}]}`. 1–50 per request, each box ≤ 16 KB decoded, ttl 60–900 s (default 300; the app
  sends 360). Replaces your previous state at that friend. The same friend twice in one request: `bad_to`. A friend
  who blocked you: refused quietly (`ok`). An unknown account: `unknown_account`. 3000 states/hour per account; an
  account holds at most 500 states (507 `inbox_full`).
- `/f/v1/state/get {}` → `{"states":[{"from","at","exp","data"}]}`, newest first. Reading doesn't delete (each one is
  replaced by the next or expires). States are not in the mailbox and don't count against its limits.
- `/f/v1/state/clear {"to"?: [account]}` → `{"cleared"}`: takes your state back from those friends; without `to`, from
  everyone you left one with (the relay remembers where, until it expires).
- `drop` and `block` take the states between the two accounts too; `leave` takes yours back first.

### The friend list
- A friend may carry `"trips": false` ("Show my trips" off); absent means on. It's in the vault like the rest.

### The coach (`CoachMap`)
- NS's `/ns/train?num=&station=` drawing: units (`materieeldelen`, each with its `bakken`), platform letters and
  `rijrichting` (`LINKS`: the front is drawn on the left; `RECHTS`: on the right). A unit's coaches are its `bakken`
  count (if NS leaves them out: the train's `lengte` shared out by unit length, at least one).
- Your coach is numbered from the front when the direction is known. Label: "Coach 3 of 6 · front" (halves; the
  middle coach of an odd train is "middle"), or "Coach 3 of 6" without a direction.
- A friend on the same train (their trip id is the vehicle you're on, or a leg of yours still to come) gets NS's
  drawing for *their own* boarding station, finds coach `n` from the front there, and the platform letter nearest
  its middle: "Wait near B, at the front end of the platform". Without letters: "Coach 3 from the front".

### Test vectors (Node's crypto; checked in `ios/Tests/FriendTravelVectorTests.swift`)
- A travel box from Sam to Lou (keys as in 0.25): payload (exact bytes)
  `{"b":{"coach":{"at":"EHV","front":true,"n":3,"of":6},"end":1800004200,"eta":1800003780,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"leg":2,"legs":2,"line":"IC","mode":"train","num":"3512","pos":{"acc":12,"at":1799999990,"lat":51.5112,"lon":5.2874},"state":"riding","to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3512"},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"travel","n":"vector-2","t":1800000000,"v":1}`; signature (b64u) `7PkPXX1XZcPuaJGBWjjmWJhPZv2Z8FlixA7Ddq0nx8x0mU2Gy6q90ZPGYeE7TaryRZL9mhCFNzpPBlSHfhilCw`; eph_priv `606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f`
  (ephPub `675dd574ed7789310b3d2e7681f3790b466c773b1521fecf36577958371ea52f`); nonce `808182838485868788898a8b`; box key `05c9590bb92a41d682e8ac3bf021bf56cf37208db21837c8f04264fb85e4da5c`; box (b64u):
  `AWdd1XTtd4kxCz0udoHzeQtGbHc7FSH-zzZXeVg3HqUvgIGCg4SFhoeIiYqLZXWLBco9z3tfobhx5IFO49FI_IR1QXGidybz-bpO_guAfOgz4G8oLdQIaF5b0bBOaJAf1w41CGfhpE6u9ABuv3dyd--Hzvkjf8lvET3kp0QXZpaPiGlZG04GLRL7cXaLgoA0WoWBO7mYef611woIfWFo_o2GXLiK8YxMongc9PQd2FIQGmhHo-xyrnK2Vy3FMYRJCpwIVDZFO5rLrLrMqzc278Q2jy7rdH468tESk0304xKQXctnPMSHZ2TDfx4TPlyErsc9DpqkRgv9ErPLJJIZDDpPvEi_-ZdeR8WSxaoQsyplZax_d_QwUpXClUC3J19Dqiz7vzptdwqEUOwhcV6i8hUE4EJ48icVvs226zj6HaYBLOayX6naO12GN2K0VikdEJ6gVq7qFXrO5TozyVPwssFx0wsBT1__KhSyL8PdhQH1rc7IFxJEWEs-vblDYPj3aOrao8LRoq1VSc-YIiE_OBac2LeIKmhBYW8PnYVUd5K4axYnbur2FS2Wqv2bt1jJMwH-1HjNkQ8Pu513wljfQCOC0TXDk-6T5TEtxUU9n2c7qnJSmefcV_m5od2Tqvx4yiz3qS9cBnjSmMoMduBGuL1QzHYAuJgQ0e9E7pLcsIFUWoDEWdwlRXxPYrTTkWBUe6A2BiS2qK932vckg-5qkXwc3rVhs4T_FxkakhGpng4J2gKoq-SKAjXprkahwrg`
- A signed `/f/v1/state/put` by Sam: body `{"states":[{"data":"AWdd1XTtd4kxCz0udoHzeQtGbHc7FSH-zzZXeVg3HqUvgIGCg4SFhoeIiYqLZXWLBco9z3tfobhx5IFO49FI_IR1QXGidybz-bpO_guAfOgz4G8oLdQIaF5b0bBOaJAf1w41CGfhpE6u9ABuv3dyd--Hzvkjf8lvET3kp0QXZpaPiGlZG04GLRL7cXaLgoA0WoWBO7mYef611woIfWFo_o2GXLiK8YxMongc9PQd2FIQGmhHo-xyrnK2Vy3FMYRJCpwIVDZFO5rLrLrMqzc278Q2jy7rdH468tESk0304xKQXctnPMSHZ2TDfx4TPlyErsc9DpqkRgv9ErPLJJIZDDpPvEi_-ZdeR8WSxaoQsyplZax_d_QwUpXClUC3J19Dqiz7vzptdwqEUOwhcV6i8hUE4EJ48icVvs226zj6HaYBLOayX6naO12GN2K0VikdEJ6gVq7qFXrO5TozyVPwssFx0wsBT1__KhSyL8PdhQH1rc7IFxJEWEs-vblDYPj3aOrao8LRoq1VSc-YIiE_OBac2LeIKmhBYW8PnYVUd5K4axYnbur2FS2Wqv2bt1jJMwH-1HjNkQ8Pu513wljfQCOC0TXDk-6T5TEtxUU9n2c7qnJSmefcV_m5od2Tqvx4yiz3qS9cBnjSmMoMduBGuL1QzHYAuJgQ0e9E7pLcsIFUWoDEWdwlRXxPYrTTkWBUe6A2BiS2qK932vckg-5qkXwc3rVhs4T_FxkakhGpng4J2gKoq-SKAjXprkahwrg","to":"65392c81aa86e697083b0960bf107afb","ttl":360}]}` (SHA-256 `0c15ebabfaa77e823f6831b5718b0ed587350e01cd3ca08e842971307246ec57`), device `00112233445566778899aabbccddeeff`,
  time `1800000000`, nonce `vector-nonce-0002` → signature (b64u) `TYjw9PyrJ_a6Y0ahTV_e6jnPN_YsdfOobgbhBIJXyLtokJQvQOCicQpl-ZnmZPbFJlCmYLw8vXV8YcZl6ikHAQ`.

### App (0.26)
- `FriendTravelShare` (watches `TripManager`: its published phase, leg, vehicle, choosing, picks; and
  `onNetTick`, one callback on the ride's network tick), `FriendStore.putTravel / clearTravel / fetchTravel`,
  `FriendInbox.readStates`.
- Friends: "Travelling now" on top (a map with their pictures, a row each: "Sam · IC 3512 to Breda · arrives 08:43"),
  Your trips (the switch for everyone), a friend's page with their trip on the map, their coach, and "Show my trips to
  Sam". The ride screen (new look): the question once on board, friends on the same vehicle, the coach picker on a train.
