# Route Cutover Touchpoints

- Legacy entrypoint: `chronicle-web/src/index.js`
- Legacy bootstrap modules: `chronicle-web/src/core/bootstrap/`
- Modern bootstrap module: `chronicle-web/src/modern/bootstrap/`
- Modern router basename logic: `chronicle-web/src/modern/app/router.tsx`
- Webpack interop for TS/CSS: `chronicle-web/config/webpack/webpack.config.base.js`
- Mixed-shell validation script: `scripts/chronicle-web-route-cutover-smoke.sh`
