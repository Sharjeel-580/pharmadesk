# PharmaDesk — Standing Quality Rules (Dazy's order, voice call 25 Nov 2026)

These rules apply to ALL work from Week 2 onward, alongside the existing
hard rules (local only, no push, no Firebase project creation, no
link/date/price promise to Hadi, per-week test then cumulative regression,
report only when all work is complete). Every builder agent must read this
file before starting work.

## 1. No mess ("koi panga nahi")
From day one, everything smooth and clean. Test EVERYTHING — no mix-ups,
no half-working flows, no dead ends. A flow is done only when it works
end-to-end, including its error/edge paths (validation, empty states,
cancel paths), not just the happy path.

## 2. Beautiful, clean UI
No dirty or cluttered UI. Everything easy to access for admin and staff
users — clear navigation, obvious actions, no hunting for features.
Consistent with the Kalora design system (primary #164AAB, Inter,
light + dark themes). If a screen feels crowded, simplify it; never add
a control the user cannot find or understand at a glance.

## 3. Internal users only — NO customer app
Users are ONLY internal people (staff / owner). There is NO customer app
— never build customer-facing screens. (The Day 0 customer-app shell was
flagged for conversion to the staff phone app; it is not a customer
product.)

## 4. Offer structure (proposal context — NOT a build change)
The live proposal (25 Nov 2026, Dazy's call): the main offer is the
desktop/web software; the mobile app (APK) is an add-on to it. The
client first says what they need — software, APK, or both. Keep the
app structured so mobile and desktop/web can be offered together or
separately: one codebase, three entry points (`main.dart` phone,
`main_admin.dart` web admin, `main_desktop.dart` Windows), no
mobile-only or desktop-only business logic. Price figures live in the
proposal/video, not in code — never invent them.

## 5. Deadline targets (planning only — never cut corners)
- Demo: within 1 week of sprint start (Week 1 demo delivered 24 Nov 2026 — met).
- Full system: 3–4 weeks. Speed comes from working continuously, NOT
  from skipping verification.
- The testing rule stands exactly as it is: per-week test first, then
  cumulative regression with all previous weeks.
- **If the deadline ever conflicts with a verification step,
  verification wins** — and the report must say so plainly.
