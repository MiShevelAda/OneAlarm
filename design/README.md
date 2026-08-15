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

## Tokens

```
--black    #000000   ground
--card     #0D0F12   card fill
--line     rgba(255,255,255,.09)
--grey     #8B9299   labels, both apps use a cool grey rather than a neutral one
--mint     #00E58F   on, and confirmed
--amber    #F0A63C   accepted but unconfirmed
--coral    #FF5A5A   failed
--optimal  #7FA8C9   Whoop's dashed target range blue
cool  #6FA8DC → #0A2136
mid   #4C6B8A → #10161F
warm  #F0763C → #2E0E10
```

Single theme on purpose. Both apps are black only, and this one is read in a dark bedroom.

## Two rules the design has to carry, not just decorate

**Green means verified, not sent.** Amber is a real state: the write was accepted but could not be
read back, or read back at a different time. Colouring that green would be claiming a confirmation
the app does not have, and the moment that costs anything is 06:00.

**The iPhone leg is visually different from the other two** and says so. It is the only one that
rings with no account, no network and no subscription. Switching it off warns.
