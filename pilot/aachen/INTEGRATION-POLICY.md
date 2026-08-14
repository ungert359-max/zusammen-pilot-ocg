# OCG Core Preservation Policy

## Purpose

The Aachen pilot uses upstream Open Community Groups (OCG) as the professional foundation. Local work must minimize newly introduced defects by preserving upstream code wherever possible and keeping pilot-specific behavior isolated.

## Binding rules

1. **Reuse before rewrite.** If OCG already provides a suitable function, use it directly instead of reimplementing or porting it.
2. **No language-driven rewrites.** Existing Rust, JavaScript, PL/pgSQL or other upstream code is not rewritten merely to standardize the stack.
3. **Upstream core is immutable by default.** Pilot-specific changes must not modify OCG application, database, chart, or other upstream core files.
4. **Additions stay isolated.** Aachen-specific implementation belongs under `pilot/aachen/**`; Aachen CI/control logic belongs in the dedicated Aachen workflows.
5. **Adapters before invasive changes.** New behavior should be connected through configuration, APIs, adapters, isolated services, migrations, or other narrow boundaries rather than edits to upstream business logic.
6. **Tests are additive.** Existing upstream tests must not be removed, weakened, or bypassed. New pilot behavior gets its own validation and regression coverage.
7. **Fail closed.** A local change outside the explicitly allowed pilot paths is treated as a policy violation until deliberately reviewed and justified.
8. **Upstream updates remain upstream.** Changes to OCG core should arrive by synchronizing the fork's `main` branch with the upstream CNCF repository, not by locally recreating them in the pilot branch.
9. **Release only on verified PASS gates.** A pilot addition is not considered releasable merely because it builds; the applicable validation, smoke, security, and deployment gates must pass.

## Current allowed local surfaces

- `pilot/aachen/**`
- `.github/workflows/aachen-*.yml`
- `.github/workflows/pilot-validate.yml`

Anything else is blocked by the core-preservation CI guard.

## Exception rule

If an upstream core modification ever becomes technically unavoidable, it must be handled as an explicit exception: documented reason, minimal patch, dedicated regression tests, separate review, and a clear explanation of why an adapter or isolated addition was insufficient. The default remains **do not modify upstream OCG core**.
