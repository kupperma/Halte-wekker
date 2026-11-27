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

## As built (0.27)

What 0.27.0 (build 115) adds: chats (one-to-one and groups), trip cards, and "Take this trip". Everything in "As built
(0.25)" and "As built (0.26)" holds unchanged; this only adds box kinds and one optional header use. **No relay change**:
the 0.25 routes already carry all of it (`/f/v1/send` takes up to 20 boxes to any mix of mailboxes, which is a group
message's fan-out; slots replace the newest box per sender per mailbox). `FriendMessage.kindsVersion` is 3.

### The header's `g`
- A group's boxes carry `"g": <group id>` in the payload header (the 0.25 field, until now unused). A group id is 12
  random bytes as 24 lowercase hex characters (so `gr.<id>` fits the relay's 32-character slot).
- **Opening** (0.25 rule extended): the signing key is the friend's card, or (for a sender who isn't your friend) the
  card a **group list** you're in gives for that account (the account id is always SHA-256 of the signKey, so a list
  can't put a wrong signKey on someone). What's then accepted:
  - without `g`: `message`, `trip`, `seen` only from a friend;
  - with `g`: `message`, `trip`, `seen` only from someone on that group's list while you're on it; `group`, `gpicture`
    by the rules below; `gleave` from anyone on the list.
- A box that can't be opened because the sender's card isn't known yet (a group's list may still be on its way) is
  taken off the relay and kept on the phone for 7 days (at most 100), and tried again with each new batch.
- **Order in a batch**: everything but `message`/`trip`/`seen` is read first (in the relay's order), then those (in the
  relay's order), so a list that came in the same batch is known before the lines it lets in.

### Kinds (bodies; every key optional unless said)
- `message` — `b = {"text": string (required), "re": n, "answer": "in" | "cant"}`. Text: UTF-8, no control characters
  but line breaks, at most two line breaks in a row, trimmed, at most 1000 characters (readers clean it the same way and
  drop an empty one). An **answer to a trip card** says the card's `n` in `re` and `answer`; its `text` is the words
  ("I’m in", "Can’t make it") so an app that doesn't know answers still shows something; an `answer` value you don't
  know reads as plain text. Quick replies are plain `message`s ("On the 305", "Running 5 min late", "Save me a seat",
  "Wait for me", "I’m at the stop").
- `trip` — a trip card, `b = {"rides": [ride] (1–8, required), "to": spot (required: where it ends), "from": spot (where
  the sender starts), "start", "end" (leave the door / arrive, unix s), "by" (a planned trip's "be there by", unix s),
  "note" (the sender's line, ≤ 200 characters; absent: the app says "Take the 07:41 with me?" / "Thursday: be at BUas by
  09:00, this way")}`.
  - ride = `{"mode": "train" | "bus" (a newer app may add others; unknown reads as train), "line" (as shown: "IC",
    "305"), "trip" (required: the vehicle's trip id as Transitous names it), "from", "to" (spots), "dep", "arr" (unix s,
    required, arr ≥ dep), "name" ("Intercity"), "num" (a train's number), "head" (headsign), "sdep", "sarr" (scheduled,
    when they differ), "plat", "walk" (minutes of walking before it)}`.
  - spot = `{"name" (required; a stop's name as Transitous gives it), "id" (Transitous stop id), "lat", "lon"}`. Home is
    never sent as a place: `{"name":"Home"}` without coordinates (the friend plans to the last ride's stop instead).
  - A card that breaks these (no rides, more than 8, an arrival before its departure, an empty trip id) is dropped.
- `seen` — `b = {"got": t, "read": t}`: the newest of the *recipient's* lines in that chat (by the recipient's own `t`)
  that the sender has on their phone / has read. Sent with slot `seen` (one-to-one) or `se.<group id>` (with `g`), so
  only the newest waits on the relay; one per writer, only when it moved on. A line of yours counts as delivered/read
  when a mark's value is ≥ its `t`.
- `group` — a group's list, `b = {"name" (required, a cleaned name ≤ 40), "admin" (account, required, on the list), "rev"
  (integer ≥ 1, required, one higher with each change), "members": [{"card": card, "name"}] (required, 1–20 people,
  everyone including the admin, each account once)}`, with `g`, slot `gr.<group id>`, ttl 30 days, sent by the admin to
  every member (on a change: to the old and the new members, so someone taken off learns it).
  - A list for a group you don't have: taken only if the sender is your **friend**, is its `admin`, and you're on it
    (members must be the admin's friends; they needn't be each other's).
  - A list for a group you have: taken only from its current `admin` and only with a higher `rev`. Not on it any more:
    you were **removed** (the chat stays to read; a later list with you on it puts you back). After you **left**, no
    list is taken for that group again (to come back, someone makes a new group).
  - Member names in the list are the admin's names for them (the admin's app updates the list when a friend renames).
- `gpicture` — `b = {"jpeg": b64u}` as `picture` (256×256 baseline JPEG ≤ 40 KB; an empty string takes it away), with
  `g`, slot `gp.<group id>`, only from the admin (others' are ignored).
- `gleave` — `b = {}`, with `g`, from a member to every other member: they're off the list on every phone at once (no
  `rev` change). If they ran it, the first member left on the list runs it now (every phone works this out the same
  way; that member's next list has `rev` + 1).
- Pictures in groups: each member sends their own `picture` (slot `picture`, as 0.25) to the members who aren't their
  friends, when they first share a group; `picture` is accepted from anyone you share a group with.

### Fan-out
- A group line is **one payload** (the same `n`, `t` and `g`) **locked once per member** (signed for each recipient, as
  every box), all posted in one `/f/v1/send` (≤ 20 boxes: a group has at most 20 people, so 19 others). The relay sees
  only N boxes from you to N mailboxes.
- Line ids are `<from>|<n>` (the same box twice is the same line).

### Fetching (no push)
- No new loop: the app's checks of the relay (app to the front, every 30 s while Friends is open, the background
  refresh) now read lines too; **every 8 s while a chat is open** and the app is in front (friends' trips every 30 s of
  those); and the ride's 30 s network tick during a trip does a whole check at most once a minute (it already read
  friends' trips there). The UI says plainly that a line arrives when the other phone opens the app or is on a trip.
- A line that comes in while the app is open: the in-app banner (none for the chat on screen). Fetched in the
  background (a trip's tick, the background refresh): one local notification per chat (`friends-chat-<chat>`); tapping
  it opens that chat.

### "Take this trip" (`TripTake`, tested)
- The **shared ride** is the card's first train, else its longest ride.
- It has left (more than a minute ago): "That bus or train has left already".
- It leaves **within the hour**: Fastest trip opens with the trip as your pick (it watches it and starts the ride when
  you're on board). Your way: the card's rides if you're within 600 m of its first stop; else the planner from where you
  are, arriving by the card's "by" (or its arrival), taking an option that has the shared ride's trip id; else onto the
  shared ride at a stop of its route nearest you (its stops before you'd get off that you may board and it leaves
  more than 2 minutes from now; the nearest two), walking there (< 900 m) or with the planner's way there. Nothing
  fits: Plan opens with where to and "there by" filled in.
- Later **today or tomorrow, to your School or Home** (the card's end within 500 m of it): a Be there by plan at the
  card's "by" (or its arrival), with the option that has the shared ride picked first.
- Anything else (another place, another day): Plan opens with where to and "there by" filled in.
- Taking it answers "I’m in" if you hadn't answered.

### Test vectors (Node's crypto; checked in `ios/Tests/FriendChatVectorTests.swift`)
- Keys as in 0.25, plus **Kim**: seed `202122232425262728292a2b2c2d2e2f`; signKey
  `42dc39acb9621b6cae51150c70a8c2d08bd484060fe11bf1f99a4a21dc9f9582`; agreeKey
  `8494a0fe797543f6b743070880154198b41ce5ca71dccb3f74f1ce8e050d3a4c`; account `9bc64cbb2dab5f14d76c61166b324b98`.
- A message from Sam to Lou: payload (exact bytes) `{"b":{"text":"On the 305"},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"message","n":"vector-3","t":1800000000,"v":1}`; eph_priv
  `a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf`, nonce `c0c1c2c3c4c5c6c7c8c9cacb` → signature (b64u) `C-Wt4CDWC_JyBVNuBtPk1-FVV0yP9g5FRScvJjRJ0SgkyfRf6VjOUIxh-SOHDwcn9Gwb0HB3yYABiE1vVttEDg`; ephPub `605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23c`; box key `3efcf6f8bda00486b5377490e2b37b82d3cc3ed26739c9f8d05edf327b356d93`; box (b64u):
  `AWBacl0qSt_usaKeF-3WIcG3WT7ozbxErGxKtuL4BdI8wMHCw8TFxsfIycrLRqFOo-EkGjQPOnM4XKXDadlG8WQ5tpTwi_0U5Uns-Z1xBiFtYMaIN79Cr8oXgKvrJKpNshS2dROPnVqMF4ZKWKh9X26BUeS2PAG57uU0JIwrOkT31H0vHyJLExZLEdgc8G8V6vIfcUMGLzBBzlP3F08iDF01gGFFCVZ1wpQLZ_rebRG0027r_zRGQrqduN2jMcme7z31aWLls0bxjcI1WO7CRPhIz51mRqY6BHNTiftUnyUDY3ZU2HUHj3EBO1Y2cDIbJg`
- Sam's group list to Lou (group `0123456789abcdef01234567`, slot `gr.0123456789abcdef01234567`): payload
  `{"b":{"admin":"3c157621a97cf055f5804a9826c6d1e1","members":[{"card":{"a":"4BkenPteSyzMhZGAEzxCVDtPbsYAfktcUGCFY_f6wTQ","s":"Pimf5pXMDZx03fVhlCwafY9i6il4P1yqNBRkQCW0IMI"},"name":"Sam"},{"card":{"a":"mJcwSQIqMduIElgAV4WiNQyNWrNO9pXpcmuy_ro-H14","s":"jovYuOL-kNKocNr5m2ZGyLdEWYo8qECxLRmVm84HQ_8"},"name":"Lou"},{"card":{"a":"hJSg_nl1Q_a3QwcIgBVBmLQc5cpx3Ms_dPHOjgUNOkw","s":"Qtw5rLliG2yuURUMcKjC0IvUhAYP4Rvx-ZpKIdyflYI"},"name":"Kim"}],"name":"Uni crew","rev":1},"f":"3c157621a97cf055f5804a9826c6d1e1","g":"0123456789abcdef01234567","k":"group","n":"vector-4","t":1800000000,"v":1}`; eph_priv `d0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeef`, nonce
  `f0f1f2f3f4f5f6f7f8f9fafb` → signature (b64u) `pBsY4bQds41vtaz4g7u3p-_hoHtfyVx84qyUzxpHU_IUKWHSP8h9jZ3ryGMMvaGqf80SDXz04W2GHbnaz3r8Cw`; ephPub `6b3ee67463583cbe3dc08fe9d0765c2666ff5210dd527c9d8705e44927c80d55`; box key `758ec218842a5fd19f9e05fea11e7753846f76f522134946b9709f4d2ebadee6`; box (b64u):
  `AWs-5nRjWDy-PcCP6dB2XCZm_1IQ3VJ8nYcF5EknyA1V8PHy8_T19vf4-fr7kQajN_ueiSFAQU_1PF_phMn7SqcyQOUkHfuuVVyQb3zCY_Q78mmKFMHYUmhGAX1ghsvUdKUoBBG-EvRBuUKUtIx3K37SJa8BKVsrFT6yhtBic79k3gLb2E_y7r1Fh5PgpVI8o5b3JyiWjk0aTBOEEXncwES2AHJmkR44GDRdpVad9xr_8pVFOuHgXdfV8piLGKp5K0GSPaFzNZ25jG1ZNtEeXT25aBag_LEEPJZsOyaOHXYMHddtGnFsokBFh12AaG42Lyr_IvAgluB-LETEKwCMEfiFGBtl-SOi9vrYh-4D78UZMRWjw6GRbK79Y2pgkU_BLN03OZxvO7mjHzzcrnB6FpHRM1BUeP8ftOzLVva4p1dV3sSGWcYy8V9eDeL5G8-BFlVq7lTiKV9ccDPliEOYKeXO2uS1GS3piSzbWsXRMGed9_Kt8Hiv0IeoaiGky-VJV2QtU_Jt0YRu7BbOLr4FuMUNKG7I2C4F3PzKsAkylxyCVUw3dUSR2qGoWcu2sY85bHlHoq_3BYCbGiNNPCDeEbsi6UUApGBeWUmn_xaO6i1ISh8X8-IonqYcc3Fve1Ye6wn5wWaeL_ql6QBsSogf74idv-jjQ_TPXypJN0VSEWvaElcsAv-KQj56SeebJtH1FC-cSvuD43y9QJZueL0gs4xS1J9h82NtAIaiVAppbNDl9GfNde2msMqJNbxaLvEQbOwIDlBi2yLVnlgGPdHlZ4V7myrnMK-3eywOnebPrc61CQfP1LBM8jhQomMYA4unx5xtyx02awDDGnlx8Q-jNCotQTTj1N0EjsU4PApiwaAtEUIhy4thnujUFBzIe0dCreXmLRJlnQm-ESrwfZ1zrGJkiRIPLVPVkFBbPbLikA`
- Kim's line in that group, fanned out (one payload, two boxes): payload `{"b":{"text":"Save me a seat"},"f":"9bc64cbb2dab5f14d76c61166b324b98","g":"0123456789abcdef01234567","k":"message","n":"vector-5","t":1800000060,"v":1}`.
  - To Lou (who isn't Kim's friend: Kim's card from the list): eph_priv
    `0001020304050607080910111213141516171819202122232425262728293031`, nonce `a1a2a3a4a5a6a7a8a9aaabac` →
    signature (b64u) `Jhg6KmEvwF4SdBCDObQIeS3uq8-ZIiQlc0-Q2n2dKTVExpkQTr7xvdUmMeSAgu93_M-AWm_SsLvSIxfaU4Q3Cg`; ephPub `c1e0c8f5681ecdbdfeed4aaa5499ce9754d0f4719a9e0c1781cd78fed23da714`; box key `5079c9de688bad36d193a73ab98f2f54678828ee64965e988768abefe4ad4f97`; box (b64u):
  `AcHgyPVoHs29_u1KqlSZzpdU0PRxmp4MF4HNeP7SPacUoaKjpKWmp6ipqqusROmx4BC81O-NVmsLma46Q0CUd3NKmrHkOWfkSa8yKCHm1OZDiTViVTjXcXkSa7WDl2FS6BBd-h-Hpro_8R6nAHlgfo9-4g_1xrwCZ-Nw_os6KQFFKACdfSxBWOx7oci5R2mtdBslgqqxTNRHbQRb1_ih-J2eCqYDWZolXh9qys-UlU6ErdtHPUMkyLRmhMXGfmC8LcZ6x7mbQiDQYlV7ZcF7FMXyfeIEYqWZsACSGSzaSHOS8F2GDu4UcU1ytROhPpBDj2Dy1p69Xc1MfFVTWGaU0Gs7m9uwFp846SpdQ8mucHtIRXR6`
  - To Sam: eph_priv `3132333435363738394041424344454647484950515253545556575859606162`, nonce
    `b1b2b3b4b5b6b7b8b9babbbc` → signature (b64u) `bAKqe-KrGg2v1BNSYti8EiCsyMWjgU6FWhqZzWZXuUFvkHdyMHEBlEK9ejv5ZQncm0wj_E437snlsUn-SHv9AQ`; ephPub `670e9ff7441bdd5ca886e26ad4e18e9bd9b4edf52219efc071cdc13eee9d8e43`; box key `c753e93d8362807e72e785f78fa0ad24c43947d0c15d497b73aa1e5330f9fc19`; box (b64u):
  `AWcOn_dEG91cqIbiatThjpvZtO31IhnvwHHNwT7unY5DsbKztLW2t7i5uru8X_0tIgokGLQwviDssVFErIKZLgBN4n9Ft_NgAecydT0R0HNxCU-aObfKdaOHukE72nxbw9Gy8Q5KgMc6ZhUbCUZ0p5V_IIN_5IuXJyp1dml47nVifyi9BPswrJao7VRp4BDGYtq5c79B7SAYdDwJxGhrnEyw1aaln2YiZ2BRAf69RN97XCfh0embpOOcsUIBeg07-syRxm5dwbV_XKwhAd3uKBoYD_TXZxI2cqKzDcepW2_IjIP7QRJOlj8nYp30DkWKrvc5hORftcKsUzX14znV2qdVqOJ9rC3TEOqkYenWhZWCScal`
- A trip card from Sam to Lou: payload `{"b":{"by":1800006000,"end":1800005400,"note":"Take the 07:41 with me?","rides":[{"arr":1800004200,"dep":1800001260,"from":{"id":"vector-stop-ehv","lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"line":"IC","mode":"train","name":"Intercity","num":"3512","plat":"4","to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3512"}],"start":1800000900,"to":{"lat":51.5866,"lon":4.7745,"name":"BUas"}},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"trip","n":"vector-6","t":1800000000,"v":1}`; eph_priv
  `4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60`, nonce `d1d2d3d4d5d6d7d8d9dadbdc` → signature (b64u) `_YY3pPeiv3WsTZ3ZZeygo1iajicOqqoD0_w6TwlMRBgIy81h1jlkHHAb_-XcQ_uUaxb9vmdUW6rcP3EB1zGQCA`; ephPub `64b101b1d0be5a8704bd078f9895001fc03e8e9f9522f188dd128d9846d48466`; box key `8f2c28ea802e79215bdb91f010e5b080b7aed30f50c3f2a036a86a1176891f7f`; box (b64u):
  `AWSxAbHQvlqHBL0Hj5iVAB_APo6flSLxiN0SjZhG1IRm0dLT1NXW19jZ2tvcpaSNBO2NCnxoHbkx--22UkdLqhhsh635p0DInyf9QvRoR1cpULartizgPTxXhw1XJpxxnvKFqjs1ha4LCODhIuaxG6DtiYR3fAhainRDLsW0alzRKpSOi8GTm5XfR9CEFIpY-t1K-4NCeSqQmij51Cy1REq4SAd1-b94OekuxLgorNquCM8DTWdhPjTef3HmdAyj1wmaJyXGDbHT162MzM1t5gg1VgJ9Jt4DPu1mBkNE5neZ7PywC3aqmWhb999D7vhHXabuWPzFQGTbheixFbyfBltcHxU-idHXWVaq1uRFZA9VFJatwOQRHQoCTK8tK9akQAWP9B675E9FswCbHxy-9Xp6otJstsA2VuxwimjDcpQ6qb6NbH7hkbIXWCGpCKUNFjo37-ifvvO6zzmILfSlU5oRfGkVLUsA_Yi8rH-HxX0y7FqJHg6wn-LmWEmjZkoqeRn-nWhu4FUqASz1bgA4cuy1F-4JSJoZqBCQXYvzR1Qmpxn22eHBO9JF2UiXmP2HlKglZ59NB10CDDRJfmttE3K4jdDG4WVVyE9h6P17MfAZWSPUfl3i-56IbFsqrsTvslYZtY0h4NaB_aELuMxppojQVdy2TxvSfcjIm2WmNx9VUxYA24JnodKoazK4GP9VAQqCEVGombnhzwgnFzQPMq22fVeUyeqM6U2eW6k-aQH1A8YYGRb4ADeOx8xr9WMkqrpPaaPeBtDSZNUKRaxDjmLGN4dzIgElHXLC9IvilHR0-dOu2ONt-mCKaLcSM13AqwGKxHYW`
- Lou's answer to it (payload only): `{"b":{"answer":"in","re":"vector-6","text":"I’m in"},"f":"65392c81aa86e697083b0960bf107afb","k":"message","n":"vector-7","t":1800000120,"v":1}` (the `’` is U+2019, UTF-8).

### App (0.27)
- Pure, tested: `ChatBook` (lines, unread, marks due, delivery, answers), `GroupBook` (list rules, admin changes,
  leave), `TripCard`/`TripTake`/`TripCardWords`; `FriendInbox.process` reads groups, lines and marks and keeps the
  boxes without a key yet.
- `FriendChats` (the chats file, banners and notifications, sending), `FriendStore` (groups in its file and in the vault
  as `"groups": [{"id","roster","since","out"?}]`, which an older app ignores; fan-out sealing; seen boxes replace
  their slot in the queue), `TripCards`/`TripTaker` (cards from the planner's trips, taking them).
- Screens: Friends › Chats (each chat with what's new, New group), a chat (lines, quick replies, trip cards with "Take
  this trip" / "I’m in" / "Can’t", how far your last line got), a group's page (picture, name, who's in it; the admin
  adds, removes, renames; anyone leaves), a friend's page gets "Message". "Send to a friend" under Fastest trip's trip,
  under Plan's options, on a Be there by plan and on the friend's train. The Friends button's badge counts requests and
  unread lines.
- Not yet: chats aren't in the vault (a restore brings back the friends and groups, not the lines); no read-mark switch.

## As built (0.28)

What 0.28.0 (build 116) adds: timetables and start areas shared with friends, compare (a friend or a whole group),
rides together, and meet halfway. Everything in "As built (0.25)" to "(0.27)" holds unchanged; this only adds two box
kinds and one optional vault field. **No relay change**: both kinds go through `/f/v1/send` with a slot (the newest
replaces the last in that mailbox). `FriendMessage.kindsVersion` is 4. All times are unix seconds; days are
`yyyy-MM-dd` in Europe/Amsterdam.

### The `timetable` box (slot `tt`, ttl 21 days)
- Body: `{"from": t, "to": t, "classes": [class] (0–300), "src"?: "calendar" | "week", "off"?: true}`.
  - `from` is the first day's local midnight (today), `to` the end of the 14th day (exclusive), at most 16 days after
    `from`. A day inside `[from, to)` without classes has **no school**; a day outside it is **not known**.
  - class = `{"start": t (required, in the window), "end"?: t, "title"?: string, "room"?: string}`. `end` is absent
    when not known (a week of first classes without an end time); readers drop an `end` that isn't after `start` or
    is over 12 h after it. Titles ≤ 80 and rooms ≤ 60 characters, control characters removed, whitespace runs →
    one space, trimmed, empty → absent. Sorted by start; at most 300 kept.
  - `"off": true` (with `classes: []`, `from == to`): **taken back** — the reader forgets the sender's timetable and
    area. A window that doesn't make sense (`to ≤ from`, over 16 days) and isn't `off`: the box is dropped.
- Calendar users send every non-all-day, non-cancelled event of the calendars picked for the school alarm (title,
  location as room; nothing over 12 h). Same-times-every-week users send one class per school day: from the first
  class to the day's end time when set, with the day's title.

### The `area` box (slot `area`, ttl 30 days)
- Body: `{"stops": [spot] (0–4, required), "station"?: station, "school": spot (required, with lat/lon), "early"?: 0–60}`.
  - `stops`: the bus stops nearest home, nearest first (spot as 0.27: `{"name","id"?,"lat","lon"}`, `id` a Transitous
    stop id): the home board's stops when the setup knows where they are, else the three nearest non-rail stops
    within 1.2 km of Home (looked up once, again when Home moves 300 m). A stop without lat/lon is dropped.
  - `station`: `{"name","code"?,"id"?,"lat","lon"}`, the NS station nearest Home within 5 km (`code` NS's).
  - `school`: name (the app's short name, e.g. "BUas"), lat/lon (5 decimals), `id` its first Transitous stop id when it
    has one. `early`: minutes the sender likes to be there before class (absent: 10).
  - **Never the home address**: only stops, a station and the school.
- A trip from home starts at the first stop (else the station); to school is to `school.id` (else its lat/lon).

### Who sends, who reads
- Read from a **friend**, or from someone on the list of a group you're in (0.27's group cards); anything else is
  dropped (acked). The newest per sender by the box's `t` wins. Readers keep them only while the sender is a friend or
  in a group with them.
- Sent to: friends (unless "Share my timetable" is off for them, or off for everyone, or the one-time screen wasn't
  answered yet), plus the members of groups where you turned on "Share my timetable with this group" who aren't your
  friends. Someone who had it and no longer should (a switch went off, they left the group) gets an `off` box.
- When (`TimetableShareRules`): at a check of the relay (app to the front, the 30 s Friends tick, the 8 s chat tick,
  the ride's once-a-minute check, the background refresh) the app reads its own timetable at most every 30 minutes, or
  at once when the calendar or the week changed or someone new should get it. The timetable goes to everyone when it
  changed and the last went ≥ 3 h ago, or ≥ 20 h ago whatever (the window moves on daily); to someone who hasn't had
  it, at once, to them only. The area the same, with 7 days instead of 20 h. The fingerprint is FNV-1a 64 over the
  body's JSON (sorted keys). No loop of its own.

### The vault
- `FriendVaultContents` gains `"timetable"?: {"answered"?: bool, "on"?: bool, "off"?: [account], "groups"?: [group id]}`
  (the switches, not the timetables). An older app ignores it.

### Compare (`Compare`, `SharedRides`; on the phone)
- Days: today to Sunday, then next Monday to Sunday; Saturday and Sunday only when someone has class. Per person and
  day: known (the window covers it), the classes, first start, last end (the latest `end`, when it's after the last
  start).
- **Free together**: each person's gaps between classes (overlapping classes merge; a class without an end runs into
  the next), cut where any gap starts or ends; segments where ≥ 2 people are free, merged while the same people;
  ≥ 30 min; the most people first, then the longest; two shown, in time order.
- **Rides together**: per person with class and an area, one planner question per direction: to school arriving by
  first class − `early` (arriveBy, 5 options, ≤ 3 changes); home leaving from 5 min after the last end. A way is
  *usable* to school if it arrives by the bound (+60 s) and no more than 45 min before that person's latest usable
  way; home if it leaves after the bound (−60 s) and no more than 45 min after their earliest. Every leg's trip id of
  every usable way is a vehicle; a vehicle with ≥ 2 people is a shared ride (each person's way: to school the one
  leaving latest, home the one arriving first). Order: most people, then the longest time all are on it at once (last
  boarding to first alighting), then the earliest departure, then trip id. Shown: the best, and others only when they
  bring a set of people that isn't a subset of one shown (at most 3).
- Words: "IC 3512 · 07:41 from Eindhoven Centraal", "With Lisa, you and Sam (gets on at Tilburg 08:03)", and for each
  person not on it "Tom starts 10:45" / "Tom ends 17:15" / "Kim: no classes" / "Kim hasn’t shared this day" /
  "Kim: no start area yet".

### Meet halfway (`MeetHalfway`)
1. Everyone's own ways to school by their bound (first class − early, or a chosen time). The shared rides (as above)
   are the plans; each plan lists who it doesn't fit. Kind: **same ride** (each gets on at their own stop), or **meet
   at** a stop when everyone boards at the same stop (same name, or within 300 m) and someone comes by an earlier leg:
   at the latest arrival of those earlier legs (never after the departure).
2. No shared ride at all: each of the first two people's main ride (the longest leg of their latest usable way) is a
   one-person plan to get the others onto.
3. For the best two plans with someone missing: the vehicle's stops (`/v5/trip`); for each missing person the stops
   before the last rider gets off, where boarding is allowed and it leaves ≥ 10 min from now, nearest their start
   first; for each (at most two) a way on: off at the stop nearest their school if within 1.5 km and there (with the
   walk) by their bound, else onto the rest of one of their own ways that leaves from a stop of the route (≤ 300 m) ≥
   3 min after the vehicle gets there. Their way to the stop: a walk when it's within 900 m of their start, else one
   planner question arriving by its departure − 3 min (the way leaving latest that is there a minute before it).
4. Rank: fewest missing, most riders, least time to spare summed over people, fewest changes, then id. Plans with
   fewer than 2 people aren't shown; at most 4.
- "Send to …" posts a 0.27 trip card to the chat it came from: in a friend's chat the friend's own way (to their
  school, `by` their bound), so "Take this trip" makes it their Be there by plan with the shared ride first; in a group
  your own way (each member takes it from where they are, as 0.27). Its `note`: "Meet halfway: IC 3512 together · Sam
  gets on at Tilburg 08:03".

### Request budget
- Compare screen: at most **24** Transitous planner questions while it's open: the next school day you share is
  looked up by itself (2 per person: there and home; people with the same start, school and time share one), any
  other day only when tapped. Answers kept per question for the day (`WayCache`, Caches/friend-ways.json): 30 min for
  a time within 36 h, else 6 h; plus the planner's own 45 s memo.
- Meet halfway: at most **12** per search (N for everyone's ways, mostly kept from the compare screen; 1 per plan for
  the vehicle's stops; 1 per missing person's way to a stop). For three people ≈ 3 + 2 + 4.
- Your own area: one `/v1/map/stops` question near Home, once (again only if Home moves).

### Test vectors (Node's crypto; checked in `ios/Tests/FriendTimetableTests.swift`)
- A timetable from Sam to Lou (keys as in 0.25): payload (exact bytes)
  `{"b":{"classes":[{"end":1800010800,"room":"C1.02","start":1800004500,"title":"Design"},{"end":1800024300,"start":1800016200,"title":"Maths"}],"from":1799967600,"src":"calendar","to":1801177200},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"timetable","n":"vector-8","t":1800000000,"v":1}`
  (Friday 15 January 2027: Design 10:15–12:00 in C1.02, Maths 13:30–15:45, Amsterdam time; the window to 29 January
  00:00); eph_priv `e0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff`, nonce `0a0b0c0d0e0f101112131415` →
  signature (b64u) `PhtJtWWwYne2jAvNgh5dBivMMs3MYal36jGMHf91URegi3vJOFDnTX0frmmjT9YZbsI9UV-73lkwk2sUBGeMDA`; ephPub
  `736845d54e87de09d6bb114aa7042c50a4a015bd9901d1a0026f5956533a1519`; box key `24ac3b6697d3e534b1d114ee317b401608258e500d3224cac9783a9641cc0cf1`; box (b64u):
  `AXNoRdVOh94J1rsRSqcELFCkoBW9mQHRoAJvWVZTOhUZCgsMDQ4PEBESExQVUxMTxDR2FAxkJX3qhoNrBCJncUIfOfkfJjntZ0pd8fh1vrOGo-Sys35eTTnNHXM-Az3pzc_CH_XS_TIA9hRe6PMo321YrlGo3tfPC10VxchYYlzyAER-DubzI_Ix_3ALwatYL9PW0TmCATUVWG_UBXAbN7fkj8RioTXAa2EmWbWnpt38MYvc6sVFvYKTru2KsvRPZkqpS4wHmndn0-T4FE0g3Ey_vm4YZcw4i4riTdqYUmRFtHjCEpo7AbXb_MXgb4TgPdfZ-m-yX1YLptvqZXDSLx716k3zFL_Po4whHeR8Ds6q7uTZJpvF9uRnSIQgqG_NXv7C95b89-W3kDlBIc8aPhmKfH03cGrgp6wsvK8P-rPOvKdaYs2e30A4g6bFjnGnHRESID5IJog5ROBAQoG1EkrDeGE1SPudxqn5lSW6dNfGtCC1dXB8kGcHOoHCaBBlrH4fdgSCl77ft98vH1Hd_rfeRg6TYh0IhaM`
- Sam's area to Lou: payload
  `{"b":{"early":10,"school":{"lat":51.5866,"lon":4.7745,"name":"BUas"},"station":{"code":"EHV","lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"stops":[{"id":"vector-stop-1","lat":51.4401,"lon":5.4789,"name":"Eindhoven, Station"}]},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"area","n":"vector-9","t":1800000000,"v":1}`;
  eph_priv `1112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30`, nonce `161718191a1b1c1d1e1f2021` →
  signature (b64u) `Ss9LsAU1yEaX78X0NNGZFVbmMGCXyExL5bWwVVSymzYmKLKb_MhS1ygSw5fsTHnDaCSo7OIwxLpf6-TAM0PDDA`; ephPub
  `4d27bcee3135c4944b28d27dd809b07be10c35160d20131caa7e85575498d07c`; box key `4423045437c7bc86a7785ab582f3d1484d4ebebb030362781ef112ebaf53947b`; box (b64u):
  `AU0nvO4xNcSUSyjSfdgJsHvhDDUWDSATHKp-hVdUmNB8FhcYGRobHB0eHyAhU3XtQHq-Kuv74wBPlsCOmaWksIfkUDbPCW0apmIKieezb6cFqAZ63AHeQe4XXFDv76oFbqYeUij9rl0PMQwxkFmNZgK2Mg1oqBp3sDufRowOyjVrcRDaP4obdhOlN9ot0tQ4Iuifd4oCvkFWMc7MhWNZ8eVA0IXLBIlTsRiQoysMZ1CxgTULPogfMBFoCh9g0vu1ZWsd58izUufy1Zl2uL3_X5bnb0_hJuCQrmKMlkzJeIWTVxGQbRiq5ap13GALwBblYhO2Y10ZWjIynlfs1LIFG3E5uKAViR74WGG4inY-wV5asAhgo2VkMJsPV4aLkjZUJxpAF26TVVBXl2K_S95hD66KYH2QqrQp7zy1AnEn6iyP-tz-lg3Rxpf5_8LliKgaRCufXpu0qgq-gJsiiqeHwibhVEBwOQUIZV0couDS9kiCU-tkao2VcGmfgsfxgliM-1R9Dxat4OU8GvYy4t3SwoL6ukAMlKxbSQOArQD2KY5y400LatGpejnkyR_SY9eLh44yqGSg_OrieMUPzKSPwZOd1A`
- Taking it back (payload only): `{"b":{"classes":[],"from":1800000000,"off":true,"to":1800000000},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"timetable","n":"vector-10","t":1800000060,"v":1}`.
- Matching, worked (checked in `ios/Tests/FriendCompareTests.swift`), Monday 18 January 2027, everyone there by 08:50:
  you: bus `b305-0` 06:35–07:05 + IC `ic-3510` 07:11–08:02 (there 08:15), or bus `b305-1` 07:05–07:35 + IC `ic-3512`
  Eindhoven 07:41 – Breda 08:32 (there 08:45); Lisa: `ic-3512` from Eindhoven 07:41; Sam: `ic-3512` from Tilburg
  08:03; Tom (there by 10:35): `ic-3520`. → one shared ride `ic-3512` with Lisa, you and Sam (your second way; 29 min
  all on it); "IC 3512 · 07:41 from Eindhoven Centraal", "Lisa, you and Sam (gets on at Tilburg 08:03)", "Tom starts
  10:45"; meet halfway: same ride. With Lisa instead coming by Sprinter Helmond 07:20–07:33: "Meet at Eindhoven
  Centraal 07:35, then IC 3512 together". Kim (start Tilburg station, going to 51.5930, 4.7790, her own train too late):
  onto `ic-3512` at Tilburg (a walk), off at Breda, 6 min walk, there 08:38.

### Also in 0.28
- **Your week** (`ManualWeek.Day`): `"end"?: minutes after midnight` (after the start) and `"title"?: string`
  (≤ 40), both optional; a week saved before 0.28 reads as it was, and one without them is written as before. It
  lives in `profile.v1`, which "Test the setup" already keeps. Settings › School alarm › Your week and the setup's
  "Same times every week" step set them ("Add end time", "What it is").
- **The home's on-board look backs off** (`OnBoardBackoff`, Thrift.swift): after 6 looks in a row that find nothing
  while you move like a bus or train, one every 2 min until you stop or start moving (or it finds one). Trips, alarms,
  wake-at-stop, the Live Activity and a running trip's matching are unchanged.

### App (0.28)
- Pure, tested: `TimetableShare`/`TimetableArea`/`TimetableShareRules`, `Compare`, `SharedRides`/`RideWords`,
  `MeetHalfway`/`MeetWords`, `RequestBudget`, `OnBoardBackoff`; `FriendInbox.process` reads both kinds.
- `FriendTimetables` (theirs, the switches, yours as read; Friends/timetables.json), `FriendStore.timetableDue` (in
  every check), `CompareModel`/`MeetModel`/`WayCache` (the planner's questions).
- Screens: a friend's page and a group's page get "Compare timetables": who shared, each day this week and next with
  everyone's day, "To school"/"Home" rides together and who's missing, free time together, "Every class" (the day in
  full), "Meet halfway" (pick a day, each first class or a time; each plan with everyone's way and "Send to …").
  Friends › Your timetable (the switch for everyone), the one-time screen, "Share my timetable with Sam" on a friend's
  page, "Share my timetable with this group" on a group's compare.
- Not yet: friends' timetables aren't in the vault (after a restore they come back at their next send, within a day);
  meet halfway plans to school only.

## As built (0.29)

What 0.29.0 (build 118) adds: four Friends extras ("part A"): **Wait for me**, the **delay alarm for shared rides**, the
**wake-up buddy** and **who's on campus**. Everything in "As built (0.25)" to "(0.28)" holds unchanged; this only adds
four box kinds, two answer values and one optional vault field. **No relay change**: every box goes through
`/f/v1/send` with a slot (the newest replaces the last one waiting in that mailbox) and a ttl inside the relay's
60 s – 30 days. `FriendMessage.kindsVersion` is 5. Times are unix seconds; days are `yyyy-MM-dd` in Europe/Amsterdam.
Rides are 0.27's `ride` objects (`{"mode","line","trip","from","to","dep","arr", "num"?, "sdep"?, …}`), spots 0.27's
`spot` (`{"name","id"?,"lat"?,"lon"?}`). No push still: everything arrives at the other phone's next check.

### When anything is sent or read
- Only inside the app's existing checks of the relay (`FriendStore.sync`: app to the front ≤ every 20 s, every 30 s
  while Friends is open, every 8 s while a chat is open, the ride's once-a-minute check during a trip, the background
  refresh) and at region events (School's region, leaving a home region). No loop of its own; the trip, alarm,
  wake-at-stop, Live Activity and matching are only read. Live times for the delay alarm at most every 2 minutes,
  only while a shared ride is due within 90 minutes; planner questions only on a delay or a tap (below).

### `wait` — "Wait for me" (slot `wait`, ttl 900 s)
- Body: `{"id": string (required, 1–32 of [A-Za-z0-9_-], the same in every update), "state": "coming" | "there" | "off"
  (required; unknown reads as coming), "stop": spot (required, with lat/lon), "ride"?: ride, "dist"?: integer metres
  (straight line to the stop, 0–100000), "eta"?: t (when the sender expects to be at the stop), "at": t (required, when
  measured)}`. A ride with an empty trip id or `arr < dep` is dropped from it; a bad id or a stop without a place drops
  the box.
- In a chat: one-to-one without `g` (only from a friend), or a group with `g` (one payload locked per member, from
  someone on its list while you're in it), like 0.27's lines. The newest per sender (by `t`) wins.
- **Sender** (`WaitRules`): started from a trip card in a chat (you sent it or said "I'm in", its shared ride leaves
  within the hour: the card's shared ride and its first stop), from a friend's trip on their page while they wait at a
  stop or change there (their `from`, no ride), or from the ride screen while you're not on board yet (the leg's first
  stop and its planned ride; at a change, the next leg's stop and ride) to a friend or a group. Updated at each check:
  `there` within 40 m, else `coming`; `eta` = now + `BoardAt.walkMinutes(dist)` (a third longer by the streets at
  1.2 m/s, whole minutes up; now when within 40 m), or the bus or train's arrival there when you're riding to that
  stop. Sent when the phase changes, else not within 20 s of the last, then when you moved ≥ 25 m, the eta moved ≥ 60 s,
  or 60 s went by. Over (an `off` box) when you tap "Stop asking", 30 minutes after it started, or 2 minutes after its
  ride left. Position: the trip's last fix (≤ 90 s old, accuracy < 300 m), else one asked for now while the app is in
  front.
- **Reader** (`WaitAge`): fresh for 90 s after `at` (never later than it came), greyed "Last update 08:41" until
  15 minutes, gone then, at `off`, or 5 minutes after its ride's `dep`. Words: "Sam is 2 min from the stop (300 m)"
  (minutes = eta − now, rounded up; "under a minute" at 0), "Sam is 300 m from the stop" (no eta), "Sam is at the stop";
  under it "At Eindhoven Centraal · for the IC 3512 at 07:41", plus "· it leaves before Sam gets there" when eta > dep.
  Distances: tens of metres below 1 km, else "1.2 km". The first box of a wait id: a banner, or (fetched in the
  background) a notification that opens the chat.
- **Answers**: a 0.27 `message` with `re` = the wait's `id` and `answer`: `"wait"` (text "I’ll wait") or `"next"`
  (text "Let’s take the next one together"). An app that doesn't know them shows the text. With `next` the answering
  phone also sends a 0.27 `trip` card for the next ride (`WaitNext`): one planner question from the wait's stop to its
  own destination (its trip's leg from that stop, else the wait ride's `to`) at max(now, eta) + 60 s; the earliest way
  whose first ride gets on within 300 m of the stop at or after that time and isn't the wait's ride, or one of the same
  line instead when it leaves within 15 minutes of that one; note "Take the next one with me? IC 3516 at 08:11".

### `delay` — the delay alarm for shared rides (slot `delay`, ttl 3 h)
- Body: `{"ride": ride (required: as the sender has it, `from` where they get on, `dep` live and `sdep` scheduled
  there), "late": minutes (required, 0–600; 0 when only cancelled), "cancelled"?: true, "next"?: ride (the next ride you
  can all still take, from where the first of you gets on), "who"?: [account] (everyone on it the sender knows of,
  their own too; at most 20 read)}`. Read from a friend or someone sharing a group with you.
- **Shared rides** (`DelayAlarm.shared`): your trip's rides (the vehicle you're on, the next at a change, the planned
  ones still to come) with each friend whose `travel` state has that `trip`; and 0.27 trip cards in your chats from the
  last 24 h that you're in (you sent it, or answered "in") with the sender and everyone else who answered "in", on the
  card's shared ride (first train, else longest; your own ride on it when your trip has that vehicle). Watched while it
  leaves within 90 minutes and hasn't arrived, and someone else is on it.
- **Lateness**: a train at an NS station with its number: NS's board (`/ns/departures`) delay and cancelled; else the
  live data's trip (`/v5/trip`): at your stop (within 300 m, else by name) while it hasn't left there, after that at its
  next stop ahead; cancelled when that stop is, or the whole trip is.
- **Told** (`DelayAlarm.shouldTell`, the same rule as the 0.18 train watch): cancelled when you weren't told so; else
  ≥ 3 min late and ≥ 2 min away from what you were told (never for "back on time"). One record per vehicle, shared by
  what your own phone finds and what friends send, so you hear it once either way. Your phone tells you (banner, or a
  local notification in the background) and sends a `delay` box to everyone else on it.
- **Next ride** (`DelayAlarm.next`, 0.28's matching): on the first alarm for a vehicle, each person's ways from where
  they get on to where they get off it (their `travel` state's from/to, or the card's ride), asked from now + 60 s (5
  options, ≤ 2 changes), one question per distinct pair, at most 4; the ways that use the late vehicle left out;
  `SharedRides.match(…, .home)` (leaving after the bound, within 45 min of each person's earliest); the late one left
  out, only those leaving ≥ 2 min from now; the earliest with everyone, else the earliest with the most (at least two).
  Later alarms for the same vehicle reuse it.
- Words: "IC 3512 is 6 min late" / "Bus 305 is cancelled"; "You, Lisa and Sam are on it. It now leaves Eindhoven
  Centraal at 07:47. Next you can all take: IC 3516 at 08:11 from Eindhoven Centraal." (cancelled without a next: "Look
  for another way in Fastest trip.").

### `buddy` — the wake-up buddy (slot `buddy`, ttl 36 h)
- Body: `{"on": bool (required), "day"?: "yyyy-MM-dd", "leave"?: t (when they plan to leave the door), "ride"?: ride
  (the first bus or train of it), "left"?: t (when they set off that day)}`. `{"on": false}` takes it back. Only from a
  friend; the newest by `t` wins.
- **Opt-in by the friend being watched**: "Tell Sam if I haven't left yet" on Sam's page, off by default, per friend
  (`ExtrasSettings.buddy`). Only those friends get boxes; one switched off gets `{"on":false}`.
- **Sender's plan**: the school alarm's next planned day (leave, its first ride) when it leaves within 24 h; else the
  way to the next first class from the sender's own shared timetable and start area (0.28's question, one planner
  question a day, cached). `left`: set once per day when a trip starts (any trip), when a home region is left, or at a
  check on the plan's day from an hour before leaving when the phone is > 400 m from Home. Sent when it changed (so
  `left` goes at once) or every 12 h, and at once to a friend newly allowed.
- **Watcher** (`BuddyRules`): the plan for today is the buddy box's (day = today) else a trip card in your chats they're
  in (they sent it: its `start`; they answered "in": 15 min before its shared ride). **Moving** if `left`, a `travel`
  state, or a `wait` from them came since an hour before they'd leave. Told when not moving, from 5 min after `leave`
  until 10 min after the ride's `dep` (or 15 min after leaving without a ride), **once per friend per day**: "Lisa isn’t
  moving yet — their train is at 07:41" / "…— they planned to leave at 07:20", body "Lisa planned to leave at 07:20 for
  the IC 3512 from Eindhoven Centraal. Maybe send a message?" (a notification opens their chat). The watcher only knows
  it at its own next check (no push).

### `campus` — who's on campus (slot `campus`)
- Body: `{"on": bool (required), "school"?: the school's short name, "since"?: t, "until"?: t (≤ since + 10 h)}`; ttl
  = until − now (60 s – 10 h). `{"on": false}` (ttl 3600) takes it back. Only from a friend; the newest by `t` wins;
  shown while `on` and now < `until` and until − since ≤ 10 h (+60 s). Never a position.
- **Opt-in**: "Show friends when I'm at school" (Friends › At school), off by default (`ExtrasSettings.campus`); to all
  friends.
- **Inside** (`CampusRules`): School's region (with "Always" location: the switch makes its region tell on entry and
  exit; an exit added only for this never starts a trip), or the last fix at a check (≤ 10 min old): inside within the
  school radius (350 m), outside past it + 150 m, else as it was. Posted once per stay (since = when you got there),
  to friends who haven't had it (a new friend too); taken back when you leave, turn it off, or after 10 h (then not
  again until you've left and come back).
- Words: "On campus now: Tom and Lisa", "At BUas since 09:05".

### The vault
- `FriendVaultContents` gains `"extras"?: {"campus"?: true, "buddy"?: [account]}` (the switches only). An older app
  ignores it. What came (waits, delays, plans, campus) is in Friends/extras.json, not backed up.

### Test vectors (Node's crypto; checked in `ios/Tests/FriendExtrasVectorTests.swift`; keys as in 0.25)
- A wait from Sam to Lou (Sam 300 m from Eindhoven Centraal, there 09:02, for IC 3512 at 09:11): payload (exact bytes)
  `{"b":{"at":1799999990,"dist":300,"eta":1800000120,"id":"vector-wait-1","ride":{"arr":1800003720,"dep":1800000660,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"line":"IC","mode":"train","num":"3512","to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3512"},"state":"coming","stop":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"}},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"wait","n":"vector-11","t":1800000000,"v":1}`; signature (b64u) `dvEcw94cpL8gWf9Pk5zYUIs1-BuEqsDFUGLCyxkupqCyiFUZQNQ2u9kTLUICfKy0W_EOElr6dHRbdLfVWwJDBA`; eph_priv `5152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f70` (ephPub `0233f006ef4bed144ea0a5bb46c7067c7c2acec5f8cc811f3df59fdcd5ac7614`); nonce `7172737475767778797a7b7c`; box key `dcb844e611ba42e669c113ac7cc329bd2e7fd7f9de9a2743a35ee2c097803da9`; box (b64u):
  `AQIz8AbvS-0UTqClu0bHBnx8Ks7F-MyBHz31n9zVrHYUcXJzdHV2d3h5ent8F4o711H-IQXcNO0jPzR1Ejq4_JNB8y8vGAu7V-8zdOX1UD3N50pM00P_1ADbwrE3h2wmhHcHqQEz3aRrX0n3sIOzc-UWOECBBaxHwmpFfUoOHcakg99KDVQeMqmhhAYlfNcUv5s09i7WlXYo67QXcMQAxr5LJm72nq6ZhSNVBXjGtjFHTuuUCl3ilkUa-8nepuYvnJSCbcLXRclEJUDxFeVEBO0-6NXuHP7FBDo7mTMP-TARfC1o7ZDV-dK67xSB-CeKwDJZelbIe7_mUIBbkv8lrXudYV_1qhsBCp-CBR_-XRSu-07ceS9do_vOnz6YQ0DSo-ec87gJn-J9jQlxYOWYhVezq9ZwxIOH-pLym5h0uZeYGhN6PAxlBQRZwJIbRILXFpqypJm36Ly9CjU7nxsZrGRMtrqmDTHxkSQwmbl9UTpgf6yZxz0BzBEAvOcz2ygKb8SITHbSbyaVL4TwQel2xRmpgMVfpe4KwaYlxTXLz6TObtYy6Kmx1urlARXMP2lRhDfH3TGnzA8Qq00AH43ryoWsZGtF4j7E6FSV5Jq1qAtOo7qIFPIx0XttCjdbaCUyfu-U_w0tz8Sh6hapPzAcJCYeI0UOgzsw63llntPRDyN9qb1pNHrKPIbHaSLdFV7tGH11uhMG9r7u92952kkBSFh9EeAuhn1nswYrEnL9vsH-K4aLg8PR1oTtR10ifQ5FF5YVTZWlzrrn66h83XM`
- Sam on campus, to Lou (at BUas since 08:35, until 18:35): payload (exact bytes)
  `{"b":{"on":true,"school":"BUas","since":1799998500,"until":1800034500},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"campus","n":"vector-12","t":1800000000,"v":1}`; signature (b64u) `KZJaSU7N-X7-nf4ppDL55RLL8r1QNVvZk4tS_e-5MVXjklHFbv0DrckGuITkgbOQBMkqpwd-ZiiN2NKaHm0IAg`; eph_priv `8182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0` (ephPub `883186b800b41d5cf0429695da9b3cc4f328ebcd184a6e482fa578c103f06c77`); nonce `c1c2c3c4c5c6c7c8c9cacbcc`; box key `f1cbd7bf15bd198183f9df1d2c458781e5410eb1b5dc19f8464f81f8bc9c7341`; box (b64u):
  `AYgxhrgAtB1c8EKWldqbPMTzKOvNGEpuSC-leMED8Gx3wcLDxMXGx8jJysvM7sUXIpFk66f2MxcXYYb_tMTT0JGE-coRJl94y_gjkkUpyQ_ek_2yhJS6fKfMo-pj9FNhe4peWbLP9HKoM4MKBl28GjWBJwVOwQ4G6cVMY_hDekvjQ95EHvOI39blGlgywHJi9oPKRZ9Ekxmlt8QzpLsk5t7xneAEPe-cObvOIgpDj3rPTKtBac__D4tMib7wYbiF-RVet2Ye-iIf8ku1lYuiCOEuXyBMNYvzEWPO3nv_ROSbsh9G7-jmTcDLepeX-ajit0lGM0KX8xALe_wdEIUXHrqadwbnll2Rvzk-2tVpM2Swb0y6udi-r5frt2Ai`
- Sam's plan for the wake-up buddy, to Lou (leave 07:20, IC 3512 at 07:41): payload (exact bytes)
  `{"b":{"day":"2027-01-15","leave":1799994000,"on":true,"ride":{"arr":1799998320,"dep":1799995260,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"line":"IC","mode":"train","num":"3512","to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3512"}},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"buddy","n":"vector-13","t":1799992800,"v":1}`; signature (b64u) `Zazseam6h_FFLC8gnZaYfx4ukSG2Dl2YbRSObRDZa9odsX5tHpyA-HpdHZJeZLEg3OQ91RYkIEUGzw8N6jR-Dg`
- A delay from Sam to Lou (IC 3512 6 min late, next IC 3516): payload (exact bytes)
  `{"b":{"late":6,"next":{"arr":1800004860,"dep":1800001800,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"line":"IC","mode":"train","num":"3516","to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3516"},"ride":{"arr":1800003420,"dep":1800000360,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"line":"IC","mode":"train","num":"3512","sdep":1800000000,"to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3512"},"who":["3c157621a97cf055f5804a9826c6d1e1","65392c81aa86e697083b0960bf107afb"]},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"delay","n":"vector-14","t":1800000000,"v":1}`; signature (b64u) `hvyCU_Sk36bcLvd52FSIHuHI37Ni_qQhs7_Rpnmy5B_2hlbgSa2d47QAXRfYbBzbLV8gMvcS_c4zlVL_wJdZAA`
- Lou's answer to the wait (to Sam; the `’` is U+2019): payload `{"b":{"answer":"wait","re":"vector-wait-1","text":"I’ll wait"},"f":"65392c81aa86e697083b0960bf107afb","k":"message","n":"vector-15","t":1800000030,"v":1}`; signature (b64u) `quv2P-b4oVOMfuXKCxJIVQIMwkH9zSq25Djgu81cSa7uWyaFt7gjlmcnX5kqidzMy_K-R9OC9PMbuWXzC8xDDA`.
- Rules, worked (checked in `ios/Tests/FriendExtrasTests.swift`): 300 m → "6 min" walking; a stop's live departure
  09:06 against 09:00 → 6 min late, 8 min at the next stop once past yours; with the late IC left out, the next ride
  for you, Lisa (both Eindhoven) and Sam (Tilburg) is the one all three can take (IC 3520) rather than IC 3516 that
  only two can; the buddy alert from leave + 5 min to ride + 10 min; campus posting, a new friend, leaving, 10 hours.

### App (0.29)
- Pure, tested (`FriendExtras.swift`): `WaitFor`/`WaitRules`/`WaitAge`/`WaitWords`/`WaitNext`, `RideDelay`/`DelayAlarm`/
  `DelayWords`, `BuddyPlan`/`BuddyRules`/`BuddyWords`, `CampusState`/`CampusRules`/`CampusWords`, `ExtrasSettings`;
  `RoleRegions.withCampus`/`exitStartsTrip`; `FriendInbox.process` reads the four kinds and the two answers;
  `BoardAt.Stop.cancelled` (the live data's cancelled stop or trip).
- `FriendExtrasStore` (Friends/extras.json; `due` in every check, `take` with each batch; region events through
  `TripManager.onRegion`), `FriendStore.queueBox` (one payload locked per person, replacing a waiting box in its slot).
- Screens: Friends gets "Waiting for you to wait" (each with "I’ll wait" / "Take the next one with you"), "Your wait",
  "On campus now", "Rides with friends" (delays), and Friends › At school (the switch, and where the buddy switch is);
  a friend's page "Tell Sam if I haven’t left yet" and "At BUas since 09:05"; a chat shows its waits and yours on top
  and "Wait for me" on trip cards you're in; a friend's trip while they wait "Wait for me"; the ride screen "Ask a
  friend to wait for me", your wait and the delays on your rides.
- Not yet: the waits' and delays' records aren't in the vault; "Wait for me" updates in the background only while a
  trip runs (its GPS and tick); the buddy and the delay alarm reach a phone only at its next check.

## As built (0.30)

What 0.30.0 (build 119) adds: the Friends extras' **part B**: **free hours together**, a **live link** for people
without the app, the **leaderboard with friends** and the **ride history together**. Everything in "As built (0.25)" to
"(0.29)" holds unchanged; this adds one box kind (`scores`), two optional vault fields, and one relay feature (live
links, additive: new routes and a new Durable Object class, nothing else touched). `FriendMessage.kindsVersion` is 6.
Times are unix seconds; days `yyyy-MM-dd` and months `yyyy-MM` in Europe/Amsterdam. No push still.

### When anything is sent or read
- The `scores` box and the free-time note only inside the app's existing checks of the relay (`FriendStore.sync`: app to
  the front ≤ every 20 s, every 30 s while Friends is open, every 8 s while a chat is open, the ride's once-a-minute
  check, the background refresh); scores are looked at most once a minute. The ride history and the live link only on
  the ride's existing 30 s network tick (and, for the live link, 2 s after a leg, stage or vehicle change settles).
  No loop of its own; the trip, alarm, wake-at-stop, Live Activity and matching are only read.

### Free hours together (`FreeToday`, on the phone only)
- From your own timetable (as read for sharing, or read without sending at most every 30 minutes) and each friend's
  shared `timetable` (0.28) that covers today: for you and each friend, 0.28's "free together" (the gaps between
  classes, overlapping classes merged, a class without an end running into the next; segments where both are free,
  ≥ 30 min); only those that still end after now; the very same stretch with several friends is one line (friends
  sorted by account); by start, then end; at most 3.
- Words: "Today: you and Sam are both free 12:00–13:30", "Today: you, Kim and Lisa are all free 12:00–13:30", and once
  it has begun "Now: you and Sam are both free until 13:30". Shown on Friends ("Free together today").
- **Morning note** (Friends › At school, "Tell me in the morning when we're free together", **off by default**): one
  local notification a day, "Free time together today", body the lines without "Today: " (capitalised, one per line),
  at the first check from 06:00 until before 11:00 while the first free time is still ahead. In the app: a banner.

### The `scores` box — the leaderboard with friends (slot `scores`, ttl 14 days)
- Body: `{"on": bool (required), "month"?: "yyyy-MM", "best"?: [best] (0–8), "mbest"?: [best] (0–8), "rides"?: 0–1000}`;
  best = `{"route": string (required), "home": bool (required), "mins": number (required, 5–600, one decimal), "at": t
  (required, when that trip ended)}`. `best` is the fastest trip per route ever, `mbest` the fastest this `month`,
  `rides` the rides together with friends this `month` (see the ride history). Each list: to school first, then the
  fastest, then by route. `{"on": false}` takes it back.
- Routes are the leaderboard's keys: `"home→school"` / `"school→home"` (door to door, 0.24's `DoorScore`; the `→` is
  U+2192) or a corridor route's name ("Via Den Bosch"). Minutes: from starting the alarm to the last stop (as the
  leaderboard has them).
- Readers: only from a **friend**; the newest by `t` wins; routes cleaned as names (≤ 40, empty dropped), minutes
  outside 5–600 dropped, at most 8 per list; a `month` that isn't `yyyy-MM` (01–12) drops `month`, `mbest` and `rides`;
  `rides` outside 0–1000 dropped. Kept only while they're a friend.
- **Opt-in**: "Share my scores" (Settings › Leaderboard › With friends, or Friends › Leaderboard with friends), **off by
  default**, to all friends. On: every friend gets it when it changed (FNV-1a 64 over the body's JSON, sorted keys) and
  the last went ≥ 12 h ago, or ≥ 7 days ago whatever; a new friend at once. Off: `{"on":false}` (ttl 14 days) to those
  who had it.
- **The board** (`ScoreBoard`, you and the friends who share): per route (to school first, then home; within each the
  most people, then the route's name), each person's fastest on it, fastest first (then the earliest). "This month":
  `mbest` of those whose `month` is this month; "All time": `best`. "Most rides together this month": everyone whose
  `month` is this one with `rides` ≥ 1, the most first. Your own row is there whether or not you share. Labels:
  "Home → school", "School → home", else "Via Den Bosch · to school" / "· home".

### Ride history together (`RideHistory`, on the phone only: Friends/together.json, not backed up)
- On the ride's tick while you're on board a bus or train (a vehicle, not waiting, not at a change, not the demo):
  the friends on it with you are those whose `travel` state (0.26) has its trip id and is `riding`, and the others in on
  a 0.27 trip card you're in (you sent it, or said "I'm in"; from the last 24 h) whose shared ride (first train, else
  longest) is that vehicle. Only friends count.
- One record per vehicle per day: `{"trip","day","label" ("Bus 305", "IC 3512"),"from","to" (your stops' names),"dep"
  (when it left where you got on),"with": [account]}`; a later tick adds people to it. Kept 400 days, at most 1000,
  only while someone in it is still a friend.
- A friend's page: "You rode together 14 times this month" ("once", "twice", "No rides together this month yet")
  counting this month's records with them, and the last 10: "Fri 15 Jan · 09:11 · IC 3512 · Eindhoven Centraal →
  Breda". `rides` in the `scores` box = all of this month's records.

### Live link (`LiveLink.swift`, relay `relay/live.js`)
For someone without the app (a parent): a web page with your trip's live times, ending with the trip. Works without a
friends account. From the ride screen ("Share a live link") or Friends while a trip runs (not the demo); sent with the
iOS share sheet.
- **Secrets**: `secret` = 32 random bytes (stays on the phone; it lets the phone write), `key` = 32 random bytes.
  `token` = b64u(first 16 bytes of SHA-256(ASCII "hw-live-token-v1" ‖ secret)) — 22 characters.
- **Link**: `https://haltewekker-relay.tsfaw1.workers.dev/live/<token>#<b64u(key)>`. The key is only in the fragment,
  which browsers never send, so the relay can't read the trip.
- **Lock** (chosen: **AES-256-GCM** with that random key, so the page can decrypt with WebCrypto in any browser):
  `data` = `0x01 ‖ nonce (12, random) ‖ AES-256-GCM ciphertext ‖ tag (16)`, AAD = UTF-8 `"hw-live-v1\n" + token`,
  plaintext the state's JSON (UTF-8, keys sorted by the app; readers take any order).
- **State** (every key but `v`, `name`, `state`, `mode`, `t` optional): `{"v":1, "name": the sender's name (≤ 40),
  "state": "waiting" | "riding" | "change" | "arrived" (unknown reads as riding), "mode": "train" | "bus" (or "tram",
  "metro", "ferry"), "line", "num", "from", "to" (this ride's stops, names only), "dest" (the trip's end when it isn't
  `to`), "dep" (when the ride leaves `from`: waiting, or the next ride at a change), "eta" (arrival at `to`; arrived:
  when you got there), "end" (arrival at the trip's end), "late" (minutes, 0–600: the live arrival at your stop against
  the scheduled one while riding, the departure's delay while waiting or at a change; absent when not known), "pos":
  {"lat","lon","at"} (the phone's last fix, 5 decimals, ≤ 5 minutes old, as in 0.26), "t": when written}`. It's the
  0.26 travel state cut down: no trip id, coach, accuracy, leg numbers or coordinates of stops; Home is "Home".
- **Posting** (`LiveRules`): the first state when the link is made; then on the ride's network tick when 55 s went by,
  or (≥ 6 s after the last) when the stage, mode, line, number, `from` or `to` changed. Each put asks `until` = now +
  30 min (so a phone gone quiet lets it end by itself), never past 4 h after the link was made. At the last stop: an
  `arrived` state (`to` = the last stop, `eta` = now, no position) with `until` = now + 15 min, then nothing more (tried
  again once after 6 s if the relay said slow down). The trip ended any other way, "Stop sharing", or 4 hours: `end`
  (tried again at the next tick or start if the network was away). A link left from a trip that ended while the app was
  gone ends when the app starts. Kept in Friends/live.json (not backed up).
- **Relay routes** (no account; JSON; `Cache-Control: no-store`; nothing logged):
  - `POST /live/v1/put {"secret": b64u(32 bytes), "data": b64u(≤ 4096 bytes, first byte 1), "until": unix s}` →
    `{"ok":true,"token","exp"}`. The token is worked out from the secret. The first put makes the link (≤ 20 new links
    an hour per network address, hashed: else 429); `exp` = min(until, made + 4 h); `until` must be ≥ now + 30 s (400
    `bad_until`). Puts ≥ 5 s apart and ≤ 240 an hour per link (429 `slow_down`). An ended link: 410 `ended`. 400
    `bad_secret` / `bad_data` / `bad_json`, 413 over 16 KB.
  - `POST /live/v1/end {"secret"}` → `{"ok":true}` (also when there's nothing): the data goes at once; the link is kept
    without it until its 4 hours are up so the page can say it ended.
  - `GET /live/v1/get?t=<token>` → `{"data","at","exp"}` (`at`: when the relay got it), 410 `ended`, 404 `gone`
    (unknown or expired), 400 `bad_token`, 429 over 120 a minute per link.
  - `GET /live/<token>`: the page (HTML; CSP `default-src 'none'; script-src 'self'; style-src 'unsafe-inline';
    img-src https://tile.openstreetmap.org; connect-src 'self'; …`, `Referrer-Policy: strict-origin` so the map's tiles
    never see the token, `noindex`). `GET /live/app.js`: its script (no other script anywhere).
  - Storage: one Durable Object (SQLite-backed, key-value API) per link, `t:<token>`, deleted at `exp`; `ip:<hash>`
    counts new links for an hour. Migration `v3`, class `Live`, binding `LIVE`.
- **The page** (`relay/live.js`): reads the token from the path and the key from the fragment, polls `/live/v1/get`
  every 15 s while visible (30 s after a 429, backing off on errors), decrypts with WebCrypto, and shows (times in the
  viewer's clock):
  - riding: "Sam is on bus 305 to Den Bosch · arrives 07:51 · 3 min late" ("· on time" at 0; nothing when not known);
  - waiting: "Sam is waiting for the IC 3512 to Breda at Eindhoven Centraal · leaves 07:41";
  - change: "Sam is changing at Eindhoven Centraal · then the IC 3512 to Breda at 08:03" (without a line: "Sam is
    changing at Eindhoven Centraal");
  - arrived: "Sam has arrived at Den Bosch · 07:52" with an "Arrived" badge;
  - vehicle words: a train "the IC 3512" / "the IC" / "the train"; otherwise "bus 305" / "tram 1", without a line
    "the bus"; an empty name reads "Your friend";
  - under it "Then on to Breda · there around 08:45" (not when arrived, nor when `dest` is `to`), "Last update 07:41"
    after 150 s ("· the phone may be out of reach" after 10 min), and a small map: OpenStreetMap tiles at zoom 15
    around `pos` with a dot (no map without a position, or when arrived);
  - 404/410: "This link has ended"; no or a bad key: "This link is missing its key…" / "This link's key doesn't fit…".
  The app shows the same words (`LiveWords`).
- `node relay/test-live.mjs [url]` checks the routes and limits, and runs the page's own script on a stand-in browser
  so it decrypts a state with the key from the link.

### The vault
- `FriendVaultContents.extras` gains `"free"?: true` and `"scores"?: true` (the two switches). An older app ignores them.

### Test vectors (Node's crypto; checked in `ios/Tests/FriendLiveTests.swift` and `ios/Tests/FriendExtrasBTests.swift`)
- Live link: secret `000102…1f` (bytes 0x00–0x1f), key `202122…3f` (0x20–0x3f) → token `2x1Ot-EFfLIivv_lmStBuw`; link
  `https://haltewekker-relay.tsfaw1.workers.dev/live/2x1Ot-EFfLIivv_lmStBuw#ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8`.
  State (exact bytes) `{"dest":"Breda","end":1800004500,"eta":1800001260,"from":"Veghel","late":3,"line":"305","mode":"bus","name":"Sam","pos":{"at":1799999990,"lat":51.61672,"lon":5.54861},"state":"riding","t":1800000000,"to":"Den Bosch","v":1}`,
  nonce `404142434445464748494a4b` → data (b64u)
  `AUBBQkNERUZHSElKS7l22eQjAucxcHAiTeErc14x6_Pn13qW5l7OpDBU3_8y5jF6alf-mxd1pw20reGB2e60y1bPhb3fRMafBUHNMX0XzIrkdFdZINAvfQZc6wgCKn4B3YWG2r9jXEn0RXpeVbJnZrAQ2fH-jvvebSMWbiXub8wm-a4kw_nwp59f9VyUkXutBMfsSHUt3Agu3YlcN2wqOLT2L2x4rrqImgvKvsoulSwMAdncswKlNM9vKwSvq3RIztNMa-KL1guHyZLcJ5KPVhXxLPpZVMixIoV0J937rVtJ9dYWTJ1LJ0lsBKOwV_k08p4uVV-3ue-8vAw`.
  Shown (Amsterdam): "Sam is on bus 305 to Den Bosch · arrives 09:21 · 3 min late", "Then on to Breda · there around 10:15".
- Sam's scores to Lou (keys as in 0.25): payload (exact bytes)
  `{"b":{"best":[{"at":1799996400,"home":false,"mins":48.5,"route":"home→school"},{"at":1799910000,"home":true,"mins":52,"route":"school→home"}],"mbest":[{"at":1799996400,"home":false,"mins":48.5,"route":"home→school"}],"month":"2027-01","on":true,"rides":14},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"scores","n":"vector-16","t":1800000000,"v":1}`;
  signature (b64u) `6rLh_QChtON4H7TK4hzq8a0UxhBkm55Zq67PCwiZFCholCtVlWmo5R_13XRlGu7Vb3wcZU9wVpqMKxKcSoqcDQ`; eph_priv
  `9192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0` (ephPub
  `9cced751b301bbd16c4fb8deddd82f18925d71ed90c844fa0158f845b0fa7f4b`); nonce `d1d2d3d4d5d6d7d8d9dadbdd`; box key
  `a656690c6bb10400c938ea7f1888af6f348a47c5d7f09d7317eaee094ff8a41e`; box (b64u):
  `AZzO11GzAbvRbE-43t3YLxiSXXHtkMhE-gFY-EWw-n9L0dLT1NXW19jZ2tvd2yVEWneoEWqLeQL9E6U4tx_P1PQUZHFE0SJnGsrRekEFLdfQJJ5WTl07a8y-r1W9TrD3wY0xRFCfEXBmplz4mbB53BKkqZiLX1r8JAtjw4gc3cCshJuxPi5wI6VyWk0syVe7ZR6lvKJVRH9hMzJtULbGBPzrLoZSB9OXwcj5PnVuQUZcc6tJiAi8C6pFIfu05GXTXY97-zshmL0FOGC7GmeF2WBWojbxnt4SHwxt0VX4zc625bdH-6DVzm-mNejIBbheioXp_XLn39U4-tf3dhUMB8aarwPDxeQKawwjQjgXC2ZMVveb5jvkKqLEvjEv7zSVITyNma_T9cjEgvmZQi1Drlfv5TGcVOzF8Zlli2sWQFAtU6tdXEiqw_PW-jqIYHH7psu0FGzeLPbO_HWKJ__71nlMtqW9VptFYoHTdOjNjDHStEm5x8fMsXwAOW2thjzBvyctDHCJk0LZCgHQBCGgAt45xCgHTDViqG97IYH-qzRN6VNIavLbEhvui4514nG_Usol_5kP2S0j2gpM_B59rPMkNF4cTFLygK7GN9AXWtLKkTO5zMqD0dF4V4vm`
- Rules, worked (Friday 15 January 2027): you 10:15–12:00 and 13:30–15:45, Sam 09:00–11:30 and 13:00–14:00, Lisa
  10:00–12:00 and 13:30–16:00 → "Today: you and Sam are both free 12:00–13:00", "Today: you and Lisa are both free
  12:00–13:30"; the note at 06:00–10:59 once; your trips 48.5 (today) and 52.34 min to school, 52 and 55 (December)
  home → `best` as in the payload (the payload's `mbest` holds the trip to school only; `build` also puts the 14th's
  trip home in it); the same vehicle on one day is one record, the people added to it.

### App (0.30)
- Pure, tested: `FreeToday`, `ScoresShare`/`ScoresRules`/`ScoreBoard`, `RideHistory`/`RideHistoryWords`
  (`FriendExtrasB.swift`); `LiveState`/`LiveKeys`/`LiveCrypto`/`LiveRules`/`LiveWords` (`LiveLink.swift`);
  `FriendInbox.process` reads `scores`.
- `FriendTogetherStore` (Friends/together.json: rides together, friends' scores, what you sent; `due` in every check,
  `take` with each batch, `rideTick` on the ride's tick), `LiveLinkStore` (Friends/live.json; the ride's tick through
  `FriendTravelShare`, the trip's phase), `FriendTravelShare.currentState()` (the travel state, for the live link).
- Screens: Friends gets "Free together today", the live link card (while a trip runs or a link is shared; a line
  otherwise), "Leaderboard with friends", and in At school the morning-note switch; a friend's page "Rides together";
  the ride screen "Share a live link" (also without friends), the link's "Send the link" / "Stop sharing"; Settings ›
  Leaderboard gets "You / With friends" (with "Share my scores").
- Not yet: rides together and friends' scores aren't in the vault; the live link's page is English only and shows the
  viewer's clock; a trip longer than 4 hours ends its link.

## As built (0.30.1)

What 0.30.1 (build 120) adds: a **test friend** (iOS only for now; Android should get the same, built from this text)
and a sturdier **live link**. Everything in "As built (0.25)" to "(0.30)" holds unchanged: no new box kind, no new
relay route, `FriendMessage.kindsVersion` stays 6. One relay change, in the live link's page only (`relay/live.js`).

### The live link: why the key went missing
- Seen: a shared link opened in Safari said "This link is missing its key…" with an "Ended" badge while the trip ran.
  The page only says that when the part after `#` (the key) didn't reach it: the relay doesn't redirect `/live/<token>`
  (a redirect would keep the fragment anyway), the app makes the link with its first state already on the relay
  (`LiveLinkStore.make` puts the state before it hands out the link, so the page says "… is waiting for …" from the
  first second), and `relay/test-live.mjs` decrypts a state with the page's own script. What lost it was the way it
  was handed on: 0.30 gave the share sheet the link **as a URL**, which Messages (and others) turn into a link preview
  made by fetching the page; a fetch never carries the fragment, and the preview can open the address it fetched rather
  than the one sent. The "Ended" badge was the page's missing-key message wearing the ended look, not the link ending.
- So (app): "Send the link" hands the share sheet **plain text** (`LiveWords.shareText`: "Follow my trip live:" and the
  whole link on its own line); "**Copy link**" next to it puts the whole link on the clipboard as text and as a URL; the
  link carries the key as `#k=<key>` (`LiveCrypto.link`; the vector link is now
  `https://haltewekker-relay.tsfaw1.workers.dev/live/2x1Ot-EFfLIivv_lmStBuw#k=ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8`);
  `LiveCrypto.parse` reads `#k=<key>` (among `&`-separated fields) and 0.30's bare `#<key>`.
- So (page): the key is read from the fragment only (never a query: the relay must never see it) as `#k=<key>` or
  `#<key>`, %-encoded or not, with anything an app glued on after its 43 characters, standard base64 (`+` `/`) too. A key
  that decrypted once is kept in that browser's `localStorage` (`hw-live:<token>`) until the link ends (404/410), so
  the same link opened again without its fragment still works (the page then puts `#k=<key>` back in the address). No
  key: the headline "This link is missing its key. Ask for the link again (all of it, with the part after the #).", a
  **"Key missing"** badge (not "Ended") and "Some apps cut a link short. In Haltewekker, “Copy link” gives the whole link
  to paste."; it asks `/live/v1/get` once and says "This link has ended" if it has.

### The test friend (`TestFriendBrain.swift` pure and tested; `TestFriendBot.swift`; `TestFriendViews.swift`)
- **What it is**: a bot that is a real second Friends account made on this phone: its own random seed and device id,
  its own `/f/v1/register`, kept in its own file `Friends/testfriend.json` (the Friends folder: not backed up), apart
  from your account's Keychain entries. It talks to you only through the live relay with the very boxes a friend's
  phone sends (0.25–0.30 formats, sealed with its keys, read with `FriendInbox.process` on its own book and groups). Its
  relay calls go without a field-log label, so they never show in a shared ride log.
- **When it runs**: only inside your app's own checks (`FriendStore.sync`): right after your waiting boxes went, it
  sends what it has waiting, reads one page of its mailbox, answers, acks, moves its pretend trip or wait on (at most
  every 20 s) and sends again, so its answers arrive in that same check. No loop of its own. Each of its controls does
  one thing and then runs a check at once.
- **Adding** (Settings › Friends "Add a test friend", or the empty friend list's card): it registers and sends you a
  `request` (name "Test friend", note "A test friend made on your phone…") with its `picture` (a 256 px JPEG: a test
  tube on violet to teal, "TEST"); you accept it like anyone's. A request from you it accepts at once. Once friends it
  says hello, and sends a `timetable` (`TestFriendBrain.timetable`: each weekday of the 14-day window a first class when
  yours starts that day, else 08:45, Friday 10:30, clamped to 07:30–13:00; then +120 and +270 minutes, 90/90/120
  minutes long, Wednesday without the third; no weekends; `src: "week"`) and an `area` (the stops near Home and the NS
  station nearest Home that your own area has, else that station; your school; `early` 10; never an address); both
  again after 20 h.
- **What it answers**: every line from you (one-to-one, or in a group from you only): the quick replies ("Running 5 min
  late" → "No problem, I’ll wait. See you in a bit!", "Save me a seat", "Wait for me", "I’m at the stop", "On the 305" →
  "Nice, I’ll look out for you on the 305."), hello, a question, else "You said: “…”. Got it, locked end to end.";
  answers to its wait or cards; a trip card → a `message` answering `in` ("I’m in") and "See you on the IC 3512 at
  07:41!"; your `wait` → `wait` ("I’ll wait"). It marks your lines read at once (`seen`, got = read = your newest `t`).
  Added to a group it says hello there once ("Hi everyone! I’m the test friend…").
- **Its controls** (its page, "Test friend controls"; one tap = one box or one short pretend run):
  - "Pretend I’m travelling": a real departure within 45 minutes from the rail stop at the NS station nearest Home, else
    the stop nearest Home (Transitous `/v6/stoptimes`, then `/v5/trip` for its stops from there on, up to 25 minutes of
    it and 8 stops); without an answer, a Sprinter from that station to the next one 1.5 km or more away. It's squeezed
    into a minute waiting at the first stop and 10 minutes riding (`TestTripSim`: the stops' real times, else their
    distances, spread over 600 s; the position between the two stops it's between), sent as `travel` states
    (`/f/v1/state/put`, ttl 360) at most every 20 s, with coach 3 of 6 from the front on a train; at the end it's taken
    back (`/f/v1/state/clear`) and it says "Made it to …!". Tap again to stop.
  - "Ask you to wait for me": a `wait` at the NS station nearest Home (`TestWaitSim`: coming from 650 m, there after
    5 minutes, `off` after 10), updated at most every 20 s.
  - "Pretend I’m on campus" / "…left campus": `campus` `{on, school: your school's short name, since: now − 20 min,
    until: now + 4 h}`, or `{on:false}`.
  - "Share scores": `scores` (`TestFriendBrain.scores`: your routes' fastest × 1.05 going, × 0.96 home, from an hour ago;
    without trips of yours "home→school" 46.5 and "school→home" 51.2; rides = your rides with it this month).
  - "Pretend we rode together": a ride in **your** ride history with it (the history lives on the phone; there's no box
    for it), from the station nearest Home, and a line about it.
  - "Wake-up buddy: pretend I haven’t left": `buddy` `{on, day: today, leave: now − 6 min, ride: a Sprinter from the
    station nearest Home in 4 minutes}`, its pretend trip and wait stopped first. Your phone tells you once a day per
    friend, and not when its trip or wait came in the hour before that leave (0.29's rules).
- **Removing** ("Remove test friend" on its page or in Settings): your side removes it (0.25's `drop` + `unfriend`), its
  chat goes, it sends `gleave` to every group it's in, takes back its state and leaves the relay (`/f/v1/leave`; tried
  again at the next check if the network was away); then its file goes. Removed any other way, or your own account
  deleted or moved: it leaves the same way.
- **Never in your backup**: the vault is written through `TestFriendBrain.scrub` (the bot out of the list, every group's
  members, the timetable's "off" list and the buddy switch). Its "TEST" tag shows beside its name wherever a friend row
  does, and on its page.
- **For Android**: build it the same way: a second identity in its own file, its brain only inside the app's checks,
  the same replies, timetable, area, scores and pretend runs, kept out of the vault and out of shared logs.

### Tests
- `ios/Tests/TestFriendTests.swift`: the replies, the trip-card answer, the timetable near yours (Friday 15 January
  2027: 28 classes in the window, Friday from 10:30, Monday 08:45/10:45/13:15; your Monday 09:30 → its 09:30), scores,
  the buddy plan (it alerts at once), the pretend trip (times 0/300/600 s, waiting then half way with a coach, over at
  660 s; by distance without times), the fallback Sprinter, the wait (650 m, 330 m at 150 s, there at 300 s, off at
  600 s) and the scrubbed vault. `ios/Tests/FriendLiveTests.swift`: the `#k=` link and 0.30's form.
- `node relay/test-live.mjs [url]`: the page reads `#k=`, bare, %-encoded, glued-on and standard-base64 keys, says "Key
  missing" (not "Ended") without one, keeps a key that worked and drops it when the link ends.

### App (0.30.1)
- Settings › Friends: "Add a test friend" / "Remove test friend". Friends: the empty friend list's test friend card; the
  "TEST" tag; its page's "Test friend controls". The live link card and sheet: "Send the link" (as text) and "Copy link".
- Not yet: the test friend is iOS only; it answers only while your app checks (no push, as everything else).

## As built (0.31)

What 0.31.0 (build 121) adds: **where you sit** (a seat: deck and window, in the coach of 0.26's `travel` box), the
**seat picker**, and Friends laid out **map first**. Everything in "As built (0.25)" to "(0.30.1)" holds unchanged: no
new box kind, no new relay route, `FriendMessage.kindsVersion` stays 6. The seat is one optional object inside
`coach`: an app before 0.31 ignores it (JSON keys it doesn't know are skipped) and sends none. Android should add it
from this text; until then an Android friend's coach just has no window.

### The seat (`TravelState.Seat` in `FriendTravel.swift`; the sums in `SeatMap.swift`, tested)
- `coach` gains `seat`: `{"deck", "w", "of"}`, all three required when `seat` is there:
  - `deck`: `"upper"` | `"lower"` (a double-deck coach) | `"none"` (a single-deck one). Anything else reads as `"none"`.
  - `w`: the window, 1-based, **counted from the back of the coach** (the end nearer the back of the train) when the
    coach is counted from the front (`front: true`); when it isn't (`front: false`), from the left of NS's drawing at
    `at`, like the coach number itself.
  - `of`: windows in a row as the sender's picker drew them (0.31 draws **11**). A reader drawing another number
    scales `w` (rounding up). A seat with `of` outside 1–40 or `w` outside 1–`of` is dropped (the coach stays).
- Words: "Coach 3 of 6 · upper deck · 8th window from the back" ("… · 6th window from the back" on one deck; "… from
  the left" without a direction). Without a seat, 0.26's "Coach 3 of 6 · front". VoiceOver, per window: "Coach 3,
  upper deck, window 8 from the back".
- It goes out like the coach did: with the next state, at once when it changes; tapping your window again takes the
  window away (the coach stays), "Take it away" takes both.

### The train in the picker (`SeatMap.train`)
- From NS's `/ns/train?num=&station=` (through the relay, as 0.26): the units and their coaches (`CoachMap.spots`),
  numbered from the front when NS gives `rijrichting`, drawn the way NS draws them (the front on the left: "← Driving
  to Breda"; on the right: "Driving to Breda →"; no direction: "Towards Breda", numbered from the left).
- Each unit's decks by its type (`materieeldelen[].type`, else its drawing's file name): **two decks** VIRM (VIRMm),
  DDZ / NID / DD-IRM, DD-AR / mDDM; **one deck** SNG, SLT, FLIRT, SGM, GTW, ICM (the Koploper has one deck, even though
  it's an Intercity), ICNG, ICR, ICE and the other international trains. A type it doesn't know: by the line.
- Without NS's drawing: NS's length (`lengte`) or the friend's `of`, else **6** coaches; the front drawn on the right
  and numbered from it (`front: true`); an Intercity (`IC`, `ICD`) double-deck, a Sprinter and anything else single.
  The picker says it's a guess.
- At most 16 coaches drawn.

### Test vector (checked in `ios/Tests/SeatMapTests.swift`)
- 0.26's travel state from Sam with a seat (header `n` = `vector-31`), the exact payload bytes `FriendBox.payload`
  makes (sorted keys, as every box):
  `{"b":{"coach":{"at":"EHV","front":true,"n":3,"of":6,"seat":{"deck":"upper","of":11,"w":8}},"end":1800004200,"eta":1800003780,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"leg":2,"legs":2,"line":"IC","mode":"train","num":"3512","pos":{"acc":12,"at":1799999990,"lat":51.5112,"lon":5.2874},"state":"riding","to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3512"},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"travel","n":"vector-31","t":1800000000,"v":1}`
  → "Coach 3 of 6 · upper deck · 8th window from the back". Read as 0.26's coach (`n`, `of`, `front`, `at`) it is
  coach 3 of 6 from the front, the seat skipped. A coach without a seat encodes exactly as in 0.26
  (`{"at":"EHV","front":true,"n":3,"of":6}`). Sealing and signing are 0.25's, unchanged.
- Windows: the front on the right, the left window is `w` 1; the front on the left, the right window is `w` 1; `w`
  16 of 22 drawn in 11 is the 8th.

### The test friend
- Its pretend train's coach (3 of 6 from the front) now has a window: an Intercity's upper deck, 8th from the back;
  a Sprinter's 6th (`TestTripSim.coach`).

### The friend's map: the bug, and the fix (`MapFrame.swift`, tested)
- Seen: on the test friend's page, while it "travelled" on a Sprinter from Best to 's-Hertogenbosch, the map showed
  Maastricht and Sittard. The state itself was right (its stops and position come from the same live data, lat and
  lon in their places: `TestTripSim` and the box vectors check that). What went wrong was the camera: the map left it
  to MapKit (`MapCameraPosition.automatic`), which frames the map's content **once**, when it first gets it, and the
  code then "reframed" by assigning `.automatic` again, which is no change at all. So the page kept whatever region
  the map had first: when the map was laid out before its pin and stop markers were in (inside the scrolling page,
  the trip arriving or moving after the page opened), that was MapKit's own default region, not the trip.
- Now (0.31): the region is always worked out by `MapFrame.fit` from the friend's position and the trip's from and to
  (whichever are real coordinates: not missing, not 0,0, on the globe), with room around them (×1.35, at least
  1.6 km), widened to the map's shape, and moved up so it sits in the part the sheet leaves free. It's set
  (`.region`) when the map appears, when its size changes and whenever any of those points changes.
- Routes: a friend's line is the bit of their vehicle's live trip shape between where they got on and where they get
  off (`MapFrame.route`, the nearest points), else a straight line from, through where they are, to.

### "Ride along" (`TripTake.rideAlong`, tested)
- On a friend's page while they travel: their bus or train now as a card (on board: from where they are, so the way
  found gets onto it further along; waiting or changing: from their stop; leaving now, there at their `eta`), taken
  like "Take this trip" (0.27): Fastest trip with your way onto it, else Plan filled in. No vehicle id, or Home as
  where they get off: no button.

### App (0.31)
- **Friends** (with an account): a full-screen map: travelling friends' faces where they are, ringed in their
  vehicle's colour (Intercity indigo, Sprinter cyan, bus orange, as the line pills), friends on campus at your school
  in the accent; their routes drawn; tap a face for their page. Over it a sheet with a handle (drag or tap it, "Show
  more"/"Show less" for VoiceOver): "Friends" and "+ Add" (the add page: show my code, scan, send my link, paste, the
  test friend), requests, a card per friend in a row (face, name, "IC 3512 to Breda", "arrives 08:43"; travelling
  first, then on campus), **Chats · N** (all chats and "New group"), **Groups** (each group's chat, "New group"),
  **Compare** (a group or a friend, then 0.28's compare and meet halfway), then what's going on now (waits for you,
  your wait, on campus, delays, free time together, the live link), **More** (your name and picture, Your trips, Your
  timetable, Extras, Requests you sent), the leaderboard, the live link note and when it last checked. "…" (name and
  picture, backup code, delete) and Done float over the map. Without an account: 0.25's page, unchanged.
- **A friend's page** while they travel: the map framed on their trip (their face, the line, where they got on and
  get off), "‹ Friends", and a sheet: face, name, line pill, "3512 to Breda · 08:43", a green chat button (with the
  count of new lines); the seat picker with their face in their window; "Sam is in coach 3 of 6 · upper deck · 8th
  window from the back" and "Taking this train too? Wait near B, at the front end of the platform" (on the same train
  as you) or "Coach 3 from the front"; Compare · Ride along · Wait for me (when they're at a stop); then on campus, the
  test friend's controls, rides together, what they see (with its switches) and Remove. Not travelling: the same as a
  page, "Friends since …".
- **The seat picker** (`SeatPicker.swift`): the whole train on top (first and last coach shaped like noses, numbers
  from the front, a dot where a friend or you sit); tap a coach and it opens below from the side: doors, 11 windows a
  row (two rows on a double-deck coach: top the upper deck, bottom the lower), the line's colour stripe, wheels. Every
  coach and window is a button for VoiceOver ("Coach 3 of 6, from the front, two decks"; "Coach 3, upper deck, window
  8 from the back, your seat"). Yours to set on the ride screen ("Your seat", replacing 0.26's coach strip) and on a
  friend's page when your trip takes that train; otherwise theirs to look at.

## As built (0.31.1)

What 0.31.1 (build 122) adds: **1st class in the seat picker**. Everything in "As built (0.25)" to "(0.31)" holds
unchanged: no new box kind, no relay change, and **nothing new in the seat**: whether a coach or a window is 1st class
is worked out by each reader from the train (NS's composition and the table below), never sent. Android ports the
table and the rules below to show the same.

### Where the class comes from (`SeatClass.swift`, tested in `ios/Tests/SeatClassTests.swift`)
- NS's `/ns/train?num=&station=&features=zitplaats` (through the relay, as 0.26) gives each unit (`materieeldelen[]`)
  its `type` ("VIRMm1 VI"), its drawing (`afbeelding`, `https://vt.ns-mlab.nl/v1/images/virmm1_6.png`), its coaches
  (`bakken`: a list of **empty** objects, nothing per coach) and `zitplaatsen.zitplaatsEersteKlas` (the unit's 1st-class
  seats). Nothing says which coach the 1st class is in.
- NS's drawings do: they mark 1st class as the trains do, a "1" by the doors and a thin line along the 1st-class
  windows, per deck. The table is read off those drawings (November 2026). It's NS's picture, not the real seats, so a
  part of a coach is shown as "1st class (about here)"; a coach that's 1st class all through as "1st class".
- The drawing's name: the file name of `afbeelding`, lower case, without ".png" (`icng_B_8.png` → `icng_b_8`); without
  one, from `type`: lower case, split on anything not a letter or digit, Roman numerals II/III/IV/V/VI/VIII to digits,
  joined with "_" ("VIRMm1 VI" → `virmm1_6`, "DDZ 4" → `ddz_4`), else with "nsr_" in front ("Flirt 3" →
  `nsr_flirt_3`).
- A unit with `zitplaatsEersteKlas` 0: no 1st class (Keolis' Flirts). A drawing not in the table (ICE, GTW, Keolis,
  Arriva…), or a unit whose `bakken` count isn't the drawing's: not known; the picker says "Where 1st class is in this
  train isn't known." when no coach of it is known to have 1st class. The guessed train (no NS) knows none.

### The table
Per drawing: where its coaches meet (shares of the unit's drawn length, from the left), then each coach's 1st-class
parts as `[a, b]`, shares of that coach from the left of the drawing, on the upper deck (U), the lower deck (L) or
every deck (no letter). `—`: no 1st class. "All" = `[0, 1]`, the coach is 1st class all through.

| drawing | coach edges | coaches, left to right |
|---|---|---|
| `virm_4` | .2523 .5033 .7477 | — · L[.45,.77] · [.22,.54] · — |
| `virm_6` | .1688 .3323 .4997 .6677 .8312 | — · [.45,.77] · — · [.45,.78] · [.22,.55] · — |
| `virmm1_4` | as `virm_4` | — · U[.54,.76] L[.46,.76] · U[.22,.44] L[.22,.52] · — |
| `virmm1_6` | as `virm_6` | — · U[.54,.76] L[.46,.76] · — · U[.54,.76] L[.46,.76] · U[.22,.44] L[.22,.52] · — |
| `virmm2_4` | as `virm_4` | — · U[.54,.76] · U[.22,.45] L[.22,.53] · — |
| `virmm2_6` | as `virm_6` | — · U[.54,.76] L[.46,.76] · — · U[.54,.76] · U[.22,.45] L[.22,.53] · — |
| `ddz_4` | .2648 .5263 .7878 | U[.21,.50] L[.21,.37] · — · U[.59,.78] L[.44,.78] · — |
| `ddz_6` | .1739 .3456 .5173 .689 .8607 | U[.21,.50] L[.21,.37] · — · U[.59,.78] L[.44,.78] · — · U[.59,.78] L[.44,.78] · — |
| `icm_3` | .333 .666 | — · [.43,.89] · — |
| `icm_4` | .2496 .4993 .75 | — · — · **All** · — |
| `icng_5` | .2159 .3847 .5844 .7841 | — · — · [.25,1] · [0,.32] · — |
| `icng_8`, `icng_b_8` | .1434 .2555 .3674 .5 .6326 .7445 .8566 | — · — · [.27,1] · [0,.13] · [.87,1] · [0,.67] · — · — |
| `slt_4` | .2756 .5 .7237 | [.24,.47] · — · — · [.53,.76] |
| `slt_6` | .1903 .345 .4997 .6545 .8092 | [.24,.47] · — · — · — · — · [.53,.76] |
| `sng_3` | .3634 .6366 | [.20,.42] · — · — (one end only) |
| `sng_4` | .2854 .5 .7146 | [.20,.42] · — · — · [.58,.80] |
| `nsr_flirt_3` | .361 .638 | [.27,.41] · — · [.59,.73] |
| `nsr_flirt_4` | .2824 .4994 .7164 | [.27,.41] · — · — · [.59,.73] |

### The rules
- A coach's place in its unit: the picker's coaches (`CoachMap.spots`, as 0.26) by the unit their middle falls in,
  counted from the unit's left; its parts are the table's for that coach (the drawing is used as NS draws it, the same
  way round as the train's drawing, like 0.26's coaches).
- A coach is **1st class all through** when one of its parts is on every deck from ≤ .02 to ≥ .98; **part 1st class**
  when it has any part; else 2nd class.
- A window (11 a row, drawn from the left, 0-based `i`) is 1st class when its middle, `(i + 0.5) / 11`, is inside a
  part on its row's deck (the top row the upper deck, the bottom the lower; a single-deck coach's row takes every part)
  — or the coach is all 1st class.
- Your pick (or a friend's) is 1st class when its coach is all 1st class, or its seat's window (`SeatMap.drawnWindow`,
  scaled to 11 as 0.31) is a 1st-class window in its row. A coach without a window in a part-1st coach is not.
- Platform letters ("1st class near A, D", 0.24): the zones are now the table's parts as shares of the unit (any deck,
  merged where they touch) — this fixes the SNG-3, which used to show 1st class at both ends.

### Test vectors (from the relay, 19 November 2026; `2` none, `p` part, `1` all, `?` not known; drawn from the left)
- IC 3078 at UT (VIRMm1 VI + VIRMm1 IV, `LINKS`): `2p2pp22pp2`. Its coach 2 from the front, upper deck, window 5 from
  the back is 1st class ("Coach 2 of 10 · upper deck · 5th window from the back · 1st class"); window 1 isn't. The
  VIRMm1 IV's second coach: upper deck windows 6–7, lower 5–7 (drawn, 0-based).
- IC 2280 at RTD (VIRM IV + VIRMm1 VI): `2pp22p2pp2`; the VIRM IV's second coach only on the lower deck (5–7).
- SPR 4982 at UT (SLT 4 + SLT 6): `p22pp2222p`. IC 678 at UT (ICM 3): `2p2`, windows 5–9. IC 2685 at ASD (2× ICM 4):
  `22122212` ("Coach 3 of 8 · 1st class"). IC 1783 at UT (DDZ 4): `p2p2`, behind the cab upper 2–5, lower 2–3.
  SPR 5683 at UT (SNG 3): `p22`. IC 1184 at EHV (ICNG 5): `22pp2`. IC 9583 at RTD (ICNG-B 8): `22pppp22`.
  ICE 120 at UT: `????????`. Keolis 8581 at ZL (0 1st-class seats): `222`.

### App (0.31.1)
- **Seat picker**: in the side view, 1st-class windows have darker gold glass with a gold frame, and a gold "1" badge
  on the first window of each run; a coach that's all 1st class has a cream body and a gold "1st class" tag. In the
  train strip, a part-1st coach has a gold bar where its 1st class is; an all-1st coach is gold, with a "1" by its
  number. Under it the legend: "[1] = 1st class (about here)" (and "gold coach: all 1st class" when there is one).
  VoiceOver: "Coach 3 of 8, 1st class", "Coach 2 of 10, from the front, two decks, part 1st class", "…, window 5 from
  the back, 1st class".
- **Your seat** (ride screen): "Coach 2 of 10 · upper deck · 5th window from the back · 1st class" when your pick is.
  A friend's page: "Sam is in coach 3 of 8 · 1st class" the same way (from NS's drawing at the station of their coach).

## As built (0.35)

What 0.35.0 (build 127) adds: **today's best and worst trip** among friends, carried in the 0.30 `scores` box. Everything
in "As built (0.25)" to "(0.31.1)" holds unchanged: no new box kind, slot or relay route; `FriendMessage.kindsVersion`
stays. One optional field in the `scores` body, additive: an older app ignores it, a newer one reads a body without it.

### The leaderboard (why trips stopped showing, fixed in 0.35)
- Until 0.34 a finished trip was scored only when it was one of the corridor's two fixed routes ("Via Den Bosch") or,
  off the corridor only, a door-to-door trip (0.24's `DoorScore`). Since 0.19 the new look's home starts every trip as a
  planned trip (Go's board, "I'm on it", the home map, the auto-start off the corridor), and a fixed route planned again
  on board becomes one too: on the corridor no trip reached the board any more.
- Now (`ScoreRules.board`): not the demo, started at the trip's first leg; a fixed route by its name; a planned trip that
  started near Home (≤ 2.5 km; where you were if that fix was ≤ 10 min old, else its first stop) and ended near School
  (≤ 1.5 km), or the other way, as `"home→school"` / `"school→home"`, **on or off the corridor**. A single stop: never.
  Going on with a trip ended by hand (0.26.2) is still that trip. Keys and the saved board (UserDefaults `trips`) are
  unchanged; it now reads entry by entry (one bad entry no longer empties it). Android: the same rule.

### `today` in the `scores` box
- Body (0.30) gains `"today"?: [day]` (0–12, newest first): the sender's trips on the leaderboard that ended **today in
  the sender's own time zone**; absent when there are none (so a body without trips today is byte for byte 0.30's).
  day = `{"home": bool (required), "mins": number (required, 5–600, one decimal: from starting the alarm to the last
  stop), "at": t (required, when it ended), "plan"?: number (5–600: planned minutes, from starting the alarm to the
  scheduled arrival at the last stop; a planned trip only), "line"?: string (≤ 20: the ride that was latest at your
  stop, "305" for a bus, "Intercity" / "Sprinter" / the line for a train), "late"?: number (1–600: its minutes late)}`.
  `line` and `late` come together or not at all.
- Readers (`DayTrip.valid`): minutes outside 5–600 drop the trip; a `plan` outside 5–600 drops the plan; `line` cleaned
  as a name (no control characters, single spaces, ≤ 20), and an empty one or a `late` outside 1–600 drops both; at
  most 12 (the first kept). `{"on": false}` carries none.
- **Sending**: as 0.30, with one change: when `today` differs from the `today` that last went to every friend (FNV-1a 64
  over `{"on":true,"today":[…]}`, sorted keys), the body goes to every friend once the last went ≥ **5 minutes** ago
  (else a change still waits 12 h). Only while "Share my scores" is on.

### Today's best and worst (`DailyRank`, on the phone)
- Today is the **reader's** own day (local midnight to midnight): only trips whose `at` is today count, yours (from the
  leaderboard) and those of friends who share their scores; it starts again at local midnight.
- Per direction (to school first, then home): the **fastest** (least `mins`) and the **slowest** (most), ties to the
  earlier `at`, then you, then by account; no slowest with a single trip that way today.
- **With friends** (a friend's trip that way today): "🏆 Fastest today: Sam, 41 min", "🐌 Slowest today: Tom, 1 h 12 —
  the 305 was 18 min late" (you are "you"). The reason: " — the {line} was {late} min late" when `late` ≥ 3; else
  " — {mins − plan} min more than planned" when that's ≥ 5; else nothing.
- **On your own** (only your trips that way today): "🏆 Fastest today: 41 min · 9 min quicker than usual", "🐌 Slowest
  today: 1 h 05 — the Intercity was 9 min late"; one trip: "Today: 51 min · about your usual". Usual = the median of
  your trips that way in the 28 days before today, from 3 trips (none: no comparison); within 2 min is "about your
  usual", else "{n} min quicker" / "slower than usual".
- Durations: under 60 "41 min"; else "1 h", "1 h 05", "1 h 12" (minutes rounded).
- Shown: Settings › Trips & alarm › Leaderboard and Friends › Leaderboard with friends ("Today", on top), and a small
  "Today's trips" card on Friends (only when there's a trip today; it opens the leaderboard).

### Test vectors (checked in `ios/Tests/FriendExtrasBTests.swift` and `ios/Tests/DailyRankTests.swift`)
- Body (exact bytes, sorted keys, unix seconds):
  `{"month":"2027-01","on":true,"today":[{"at":1799998200,"home":false,"late":18,"line":"305","mins":72,"plan":52}]}`.
- Worked (Friday 15 January 2027, Europe/Amsterdam, now 09:00): to school today you 48.5 min (ended 08:30), Sam 41
  (08:20, plan 40), Tom 72 (08:50, plan 52, the 305 18 min late) → "🏆 Fastest today: Sam, 41 min", "🐌 Slowest today:
  Tom, 1 h 12 — the 305 was 18 min late". On your own with 50, 46 and 52 min to school the three days before (and 30,
  40 days ago, not counted): usual 50; today 41 and 65 (the Intercity 9 min late) → "🏆 Fastest today: 41 min · 9 min
  quicker than usual", "🐌 Slowest today: 1 h 05 — the Intercity was 9 min late". A trip at 23:59 the day before: none.
- Test friend (0.30.1): its `scores` now also has `today` = one trip to school an hour ago, 52.4 min, plan 45, the 305
  7 min late.

### App (0.35)
- Pure, tested: `ScoreRules` (the board's rule, the score, reading the board), `DayTrip` / `DailyRank`; `ScoresShare.today`,
  `ScoresRules.build(today:)`, `ScoresRules.due(soon:)` (`FriendExtrasB.swift`).
- `FriendTogetherStore`: `todayPeople`, and `scoresToday` in Friends/together.json (what `today` last went).
- Your year in travel (Settings › Advanced) is on the phone only and sends nothing.


## As built (relay 2026-11-27, iOS 0.42.5, Android 0.10.1)

The live link (0.30) gets a **new page**, the **whole trip** in its state (payload v2), **messages back** from the people
with the link (and the sharer's answers), and **an app that opens a live link** itself. Everything in "As built (0.30)"
and "(0.30.1)" holds: the token, the key in the fragment, the lock (`0x01 ‖ nonce ‖ AES-256-GCM ‖ tag`, AAD
`"hw-live-v1\n" + token`) and every route are as they were; a 0.30 app's links keep working and draw in the new look.

### The page (`relay/live.js`, its script `relay/live-app.js`)
- A full-screen dark map: MapLibre GL JS 4.7.1 from unpkg (pinned, with its SRI hash) and OpenFreeMap's dark style
  (`https://tiles.openfreemap.org/styles/dark`; no key, no cookies; credits folded into the map's (i)). The current
  leg's road in its line colour (the part done bright, the rest at 35 %), its stops as rings (passed ones bright), the
  stop it goes to as a green dot with its name, the vehicle as its line's pill at `pos` gliding there over 10 s (a jump
  over ~5 km, a hidden page or *reduce motion*: at once). Framed on the road and the vehicle for each new leg, then it
  follows only when the vehicle leaves the free part of the map; a drag stops that until "⌖". No WebGL or no library:
  the card alone on a dark background.
- The card (a bottom sheet with a handle on a phone: 30 / 56 / 88 % of the height; a 400 px side panel from 900 px):
  the initial on `face` (else a colour from the name); an eyebrow **Live** / **Waiting** / **Changing** / **Almost
  there** (yellow: riding and arriving within 3 min, or the next stop is the last and within 5) / **Arrived** / **Last
  seen 10:02** (grey: no update for 3 min; "· the phone may be out of reach" after 10) / **Ended** / **Key missing** /
  **Can’t open**; "Sam is on bus 305" / "to Eindhoven Centraal · on time"; an "● 12 s" age; the **listening now** strip
  (below); the big time (riding: the stop it goes to, "10:03", "in 16 min · 4 stops", "Then Campus 11:17"; waiting:
  when it leaves; at a change: where that ride gets to); a note at a change ("Waiting on platform 4 · IC 3512 leaves in
  3 min", "Walking 4 min to platform 4 · …") or almost there ("Change to IC 3512 to Breda · platform 4 · leaves 10:12
  (9 min)") or arrived ("The live trip has ended. The link stops working soon."); the legs row (`305 → 🚶 → IC → 1 →
  🚶 Campus`, done ones faded, the current outlined); the whole trip as a timeline (times on the left, done grey, "now"
  pulsing in the line colour, the rest hollow): got on, on the ride (next stop · lateness · "GPS 12 s" / "phone 12 s"),
  each change ("change · walk 4 min to platform 4", done: "got off · walking to platform 4"), each next ride ("IC 3512 to
  Breda" · from · platform · "coach 3, upper deck"), the end ("arrives · 3 min walk"). A v1 state shows its one ride and
  "Breda · there around 08:45". English only, the viewer's clock. CSP `default-src 'none'; script-src 'self'
  https://unpkg.com; style-src 'unsafe-inline' https://unpkg.com; img-src data: blob: https://tiles.openfreemap.org
  https://i.scdn.co https://*.mzstatic.com https://lastfm.freetls.fastly.net; connect-src 'self'
  https://tiles.openfreemap.org; worker-src blob:; child-src blob:; …`. No trackers; nothing but the map's tiles leaves.
- **Listening now** (only when `music` is there and its `at` is under 10 minutes old): the cover (only from `i.scdn.co`,
  `*.mzstatic.com`, `lastfm.freetls.fastly.net`; else a ♪ tile), an equalizer and "LISTENING NOW", the title, "artist ·
  app", and "Open ↗" when `url` is on `open.spotify.com`, `music.apple.com` or `www.last.fm` (https only). All text is set
  as text. The apps don't fill `music` yet (reserved: their builders take it, nil by default).
- On a phone, "Open in Haltewekker" (top right) opens `haltewekker://live/<token>#k=<key>`.

### Payload v2 (inside the same lock; `LiveTripV2` in `ios/App/LiveTripV2.swift` and `android/…/friends/LiveTripV2.kt`)
- Every v1 key stays as 0.30 has it (`v` becomes 2). Added, each optional:
  - `legs`: ≤ 12 `{mode ("bus"|"train"|"tram"|"metro"|"ferry"|"walk"), line?, num? (trains), color? ("RRGGBB": bus
    E0632E, intercity 3B44B0, sprinter 0A93B5 (line SPR…/SNG…/S + digit), tram/metro 7A55B0, ferry 2A7898; none for a
    walk), from, to (≤ 40 each), dep?, arr? (whole unix s; the current leg's `arr` its live arrival), depPlatform?,
    arrPlatform? (≤ 8; a bus's is its stop letter), coach? (1–30) and deck? ("upper"|"lower") only for the train you
    shared a coach on, late? (0–600, rides), mins? (0–120, walks)}`. Walks between rides from the planner's walk
    before each ride; the last walk to the trip's end.
  - `leg`: the index in `legs` of the ride you're on, or waiting for (at a change: the next ride).
  - `stops`: ≤ 60 of the current leg, where you got on to where you get off (more: the first 59 and the last),
    `{name, lat, lon (5 decimals, half away from zero), t? (its live time, else timetable)}`; `next`: the first with
    `t` after now (waiting: 0; none: the last).
  - `shape`: the current leg's road as Google's encoded polyline (5 decimals): the vehicle's road cut at the points
    nearest the first and the last stop (searching on from the first), equal neighbours dropped, Douglas–Peucker in
    integer 1e-5 degrees with tolerance 1, doubled until ≤ 200 points (perpendicular distance² = cross² / len², in
    doubles, the first largest wins). No road: straight between the stops.
  - `pos` gains `src`: "gps" (the vehicle's own position from the open feeds, OVapi or NS, preferred when fresh) or
    "phone" (this phone's fix, as v1).
  - `face`: the initial's colour ("RRGGBB": the friends account's avatar colour, else the accent); `inbox`: true when
    the app reads messages (the page shows its box); `music` (above): `{title (≤ 80), artist? (≤ 60), app? (≤ 20),
    url?, coverUrl? (https, ≤ 500), at (ISO 8601)}`.
- Sorted keys, no escaped slashes, at most 12 000 bytes (over it the road goes, then the stops); the relay takes ≤ 16 KB.
- Names: `name` is the sender's own — their Friends name, else the name they typed for live links (`LiveNames`); an
  empty one reads "Your friend". Nothing else is ever put there.

### Messages back
- From the page (a box when `inbox` is true: "Send Sam a message", the chips "👋 On my way", "I’m at the station",
  "Running late", "Call me", ≤ 280 characters, an optional name kept in that browser for the link) or from an app that
  opened the link: `{from (≤ 40), fromKind: "web"|"app", friendId? (an app's friends account, 32 hex), text (≤ 280),
  at}` locked with the link's key, AAD `"hw-live-msg-v1\n" + token`, posted as `POST /live/v1/msg?t=<token>
  {"data"}` (≤ 2 KB) → `{"ok","seq","at"}`. Only while the link is live; ≤ 50 a link (429 `full`), one per 10 s and 20 an
  hour per network address (hashed) and link (429 `slow_down`); 410 ended, 404 gone.
- The sharer's phone: each put's answer says `mseq` (the newest message); when it's past what it has, `POST
  /live/v1/inbox {"secret","after"}` → `{"msgs":[{"seq","at","data"}],"mseq","seen"}`. Each one a notification "💬 Kim: On
  my way" (an app's message by the friend's name when `friendId` is a friend; no name: "Someone with your link"; id
  `livemsg-<seq>`, gone after 60 min) and on the live link card; once on screen `POST /live/v1/ack {"secret","seq"}`
  and the pages say "Seen ✓✓" (`GET /live/v1/get` adds `mseq` and `seen`). No extra wake-ups: only on the ride's tick.
- "Reply": `{text, at, re?}` locked with AAD `"hw-live-reply-v1\n" + token`, `POST /live/v1/reply {"secret","data"}`
  (one per 5 s, the newest 10 kept); every page shows them under the messages (`replies` in `get`).
- All of it goes when the link ends (or at its 4 hours). Nothing logs a message, only how many.

### An app opens a live link
- `haltewekker://live/<token>#k=<key>` (the page's button), the https link (Android: opened by the app when allowed;
  both: pasted in Friends › "Follow someone’s live link", or shared to the Android app as text): the trip as the page
  reads it, polled every 15 s while it's open, with the same message box; a message from the app carries your own
  name and your friends account.

### Test vectors (`docs/live-link-vectors.json`; checked by `relay/test-live.mjs`, `ios/Tests/LiveTripV2Tests.swift`,
`android/app/src/test/java/nl/haltewekker/LiveTripV2Test.kt`)
- Secret 0x00–0x1f, key 0x20–0x3f, token `2x1Ot-EFfLIivv_lmStBuw`; the builder's input (`input`: a v1 state and the
  trip: five legs, six stops, a 20-point road, the vehicle's fix, a face, music) gives exactly
  `` {"dest":"Campus","end":1800005400,"eta":1800000960,"face":"3DD598","from":"Veghel, Busstation","inbox":true,"late":0,"leg":0,"legs":[{"arr":1800000960,"color":"E0632E","dep":1799999640,"from":"Veghel, Busstation","late":0,"line":"305","mode":"bus","to":"Eindhoven Centraal"},{"arr":1800001200,"dep":1800000960,"from":"Eindhoven Centraal","mins":4,"mode":"walk","to":"Eindhoven Centraal"},{"arr":1800003840,"arrPlatform":"6","coach":3,"color":"3B44B0","deck":"upper","dep":1800001500,"depPlatform":"4","from":"Eindhoven Centraal","late":1,"line":"IC","mode":"train","num":"3512","to":"Breda"},{"arr":1800005220,"color":"E0632E","dep":1800004440,"depPlatform":"E","from":"Breda","line":"1","mode":"bus","to":"Breda, Hogeschool"},{"arr":1800005400,"dep":1800005220,"from":"Breda, Hogeschool","mins":3,"mode":"walk","to":"Campus"}],"line":"305","mode":"bus","music":{"app":"Spotify","artist":"The Bands","at":"2027-01-15T07:59:00Z","coverUrl":"https://i.scdn.co/image/ab67616d0000b2730000000000000000000000","title":"Night Song","url":"https://open.spotify.com/track/0000000000000000000000"},"name":"Sam","next":3,"pos":{"at":1799999988,"lat":51.54801,"lon":5.4685,"src":"gps"},"shape":"mk`zHwuz`@`b@ns@be@v~@zm@jiAvkB~|Db~@rmBb[r]ja@z^fw@wj@vcA_q@~mDooBbcArNjdArN~{Bnd@zuAfJnpAlF","state":"riding","stops":[{"lat":51.61671,"lon":5.5486,"name":"Veghel, Busstation","t":1799999640},{"lat":51.605,"lon":5.53,"name":"Eerde","t":1799999880},{"lat":51.57,"lon":5.47,"name":"Sint-Oedenrode, Centrum","t":1799999980},{"lat":51.54,"lon":5.475,"name":"Rijksweg","t":1800000180},{"lat":51.512,"lon":5.493,"name":"Son, Centrum","t":1800000420},{"lat":51.44306,"lon":5.47901,"name":"Eindhoven Centraal","t":1800000960}],"t":1800000000,"to":"Eindhoven Centraal","v":2} ``
  (1751 bytes), locked with nonce `404142434445464748494a4b`. A web message `{"at":1800000030,"from":"Kim","fromKind":"web","text":"👋 On my way"}` (nonce
  `505152535455565758595a5b`), an app's `{"at":1800000040,"friendId":"3c157621a97cf055f5804a9826c6d1e1","from":"Lou","fromKind":"app","text":"I’m at the station"}` (nonce `606162636465666768696a6b`) and an answer
  `{"at":1800000060,"re":1,"text":"See you there"}` (nonce `707172737475767778797a7b`), each with its locked bytes in the file.
- The page draws it as "Sam is on bus 305" / "to Eindhoven Centraal · on time", legs `305 → 🚶 → IC → 1 → 🚶 Campus`, a
  16-point road.
