# Exact-head Aachen promotion gate trigger

Update this control-only file in an isolated promotion repair commit when all
Aachen host-image, PostGIS, remote-probe, private-smoke and product-E2E gates
must run again for the same new HEAD. It does not change runtime configuration
or relax any test, security check or Payment-OFF boundary.

2026-08-20: rerun after host-writer and workflow-dependency repairs.
2026-08-20: rerun after stats-responsive and Payment-OFF suite-classification repair.
