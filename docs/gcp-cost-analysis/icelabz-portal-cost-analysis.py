#!/usr/bin/env python
# Final cost analysis - icelabz-portal

print("""
================================================================================
icelabz-portal - COST ANALYSIS
Billing account: 009B76-804735-EE9B14 (currency: GBP)
Catalog prices are USD; this project is billed in GBP (multiply by ~0.79 for GBP)
================================================================================
""")

print("""
--------------------------------------------------------------------------------
SECTION 1: ESTIMATED MONTHLY COST BREAKDOWN (based on last 30 days actual usage)
--------------------------------------------------------------------------------
""")

costs = []

# ---- Cloud Storage ----
sizes = {
    "us.artifacts.icelabz-portal.appspot.com (US multi-region, 1.00 GiB)":      ("US",  1.00,  0.026),
    "artifacts.icelabz-portal.appspot.com (US multi-region, 442.88 MiB)":      ("US",  0.433, 0.026),
    "eu.artifacts.icelabz-portal.appspot.com (EU multi-region, 1.74 GiB)":     ("EU",  1.74,  0.020),
    "icelabz-portal.appspot.com (europe-west2 regional, 15.01 MiB)":          ("ew2", 0.015, 0.023),
    "icelabz-portal_cloudbuild (US multi-region, 19.78 MiB)":                  ("US",  0.019, 0.026),
    "gcf-sources-3292451052-europe-west2 (europe-west2, 481 KiB)":             ("ew2", 0.0005,0.023),
    "gcf-sources-3292451052-us-central1 (us-central1, 840 KiB)":               ("uc1", 0.001, 0.023),
}

print("Cloud Storage (Standard class):")
total_gb = 0
total_cost = 0
for name, (_region, gb, price) in sizes.items():
    cost = gb * price
    total_gb += gb
    total_cost += cost
    print(f"  {name[:72]:<72} {gb:>6.3f} GB x ${price}/GB = ${cost:>6.4f}/mo")
print(f"  {'TOTAL':<72} {total_gb:>6.3f} GB                    ${total_cost:>6.4f}/mo")
costs.append(("Cloud Storage (total 3.22 GB)", total_cost))

print()
print("  >>> Key observation: 3.18 GiB of the 3.22 GiB total is ORPHANED")
print("      container images from 2021 that are no longer used.")

# ---- Cloud Functions ----
invocations = 9398
print()
print("Cloud Functions (1st gen, free tier eligible):")
print(f"  30-day invocations: {invocations:,}")
print(f"  Free tier covers: 2,000,000 invocations/mo + 400,000 GB-sec/mo")
print(f"  Your usage is well within free tier.")
print(f"  Monthly cost: ~$0.00")
costs.append(("Cloud Functions (1st gen, 27 fns)", 0.0))

# ---- Firestore ----
print()
print("Cloud Firestore (Standard edition, free tier enabled):")
print(f"  30-day reads:  17    (free tier: 50K/day)")
print(f"  30-day writes: 20    (free tier: 20K/day)")
print(f"  Storage:       ~0    (free tier: 1 GiB)")
print(f"  Monthly cost: $0.00 (entirely within free tier)")
costs.append(("Cloud Firestore (Standard)", 0.0))

# ---- Cloud Scheduler ----
print()
print("Cloud Scheduler:")
print(f"  2 jobs (free tier = 3 jobs/month) -> $0.00")
costs.append(("Cloud Scheduler (2 jobs)", 0.0))

# ---- Cloud Build ----
print()
print("Cloud Build:")
print(f"  No build activity in last 30 days -> $0.00")
costs.append(("Cloud Build", 0.0))

# ---- Pub/Sub ----
print()
print("Cloud Pub/Sub:")
print(f"  2 topics, no message traffic -> $0.00")
costs.append(("Cloud Pub/Sub", 0.0))

# ---- Network Egress ----
print()
print("Network Egress (Storage + Functions):")
print(f"  Last 30 days: 0.016 GB (Cloud Functions only) -> ~$0.00")
costs.append(("Network Egress", 0.0))

# ---- TOTAL ----
print()
print("-" * 80)
total = sum(c[1] for c in costs)
print(f"{'SERVICE':<40} {'MONTHLY (USD)':>15}   {'SHARE':>8}")
print("-" * 80)
for name, cost in sorted(costs, key=lambda x: -x[1]):
    pct = (cost/total*100) if total > 0 else 0
    bar = "#" * int(pct/2)
    print(f"  {name:<38} ${cost:>10.4f}   {pct:>5.1f}% {bar}")
print("-" * 80)
print(f"  {'TOTAL (USD)':<38} ${total:>10.4f}")
print(f"  {'TOTAL (GBP @ ~0.79)':<38} GBP {total*0.79:>10.4f}")
print()

# ============================================================
print("""
================================================================================
SECTION 2: WHERE THE MONEY ACTUALLY GOES
================================================================================

The icelabz-portal project is essentially a LOW-COST, MOSTLY-IDLE deployment.
Every active billable resource falls within GCP free tiers. The ONLY real cost
comes from idle storage accumulating over years.

Cost driver #1: ORPHANED CONTAINER IMAGES (97% of monthly bill)
--------------------------------------------------------------------------------
  Bucket                                      Images    Size
  us.artifacts.icelabz-portal.appspot.com       62       1.00 GiB
  eu.artifacts.icelabz-portal.appspot.com      113       1.74 GiB
  artifacts.icelabz-portal.appspot.com          14       442 MiB
  ----------------------------------------------------------------
  Total:                                       189       3.18 GiB

  All images dated 2021 - dead artifacts from Cloud Build / GCR pushes
  nobody cleaned up. Container Registry (gcr.io) is now legacy; GCP
  recommends migrating to Artifact Registry (which you don't use yet).

  Monthly cost: ~$0.083 USD (~6.5p GBP)

  >>> ACTION: Delete unused images:
      gcloud container images list --project=icelabz-portal
      gcloud container images delete <image> --force-delete-tags

Cost driver #2: LIVE BUT NEARLY-UNUSED WORKLOAD (negligible cost)
--------------------------------------------------------------------------------
  27 Cloud Functions deployed. 90-day invocation pattern:
      pandaSchedule       6,250/mo   (cloud scheduler every 5 min weekdays)
      clickUpSchedule     3,122/mo   (cloud scheduler every 10 min weekdays)
      postEnquiry              17/mo
      userOnCreateMethod        3/mo
      userOnDeleteMethod        3/mo
      recaptcha                  2/mo
      internal                   1/mo
      <19 others>                0/mo   <-- zombie functions

  Monthly cost: $0 (well inside 2M invocations/mo free tier)

  >>> ACTION: Delete 19 unused functions:
      gcloud functions delete <name> --region=<region>

Cost driver #3: STALE BUILDS (negligible cost)
--------------------------------------------------------------------------------
  gs://icelabz-portal_cloudbuild/source/*.tgz
    2 source archives from March 2021 - 19.78 MiB total

  Monthly cost: <$0.001

  >>> ACTION: These expire automatically, no action needed.

Cost driver #4: LIVE WORKLOAD DATA (kept by design)
--------------------------------------------------------------------------------
  gs://icelabz-portal.appspot.com/enquiryFiles/
    13 enquiry folders, 40 files, 15.01 MiB
    Real customer data (CAD files, PDFs) - keep!

  Monthly cost: <$0.001
================================================================================
""")

# ============================================================
print("""
================================================================================
SECTION 3: FREE-TIER BOUNDARIES YOU'RE USING
================================================================================

Service              Your usage/mo        Free tier limit       Headroom
-------              ---------------      -----------------     --------
Cloud Functions      9,398 invocations    2,000,000/mo          99.5% headroom
Firestore reads      17                   1,500,000/mo (50K/d)  ~100% headroom
Firestore writes     20                   600,000/mo (20K/d)    ~100% headroom
Firestore deletes    0                    600,000/mo (20K/d)    ~100% headroom
Firestore storage    ~0 GiB               1 GiB                 ~100% headroom
Cloud Scheduler      2 jobs               3 jobs/mo             33% headroom
Cloud Storage        3.22 GiB             5 GiB (US, Standard)  36% headroom


================================================================================
SECTION 4: RECOMMENDATIONS (ordered by impact)
================================================================================

1.  [Cleanup, ~6.5p/mo]  Delete orphaned 2021 container images in the three
    artifacts.* buckets. Use:
      gcloud container images list-tags <image> --project=icelabz-portal

2.  [Cleanup, $0/mo but reduces clutter] Delete the 19 Cloud Functions with
    zero invocations in the last 90 days. Confirms the workloads are no
    longer used by your app.

3.  [Setup, no cost] Set up a billing budget alert so future cost anomalies
    are flagged:
      gcloud billing budgets create \
        --billing-account=009B76-804735-EE9B14 \
        --display-name="icelabz-portal alert" \
        --budget-amount=5GBP \
        --threshold-rule=percent=50 \
        --threshold-rule=percent=90 \
        --threshold-rule=percent=100

4.  [Setup, no cost] Enable BigQuery billing export so you can query real
    historical costs in the future:
      gcloud billing accounts set-iam-policy (requires billing IAM)
      Then in Console: Billing > Budgets & alerts > Exports

5.  [Optional cleanup] Migrate to Artifact Registry (the project is still
    on legacy Container Registry gcr.io). New image pushes go to clean
    buckets with lifecycle rules.

6.  [Optional, security] Audit the ~79 enabled APIs. Many Firebase/Maps
    APIs are enabled but may not be needed - they don't cost anything
    unless invoked, but increase attack surface.
================================================================================
""")
