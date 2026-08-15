# Design

- **`prototype.html`** — every screen and state, clickable. Open it on the phone.
- **`FLOW.md`** — the flow and the states inventory the prototype has to cover.

## The design language, and where it came from

Built from real screenshots of the Whoop and Eight Sleep apps, not from memory or marketing sites.

**From Eight Sleep: the ground and the gradient.** Pure black, near-black cards with a hairline
border, sentence case headings, uppercase only for small labels, a floating pill tab bar. Their
signature device is the gradient card: Nap runs cool blue, Rapid Cooling runs warm orange.

That scale is not decoration. It is what their machine physically does, and it maps exactly onto
this product, which is why it carries the cascade:

| Leg | Gradient | Why |
|---|---|---|
| Eight Sleep, T minus 10 | cool blue | the bed is doing thermal work |
| Whoop, T minus 5 | mid slate | a nudge, neither hot nor cold |
| iPhone, T | warm orange | the loud one, the top of the ramp |

**From Whoop: the type and the instruments.** Uppercase labels at .15em tracking, huge tabular
numerals, thin outlined pills for secondary actions, the hatched span bar and the dashed target
range, and mint green as the single state colour.

**Where they disagree, and how it was settled.** Whoop is dense and technical, Eight Sleep is calm
and consumer. Whoop uppercases section titles, Eight Sleep uses sentence case. The split here:
Eight Sleep wins on **prose**, so headings and body are sentence case and readable at six in the
morning. Whoop wins on **data**, so every label, time and state reads as an instrument.

## The rule that keeps the two systems from fighting

This is the important part, and it is not a matter of taste.

**Eight Sleep's colour is continuous.** A position on a ramp. It answers "how far along?"
**Whoop's colour is discrete.** Seven flat accents, each meaning exactly one thing. It answers
"what kind of thing is this, and is it good?"

On one screen they destroy each other. A colour halfway along a ramp is none of Whoop's meanings, so
the semantics break. And seven flat accents turn a gradient into decoration, so the ramp stops
reading as a measurement. The fix is to give each one job and never the other:

> **The gradient encodes TIME. The flat accents encode STATE.**
> There is exactly one gradient in the app, and it is the cascade.

**Corollary, easy to walk into:** because the gradient means time, it may never also mean bed
temperature, in an app that controls a heated bed. Temperature is shown as a number, never as a hue.
If a temperature control is ever added, steal Eight Sleep's relative minus ten to plus ten scale
rather than degrees. Nobody sets their bed to 31 degrees, they set it to plus three.

**And never grade the user.** Whoop's evaluative red describes your recovery. Here, red describes a
*device*. A red thing at six in the morning means the speaker is offline, never that you slept badly.
An alarm clock that tells you off is an alarm clock people delete.

## Tokens

State colours are Whoop's official values, taken from their public brand guideline, so they are
known good on a dark ground.

```
--ground-top #101A2B  Whoop's method, Eight Sleep's hue: their app is not black
--ground-bot #05070C  but a subtle vertical gradient. This one is shifted navy.
--card       #0D1119
--line       rgba(255,255,255,.08)
--grey       #B8C0C3  Whoop text secondary, official
--grey-dim   #7F898D  Whoop text tertiary, official

--mint    #00F19F  Whoop teal: confirmed
--amber   #FFDE00  Whoop medium recovery: accepted but unconfirmed
--coral   #FF0026  Whoop low recovery: failed
--optimal #7BA1BB  Whoop sleep blue: the target range marker
```

The cascade ramp is dawn, which is what Eight Sleep's gradient originally meant. Their first identity
took it from dawn and sunset, before it ever meant temperature, so using it for time is returning it
rather than appropriating it.

```
cool  #2E7FD4 → #0A1F38   the bed, doing thermal work
mid   #6E74D8 → #16172E   periwinkle, the dawn transition
warm  #F4643C → #2E0E10   the loud one
```

**The violet midpoint is load bearing.** A straight blue to orange ramp muddies through grey and
reads as a weather map. Routing through periwinkle is what makes it Eight Sleep.

## Typography

Whoop's rule is two typefaces: one for words, a rigid engineering face for numbers, so data is
distinguishable from language before you read it. Theirs are Proxima Nova and DINPro, both
commercial.

**`DIN Alternate` ships with iOS.** That is a genuinely correct DIN for the numerals, free, on
device, no bundled font and no licence. Words use the system face. This is the single most useful
practical finding in the whole research pass.

Single theme on purpose. Both apps are dark only, and this one is read in a dark bedroom.

## Two rules the design has to carry, not just decorate

**Green means verified, not sent.** Amber is a real state: the write was accepted but could not be
read back, or read back at a different time. Colouring that green would be claiming a confirmation
the app does not have, and the moment that costs anything is 06:00.

**The iPhone leg is visually different from the other two** and says so. It is the only one that
rings with no account, no network and no subscription. Switching it off warns.
