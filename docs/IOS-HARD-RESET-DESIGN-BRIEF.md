Yes. The current iOS build needs a **hard visual reset**, not another polish pass.

The core problem is systemic: it is still using **large rounded SwiftUI cards, oversized whitespace, generic sheets, big pill controls, and default-looking lists/forms**. Those patterns are being repeated across Sessions, Bots, Settings, New Session, Approval, Model picker, Sharing, Tools, and Chat. Fixing screens individually will keep producing the same result.

The agent needs to **delete the current visual grammar while preserving the actual product architecture and behavior**, then rebuild every production surface from one compact mobile industrial system derived from the macOS app.

Paste this into the agent:

```md
# VAMP ASSISTANT iOS — HARD RESET DESIGN MIGRATION
# Remove the generic AI/SwiftUI visual language and rebuild the entire production UI
# as the mobile counterpart of the finished macOS Vamp Assistant.

Work in the REAL iOS/iPadOS target in the existing repository.

This is a production implementation task.

Do not return a design proposal.
Do not create isolated mockups.
Do not create a second unused component library.
Do not stop after redesigning Chat or Composer.

The entire iOS application currently suffers from one systemic design failure:

    DEFAULT SWIFTUI / AI-SLOP VISUAL LANGUAGE

Symptoms visible throughout the current production build:

- giant rounded cards everywhere
- cards inside cards
- huge blank vertical spaces
- oversized headings
- giant pill buttons
- weak hierarchy
- every section treated as an isolated floating container
- inconsistent padding
- generic Settings styling
- generic model picker styling
- generic session cards
- generic empty states
- generic connection screens
- composer that still feels like a styled text field instead of an instrument
- too many shapes competing with one another
- poor information density
- iPad often behaving like a stretched iPhone
- accessibility layouts scaling the existing design instead of adapting
- insufficient relationship to the macOS product
- screens feeling generated independently rather than designed as one system

This task must correct the SYSTEM, not decorate the symptoms.

---

# 1. PRESERVE PRODUCT FUNCTIONALITY — REPLACE THE PRESENTATION

Preserve all real behavior:

- pairing
- Tailscale / LAN connectivity
- sessions
- session search
- new sessions
- chat
- streaming
- approval
- model selection
- tools/context
- bots
- autonomous runs
- sharing
- clipboard
- file transfer
- settings
- diagnostics
- remote state
- keyboard behavior
- drafts
- attachments
- iPhone/iPad navigation
- accessibility
- persistence
- permissions

DO NOT rewrite backend/state architecture merely to redesign the UI.

But do NOT preserve the current visual components just because they are already implemented.

Separate business behavior from presentation where necessary.

---

# 2. THE MAC APP IS THE PRODUCT-DESIGN AUTHORITY

The finished macOS app establishes the actual Vamp design language:

- engineered silver / graphite instrument surfaces
- rectangular low-radius modules
- visible structural seams
- recessed working areas
- dark inserted controls
- tiny orange hardware markings
- tiny green status LEDs
- technical micro-labels
- restrained typography
- compact density
- clear alignment
- minimal visual noise
- precise button bays
- hardware/software character

The iOS app should feel like:

    THE HANDHELD VERSION OF THAT DEVICE

not:

    A NEW SWIFTUI APP USING SIMILAR COLORS

Translate the principles.
Do not literally shrink desktop geometry.

---

# 3. DELETE THE CURRENT "CARD EVERYWHERE" MENTAL MODEL

This is mandatory.

Stop treating every feature as:

    VStack
      rounded card
      rounded card
      rounded card
      big button
      another rounded card

Major sections should not automatically have an outer rounded rectangle.

### REMOVE EXCESSIVE CARDS FROM:

- Session list
- Settings
- Bots list
- Bot detail
- New Session
- Sharing
- Tools
- Model picker
- Approval
- Connection states
- Pairing
- About
- Paired Mac

Use cards/panels ONLY where they represent a meaningful physical module.

The default content presentation should instead use:

- layout
- spacing
- seams
- typography
- rows
- recessed fields
- grouped controls

rather than an outline around everything.

---

# 4. REDUCE CORNER RADII DRAMATICALLY

Current iOS radii make everything feel soft and generated.

New shape system:

    page/container outer radius:     0
    major instrument module:         8–10
    recessed editor/input:           6–8
    ordinary button:                 6–8
    selected dark insert:            6–8
    compact chip:                    999 only when actually a chip
    circular status/control:         circle only when semantically justified

Do NOT use 20–30pt corner radii on normal panels.

Do NOT make every button a capsule.

Do NOT make normal list rows individual rounded rectangles.

---

# 5. BUILD ONE IOS INDUSTRIAL DESIGN SYSTEM

Centralize it.

Required semantic primitives:

    VampCanvas
    VampFaceplate
    VampRecess
    VampDarkInsert
    VampHairline
    VampSectionHeader
    VampMicroLabel
    VampStatusLED
    VampIconButton
    VampButton
    VampSegmentedControl
    VampSearchField
    VampListRow
    VampComposer
    VampApprovalModule

These must drive actual production screens.

Do not create them and leave existing views untouched.

---

# 6. MATERIAL SYSTEM

Use only four primary material roles.

## CANVAS

The page itself.

Light:
    warm off-white / technical paper-silver

Dark:
    neutral graphite

No floating effect.

---

## FACEPLATE

Meaningful device/module container.

Examples:
- composer
- approval module
- adaptive workflow
- selected bot workstation
- technical connection configuration

Properties:
- radius 8–10
- subtle directional material
- very thin edge
- restrained inner seams
- almost no drop shadow

---

## RECESS

Used for editable/technical working areas:

- editor
- search
- diff
- task field
- technical input
- console

Properties:
- darker/inset
- radius 6–8
- clear inner edge
- no floating shadow

---

## DARK INSERT

Used for:

- primary action
- selected segment
- current mode
- Send/Stop

Near-black / graphite with light content.

---

# 7. COLOR MUST BE RARE

Do not make the redesign colorful.

Approximately 95% neutral.

Use color as device instrumentation.

Orange:
- current/active hardware marker
- tools indicator
- focus
- active workflow index

Green:
- connected
- ready
- completed
- available

Amber:
- warning
- degraded

Red:
- destructive / failed

Blue / magenta:
only tiny categorical indicators where already meaningful.

No colored cards.
No gradients used as decoration.

---

# 8. TYPOGRAPHY RESET

Current screens frequently use typography that is too large.

The app is a productivity instrument, not a lifestyle landing page.

Use:

    nav title             17 semibold
    primary screen title  22–26 semibold
    section title         15–17 semibold
    row title             16–17 medium/semibold
    body                  15–17 regular
    secondary             13–14
    technical             11–12
    micro-label           9–10 uppercase tracked
    code/paths            mono

No giant "Appearance", "Paired Mac", etc.

Do not use navigation large titles for utility screens.

Use inline navigation titles.

---

# 9. CUT EMPTY SPACE

The current app wastes enormous amounts of vertical space.

Every screen must be audited for dead regions.

Examples:

Connection Lost:
current giant empty upper area → remove.

Conversation:
chat content should flow naturally from header → no arbitrary massive gaps.

Bots:
delegate and specialists should begin naturally after status.

Sessions:
header should not consume half the first screen.

Settings:
dense but readable.

New Session:
task/setup/action should fit substantially more efficiently.

Use space intentionally.

---

# 10. PAGE GRID

iPhone horizontal content inset:

    16–20pt

Standard vertical gaps:

    8
    12
    16
    20
    24
    32

Do not invent dozens of one-off spacings.

Repeated components should align to common edges.

---

# 11. IPHONE CHAT — REBUILD COMPLETELY

Current chat looks like generic dark AI UI.

Rebuild production Chat from this architecture:

    NAV BAR
    STATUS RAIL
    TRANSCRIPT
    MOBILE INSTRUMENT COMPOSER

---

# 12. CHAT NAV

Use compact native navigation.

Structure:

    [back]   conversation title        [actions]

No giant horizontal floating pill containing multiple unrelated buttons.

Action controls should be separate compact instrument icon buttons.

Title truncation must be clean.

---

# 13. CHAT STATUS RAIL

Use a thin system readout:

    ● READY   CHAT                     [comments] 8

Height:
    ~32–36pt

Technical text.

Hairline boundaries.

It should feel like a status display on a device.

Not a toolbar.
Not a card.

---

# 14. USER MESSAGE

Do not use an enormous bubble.

Use a restrained dark message plate.

    YOU
    actual message

Rules:

- max width around 78–82% on phone
- padding 12–14
- radius 10–12
- right aligned
- no floating shadow
- compact top label

---

# 15. ASSISTANT MESSAGE

Assistant messages should mostly be unboxed.

Structure:

    [small mark]  Vamp Assistant
                  prose

Then Markdown content.

Do not put complete assistant responses inside a generic rounded rectangle.

Improve:
- list rhythm
- paragraph spacing
- code
- headings
- links

---

# 16. REASONING

Current reasoning treatment looks like raw debug output.

Replace with a small disclosure module:

    ◉ REASONING                       ˅

Collapsed:
    header only or one-line summary

Expanded:
    recessed technical content

Use:
- 11–12pt technical label
- compact spacing
- no Markdown `**` displayed literally
- no large vertical gaps

Reasoning must clearly be secondary to the answer.

---

# 17. MOBILE COMPOSER — REBUILD AS AN INSTRUMENT

This is the highest-priority component.

Current composer still looks like:

    rounded gray box
    +
    random controls

Instead build:

    ┌──────────────────────────────────┐
    │ RECESSED EDITOR                  │
    │                                  │
    ├───────┬───────────┬───────┬─────┤
    │ +     │ MODEL     │ TOOLS │ ↑   │
    ├───────┴───────────┴───────┴─────┤
    │ ● READY · CHAT                   │
    └──────────────────────────────────┘

This is ONE compact mobile instrument.

---

# 18. COMPOSER GEOMETRY

Phone portrait normal state:

Outer side margin:
    12–16

Outer radius:
    10–12

Editor:
    initial 72–90pt
    grows to max
    then scrolls

Hardware controls row:
    48–54pt

Status:
    22–26pt

No gigantic 300pt composer unless accessibility layout requires it.

---

# 19. COMPOSER STRUCTURAL SEAMS

Strongly improve the internal structure.

Use visible machined seams:

- horizontal seam editor/control deck
- vertical seam between hardware bays where useful
- subtle two-tone edge where practical

Controls should look installed into bays.

Do not simply space controls inside an HStack.

---

# 20. COMPOSER CONTROLS

### PLUS
Compact instrument key.

### MODEL
Use compact selector:

    GPT-5 Codex ˅

Not oversized.

### TOOLS
Use four-dot tool mark with tiny orange index.

### SEND
Dark insert when ready.

Disable ONLY Send if sending unavailable.

Never fade the whole composer.

### STATUS
    ● READY  CHAT

Small.

---

# 21. KEYBOARD

The keyboard-visible screenshot is a critical test.

Fix all of:

- composer follows keyboard correctly
- editor visible
- Send visible
- model/tools visible where width allows
- no duplicate keyboard accessory
- no second trailing Send button
- no hardcoded keyboard heights
- interactive dismissal works
- transcript adjusts

Use proper safe area / keyboard-safe layout.

---

# 22. NEW SESSION — REMOVE CARD STACK

Current New Session is too card-heavy.

New layout:

    NEW SESSION               CANCEL

    ● MAC OFFLINE             RETRY

    TASK
    [ recessed task editor ]

    [Plan] [Explain] [Help]

    SETUP
    Works in            Chat
    Bot                 Assistant >
    Model               Qwen... >

    MORE
    Advanced setup >

    [ START SESSION ]

Do NOT wrap Task, Setup, More, CTA each inside giant individual rounded cards.

Use section hierarchy + seams.

Task editor may sit inside ONE faceplate.

Setup can be one grouped technical table.

---

# 23. SETTINGS — REMOVE GENERIC CARDS

Current Settings still resembles a generated settings app.

Use:

    SETTINGS                         DONE

    APPEARANCE

    System | Light | Dark
    accent dots

    ───────────────

    PAIRED MAC

    ● 100.73.221.10
      Private over Tailscale

    Switch computer        >
    Control diagnostics    >

    Forget this Mac

    ───────────────

    ABOUT

    Product       Vamp Assistant
    Platform      iPhone / iPad
    Version       ...

Do not wrap every section in a huge bubble.

Use seams and groups.

---

# 24. APPEARANCE

Color dots:

Visual size:
    28–30pt

Touch region:
    44pt

Selected:
    precision double-ring or orange index

Do not use enormous circles.

Segment control:
- radius 7–8
- dark insert selection
- clean machined track

---

# 25. SESSIONS — REMOVE INDIVIDUAL BIG CARDS

This page currently looks especially AI-generated.

Do NOT put every conversation in a large rounded bordered card.

Use a single conversation library list.

Example:

    SESSIONS · 98

    ● Approval-boundary release test...
      Workspace · 6 messages             37 sec

    ─────────────────────────────────────

    ● Release approval test...
      Workspace · 7 messages             4 min

Rows:
- ~68–76pt
- internal separators
- selected row gets subtle recess
- no individual surrounding card

This alone will dramatically improve the product.

---

# 26. SESSION HEADER

Current top is too bulky.

Use:

    VAMP / REMOTE

    Vamp Assistant                  ● CONNECTED
    Private over Tailscale

    [ Search sessions ]

Then list.

Top action controls remain compact.

---

# 27. BOTS LIST — STOP USING CARDS FOR EACH SECTION

Use:

    BOTS                           DONE

    ● MAC OFFLINE                RETRY

    DELEGATE
    Adaptive Workflow
    [task input]
    [Orchestrate]

    SPECIALISTS

    Assistant
    Balanced assistant          Chat only      >

    ─────────────────────────────────────────

    Builder
    Build and fix               Idle           >

Use ONE specialist list surface with separators.

Not a giant card for each item.

---

# 28. BOT DETAIL

Current Bot Detail contains too many massive containers.

Use:

    Builder

    [avatar] BUILDER
             Build and fix
             ● OFFLINE

    MODE
    [ CHAT | RUN ]

Then corresponding content.

Chat:
- short description
- openers
- start action

Run:
- task editor
- model
- Start

Do not show massive Chat and Autonomous cards simultaneously unless genuinely needed.

---

# 29. APPROVAL

Make approval feel serious and engineered.

Do not use a large soft floating card with giant empty margins.

Use:

    APPROVAL NEEDED                 REVIEW
    EDIT FILE

    Update the screen title

    ┌─────────────────────────────┐
    │ Views/Chat.swift      +1 -1 │
    ├─────────────────────────────┤
    │ - Text("Chat")              │
    │ + Text("Conversation")      │
    └─────────────────────────────┘

    [ALLOW ONCE]             DECLINE

Compact authorization module centered vertically.

Tiny orange attention mark.

---

# 30. TOOLS

Current Tools list is too generic.

Use technical section hierarchy:

    TOOLS & CONTEXT                  DONE

    WORKSPACE
    Git diff
    Review uncommitted changes

    @context
    Use the current workspace...

    BROWSER
    Open page
    Read page
    Browser screenshot

    SYSTEM
    System status

Rows:
- icon bay
- title
- description
- optional arrow

Use separators.

Not cards.

---

# 31. MODEL PICKER

Same approach.

Do not make the one model a giant card.

Use:

    MODEL                             DONE

    [search]

    [LOCAL] [CHATGPT] [API]

    LOCAL · 1

    ● GPT-5 Codex
      ON YOUR MAC

Single row list.

Selected indicator green/orange as appropriate.

---

# 32. SHARING

Current Sharing has good content but generic containers.

Use hardware/control-panel hierarchy.

    SHARE WITH MAC

    ↔
    MOVE WORK, NOT ACCOUNTS.

    CLIPBOARD

    ┌──────────────┬──────────────┐
    │ ↓ FROM MAC   │ ↑ TO MAC     │
    └──────────────┴──────────────┘

    FILES

    + SEND FILE TO MAC

Make two clipboard actions feel like real paired hardware keys.

---

# 33. CONNECTION LOST

Current huge card + blank screen is unacceptable.

Use a centered device-state composition WITHOUT a giant outer card:

        [connection glyph]
        CONNECTION LOST
        MAC UNAVAILABLE
        Tap to retry

        [ RECONNECT ]

        Back to Vamp Assistant

No enormous white/black empty top area.

The complete state should sit naturally around the screen center.

---

# 34. PAIRING

Pairing is closer to acceptable.

Retain basic information hierarchy.

Reduce:
- oversized containers
- generic button radius

Add:
- compact device marks
- tiny orange Remote index
- cleaner spacing
- stronger seams

---

# 35. IPAD — NOT STRETCHED IPHONE

Use NavigationSplitView.

Sessions:
    list | chat

Bots:
    bots | detail

Settings:
    normal centered content

Chat:
    centered reading column
    max ~720–780pt

Composer:
    max ~760–840pt

Do not use an iPhone-width card floating randomly in a giant canvas unless intentionally centered.

---

# 36. IPAD EMPTY STATE

Replace excessive blank space with a compact intentional empty state.

Example:

    [small technical glyph]

    CHOOSE A CONVERSATION
    Your chats stay in the conversation library.

No enormous central decoration.

---

# 37. RESPONSIVE SYSTEM

Define semantic width modes based on actual available width:

COMPACT:
    normal iPhone portrait

SHORT:
    phone landscape

REGULAR:
    iPad / split

ACCESSIBILITY:
    large Dynamic Type

Do not write device-specific layouts for iPhone 17 etc.

---

# 38. ACCESSIBILITY

Current accessibility screenshots show catastrophic layout scaling.

At accessibility categories, explicitly change composition.

Do not simply enlarge everything.

Examples:

Composer:
    editor
    model button
    tools button
    Send
    status

stack vertically.

Settings:
    label
    control below

Approval:
    actions stack vertically

Model selector:
    tab bar may become menu/list

Bot rows:
    taller rows

Typography remains readable without enormous 70pt section headers.

---

# 39. LIGHT MODE

Current Light is too generic.

Make canvas slightly warm.

Faceplates:
    restrained silver.

Recesses:
    perceptibly darker.

Dark inserts:
    strong graphite.

Orange:
    tiny precise markers.

Green:
    status only.

No shadows used to simulate design quality.

---

# 40. DARK MODE

Match current Mac dark design.

Neutral graphite.

Do not overuse green tint.

Maintain:
- panel hierarchy
- visible borders
- readable disabled controls
- orange/green indicators

---

# 41. REMOVE THE CURRENT GENERIC STYLE IMPLEMENTATION

Search iOS presentation code for:

- huge cornerRadius values
- `.background(.ultraThinMaterial)` generic use
- generic `Form`
- generic `List` styling where custom list is needed
- giant RoundedRectangle cards
- `.buttonStyle(.borderedProminent)` leaking into production
- duplicate composer views
- one-off paddings
- huge `.font(.largeTitle)`
- magic keyboard offsets
- duplicate sheet styling

Replace rather than layering new modifiers on top.

---

# 42. BUILD SHARED MOBILE COMPONENTS FIRST

Before rebuilding screens, implement/refine:

    VampMobileSection
    VampMobileRow
    VampMobileFaceplate
    VampMobileRecess
    VampMobileKey
    VampMobileSegment
    VampMobileStatusLED
    VampMobileSearch
    VampMobileComposer

Then migrate the production screens to them.

Do not independently redesign each view again.

---

# 43. POLISH STATES

Every control needs intentional:

- rest
- pressed
- focused
- selected
- disabled
- loading
- success/error

Press:
    0.98 or brightness change

Focus:
    small orange index/edge

No layout movement.

---

# 44. SUBTLE MOTION

Use only:
- composer focus/growth
- reasoning disclosure
- segmented selector
- state LED transition
- connection transition
- button press

No excessive spring.

---

# 45. HAPTICS

Use lightly for:
- Send
- Approval
- mode/model selection
- successful connection

Do not haptic ordinary scrolling/list taps.

---

# 46. MIGRATION ORDER

Execute in this order:

1. design tokens
2. base mobile components
3. composer
4. conversation
5. Sessions
6. New Session
7. Bots
8. Bot Detail
9. Model
10. Tools
11. Approval
12. Pairing/Disconnected
13. Sharing
14. Settings
15. iPad
16. accessibility
17. light/dark parity
18. interaction polish
19. delete obsolete visual components

---

# 47. SCREENSHOT GATE

Generate real production captures.

iPhone:
- chat
- keyboard
- multiline
- Sessions
- New Session
- Bots
- Bot Detail
- Approval
- Model
- Tools
- Pairing
- Disconnected
- Sharing
- Settings

iPad:
- sessions/detail
- chat portrait
- chat landscape
- reduced width
- Bots

Accessibility:
- chat
- composer
- settings

---

# 48. FAIL THE DESIGN IF

Do not call it finished if:

- giant rounded cards remain everywhere
- session history still uses card-per-row
- settings still use giant cards for every section
- Bots still use cards nested inside cards
- typography remains oversized
- the composer still looks like generic AI chat
- Light looks like default SwiftUI
- empty screens contain giant dead areas
- iPad simply stretches iPhone
- accessibility simply enlarges ordinary layout
- controls have inconsistent shapes
- macOS and iOS do not clearly feel related

---

# FINAL TARGET

The final experience must feel:

    NOT "AI APP"

    NOT "SWIFTUI TEMPLATE"

    NOT "CHATGPT CLONE"

but:

    VAMP ASSISTANT
    A DESIGNED MOBILE INSTRUMENT

Minimal.
Industrial.
Precise.
Fast.
Quiet.
Slightly unusual.
Immediately recognizable.

Use the macOS application as the product-design benchmark.

Remove the existing iOS visual language instead of endlessly styling it.
```

This is the kind of instruction I’d use now: **remove the design debt first, then migrate the actual product to one shared mobile system**. Otherwise each subsequent prompt will keep producing prettier versions of the same card-heavy problem.
