# Home Page Redesign Phase 1: Claude Code Instructions

## TASK: Redesign header and home page to match approved mockup

The approved mockup is at: colossus-home-mockup-v3.html
This is a frontend-only change. No new backend endpoints needed — the existing
`/case` endpoint already returns everything we need.

**Branch:** `feature/home-redesign` from `main`

---

## STEP 0: Read These Files First (MANDATORY)

```
Read CLAUDE.md (coding standards)
Read frontend/src/components/Header.tsx (current header — will be replaced)
Read frontend/src/pages/Home.tsx (current home page — will be replaced)
Read frontend/src/App.tsx (routes)
Read frontend/src/services/api.ts (API_BASE_URL pattern)
```

Also examine the mockup HTML to understand the exact design:
```
Read /mnt/user-data/uploads/colossus-home-mockup-v3.html (if accessible)
```

**DO NOT make any changes yet. Provide Pre-Coding Analysis and wait for approval.**

---

## DESIGN SPECIFICATION

### Color Palette (CSS variables to define globally)
```css
--navy-900: #0f172a;
--navy-800: #1e293b;
--navy-700: #334155;
--slate-500: #64748b;
--slate-400: #94a3b8;
--slate-300: #cbd5e1;
--slate-200: #e2e8f0;
--slate-100: #f1f5f9;
--white: #ffffff;
--blue-700: #1d4ed8;
--blue-600: #2563eb;
--blue-500: #3b82f6;
--blue-100: #dbeafe;
--blue-50: #eff6ff;
--emerald-700: #047857;
--emerald-50: #ecfdf5;
--amber-600: #d97706;
--bg: #f0f2f5;
```

### Typography
- Single font family: `'DM Sans', sans-serif`
- Load via Google Fonts in `index.html`:
  `https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&display=swap`
- NO other font families anywhere

### Page Background
- Body/app background: `#f0f2f5` (slightly darker than current)

---

## STEP 1: New Header Component

### Replace frontend/src/components/Header.tsx entirely

The current Header has dropdown nav groups. Replace with a clean single-row header.

**Layout:** Three sections in a flex row with `justify-content: space-between`:

1. **Left** — Logo: blue rounded square with "C" + "Colossus Legal" text
2. **Center** — Nav links centered via `position: absolute; left: 50%; transform: translateX(-50%)`
3. **Right** — User avatar circle (initials) + name + "Sign Out" button

**Header style:**
- Background: white (`#ffffff`)
- Border bottom: `1px solid #e2e8f0`
- Height: 56px
- Sticky top: 0
- z-index: 100

**Nav links:**
```typescript
const NAV_ITEMS = [
  { label: "Home", path: "/" },
  { label: "Evidence", path: "/explorer" },
  { label: "People", path: "/people" },
  { label: "Documents", path: "/documents" },
  { label: "Analysis", path: "/analysis" },
];
```

Active link style: blue text (`#2563eb`) with light blue background (`#eff6ff`)
Default: slate text (`#64748b`), hover gets darker with `#f1f5f9` background

**User badge:** Hardcoded for now (auth comes in Phase 2):
```typescript
const userName = "Roman";
const userInitials = "R";
```

**Logo:** Always links to `/` (home)

**IMPORTANT:** The header MUST be under 300 lines. The current Header.tsx is
already over 300 lines — this rewrite should be MUCH simpler since we're
eliminating dropdown menus. Target: 120-180 lines.

---

## STEP 2: New Home Page

### Replace frontend/src/pages/Home.tsx entirely

This page fetches data from the existing `GET /case` endpoint and renders
the approved layout. If the endpoint lacks data for a section, use sensible
defaults from what we know about the case.

**Sections in order:**

### 2A: Case Header
```
Marie Awad v. Catholic Family Service, et al.
Macomb County Circuit Court · Case No. 2011-XXXXX · Filed 2011-11-13
[Active] badge
```
Source: `GET /case` returns `case_name`, `court`, `case_number`, `filed_date`, `status`

### 2B: Case Summary
White card with "CASE SUMMARY" label and summary paragraph.
Source: `GET /case` returns `summary`

### 2C: Causes of Action
Section title "Causes of Action" then a 2-column grid of 4 cards.

Each card shows:
- Count number (e.g., "COUNT I") in blue uppercase
- Count name (e.g., "Breach of Fiduciary Duty") bold
- Brief description
- "Supported" badge in green
- Arrow → on the right

Source: `GET /case` returns `legal_count_details` array with `id`, `name`

**Click behavior:** Navigate to `/explorer?count={count_id}`

The count descriptions can be hardcoded since they're stable legal definitions:
```typescript
const COUNT_DESCRIPTIONS: Record<string, string> = {
  "count-breach-of-fiduciary-duty": "CFS and Phillips violated duties of loyalty and care owed to Marie as estate beneficiary.",
  "count-fraud": "Defendants made material misrepresentations to the court about Marie's cooperation and estate assets.",
  "count-declaratory-relief": "Request for court determination regarding the rights and duties of parties under the estate.",
  "count-abuse-of-process": "Phillips used court proceedings for improper purposes including sanctions motions and character attacks.",
};
```

### 2D: Explore the Evidence
Section title "Explore the Evidence" then a 3-column grid of 6 cards.

Each card:
- Name (bold)
- Description (slate text)
- Count/stat in blue at bottom

```typescript
const EXPLORE_CARDS = [
  { name: "Evidence Explorer", desc: "Browse proof chains with verbatim quotes and page numbers", stat: "102 evidence items", path: "/explorer" },
  { name: "Graph", desc: "Visual proof chain from legal counts down through evidence", stat: "18 allegation hierarchies", path: "/graph" },
  { name: "Contradictions", desc: "Where Phillips contradicted his own prior statements under oath", stat: "5 impeachment pairs", path: "/contradictions" },
  { name: "Court Documents", desc: "Briefs, motions, discovery responses, and court orders", stat: "17 filings", path: "/documents" },
  { name: "Damages", desc: "Documented financial and reputational harms with evidence links", stat: "12 harms · $46,258.61", path: "/damages" },
  { name: "Case Analysis", desc: "Gap analysis, allegation strength review, and evidence coverage", stat: "18 allegations analyzed", path: "/analysis" },
];
```

Click navigates to the path.

### 2E: Ask the Case
White card with subtle border. Contains:
- Title: "Ask the Case"
- Subtitle: "Ask any question — Minerva searches the evidence, expands through the knowledge graph, and writes a cited answer."
- Text input + "Ask Minerva" blue button
- Suggestion chips below the input

**Behavior:** On submit or Enter, navigate to `/ask?q={encodeURIComponent(question)}`
Clicking a chip fills the input and navigates.

The existing AskPage.tsx already handles the `q` URL parameter from SearchPage
pattern. If it doesn't, add `useSearchParams` to read the initial question.

Suggestion chips:
```typescript
const SUGGESTIONS = [
  "What happened to the $50,000?",
  "Phillips contradictions",
  "How was Marie treated differently?",
  "CFS conflict of interest",
  "Caregiver testimony",
];
```

### 2F: Recent Questions (Placeholder)
Section title "Recent Questions" with "View all questions →" link.

For Phase 1, show a static placeholder message:
```
"Question history will appear here once questions are saved. Ask your first question above."
```

Style it in a white card with italic slate text. This section gets wired up
in Phase 3 when Q&A persistence is implemented.

---

## STEP 3: Update AskPage to Accept URL Query Parameter

Check if `AskPage.tsx` already reads `q` from the URL. If not, add:

```typescript
const [searchParams] = useSearchParams();
const initialQuestion = searchParams.get("q") || "";
```

Use this to pre-fill the textarea and auto-submit if `q` is present.

---

## STEP 4: Update App Background Color

In `frontend/src/App.tsx` or the root CSS, set the body/app background:
```css
background-color: #f0f2f5;
```

Also ensure `index.html` has the DM Sans font loaded if not already:
```html
<link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&display=swap" rel="stylesheet">
```

---

## STEP 5: Clean Up Routes

Verify in App.tsx that these routes exist and point to the right pages:
- `/` → Home (the new page)
- `/explorer` → ExplorerPage
- `/graph` → GraphPage
- `/people` → PeoplePage
- `/documents` → DocumentsPage
- `/contradictions` → ContradictionsPage
- `/damages` → DamagesPage
- `/analysis` → AnalysisPage
- `/ask` → AskPage
- `/search` → SearchPage

Remove any orphaned routes if they exist.

---

## STEP 6: Build and Verify

```bash
cd frontend
npm run build
```

Must pass with zero errors.

---

## STEP 7: Visual Verification

Start both backend and frontend:
```bash
# Terminal 1
cd backend && cargo run

# Terminal 2
cd frontend && npm run dev
```

Open `http://localhost:5473` and verify:

1. Header shows logo left, centered nav links, user badge right
2. "Home" nav link is highlighted blue
3. Case title, court, Active badge display correctly
4. Case Summary paragraph displays
5. 4 Causes of Action cards render in 2×2 grid
6. Clicking a count card navigates to `/explorer?count=...`
7. 6 Explore cards render in 3×2 grid
8. Clicking each explore card navigates correctly
9. Ask section appears with input, button, and chips
10. Typing a question and pressing Enter navigates to `/ask?q=...`
11. Clicking a suggestion chip navigates to `/ask?q=...`
12. Background color is `#f0f2f5`
13. All text uses DM Sans font
14. No emoji icons anywhere
15. Navigate to other pages — header persists with correct active link highlighting

---

## WHAT NOT TO DO

- Do NOT implement authentication (Phase 2)
- Do NOT implement Q&A persistence (Phase 3)
- Do NOT add any backend endpoints
- Do NOT add any new npm packages
- Do NOT use any emoji or icon libraries
- Do NOT use any font other than DM Sans
- Do NOT keep the old dropdown navigation pattern
- Do NOT keep the old Parties or Key Statistics sections
- Do NOT use green/beige/red color schemes from the old design

---

## FILE SIZE EXPECTATIONS

| File | Expected Lines |
|------|---------------|
| Header.tsx (rewrite) | 120-180 |
| Home.tsx (rewrite) | 250-300 |

If Home.tsx exceeds 300 lines, split into:
- `Home.tsx` — main page component with layout
- `HomeCards.tsx` — the card components (CoA cards, Explore cards)

---

## COMPLETION CRITERIA

- [ ] `npm run build` passes
- [ ] Header shows logo / centered nav / user badge
- [ ] Active nav link highlighted correctly on each page
- [ ] Home page shows all 6 sections in correct order
- [ ] Causes of Action cards link to filtered explorer
- [ ] Explore cards link to correct pages
- [ ] Ask section navigates to /ask with query parameter
- [ ] Background color is #f0f2f5
- [ ] DM Sans font used everywhere
- [ ] No emoji icons
- [ ] All files under 300 lines
- [ ] Pre-coding analysis was approved before implementation began
