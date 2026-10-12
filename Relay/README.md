# Push relay

iPhones only get instant notifications through Apple's push service, and something has to be awake to tell Apple that mail arrived. This is that something: one Cloudflare Worker on your own (free) Cloudflare account. The Mac app does not need it.

It stores a refresh token for each account it watches, so it can read that account's mail. Run it only under your own control.

## Set up

1. In the Apple developer portal create a key with **Apple Push Notifications service** enabled and download its `.p8`.
2. `wrangler kv namespace create mach-relay`, and put the id in `wrangler.toml`.
3. `wrangler deploy`, then set the secrets:
   - `wrangler secret put RELAY_SECRET` (any long random string)
   - `wrangler secret put APNS_KEY` (paste the `.p8` text), `APNS_KEY_ID`, `APNS_TEAM_ID`
4. In the app, save `App/Resources/PushRelay.json` before building:
   `{"url": "https://<your-worker>.workers.dev", "secret": "<RELAY_SECRET>", "sandbox": true}`
   (`sandbox` is true for builds installed from Xcode, false for TestFlight and the App Store.)

With only this, the relay asks Gmail what is new once a minute.

## Instant delivery (optional)

Gmail can tell the relay the moment mail arrives. In the Google Cloud project that owns your OAuth client:

```sh
gcloud services enable pubsub.googleapis.com
gcloud pubsub topics create mach
gcloud pubsub topics add-iam-policy-binding mach \
  --member=serviceAccount:gmail-api-push@system.gserviceaccount.com --role=roles/pubsub.publisher
gcloud pubsub subscriptions create mach-relay --topic mach \
  --push-endpoint='https://<your-worker>.workers.dev/pubsub/<RELAY_SECRET>'
```

Then set `TOPICS` in `wrangler.toml` to `{"<project number>": "projects/<project id>/topics/mach"}` and deploy again. The project number is the digits before the first `-` in the OAuth client id. An account signed in under a different Google project keeps using the once-a-minute check.

## Outlook

Outlook accounts need no setup: when the app registers one, the relay asks Outlook to tell it about every change
in the inbox, on the address the app reached the relay at, and renews that each week. The address Outlook is given
is `/outlook/<word>?email=<account>`, where the word is made from `RELAY_SECRET` for that one account. It is never
the secret itself, and one account's word opens nothing else.

Snoozed Outlook mail is brought back by the relay too, as Gmail's is: once a minute it asks Outlook which mail
carries a category, and a conversation whose `Snoozed/<time>` category has come due is moved from the archive back
to the inbox, marked unread and announced on the phone. An account with nothing snoozed costs that one question.

A banner for mail from one of the account's saved Outlook contacts shows their picture. The phone fetches it from
`/photo/<word>?email=<account>&id=<contact>`, where the word is made from `RELAY_SECRET` for that one contact, so
the address opens that one picture and nothing else. The relay asks Outlook for the picture and hands it straight
on; no picture is stored. Accounts signed in before the app asked to see contacts get banners without pictures
until they sign in again.

`POST /test` with the `X-Mach-Secret` header sends a test banner to every registered phone.

## Checking a change without deploying

Nothing here touches the network or a real account: Gmail, Outlook, both sign-ins, Apple and the store are stand-ins.

```sh
cd Relay
bun test                 # the same pushes, app messages and answers as test/golden.json, plus the cost limits,
                         # and the Outlook side (test/outlook.test.js): new mail, snoozes, contact pictures
bun test/bench.js        # what one Gmail notification costs: store reads and writes, calls out, simulated time
bun test/smoke.js        # the worker in Cloudflare's own runtime on this machine (wrangler dev --local)
```

`bun test/golden.js <old worker.js>` rewrites `test/golden.json` from a copy of the relay you trust; do that before a change, not after.
