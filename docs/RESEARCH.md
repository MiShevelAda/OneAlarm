# OneAlarm: Phase 0 research

Compiled 2026-08-15. Every endpoint below was read out of source, not out of a README. Anything
marked `[inferred]` was not confirmed and must be validated against a live account before code
depends on it.

Three findings change the brief. They are at the top because they change what gets built:

1. **Whoop has a second, better path the brief did not know about.** A Swift project arms the
   strap's firmware alarm over Bluetooth, hardware-verified, no account credentials, no ToS
   exposure. It may be the better primary. It depends on which Whoop model is on the wrist.
2. **Eight Sleep gates the alarm endpoint behind an active subscription.** A live bug report shows
   `403 {"message": "subscription required"}` on the exact call we need. Auth succeeds and the
   alarm call is what fails, so this will not show up until late unless we check it first.
3. **The Eight Sleep reference library exists twice and the two copies disagree** on endpoint paths
   and field names. The one everybody actually runs is the vendored copy inside the Home Assistant
   integration, not the standalone repo of the same name.

---

## 1. Eight Sleep

### 1.1 There are two pyEight codebases and only one is worth porting

| | `lukas-clarke/pyEight` standalone | `lukas-clarke/eight_sleep` vendored copy |
|---|---|---|
| Last commit | 2025-07-16 | active through 2025-07-27 |
| Alarm read | tries four URLs in a loop, including the dead `/routines` | `GET /v2/users/{id}/alarms`, one call |
| Snooze and dismiss | `PUT /v1/users/{id}/routines` (obsolete) | dedicated `/snooze` and `/dismiss` paths |
| Contains a destructive routine | **yes, see 1.7** | no |

The Home Assistant integration does not install pyEight from PyPI. Its `manifest.json` requires only
`httpx` and `aiohttp`, and it ships its own copy. So the vendored copy is what thousands of users
run against the live API and the standalone repo is a stale side branch.

**Port the vendored copy.** Everything below is the vendored copy.

Eight Sleep deleted the Routines feature from its app and alarms moved to a dedicated API. Any
write-up that PUTs to `/v1/users/{id}/routines` for alarm control is obsolete. Neither codebase has
had a release in about twelve months, so treat this whole section as a starting hypothesis to
validate rather than a guarantee.

> **That paragraph is about v1, and it does not retire the object in §1.5.** Two different things
> are called routines. `/v1/users/{id}/routines` is the deleted feature, and OneAlarm never writes
> it. `/v2/users/{id}/routines/{routineId}` is the current object their app renders alarms through,
> and OneAlarm reads and writes it. A session that reads the paragraph above without reading §1.5
> will conclude the routine write is dead code and delete it. It is not. See §1.5.

### 1.2 Auth

A password grant, with credentials extracted from the Android APK and hardcoded in the library.
They are public.

```
AUTH_URL            = https://auth-api.8slp.net/v1/tokens
KNOWN_CLIENT_ID     = 0894c7f33bb94800a03f1f4df13a4f38
KNOWN_CLIENT_SECRET = f0954a3ed5763ba3d06834c73731a32f15f168f47d4f164751275def86db0c76
```

The body is **JSON, not form-encoded**. This is the most common porting mistake, because a standard
OAuth2 client library will send `application/x-www-form-urlencoded` and fail.

```http
POST https://auth-api.8slp.net/v1/tokens
content-type: application/json
user-agent: Home Assistant 1.0.18
accept: application/json

{
  "client_id": "0894c7f33bb94800a03f1f4df13a4f38",
  "client_secret": "f0954a3ed5763ba3d06834c73731a32f15f168f47d4f164751275def86db0c76",
  "grant_type": "password",
  "username": "you@example.com",
  "password": "..."
}
```

Response, of which only three fields are read:

```json
{ "access_token": "...", "expires_in": 604800, "userId": "..." }
```

`expires_in` is seconds. The `604800` above is `[inferred]`, read it off the response rather than
hardcoding it.

**There is no refresh token.** Refresh is a full re-POST of email and password. That is triggered
proactively 120 seconds before expiry, and reactively on a 401, retried exactly once behind an
`_is_retry` guard. **Consequence for us: the plaintext password has to be retained for the life of
the app.** Keychain, never `UserDefaults`.

### 1.3 Hosts and headers

| Host | Used for | Auth header |
|---|---|---|
| `auth-api.8slp.net` | token issue only | none |
| `client-api.8slp.net` | account, device list, per-user profile, side | Bearer |
| `app-api.8slp.net` | **alarms**, temperature, away mode, base, audio | Bearer |

Sent on every authenticated call: `content-type: application/json`,
`user-agent: Home Assistant 1.0.18`, `accept: application/json`, `authorization: Bearer <token>`.

Three notes for the Swift port:

- **There is no app-version header.** Looked for one specifically. None exists.
- pyEight sends a literal `host: app-api.8slp.net` header even on `client-api` requests. That is a
  latent bug the API tolerates. `URLSession` computes `Host` per request and will not let you
  reproduce it. That is correct behaviour, do not chase it.
- `constants.py` defines a second `DEFAULT_HEADERS` with `okhttp/4.9.3` and HTTP/2 pseudo-headers
  `:authority` and `:scheme`. It is dead code, never referenced. `URLSession` would reject the
  pseudo-headers. Do not copy them.

### 1.4 Discovery

For a single-account app this collapses to two calls, because **every alarm endpoint is keyed on
`userId` alone and none of them need the bed side**.

```http
GET https://client-api.8slp.net/v1/users/me
    -> { "user": { "devices": ["<deviceId>"], "features": ["cooling", "elevation"] } }
```

`userId` also comes back from the auth response, so the full four-call discovery chain that pyEight
runs (device list, `devices/{id}?filter=leftUserId,rightUserId,awaySides`, `users/{userId}`,
`users/{userId}/current-device`) is only needed if we ever want side-specific state. Recorded here
so we do not rediscover it: side values are `left`, `right`, `solo`, and `solo` maps to `left` when
building device JSON keys. Note that `users/{userId}` nests side under `user.currentDevice.side`
while `users/{userId}/current-device` returns `side` at the top level. Easy mismatch to introduce.

### 1.5 Alarm endpoints

All on `app-api.8slp.net`. **Reads are v2, writes are v1.** That is not a transcription error, the
API is genuinely inconsistent, and it is confirmed by both the source and a live bug report.

**List**

```http
GET https://app-api.8slp.net/v2/users/{userId}/alarms
```

```json
{
  "alarms": [{
    "id": "uuid",
    "enabled": true,
    "time": "07:00:00",
    "repeat": { "enabled": true, "weekDays": { "monday": true, "saturday": false } },
    "thermal": { "enabled": true, "temperature": -10 },
    "vibration": { "enabled": true, "level": 50, "pattern": "rise", "duration": 300 },
    "snoozing": false, "snoozedUntil": null,
    "nextTimestamp": "2025-01-15T07:00:00Z",
    "startTimestamp": "2025-01-15T06:55:00Z",
    "endTimestamp": "2025-01-15T07:30:00Z",
    "dismissedUntil": null
  }],
  "recommendedAlarm": {}
}
```

Five fields are server-computed and **must be stripped before any write**: `nextTimestamp`,
`startTimestamp`, `endTimestamp`, `dismissedUntil`, `snoozedUntil`.

**Update time, and enable or disable.** Both are the same call. It is a **read-modify-write of the
entire object**, not a patch. Take the object from the list response, strip the five computed
fields, replace `time` or `enabled`, send the whole thing back. A partial PUT is untested.

```http
PUT https://app-api.8slp.net/v1/users/{userId}/alarms/{alarmId}
```

**Create a one-off**

```http
POST https://app-api.8slp.net/v1/users/{userId}/alarms
{ "time": "07:00:00", "enabled": true,
  "vibration": { "enabled": true, "powerLevel": 50, "pattern": "RISE" },
  "thermal": { "enabled": true, "level": 0 } }
```

Omitting `repeat` entirely is what makes it one-off.

**Snooze and dismiss**

```http
PUT .../alarms/{alarmId}/snooze    { "snoozeMinutes": 9, "ignoreDeviceErrors": false }
PUT .../alarms/{alarmId}/dismiss   { "ignoreDeviceErrors": false }
```

Snooze returns **200 with an empty body**, so do not try to decode JSON from it. Both return **409
when the alarm is not currently ringing**, which is an expected no-op and not an error. There is no
separate stop endpoint: stop is dismiss.

**Weekdays are seven lowercase named booleans**, not a bitmask and not an array:
`{"monday": true, "tuesday": true, ... "sunday": false}`.

**A field-name contradiction we must resolve before writing anything.** The create payload uses
`vibration.powerLevel` and `thermal.level`. The read shape documents `vibration.level` and
`thermal.temperature`. Both come from the same file about thirty lines apart. Casing disagrees too,
`"RISE"` on create against `"rise"` on read. Either the API accepts both or one docstring is wrong.
**This is the single highest-value thing to test first**, because it is a write-path mismatch on the
exact operation the product depends on.

### 1.5b Routines, the object their app actually renders alarms through

**Added 17 August, and it is the reason two weeks of "the write returns 200 and nothing appears"
finally made sense.** Eight Sleep's app does not render the alarm list from §1.5. It renders
routines, and each routine carries its own alarms. An alarm created standalone through
`POST /v1/users/{id}/alarms` belongs to no routine, so it exists on the API and is invisible in the
app. That is also why the account returned three alarms where the app showed two.

**This is not the retired feature in §1.1.** `/v1/users/{id}/routines` is the deleted one. This is
`/v2`, a different object, and both facts hold at once.

```http
GET https://app-api.8slp.net/v2/users/{userId}/routines
PUT https://app-api.8slp.net/v2/users/{userId}/routines/{routineId}
```

```json
{
  "id": "uuid",
  "enabled": true,
  "days": ["monday", "tuesday", "wednesday", "thursday", "friday"],
  "bedtime": { "time": "22:30:00", "dayOffset": "MinusOne" },
  "alarms": [],
  "alarmsToCreate": [{
    "enabled": true,
    "disabledIndividually": false,
    "timeWithOffset": { "time": "07:00:00", "dayOffset": "Zero" },
    "settings": { "vibration": {}, "thermal": {} },
    "dismissedUntil": "1970-01-01T00:00:00Z",
    "snoozedUntil": "1970-01-01T00:00:00Z"
  }]
}
```

Note the differences from §1.5, each of which will bite somebody:

- **`days` is an array of lowercase names**, where an alarm's `repeat.weekDays` is seven named
  booleans. Same week, two encodings, one service.
- **`dayOffset` is a string enum, not a number.** `"Zero"` for an alarm, `"MinusOne"` for a bedtime.
  Confirmed by two independent implementations, `atfinke/EightSleep` and `blacktop/clim8`. Sending
  `0` is the obvious guess and it is wrong.
- **`alarmsToCreate` is how a new alarm becomes visible.** Append an entry, PUT the routine.
- **The PUT replaces the routine.** Read modify write, and echo back every field including ones with
  no known meaning, exactly as with alarms.

**What OneAlarm authors here, and nothing else:** `days` and `enabled` on a routine it owns, and new
entries in `alarmsToCreate`. Never `bedtime`, per Alex: when he goes to bed is not an alarm setting.
Never `vibration` or `thermal`, which are copied from an existing alarm and echoed, never composed.

**Unverified on his account.** Every line above comes from public captures, not from a response
Eight Sleep has sent us. `retiredRoutinesProbe` and the raw routines panel exist to replace this with
his own data on the next run. Until then treat it as §1.1 says: a starting hypothesis.

### 1.6 Timezone semantics

**Writes are bare local wall clock, `"HH:MM:SS"`, no offset, no UTC conversion.** Traced the full
chain and there is no conversion anywhere. The account timezone does not affect the payload: it is
used only for the trends query parameter and for display formatting.

**Reads are ISO8601 UTC with a `Z`.** So the direction of travel is asymmetric and both need
handling.

**What could not be confirmed: which timezone the server resolves `"07:00:00"` against.** It must be
stored server-side, since the client never transmits one on the alarm write. No client code reads
it and no documented response carries it. If that stored zone is wrong or stale, the alarm fires at
the wrong absolute time and **the client cannot detect it from the write alone**.

**Mitigation, and this should be mandatory rather than optional in our client:** after every write,
GET the alarm list and assert the returned `nextTimestamp` is the absolute UTC instant we intended.
That read-back is the only reliable verification available.

### 1.7 Hazards

**Do not port `_bootstrap_alarm_discovery()` from the standalone repo.** It loops ten common wake
times issuing real `POST .../alarms` calls hoping an error response leaks the alarm list, and if
they succeed it **creates up to ten real alarms on the live account** at 04:30 through 23:00. It
then regex-parses JSON out of error strings inside a bare `except`. This alone disqualifies that
repo.

**Blocklist. Same bearer token reaches all of these, and none are in the alarm path.** Use an
allowlist so none can fire:

| Path | Why |
|---|---|
| `POST /v1/devices/{id}/priming/tasks` | physically runs the pump, loud, minutes long |
| `POST /v1/users/{id}/base/angle` | **moves the bed frame while someone may be in it** |
| `PUT /v1/users/{id}/temperature` | changes bed temperature, and silently turns the side on first |
| `PUT /v1/users/{id}/away-mode` | backdates 24h to force an immediate trigger |
| `PUT /v1/users/{id}/audio/player/*` | plays audio out loud |
| `PUT client-api/v1/users/{id}/current-device` | reassigns which side of the bed the account owns |
| `PUT /v1/users/{id}/bedtime` | overwrites the whole temperature schedule |
| `DELETE /v1/users/{id}/alarms/{alarmId}` | unverified, irreversible, and we do not need it |

**403 `{"message": "subscription required"}` is the single biggest project risk.** A live issue from
2026-04 shows the alarms endpoint returning it. Auth succeeds; the alarm call is what fails. Confirm
the account has an active subscription before writing Swift, and surface this as its own error
state rather than a generic failure.

**Other error behaviour.** 401 refreshes and retries once, and dropping the retry guard gives an
infinite loop. 429 is real and observed, but pyEight has no 429 handling at all, so write our own
backoff rather than copying it. pyEight also string-matches status codes out of formatted messages
(`if "409" in str(err)`); model a proper Swift error enum on the status code instead. Its
`DEFAULT_TIMEOUT` is 2400 seconds, which is forty minutes and almost certainly a bug, since the
constant is defined twice in the same file.

### 1.8 Validate first, in this order

One `curl` of the auth call plus one GET of the alarm list confirms auth, headers, subscription
status and the true read-shape field names, and costs nothing. Then create one throwaway alarm and
diff the read-back against what was sent.

Open questions to close by testing: `powerLevel` against `level` and `thermal.level` against
`thermal.temperature`; the real `expires_in`; whether `repeat.enabled: false` yields a one-off; the
valid set and casing of `pattern`; units of `vibration.duration`; the POST create response shape,
since we need the new alarm id from it; what `ignoreDeviceErrors` actually does.

---

## 2. Whoop

### 2.1 Two paths, and the one the brief specified is the weaker one

The brief named `whoop-mcp`. It was renamed to **`thebriangao/totem`** at v1.4.4 in June 2026, is
alive, and its Smart Alarm write is genuinely implemented in shipped TypeScript rather than merely
claimed in a README. That much is confirmed.

But a second project turned up that the brief did not know about: **`ryanbr/noop`**, roughly 612
stars, committed today, **already written in Swift**, which arms the strap's own firmware alarm over
Bluetooth with no cloud API at all.

| | HTTP path (totem) | BLE path (noop) |
|---|---|---|
| Credentials stored | Whoop email and password | none |
| ToS exposure | real, membership could be terminated | none, it talks to your own hardware |
| Breaks when Whoop changes a backend | yes, silently | no |
| Language to port from | TypeScript | **already Swift** |
| Hardware verification | none, no alarm fixture in the repo | **confirmed buzzing on a real WHOOP 4.0** |
| Recurrence | native, `scheduled_days` | one-shot epoch, so we re-arm daily |
| Verified on WHOOP 5 / MG | endpoints are model-agnostic | **no, arm ACKs but firing unverified** |

### 2.2 Why the HTTP path is weaker than it first appears

The `PUT /smart-alarm-bff/v1/schedule/{id}` body was presented as a literal captured mitmproxy
request. **On 2026-08-15 a live account disproved it**: see the correction in 2.3. The endpoint and
the method were right; the body was not. Everything around it was already thinner:

- The repo has 235+ tests and 30+ captured JSON fixtures, and **not one is a smart-alarm fixture**.
  Every other major surface has a recorded response. The alarm does not. This is what a wrong body
  looks like before you find out: there was nothing to check it against.
- The GET response shape carries the author's own hedge in a source comment: *"so on GET they're
  likely inside `alarm_bounds`"*. The projection tolerates both `schedule_id` and `id` because he
  was not sure which the API returns. `schedule_id` is the one that came back.
- Schedule **create** and **delete** were never captured. Only PUT on an existing schedule.
- `PUT /smart-alarm-service/v1/strap-status`, which pushes the time to strap firmware, is
  **deliberately not sent** by totem, which relies on the official app being installed to sync.
  If our app is the only client touching the alarm, **this may be the difference between the cloud
  setting changing and the strap actually buzzing.** This is the gap most likely to produce a
  working-looking port that does not wake you up.
- The ~30-day refresh lifetime is inferred from an observed 401 error string, not documented.
- Single source. No second project independently corroborates the alarm write over HTTP.
- The bundled client fingerprint (`x-whoop-ios-version: 5.52.0`) was captured 2026-05 and totem
  itself prints a staleness warning after six months. **That clock runs out this November.**

Its author's own FAQ, unsoftened: *"Whoop's terms reserve the right to take action against accounts
they catch using unsupported integrations, realistically that means suspending API access or
terminating the membership. If losing your Whoop account would be a problem for you, don't use
this."*

### 2.3 HTTP spec, if we go that way

Auth is **AWS Cognito reached through Whoop's own proxy**, not Cognito directly. Whoop's backend
injects the `ClientId` and `SECRET_HASH`, so **we do not need the iOS app's client secret**, we send
`"ClientId": ""` literally.

```
POST https://api.prod.whoop.com/auth-service/v3/whoop/
content-type: application/x-amz-json-1.1
x-amz-target: AWSCognitoIdentityProviderService.InitiateAuth
amz-sdk-invocation-id: <fresh UUID per request>
amz-sdk-request: attempt=1; max=1
user-agent: aws-sdk-swift/1.5.86 ua/2.1 api/cognito_identity_provider#1.5.86 os/ios#26.3.1 ...

{"AuthFlow":"USER_PASSWORD_AUTH",
 "AuthParameters":{"USERNAME":"...","PASSWORD":"..."},
 "ClientId":""}
```

Missing the AWS SDK header fingerprint gets a Cloudflare 403. An MFA challenge comes back with
`ChallengeName` plus `Session`, answered via `RespondToAuthChallenge` with `SMS_MFA_CODE`,
`SOFTWARE_TOKEN_MFA_CODE` or `EMAIL_OTP_CODE`. Codes expire in about three minutes. Refresh is
`REFRESH_TOKEN_AUTH` and returns **no new refresh token**, so the original is reused.

Access token is a JWT lasting exactly 24h (`ExpiresIn: 86400`). The refresh token is an opaque JWE,
so **its expiry cannot be read locally**, which is why the 30-day figure is an inference.

The write, which is the whole point. It **replaces rather than merges**, so read first, edit, resend:

```http
PUT https://api.prod.whoop.com/smart-alarm-bff/v1/schedule/{schedule_id}?apiVersion=7
{"sleep_goal":"",
 "day_of_week_list":["MONDAY","TUESDAY","WEDNESDAY","THURSDAY","FRIDAY"],
 "time_zone_offset":"+0200",
 "enabled":true,
 "latest_wake_time":"07:45:00",
 "alarm_mode":"IN_THE_GREEN"}
```

> **Confirmed working against a live account, 2026-08-16, 02:00.** Six keys, exactly as above,
> nothing echoed from the read. The Whoop app shows the new time afterwards.
>
> **This body was in this document all along and I spent five hours declaring it fiction.** The
> record of how, because the mistake is more instructive than the fix:
>
> `GET /smart-alarm-bff/v1/schedule/all` came back with `scheduled_days`, `alarm_on` and
> `latest_wake_time: "7:45 am"`, so I concluded `day_of_week_list`, `enabled`, `time_zone_offset`
> and `sleep_goal` did not exist and wrote that into this file as a finding. **They do exist. That
> GET is not the schedule.** Its top level carries `delete_error_modal`,
> `deleting_in_progress_modal`, `schedule_button_component`, `schedule_disabled_text` and
> `should_show_overlay`: it is a rendered description of Whoop's alarm *screen*. `bff` means
> backend for frontend and this one means it literally. A view model's field names are not the
> resource's, its `latest_wake_time` is a **label**, and I disproved a specification using evidence
> that could never have contained it.
>
> Three further errors followed from that one, each of which felt like progress:
>
> 1. **Mirroring the read format on the write.** Sending `"1:00 pm"` back is sending a rendered
>    string as data. The right format was `"07:30:00"` from the start.
> 2. **Treating one 400 as proof.** `"1:00 pm"` gave 400, `"07:55:00"` gave 422, and I concluded
>    the endpoint parses one and not the other. Those two requests differed in **three** ways:
>    format, clock value, and the fact that 13:00 is an implausible wake ceiling. One observation
>    with three variables moved is not evidence, and it went into two doc comments as settled.
> 3. **Concluding the body was exonerated.** After two 422s I said the body could not be the
>    problem. Both attempts were the same shape, and the six-field body had been written but never
>    run. The experiment that would have settled it had not happened.
>
> The general lesson, which is worth more than the endpoint: **a wrong model of what an endpoint
> returns will keep generating hypotheses that each explain the last failure**, and each will feel
> like a discovery. What broke the loop was dumping the response and reading it, not reasoning
> harder. That worked twice tonight and nothing else worked at all.

> **The schedule row's real field list, off Alex's account, 17 August 15:53.** Printed rather than
> inferred, which is the only thing that has ever worked on this service:
>
> ```
> alarm_mode, alarm_mode_label_display, alarm_on, days_scheduled_label_display,
> delete_label_display, edit_label_display, latest_wake_time, schedule_id, scheduled_days
> latest_wake_time = 6:55 AM
> scheduled_days   = (MONDAY, TUESDAY, WEDNESDAY, THURSDAY, FRIDAY)
> alarm_on         = 1
> ```
>
> **`delete_label_display` and `edit_label_display` are new**, and neither appears anywhere in this
> document or in the reference work. They are rendered labels, so they are not endpoints, but they
> say that this screen's model **describes a delete and an edit action per schedule**. That is the
> most promising lead yet for the two things this leg still cannot do, creating a schedule and
> removing one. Their **values** have never been printed, only their names, and the value is where
> an action target would live if one exists. `E21`.

**Read format and write format are different objects, and this is the durable fact.**

| | `GET /schedule/all` | `PUT /schedule/{id}` |
|---|---|---|
| what it is | the list screen, rendered | the resource |
| days | `scheduled_days` | `day_of_week_list` |
| enabled | `alarm_on`, as `1` | `enabled`, as `true` |
| wake time | `latest_wake_time`, `"7:45 am"` | `latest_wake_time`, `"07:45:00"` |
| timezone | absent | `time_zone_offset`, `"+0200"` |
| also present | six `*_label_display` strings, `schedule_id`, modals, button components | nothing else |

**`GET /smart-alarm-bff/v1/schedule/components/populated/{schedule_id}?apiVersion=7`** renders the
**edit** screen for one schedule: `repeat_days`, `wake_mode`, `wake_time`, `sleep_goal`. That is the
place to look first next time, and it is a read.

Semantics worth knowing before designing the UI:

- The smart-wake window is **a latest wake time plus a mode**, not an earliest and latest pair.
  `latest_wake_time` is the hard ceiling and `alarm_mode` decides how the strap picks a moment
  before it: `IN_THE_GREEN`, `EXACT_TIME_PEAK`, `EXACT_TIME_OPTIMIZE_SLEEP`.
- The `lower_time_bound` and `upper_time_bound` pair in global preferences is **ignored by the
  server whenever an explicit schedule exists**. Do not set wake time through it.
- `alarm_mode` on a live account also takes `SLEEP_GOAL` and `EXACT_TIME`, which the reference did
  not list. **`SLEEP_GOAL` means Whoop derives the wake time from sleep need**, so a fixed
  `latest_wake_time` is arguing with the feature rather than using it. The right handling is to
  reverse the direction and let Whoop be the anchor the other devices follow. Not built yet.
- There are **three independent enable levels**: per-schedule `enabled` on the resource,
  `schedule_enabled` at the top of the list screen, and a master
  `PUT /smart-alarm-service/v1/alarm-schedule/enable|disable`. All three are real; the second one
  produced the *"alarm schedule is switched off"* message while a schedule existed.
- 🔴 **A successful write may not reach the strap.** `PUT /smart-alarm-service/v1/strap-status`
  with `{"strap_driven_alarm_time": "<ISO instant>"}` is what pushes the time into strap firmware,
  and the Whoop app sends it on a delay after a schedule edit. **We do not send it**, and it is
  outside the allowlist. So the app showing the new time and the wrist buzzing at the new time are
  still two different claims, and only the first is verified. If the strap buzzes late, this is
  why.

One irony in our favour: a native Swift app naturally produces the iOS TLS and HTTP/2 fingerprint
that totem explicitly says it cannot fake from Node. Our port is less detectable than the thing we
are porting from.

### 2.4 Whoop hazards

**Never build a retry loop around `USER_PASSWORD_AUTH`.** `429 TooManyRequestsException` is real on
the auth endpoint and repeated bad passwords will hit it. One attempt, surface the error, stop.

**Allowlist, do not blocklist.** Destructive surface reachable with the same token includes
`DELETE /v2/user/access`, `DELETE /core-details-bff/v1/cardio-details`,
`DELETE /health-service/v1/hormonal-insights/settings/mci`,
`DELETE /users-service/v1/hidden-metrics/{METRIC}`, and the whole `onboarding-service` account
lifecycle surface. Also **never send `POST /smart-alarm-service/v1/smartalarm/wbl`**: it is not
destructive, but it reports device state and firmware versions, and sending fabricated values there
is the most fingerprintable thing we could do.

**The official API is confirmed read-only.** Thirteen endpoints, six read scopes, and the only
non-GET is `DELETE /v2/user/access` which revokes your own grant. There is no alarm surface and no
prospect of one.

### 2.5 Recommendation

**Which Whoop model is on the wrist decides this, and it is the one thing needed from Alex before
the Whoop leg can be sequenced.**

- **WHOOP 4.0** → port the BLE path. Already Swift, hardware-verified, no credentials stored, no
  account risk. Key files are `Strand/BLE/Commands.swift` (`setAlarmPayload`, a nine-byte frame) and
  `Strand/BLE/BLEManager.swift` (`armStrapAlarm`, `disableStrapAlarm`, `getStrapAlarm`). Constraints
  to respect: send `SET_CLOCK` first or it fires at the wrong wall-clock time, and it is one-shot
  absolute epoch so daily re-arm is our job.
- **WHOOP 5 or MG** → BLE firing is unverified, so HTTP becomes the only option. Build it read-first:
  GET both alarm endpoints, log the real JSON, and only then write the PUT against shapes we have
  personally seen. Do not port totem's projection blind.

---

## 3. AlarmKit

This is the clean leg. It is a real Apple framework, fully documented, and the research came back
almost entirely from primary Apple sources.

### 3.1 Pinned versions

| Item | Value |
|---|---|
| Minimum iOS and iPadOS | **26.0**, unchanged since release |
| macOS native, visionOS, tvOS | **not available** |
| watchOS | **not available as a framework**, see below |
| Xcode | **26.0**, the iOS 26 SDK. Secondary-sourced, Apple states no AlarmKit-specific minimum |
| Swift | 6.2 with Xcode 26.0, language mode 5 or 6 both fine. The API is `Sendable`-clean `[inferred]` |

**Apple Watch: confirmed, with the mechanism corrected.** Alarms do surface on a paired Watch and
fire there, per Apple's framework blurb and the WWDC25 session. But AlarmKit is **not** a watchOS
framework and cannot be linked on watchOS. This is system relay behaviour, so there is no watch
target to build and no integration work, exactly as the brief assumed, just for a different reason
than "AlarmKit runs on the Watch". Relay behaviour when the Watch is out of range or in Theater
Mode is not documented anywhere.

### 3.2 One API change since release, in iOS 26.1

`AlarmPresentation.Alert` lost its developer-supplied stop button, because iOS 26.1 replaced
tap-to-stop with slide-to-stop system-wide.

- `init(title:stopButton:secondaryButton:secondaryButtonBehavior:)` is **deprecated in 26.1**, with
  the verbatim message `"stopButton is deprecated and will no longer be used"`.
- The replacement is `init(title:secondaryButton:secondaryButtonBehavior:)`, with a system-provided
  stop control.

We target 26.1+ and use the new initializer. No `#available` branch, no deprecation warning.

### 3.3 The entitlement that does not exist

**There is no AlarmKit entitlement and no AlarmKit capability in the Developer Portal.** Recording
this loudly because it is a known and specific model hallucination: the invented string is
`com.apple.developer.alarmkit`, and if it lands in an `.entitlements` file the device build fails
with "Provisioning profile does not include the com.apple.developer.alarmkit entitlement." An Apple
engineer said on the record that they are "seeing an increase in LLMs making up non-existent
entitlements causing similar problems."

**If that build error appears, the fix is to delete the line.** Do not go looking for the capability
in the portal. No background modes are required either, since the system alarm daemon owns
scheduling rather than our app.

The one required piece of configuration is `NSAlarmKitUsageDescription` in Info.plist. Apple, and
this is load-bearing: "If the key is missing **or its value is an empty string**, apps can't
schedule alarms with AlarmKit." An empty string is a hard failure, not a cosmetic one.

### 3.4 The API we need

```swift
let time = Alarm.Schedule.Relative.Time(hour: 7, minute: 0)
let schedule: Alarm.Schedule = .relative(.init(time: time, repeats: .weekly(weekdays)))
let alert = AlarmPresentation.Alert(title: label, secondaryButton: nil, secondaryButtonBehavior: nil)
let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert),
                                 metadata: OneAlarmMetadata(), tintColor: .blue)
let config = AlarmManager.AlarmConfiguration(countdownDuration: nil, schedule: schedule,
                                             attributes: attributes, sound: .default)
try await AlarmManager.shared.schedule(id: UUID(), configuration: config)
```

- **The timezone trap, and it is the easiest bug to ship.** `.fixed(Date)` is an absolute instant
  that does not track the device timezone, and it cannot repeat. A 07:00 wake-up must be
  `.relative`, which is timezone-relative and repeats. Note this is the **opposite** convention to
  Eight Sleep, where wall clock is what goes on the wire and the server owns the zone.
- **Weekdays are `[Locale.Weekday]`**, the Foundation type, not a bitmask and not `Calendar`
  indices. Recurrence is `.never` or `.weekly([Locale.Weekday])`. There is no daily case, so every
  day is `.weekly(Locale.Weekday.allCases)` `[inferred]`.
- **A repeating weekly alarm is one alarm, not seven.**
- `AlarmMetadata` has no requirements, so `struct OneAlarmMetadata: AlarmMetadata {}` is legal and
  sufficient.
- Authorization is a **one-time prompt** with three states, `notDetermined`, `authorized`, `denied`.
  If denied, every scheduling attempt fails. It fires automatically on first alarm if we do not call
  `requestAuthorization()` ourselves; calling it explicitly just controls when. Users can change it
  in Settings later, so read `authorizationState` or observe `authorizationUpdates` rather than
  caching the answer.
- State transitions are `cancel`, `stop`, `countdown`, `pause`, `resume`, and they are
  **synchronous and throwing, not async**. Only `schedule` is async.
- `AlarmError` has exactly **one** documented case, `maximumLimitReached`. The numeric limit is not
  published anywhere, so handle the error and do not assume a cap.

### 3.5 The Live Activity coupling, and when it is mandatory

`AlarmAttributes` conforms to `ActivityAttributes`. That is the whole coupling: it is the same type
handed to `ActivityConfiguration(for:)` in a widget extension. We never call `Activity.request`,
AlarmKit starts and ends the Live Activity itself, we only supply views.

**It is conditionally mandatory, and the failure is silent.** Apple, marked Important: "AlarmKit
expects a widget extension **if an app supports a countdown presentation**. Otherwise, the system
may unexpectedly dismiss alarms and fail to alert."

- Alert-only alarm, no `countdownDuration`, no countdown or paused presentation: **no widget
  extension needed**.
- Any countdown or paused presentation, **including snooze**, since snooze is `postAlert` plus a
  `.countdown` secondary button: **widget extension required**, and omitting it means alarms get
  dismissed and fail to alert.

**This directly scopes v1: ship the alarm without snooze and we skip an entire target.** Snooze is a
Phase 3 item that brings a widget extension with it.

### 3.6 Gotchas worth designing around

- **Silent mode and Focus are overridden, confirmed**, with no entitlement and no critical-alert
  approval needed. That is the whole point of the framework. It is still explicitly not a
  critical-alert substitute and is for fixed pre-determined times only.
- **The app does not need to be running.** A system daemon owns the schedule.
- **Fired one-shot alarms are deleted from the daemon's store**, so there is no history. Apple's
  guidance: if you need to know an alarm fired, persist your own record and diff it against
  `AlarmManager.shared.alarms`. Absence from the list means it fired.
- **The simulator is unreliable and a simulator failure is not evidence of a bug.** Since 26.1,
  alerts do not fire in the simulator when the screen is locked; `sound:` misbehaves, with `.default`
  reportedly silent; Dynamic Island presentation is unreliable there while correct on device.
- **Open Apple bug FB20472264:** after a device restart or OS update, `LocalizedStringResource`
  values in alarm UI render as their raw keys, because strings are resolved at fire time rather than
  at configuration time. Acknowledged by an Apple engineer, unresolved as of 26.1 beta 2, and we
  could not confirm a fix in later 26.x. **The alarms themselves survive reboot, only the strings
  degrade** `[inferred]`. Cheap mitigation, which we should just adopt: name localisation keys
  identically to their English strings.

### 3.7 What could not be verified

The numeric alarm limit. The full declarations of `AlarmPresentation.Countdown` and `.Paused`, whose
shape came from Apple's sample code rather than a declaration. The associated-value shape of
`AlarmPresentationState.Mode`. That `Alarm.ID` is `typealias ID = UUID` `[inferred]` from `var id:
UUID`. The valid range of `Time.hour`. Whether FB20472264 is fixed after 26.1. File requirements for
`AlertSound.named(_:)`. **And nothing was compiled**, because this container has no Xcode, so the
reference snippet is compile-plausible rather than compile-verified.

## 4. iOS secure credential storage

We store three things: an Eight Sleep password (not a token, because Eight Sleep has no refresh
token and re-auth is a full password POST), a Whoop refresh token, and a Whoop password if we take
the HTTP path. The Eight Sleep password is unavoidable, which raises the stakes on this section.

### 4.1 There is no Swift-native Keychain API

Checked specifically, including WWDC25 and WWDC26. `SecItemAdd`, `SecItemCopyMatching`,
`SecItemUpdate` and `SecItemDelete` remain the only Apple-supported entry points and they are still
Core Foundation C APIs. Apple's own current guidance is a DTS forums post by Quinn that exists
because the API "is kinda clunky to call from Swift."

**Take no dependency.** Apple's documented position, under "Think Before Wrapping", is that a
third-party wrapper adds a dependency, obscures the real `OSStatus`, and may model the keychain
differently from how it actually works. Write roughly 120 lines ourselves and surface the raw
status codes. For three credentials that is clearly right.

### 4.2 The accessibility class, which is a real decision

| Value | Readable while locked | Leaves the device |
|---|---|---|
| `WhenUnlocked` (**the default when omitted**) | no | yes |
| `AfterFirstUnlock` | yes, after one unlock since boot | yes |
| `AfterFirstUnlockThisDeviceOnly` | **yes** | **no** |
| `Always` / `AlwaysThisDeviceOnly` | deprecated since iOS 12, do not use | |

**Use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, set on add only, with
`kSecAttrSynchronizable = false` on every query and every add.**

Both halves are load-bearing. Anything readable in the background rules out the `WhenUnlocked`
variants, and **the default is `WhenUnlocked`**, so omitting the attribute silently produces
`errSecInteractionNotAllowed` on any locked-device read. `ThisDeviceOnly` binds the item to hardware
keys so it is excluded from backups and never migrates to a restored or new phone, which is what we
want for a credential on one personal device.

### 4.3 Do not biometric-gate the credential items

**A biometric-gated keychain item cannot be read by a background task.** There is no UI to present
from a background context, so the read fails, and the correct background query flag
(`kSecUseAuthenticationUISkip`) makes such items simply invisible rather than readable.

So: **no `SecAccessControl` on the token items.** Gate the *UI* instead. Any screen that reveals or
changes a credential calls `LAContext().evaluatePolicy(.deviceOwnerAuthentication, ...)`, using
`.deviceOwnerAuthentication` rather than `.deviceOwnerAuthenticationWithBiometrics` so passcode
fallback works.

The reasoning: the threat model for a locally stored credential on a passcode-protected device is
device compromise, and `AfterFirstUnlockThisDeviceOnly` already ties the item to hardware-derived
keys. Biometric gating adds almost nothing against that threat while breaking the exact feature the
app exists for. Gating the UI buys the visible property, that someone holding the unlocked phone
cannot read the Eight Sleep password out of the app, at no cost to the background path.

Worth knowing if we revisit this: `.biometryCurrentSet` invalidates the item the moment the enrolled
face or fingerprint set changes, which is the most common source of "the app lost my credential"
reports. And `kSecAttrAccessControl` is add-only, so it cannot be changed with `SecItemUpdate`, only
by delete and re-add.

### 4.4 Two footguns that destroy credentials

**`SecItemDelete` succeeds even when the item is inaccessible because the device is locked.** So
this innocent-looking pattern silently destroys the user's credential during a locked background
run:

```swift
// NEVER
if SecItemCopyMatching(q, &result) == errSecItemNotFound { SecItemDelete(q) }
```

`errSecInteractionNotAllowed` must be its own error case and must never trigger a delete. Deletion
happens only on an explicit user disconnect or a server-confirmed invalid credential.

**`errSecDuplicateItem` comes from the uniqueness constraint, not from your query.** For a generic
password only `kSecAttrService` plus `kSecAttrAccount` form that constraint. `kSecAttrGeneric`,
`kSecAttrLabel` and `kSecAttrDescription` do not participate. So a lookup can return
`errSecItemNotFound` and the very next add can return `errSecDuplicateItem`, if the query filters on
a non-constraint attribute. Keep query and add on the same attribute set, and prefer
update-then-add over delete-then-add.

### 4.5 Token refresh: foreground is the mechanism, background is a bonus

`BGAppRefreshTask` is an opportunistic ~30 second budget granted when the system decides the app
deserves one, based on launch patterns, battery, charging, network and Low Power Mode. There is no
delivery guarantee. Each request is consumed on execution, so forgetting to re-schedule inside the
handler silently opts out of all future runs permanently, and failing to call the expiration handler
damages the app's scheduling reputation.

The failure mode is precisely wrong for us: the phone sits on a nightstand and the app goes unopened
for days, which is exactly when the system grants fewest background runs.

**So: refresh on foreground is the primary mechanism.** On launch and on every transition to active,
check stored expiry and refresh if it falls within a wide threshold. Piggyback the same check on
whatever the app already does around alarm time. Register a `BGAppRefreshTask` as well, re-schedule
as the first line of its handler, and treat every run as gravy with no user-visible promise attached.

**Single-flight the refresh behind an `actor`.** If a foreground and a background refresh overlap
and the provider rotates refresh tokens, one of them writes a dead token and we are locked out.
Write the new token to the Keychain before treating the response as successful.

**`needsReauth` is a first-class UI state**, not an error toast: a local notification, since that is
the only channel reaching a user who is not opening the app, plus a persistent in-app banner and a
Reconnect button.

**The rule that matters most for an alarm app: the alarm still rings.** A credential failure must
never become a missed alarm. If a remote leg cannot be written, the AlarmKit backstop still fires
and the app says why the others did not.

### 4.6 Keeping secrets out of logs, crashes and git

- **`os.Logger`, never `print`.** `print` goes to stdout and bypasses the unified log's privacy
  machinery entirely.
- **The asymmetry that catches people:** interpolated strings and objects default to `.private`,
  but **static literals and numeric or scalar values default to `.public`**. A token length, a user
  id or an expiry interpolated as an `Int` is public unless marked otherwise.
- **The `.public` footgun is worse than it looks.** When the Xcode debugger is attached, `.private`
  values render in full. So a correctly private interpolation *looks* like it is leaking during
  development, which is exactly what tempts someone to mark it `.public` and ship it. When
  correlation is genuinely needed, use `privacy: .private(mask: .hash)`.
- Watch the indirect leaks: logging `URLRequest.allHTTPHeaderFields` wholesale carries
  `Authorization: Bearer`, as do `String(describing:)` and `dump()`.
- **Out of crash reports:** never interpolate a credential into `fatalError`, `precondition`,
  `assert` or an error's `localizedDescription`. Give any credential-carrying type a `description`
  that prints length and expiry only, so an accidental interpolation anywhere is inert.
- **Out of the debug UI:** show presence, length and a short hash. No copy-token button, and if one
  ever exists it lives behind `#if DEBUG`. The same applies to any share-diagnostics feature.
- **Out of git:** the two that actually burn people are `xcuserdata/`, which carries scheme
  environment variables where people put keys, and **captured HTTP fixtures**, where recording a
  real call to write a test brings the `Authorization` header along. Both are already in our
  `.gitignore`. Add `gitleaks` as a pre-commit hook rather than only in CI, since a secret that
  reaches the remote is published permanently and rotation is the only remedy.

## 5. Agent orchestration practice

Two corrections to the brief, both from current documentation.

**Claude Code reads `CLAUDE.md`, not `AGENTS.md`.** There is no automatic fallback, and blog posts
claiming both are read and merged are wrong. The brief asked for the agent roster "as an AGENTS.md
entry"; the correct location is **`.claude/agents/*.md`, one file per agent**, which is a different
thing from either. If we want an `AGENTS.md` for other tools, the supported bridge is a `CLAUDE.md`
whose first line is `@AGENTS.md`.

**Agent Teams is the wrong tool for this build.** It is experimental, off by default, and every
teammate is a full independent session, so token cost scales linearly with teammate count. The docs
are direct that for "sequential tasks, same-file edits, or work with many dependencies, a single
session or subagents are more effective", which describes a single-app iOS build exactly. Two
further traps: with teams enabled *any* subagent launches as a teammate, so a team can form when
nobody asked for one, and a teammate's idle notification **does not carry its output**, so an
orchestration flow that waits on a returned result will stall. Also `/resume` and `/rewind` do not
restore teammates.

**Use in-session subagents with one lead.** Frontmatter fields that matter: `tools` is an allowlist
and `disallowedTools` a denylist applied first, `model` defaults to `inherit`, and `isolation:
worktree` is the git-worktree field.

What a subagent loads at startup: its system prompt, the delegation message, `CLAUDE.md`, a git
status snapshot, preloaded skills. What it does **not** load: the lead's conversation history. So
every delegation has to carry its own full context.

**Worktree isolation earns its cost only when two or more agents write files concurrently.** The
failure mode without it is silent: two writes to one file in one tree produce no conflict, the later
write simply erases the earlier. Isolation converts invisible data loss into a visible merge. It is
overkill for read-only agents, which pay a fresh-checkout setup cost for nothing. Note a worktree is
a fresh checkout, so gitignored files are absent and dependencies are not installed.

**Chain the build, fan out the verification.** The documented reason to fan out review is
**anchoring**: one agent finds a plausible explanation and stops, and a single reviewer gravitates
to one issue class at a time. Independent reviewers with distinct, non-overlapping lenses, told to
challenge each other, produce findings a sequential pass does not. Practical sizing from the docs is
three to five agents, and three focused beats five scattered.

---

## Sources

**Eight Sleep**
- `lukas-clarke/eight_sleep`, the vendored `custom_components/eight_sleep/pyEight/` copy, authoritative here
- `lukas-clarke/pyEight`, standalone and stale
- `eight_sleep` issue #122, the 403 subscription-required report; #128, #111, #89
- `steipete/eightctl` and its `docs/spec.md`, independent CLI, source for the 429 observation
- `davidmosiah/eight-sleep-mcp`, independent confirmation of hosts and the v2 alarms path
- `mezz64/pyEight`, pre-OAuth2 original, historical only

**Whoop**
- `thebriangao/totem`, formerly `whoop-mcp`. Read `WHOOP.md`, `src/tools/v2/smart_alarm*.ts`,
  `src/projections/smart_alarm.ts`, `src/whoop/{cognito,client,constants,token_manager}.ts`
- `ryanbr/noop`. Read `Strand/BLE/Commands.swift`, `Strand/BLE/BLEManager.swift`
- `jacc/whoop-re`, private-API notes, contains no alarm endpoints
- developer.whoop.com OAuth and API docs, reached through search rather than direct fetch, since
  the egress proxy blocked the host
- `felixnext/whoopy` and `colinmacon/WhoopAPI-Wrapper`, checked and excluded as official-API only

**AlarmKit**, almost entirely primary
- developer.apple.com AlarmKit framework docs and the JSON backing them, plus the per-symbol pages
  for `AlarmManager`, `Alarm`, `AlarmPresentation`, `AlarmPresentation.Alert`, `AlarmAttributes`
- "Scheduling an alarm with AlarmKit", Apple's sample article, source of most of the code
- WWDC25 session 230, "Wake up to the AlarmKit API"
- Apple developer forums: thread 797950 for the entitlement hallucination and the Apple engineer
  reply, 802740 for FB20472264, 804749 for the unresolved does-not-fire-while-active report,
  806998 for simulator behaviour
- ActivityKit `AlertConfiguration.AlertSound`
- Secondary: 9to5Mac and MacRumors on the 26.1 slide-to-stop change, WWDCNotes, `jacobsapps/ADHDAlarms`

**Keychain and background refresh**, Apple primary plus Apple DTS
- Quinn "The Eskimo!", Apple DTS: "SecItem: Fundamentals" (thread 724023), "SecItem: Pitfalls and
  Best Practices" (thread 724013), "Calling Security Framework from Swift" (thread 710961). These
  three are the authority for everything in section 4.
- Apple Keychain services docs and the per-symbol `kSecAttrAccessible*` pages
- `BGAppRefreshTaskRequest`, `BGAppRefreshTask`, and WWDC25 session 227
- Forums: 725675 and 729824 on `BGTaskScheduler` accuracy, 697263 on
  `errSecInteractionNotAllowed` in the background, 726354 on log redaction
- Not read, blocked by the egress proxy: the Apple Platform Security guide's "Keychain data
  protection" page, which is the canonical protection-class table. The classes above were
  reconstructed from three consistent sources instead.

**Agent orchestration**, all from code.claude.com/docs fetched today
- `sub-agents`, `memory`, `agent-teams`, `worktrees`
