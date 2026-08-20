# Stats responsive core exception

## Root cause

The exact-head private Functional run on `ac8a75b1b5450c33f7328986346959ec58eceebe`
reproduced a horizontal overflow on `/stats` only at the `xl` transition
(1280 px): `document.documentElement.scrollWidth` was 1587 px for a 1280 px
viewport. The page switches every chart section from one to two CSS-grid
columns at this breakpoint. ECharts retains an intrinsic canvas width, while
the chart-card grid items used the CSS default `min-width: auto`; those items
therefore could not shrink to their `minmax(0, 1fr)` tracks.

## Minimal exception

The pilot adds only `wrapper_class = "min-w-0"` to the eight existing chart
macro calls in `ocg-server/templates/site/stats/page.html`. It does not change
chart data, JavaScript, breakpoints, product assertions, or the shared chart
macro. Fork `main` remains byte-identical to official upstream.

## Why configuration or an adapter is insufficient

The overflow is produced by the server-rendered class list compiled into the
OCG application image. Helm values have no supported option for changing that
template. A test-only DOM/CSS injection would conceal the defect without
fixing the pilot product, and a post-render Kubernetes adapter cannot alter
application HTML. The narrow template correction is therefore the smallest
product-effective patch.

## Regression and scope guard

- `pilot-validate.yml` fails unless all eight chart wrappers carry `min-w-0`
  and the unchanged upstream overflow assertion remains present.
- The private full Functional suite re-runs the unchanged upstream
  `statistics fits every supported breakpoint` case across all declared
  breakpoints.
- `verify-upstream-core-untouched.sh` includes this one file in the exact,
  binary-safe reviewed exception fingerprint. Any other core change, or any
  semantic drift in this patch, still fails closed.

## Payment-dependent Functional cases

The same run identified three paid registration-window UI cases whose required
ticket modal is intentionally unavailable with `payments.enabled: false`.
Those unchanged tests are explicitly reported as `SKIP/open`; they are not
marked as passed and their expectations are not edited. Every other desktop
Functional case and the complete mobile Functional project continue to run.
Provider-specific checkout/refund/Stripe verification remains open until a
separately authorized payment-enabled test environment exists.
