# promo

Two competing promotional websites for OneAlarm, built 2026-08-16 so Alex can pick a direction.

**Nothing in here is live, and nothing in here is published.** These are two files to open and judge.
They are not in `brand/pages/`, they are not in `site/`, they carry no route in
`brand/pages/manifest.json`, and the Caddyfile has never heard of them. Both carry `noindex`, the
house rule for anything written from this project.

| File | Direction | Ground |
|---|---|---|
| `option-a-instrument.html` | The site is the product. A live cascade you operate in the hero | Dark, committed, the app's own Night ground |
| `option-b-one-morning.html` | The site tells one morning, 22:41 to 10:00, as a scroll narrative | Warm paper, with a real dark mode |

Open either by double clicking it. No server, no build step, no install.

## The rules they were built under

- **Single self contained file.** No CDN, no web fonts, no remote images, no fetch. Verified: the
  only `http://` string in either file is the SVG XML namespace inside the favicon data URI, which
  is an identifier and is never dereferenced. Rendered in Chromium with request logging on, both
  pages issue zero network requests.
- **Invent nothing.** Every claim traces to `README.md`, `docs/STATUS.md`, `docs/USER-CASES.md`,
  `design/FLOW.md` or `design/prototype-v2.html`. There is no price, no rating, no testimonial, no
  user count, no launch date, no App Store badge and no device model number anywhere in either
  file, because none of those facts exist.
- **The app's real design system**, from `OneAlarm/Design/Theme.swift` and `design/README.md`,
  including the rule the whole thing rests on: the gradient encodes time, the flat accents encode
  state, and there is exactly one gradient. Both pages hold that rule. The dawn ramp appears only
  on the cascade.
- **The screens are recreated, not screenshotted.** Hand built in HTML and CSS from
  `design/prototype-v2.html`, so they cost nothing to load and stay correct at any size.
- **No em-dashes.** Zero in both files, checked.

## The open decision, and it is Alex's

Both pages end on **Ask for access**, and on both of them that button currently goes to its own
section rather than anywhere real. It is marked `[to confirm]` in the markup and once visibly on
the page.

There is no App Store listing and there is not going to be one: the app drives Whoop's and Eight
Sleep's own internal web services, which is a question about their terms, so `README.md` says it
should not be published. Apple's marketing guidelines separately require the App Store badge to
link to a real listing and forbid modified artwork, and there is no "coming soon" badge. So a
download button was never available here, honestly or legally.

What the button could do instead: collect an email, point at a TestFlight internal testing
invitation, or point at the docs and nothing else. That is a decision, not a task, which is why it
is in `/srv/career-coach/NOW.md` rather than being guessed at here.

## What is weak, stated rather than buried

- **Option A's problem section** is the most generic composition across both pages. Three cards, an
  arrow, one card. It could appear on any product site.
- **Option A shows two device frames back to back** in the three verbs and foreign change sections.
  They carry different ideas and look nearly identical, so a skimming reader reads them as one.
- **Option B's cascade times are the weekend night**, 09:30, 09:55 and 10:00, not the weekday
  defaults of T minus 10 and T minus 5. That is deliberate: every verbatim quote available names
  Saturday 16 August, and the prototype's configured Eight Sleep lead is 30 minutes rather than 10.
  Option B says so on the page and uses it to show that offsets are adjustable. Option A uses the
  documented defaults instead. **Both are correct and they do not match each other**, which is a
  thing to notice when comparing them side by side.
- **Neither page answers "will this work with my gear"**, because no model, generation or iOS
  version is on record anywhere. A technical reader asks that within thirty seconds.
- **Neither page has an origin story.** It is the strongest asset this category has and there is no
  confirmed fact to write one from.

## Verified how

Rendered in Chromium at 320, 390, 768, 1440 and 1920, in light and dark, with console and network
logging on. Zero console errors, zero page errors, zero external requests, no horizontal overflow at
any width, one `h1` each, no skipped heading levels. Contrast was computed rather than eyeballed.

The one thing that was **not** checked: neither page has been opened on a real iPhone. Chromium at
390 CSS pixels is not Safari on a phone, and the system font stacks in particular resolve to
different faces here than they will on Alex's device. Both files lean on `-apple-system` and, in
option B, on `ui-serif`, which means **they will look better on his hardware than in these
checks**, but that is a prediction and not an observation.
