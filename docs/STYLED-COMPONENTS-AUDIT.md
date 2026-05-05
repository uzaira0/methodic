## Chronicle Web `styled-components` Audit

Updated: 2026-03-11

### Summary

`styled-components` still appears in 52 direct imports across the legacy web shell. The dependency is less widespread than `lattice-ui-kit`, but it still blocks a clean Tailwind-first styling model because it reaches the root shell, shared components, chart wrappers, and questionnaire builders.

### Import Concentration

- `containers/study`: 14 files
- `containers/questionnaires`: 9 files
- `containers/tud`: 7 files
- `containers/dashboard`: 5 files
- `containers/survey`: 4 files
- `containers/participant`: 4 files
- `common/components`: 4 files
- `containers/questionnaire`: 2 files
- `index.js`: 1 file
- `containers/app`: 1 file
- `assets/svg/icons`: 1 file

### Highest-Risk Styling Hotspots

1. `index.js`
   - Uses `createGlobalStyle`, so the legacy shell still depends on runtime global style injection.
2. `containers/study`
   - Largest route-level concentration, including tables, charts, and operator workflows.
3. `containers/questionnaires`
   - Heavy editor/builder surface that mixes layout, controls, and local styled wrappers.
4. `containers/tud`, `containers/dashboard`, `containers/survey`
   - Use styled wrappers for layout and progress/status presentation that should move to shared Tailwind primitives.
5. `assets/svg/icons/index.js`
   - Signals a small but shared icon-wrapping dependency that should move to plain components or utility classes.

### Replacement Strategy

1. Remove `createGlobalStyle` from the legacy shell after the Tailwind/global-token layer fully owns app-wide styling.
2. Replace shared leaf wrappers first:
   - buttons
   - error states
   - spinner/tab link helpers
   - icon wrappers
3. Replace study route wrappers next so charts, tables, and study cards define the modern utility-class approach.
4. Use the same layout primitives to replace questionnaire and TUD wrappers.
5. Remove the package only after both the legacy shell root and the shared leaf components stop importing it.

### Tailwind/Radix Implications

- The route migration should favor CSS variables plus utility classes rather than reintroducing wrapper-heavy component-local styling.
- Dialog, popover, tooltip, and menu surfaces should move to Radix primitives with Tailwind classes, not CSS-in-JS wrappers.
- Chart containers should use plain components and CSS variables for theme responsiveness so dark/light mode stays consistent without runtime style injection.

### Notes

- This audit counts direct imports only.
- Several commented-out `styled-components` imports still exist in questionnaire files; those are excluded from the headline count but indicate unfinished prior migrations.
