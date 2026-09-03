# Chronicle CrowdSec/WAF Kubernetes Package

This package ports the Docker CrowdSec/AppSec service into Kubernetes. It is
not included in the default app overlays because enforcement is only real when
the ingress controller loads the Chronicle-vendored Traefik bouncer plugin and
adds the bouncer middleware before every public route.

Production gate:

1. `ExternalSecret/chronicle-crowdsec` is `Ready=True`.
2. `Deployment/chronicle-crowdsec` is ready, with LAPI on `8080` and AppSec on
   `7422`.
3. Traefik is configured with `experimental.abortOnPluginFailure=true`, the
   local `crowdsec-bouncer` plugin, and JSON access logs. For IP decisions
   based on access logs, Traefik logs must be available to CrowdSec through
   same-namespace shared storage or an approved log-shipping path.
4. Every public route has the CrowdSec middleware first, before strip-prefix,
   headers, and rate-limit middleware.
5. A live WAF smoke test confirms benign requests pass and known SQLi/XSS
   probes return `403`.

The current disposable AWS RKE2 host uses the stock `rke2-traefik` DaemonSet.
That DaemonSet does not currently load the local plugin or write the shared
access log, so the AWS route is rate-limited and header-hardened but not yet
CrowdSec-enforced.
