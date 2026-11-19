# Shared ride logs: reading what phones sent

Since 0.28.1 the app has **Settings › Help improve Haltewekker › Share ride logs** (off unless someone turns it on).
Phones that share send the matching and ride lines of their field log to the relay, scrubbed on the phone first:
no coordinates, no names of their places (Home and School become "Home" and "School"), no friends' names, no account
ids, no requests. Each phone's uploads are grouped by a random install id (not the Friends account). The relay keeps
them **60 days**, then deletes them. A phone can delete everything it sent at any time ("Delete what I sent").

The relay stores them already. To **read** them you need one secret, `LOGS_ADMIN_KEY`, that only you know. Until it
is set, the export answers `503 not configured`.

## 1. Add the secret once (Cloudflare dashboard)

1. Make a long random value, for example in Terminal on a Mac: `openssl rand -hex 32` (64 characters). Keep it in your
   password manager.
2. Go to <https://dash.cloudflare.com> and sign in.
3. **Workers & Pages** (left menu) › **haltewekker-relay**.
4. **Settings** › **Variables and Secrets** › **Add**.
5. Type: **Secret**. Variable name: `LOGS_ADMIN_KEY`. Value: the long random value from step 1.
6. **Deploy** (or **Save and deploy**).

`wrangler.jsonc` has `"keep_vars": true`, so the secret stays when the relay is deployed again from GitHub. Nothing
else needs setting up: the storage (a Durable Object called `Logs`) is declared in `wrangler.jsonc`.

To check it works (should give `401`, not `503`):

```sh
curl -s -o /dev/null -w "%{http_code}\n" https://haltewekker-relay.tsfaw1.workers.dev/logs/v1/export
```

## 2. Export

```sh
KEY='the value from step 1'
RELAY=https://haltewekker-relay.tsfaw1.workers.dev

# everything of the last 7 days, as JSON
curl -s -H "Authorization: Bearer $KEY" "$RELAY/logs/v1/export?since=$(( $(date +%s) - 7*86400 ))" > logs.json

# since a date, as plain text: one log line per line, "<received, UTC> <install id, 8> <app version> <line>"
curl -s -H "Authorization: Bearer $KEY" "$RELAY/logs/v1/export?since=2026-11-19&format=text" > logs.txt
```

`since` is unix seconds or an ISO date (`2026-11-19`, `2026-11-19T07:00:00Z`); it is the time the relay received an
upload. One answer holds up to 1000 uploads (`limit`, at most 5000) and about 4 MB. When there's more:

- JSON: the answer is `{"uploads":[{"id","install","app","at","lines":[…]}],"next":<id>,"more":true}`; ask again with
  `&after=<next>`.
- Text: the headers `X-Next` and `X-More` say the same (`curl -D -` shows them).

All of it, page by page, into one text file:

```sh
after=0; : > logs.txt
while :; do
  curl -s -D headers.txt -H "Authorization: Bearer $KEY" "$RELAY/logs/v1/export?since=0&format=text&after=$after" >> logs.txt
  after=$(grep -i '^x-next:' headers.txt | tr -d '\r' | awk '{print $2}')
  grep -qi '^x-more: true' headers.txt || break
done
```

A line looks like this (the sample the app shows):

```
2026-11-19T06:35:02Z 3f9a1c2e 0.28.1 (117) 2026-11-19 07:33:58 ride start · Home on board, by itself · bus 305·7821 · its stop 16630 m from you · leg 1/3
```

The second time is the phone's own clock (its time zone); `match` lines are the matcher's looks, `ride` lines what the
ride did (see `ios/App/FieldLog.swift` for every kind of line).

## Limits and answers

| Route | What | Answers |
| --- | --- | --- |
| `POST /logs/v1/put` | `{"install","secret","app","lines"}`, may be gzipped | 200, 400 bad shape, 403 another phone's id, 413 over 256 KB, 429 over 60 uploads or 3 MB a day for one phone (or 120 an hour from one network), 507 storage full (800 MB in all) |
| `POST /logs/v1/delete` | `{"install","secret"}` | 200 `{"deleted":n}`, 403 wrong secret |
| `GET /logs/v1/export` | `?since=&after=&limit=&format=` | 200, 400 bad `since`, 401 wrong or missing key, 503 `not configured` (no `LOGS_ADMIN_KEY`) |

The relay never logs a line, an install id or a key. Everything older than 60 days goes by itself (checked daily).

To check the relay by hand: `node relay/test-logs.mjs` (local, no Cloudflare), or
`node relay/test-logs.mjs https://haltewekker-relay.tsfaw1.workers.dev` (puts and deletes one throwaway upload).
