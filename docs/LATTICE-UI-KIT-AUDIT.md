## Chronicle Web `lattice-ui-kit` Audit

Updated: 2026-03-11

### Summary

`lattice-ui-kit` remains a primary blocker for the React 19 and Tailwind/Radix modernization. The current source tree has 90 direct imports from `lattice-ui-kit`, with the dependency concentrated in legacy route groups rather than isolated utilities.

### Import Concentration

- `containers/study`: 27 files
- `containers/tud`: 15 files
- `containers/survey`: 13 files
- `containers/questionnaires`: 12 files
- `containers/dashboard`: 8 files
- `containers/participant`: 4 files
- `common/components`: 4 files
- `containers/questionnaire`: 3 files
- `index.js`: 1 file
- `core/router`: 1 file
- `containers/enrollment`: 1 file
- `containers/app`: 1 file

### Highest-Value Replacement Order

1. `containers/study`
   - Largest concentration and central operator workflow.
   - Replacements here should establish the table, modal, card, banner, and form primitives for the rest of the app.
2. `containers/tud` and `containers/survey`
   - Share flow-heavy UI patterns that should migrate together once the shell primitives are stable.
3. `containers/questionnaires` and `containers/questionnaire`
   - Good follow-on tranche after form primitives and dialogs are in place.
4. `containers/dashboard` and `containers/participant`
   - Mostly presentational and should benefit from primitives built earlier.
5. `common/components`, `core/router`, `index.js`
   - Clean up shared shells and edge wrappers after route groups stop depending on the library.

### Shared Primitive Gaps Exposed By This Audit

The legacy routes repeatedly consume the same families of `lattice-ui-kit` components:

- Buttons and button groups
- Cards and card segments
- Typography
- Tables, cells, and list/grid layout
- Modals and action modals
- Search inputs and filters
- Status banners and progress indicators
- Menu and dropdown primitives

The modern shell should replace these with Tailwind/Radix/shadcn-style primitives before route-by-route migration continues.

### Immediate Migration Recommendation

- Start the next replacement tranche in `containers/study`.
- Build or harden these modern primitives first:
  - data table
  - modal/dialog
  - card/stat surfaces
  - form controls
  - search/filter header
- Use the study routes as the proving ground before moving the same primitives into TUD and questionnaires.

### Notes

- This audit measures direct imports only. Commented-out imports and package transitive usage are excluded from the headline count.
- `index.js` still imports `lattice-ui-kit`, so the legacy shell itself remains coupled even before route-level components render.
