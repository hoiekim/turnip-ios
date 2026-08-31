# Turnip — Tricking Video Auto-Editor + Community Labeling Platform

*Author: claoie · Rev 2 2026-08-31 · Status: draft for Hoie's review*

*(Rev 1 targeted iOS-only, personal-use. Rev 2 expands to open-source app + backend + community labeling + continuous ML training per Hoie 2026-08-31.)*

## Problem

Hoie films his tricking practice on a phone/camera on tripod. A recording session produces one long video with:

- **Idle head**: walk from camera to starting spot, wait for turn (5-60s)
- **The trick**: 1-5s of intense motion (spins, kicks, flips, mid-air rotations)
- **Idle tail**: land, walk back to camera
- **Multiple tricks per recording** is common
- **Wasted frame space** — the trick uses only a subset of the frame

Manually clipping and re-cropping every practice video is tedious enough that most clips never get saved. Automating it makes every practice session archivable in one tap.

Because Hoie wants this open-source and contributor-friendly, the app doubles as a **community labeling + continuous training platform**: users can opt in to publish + label their clips, the labeled dataset feeds a continuously-improving pose+action model, and new model versions ship to the app as over-the-air updates.

## Product scope

**v1 (personal use)**:
- Auto-clip + auto-crop + multi-trick split (iOS-only, off-the-shelf MoveNet Thunder)
- Preview UI, export to Photos

**v2 (community + backend)**:
- Video upload + labeling UI (in-app)
- User accounts, moderation, reputation, abuse blocking
- Backend + database + object storage
- Continuous ML training pipeline (retrain when N new labels land, champion/challenger promote)
- OTA model updates delivered to installed clients

## License

**Apache 2.0** for all repos. Reasons:
1. Matches upstream — MoveNet Thunder, MediaPipe BlazePose, most Core ML tooling all ship Apache 2.0. Zero license-compatibility friction when bundling weights or fine-tuning.
2. Explicit patent grant. Better than MIT for an ML project where a contributor might hold a relevant patent.
3. Contributor-friendly: no viral obligations, commercial forks allowed.

## Repo structure

Three public repos under `hoiekim`, Apache 2.0:

- **`hoiekim/turnip-ios`** — Swift/SwiftUI iOS app. Bundles MoveNet Thunder TFLite. Handles capture, on-device clip detection, preview UI, export, and (v2) upload to the backend for the community dataset.
- **`hoiekim/turnip-api`** — Bun + TypeScript + Postgres backend. Serves video upload, labeling UI (or hosts labeling data for the iOS app to render), user accounts, moderation, quality scoring, and dataset export for the training pipeline. Matches the inbox/budget stack Hoie already runs.
- **`hoiekim/turnip-ml`** — Python + TensorFlow training pipeline. Fetches labeled dataset from turnip-api, fine-tunes MoveNet Thunder (or the current champion), evaluates on a held-out set, exports to Core ML, uploads to the model CDN endpoint the app polls.

Polyrepo chosen over monorepo because open-source contributors typically only want to touch one layer — an iOS contributor should not have to clone a 5 GB ML checkpoint tree, and vice versa.

## System architecture

### iOS app (`turnip-ios`)

- **Language**: Swift + SwiftUI, min deployment target iOS 14 (broad device coverage; feature-gate iOS 17+ 3D pose if we ever want it).
- **Pose engine**: MoveNet Thunder (Apache 2.0, ~7 MB TFLite) — pretrained on Google's "Active" dataset (yoga/fitness/dance with high motion + self-occlusion), 84% joint accuracy on the one published gymnastics benchmark.
- **Runtime**: TensorFlow Lite iOS OR Core ML (via coremltools conversion of the TFLite → Core ML). Core ML is preferable for Neural Engine acceleration on your A15 (iPhone 13 mini).
- **Pipeline** (per input video, per Rev 1):
  1. Decode frames at native fps
  2. Downsample every 3rd frame to 480p
  3. Run pose detection, extract hip-midpoint per frame
  4. Motion signal = frame-to-frame hip displacement, smoothed
  5. Peak detection with sustained-above-threshold logic → list of trick windows
  6. Crop rect = union of 17 keypoints across window, expanded 25%, snapped to aspect ratio
  7. Export N clips per input
- **Preview UI**: thumbnail per detected clip, tap-preview, drag-adjust start/end, keep/discard toggles.
- **Optional upload** (v2): opt-in per clip. "Send this to the community dataset for labeling" toggle. Uploads to `turnip-api` with the auto-detected labels (window, crop rect) as a first-pass suggestion the community can accept/refine.
- **OTA model updates**: on launch, poll `GET /api/models/current` for a new Core ML version; download in background, atomic-replace, use next launch.

### Backend (`turnip-api`)

- **Stack**: Bun + TypeScript + Express (or Bun native) + Postgres. Same stack as inbox/budget so we reuse patterns.
- **Object storage**: **Cloudflare R2** (S3-compatible, **$0 egress**, $15/TB storage). Videos and models live here, not on the droplet FS — the droplet doesn't grow with content volume.
- **Auth**: GitHub OAuth (contributors already have GitHub) + email/password fallback via `express-session`.
- **Endpoints (v2 MVP)**:
  - `POST /api/videos/upload` — presigned R2 URL, returns video ID
  - `POST /api/videos/:id/labels` — submit label (trick windows + crop rects + trick class if any)
  - `GET /api/labels/pending` — return N unlabeled clips (for labeling UI)
  - `POST /api/reports` — user reports abuse/bad label
  - `GET /api/models/current` — current Core ML manifest (version, URL, checksum)
  - `POST /api/models` — training pipeline publishes new champion (admin-scoped)
- **Database schema (v2, additive-only)**:
  - `users` — id, github_id, email, reputation, is_blocked, created_at
  - `videos` — id, user_id, r2_key, duration_ms, uploaded_at, moderation_state
  - `labels` — id, video_id, user_id, trick_windows (JSONB), crop_rects (JSONB), quality_score, created_at
  - `reports` — id, target_type, target_id, reporter_id, reason, created_at, resolved_by
  - `models` — id, version, r2_key, val_metrics (JSONB), promoted_at
- **Migrations**: `dbmate` from day 1. Numbered SQL files, forward-only, additive-first. Never drop a column in the same PR that stops writing to it — two PRs.

### Labeling UI

Lives inside the iOS app (v2) — a Labeling tab that:
1. Fetches a pending clip from `GET /api/labels/pending`
2. Plays the clip, lets user drag start/end handles, adjust the crop rect, optionally tag the trick class
3. Submits back to `POST /api/videos/:id/labels`

Web labeling UI is out of scope for MVP — iOS-only keeps the surface small. A web UI can be added as a `turnip-web` repo later if desktop labelers want in.

### ML pipeline (`turnip-ml`)

- **Language**: Python + TensorFlow + `coremltools` for export.
- **Trigger**: cron (nightly) or on-demand via GitHub Actions workflow_dispatch. Only runs if `SELECT COUNT(*) FROM labels WHERE created_at > last_train_at` exceeds a threshold (say 50).
- **Steps**:
  1. Fetch labeled dataset from turnip-api (`GET /api/labels/export?since=<last>`)
  2. Fetch corresponding videos from R2
  3. Split 80/10/10 train/val/holdout (stratified by user_id so no user's clips leak across splits)
  4. Fine-tune MoveNet Thunder or the current champion
  5. Evaluate on holdout: PCK, joint-detection rate, clip-detection precision/recall
  6. **Champion/challenger**: only promote new model if it beats current champion by ≥1% on validation. Otherwise archive and try again next cycle
  7. Export to Core ML with `coremltools.convert(...)`, quantize to fp16
  8. Upload to R2, call `POST /api/models` to publish
- **Runs where**: same droplet during MVP (Python installed alongside Bun). Move to a separate GPU worker (RunPod / Lambda Labs on-demand, ~$0.50-1/hr) when training time exceeds ~30 min.

### Label quality + abuse

- **Reputation score per user** — starts at 0, +1 per accepted label, -5 per reported+confirmed bad label. Users with reputation ≥ threshold become "trusted" and their labels bypass moderation review.
- **Spot checks** — every Nth label from a non-trusted user is queued for a trusted user to review.
- **Inter-labeler agreement** — v2.5 enhancement: same clip goes to 3 labelers, compare, quality signal = how similar their labels are. Elegant but requires N > 1 labelers per clip so hard at low volume.
- **Abuser blocking** — admin action (`UPDATE users SET is_blocked = true`) revokes upload rights. Automated triggers: N reports in T time, N labels rejected, upload rate spike. All actions logged to `moderation_events` table.
- **Data poisoning defense** — never train on labels from users with reputation < 0 or blocked. Held-out validation set is admin-curated and never touched by user labels.

## Deployment (DigitalOcean cheapest viable)

**MVP stack**:
- **1× Basic Droplet** — $6/mo (1 GB RAM, 25 GB SSD, 1 TB transfer). Runs turnip-api (Bun), Postgres, and the ML pipeline (nightly). Nginx/Caddy fronts everything.
- **Cloudflare R2 bucket** — videos + trained model artifacts. First 10 GB free, then $0.015/GB/mo storage, **$0 egress**. Two zeros: no bandwidth bill for video downloads, no bandwidth bill for the app fetching the model.
- **Domain**: `turnip.app` or similar, ~$15/yr on Namecheap/Porkbun.
- **Managed Postgres** ($15/mo) OR **self-hosted Postgres on the droplet** ($0). Start self-hosted; migrate to managed when you cross 1 GB of DB or 10 QPS sustained.
- **Object storage costs** — 100 videos × 100 MB = 10 GB → free tier. 1000 videos = $1.50/mo. 10 000 videos = $15/mo.
- **Cloudflare in front** — free tier — for the app-facing DNS + basic DDoS + edge caching of static assets.

**MVP total: ~$15-30/mo** depending on Postgres choice and video volume.

**Scaling seams built in from day 1**:
- **Stateless API** — all state in Postgres + R2. Adding a second droplet behind a load balancer is a config change, not a rewrite.
- **Videos on R2, not the droplet FS** — droplet doesn't grow with content.
- **Managed Postgres upgrade path** — swap the DSN, no schema changes.
- **Background jobs (training) already run out-of-process** — moving to a dedicated GPU worker is one variable change.
- **Migration tool from day 1** — schema changes are additive, forward-only, versioned. Zero-downtime deploys become possible when we care.

**Beyond MVP**:
- DO App Platform ($12/mo for a small autoscale) or fly.io for stateless-API layer
- DO Managed Postgres ($15+/mo cheapest, autoscales up)
- DO Load Balancer ($12/mo) if we ever put 2+ API droplets behind one URL
- Full-time GPU (RunPod A10G ~$0.35/hr = $250/mo if left on 24/7; ~$0/mo if only spun up during training) for ML training

## Continuous migration strategy

- **Tool**: `dbmate` (Go binary, zero-dependency, works well with Postgres). Migration files live in `turnip-api/db/migrations/NNNN_description.sql` (up + down).
- **Rules**:
  1. Migrations are forward-only in production (no `down` in prod).
  2. Always additive first — new column, new table. Never drop or rename in the same PR that stops writing to the old field.
  3. Two-PR pattern for destructive changes: PR A adds new + double-writes; deploy; verify; PR B drops old.
  4. Migration runs as part of the deploy script, before the API restart.
- **App-schema compatibility**: the API should tolerate its schema being one migration ahead OR behind briefly. During the migration window we're running old code against new schema (that's why additive-first matters).

## Contribution guide surface

Every repo ships (at repo root, standard OSS conventions):
- **`LICENSE`** — Apache 2.0
- **`README.md`** — what the repo is, how to run locally, how to contribute
- **`CONTRIBUTING.md`** — dev setup, PR conventions, review process, coding style
- **`CODE_OF_CONDUCT.md`** — Contributor Covenant 2.1 (standard, widely adopted)
- **`.github/`**:
  - `ISSUE_TEMPLATE/bug.md`, `ISSUE_TEMPLATE/feature.md`
  - `PULL_REQUEST_TEMPLATE.md`
  - `workflows/ci.yml` (lint + test on every PR)
  - `workflows/cd.yml` (deploy on push to main — turnip-api only)
- **`SECURITY.md`** — how to responsibly disclose vulnerabilities
- **`CLA.md`** *(optional, decide upfront)* — do we require contributors to sign a CLA? Apache 2.0's Individual Contributor License Agreement is standard but adds friction; most permissive-license OSS projects skip it.

**Recommendation**: skip the CLA. Apache 2.0's Section 5 already grants the project the necessary license from contributions. CLAs are more common in projects that plan to relicense later or that need corporate contributor rights.

## Cost analysis (updated)

### One-time
- Apple Developer Program: $99 (required to publish to App Store; not required for TestFlight or self-install)
- Domain registration: $15
- Design / branding assets: $0 (DIY)

### Recurring
| item | MVP ($/mo) | scale-to-1000-users ($/mo) |
|---|---|---|
| DO droplet (API + self-hosted Postgres + training runner) | 6 | 12-24 |
| Cloudflare R2 (video + models) | 0-2 | 10-30 |
| Cloudflare DNS + edge (free tier) | 0 | 0 |
| Managed Postgres (optional) | 0 (skip for MVP) | 15 |
| Domain amortized | 1.25 | 1.25 |
| Apple Developer Program amortized | 8.25 | 8.25 |
| **Total** | **~15/mo** | **~50-80/mo** |

R2's $0 egress is what keeps this cheap even as video volume grows. AWS S3 would triple the bill at 1000 users due to egress fees.

## Contribution ramp for friends

- **Good first issues** tagged in each repo — small, well-scoped
- **Areas of contribution** documented in each README:
  - iOS: Swift/SwiftUI, AVFoundation, Vision framework, TFLite iOS
  - API: TypeScript, Bun, Postgres, Docker
  - ML: Python, TensorFlow, coremltools, model evaluation
- **PR review flow**: reviewer + Hoie approval; use a small `.github/CODEOWNERS` to auto-request the right reviewer per subdirectory
- **CI on PRs**: lint + unit tests. Nothing gates review, but red CI slows merges.

## Open questions

1. **Model bundling vs OTA-only** — bundle a specific model version with the app for offline-first, or make first-launch download it? Bundled is simpler UX; OTA-only saves ~7 MB of app size.
2. **Trick classification in v2** — do we tag "cork/540/backflip/etc." from day 1? Enables leaderboards, per-trick filtering. Uses PoseC3D-FineGym as the starting classifier.
3. **User-facing labeling incentive** — reputation + badges + "your labels improved the model" notifications? Community-app incentive design matters.
4. **Storage retention** — do we keep every uploaded video forever, or auto-purge after N days if the labeling round is done + label is committed? Storage-cost implications.
5. **Community moderation vs Hoie-only moderation for v1** — is Hoie the sole admin, or do we grant N trusted users mod rights? Sole-admin is safest early; hard to keep up as user base grows.
6. **CLA** — recommendation is skip; confirm.
7. **Analytics** — any telemetry (privacy-respecting, opt-in) for feature usage / crash reports? PostHog self-hosted is a common OSS choice.

## What Hoie needs to decide now

1. **Apache 2.0** for all three repos? ✅ recommended.
2. **Repo names**: `turnip-ios`, `turnip-api`, `turnip-ml`?
3. **CLA yes/no**? Recommended: no.
4. **Skip CI setup for the OS-app first push, or do it upfront**? Recommend upfront; adding CI later requires backfill.
5. **Sole-admin moderation for v1 (you)**, or invite N trusted mods from day 1?

Once decided, the immediate next step is scaffolding `turnip-ios` with SwiftUI + AVFoundation + TFLite MoveNet Thunder integration, plus a small Swift file that runs pose detection on a video from your Photos library. That's the empirical test we agreed on before writing anything larger.

## Alternatives considered and rejected

- **Monorepo**: raises contribution barrier for OSS friends. Rejected.
- **AWS S3 for video storage**: $0.09/GB egress kills the economics. Rejected in favor of R2.
- **MIT license**: fine but Apache 2.0's patent grant is worth having for an ML project. Downgrade to MIT if Hoie strongly prefers minimalism.
- **Serverless API** (Vercel / Cloudflare Workers): cheap for low traffic but harder to run Postgres migrations against, and the Bun/TS + droplet stack matches inbox/budget so we reuse patterns. Rejected for MVP; reconsider for scale.
- **Fine-tuning from day 1**: expensive labeling effort + zero validated need until we measure Vision/MoveNet Thunder accuracy on real footage. Rejected — start with pretrained, escalate only if needed.
- **Web-only labeling UI**: adds a whole frontend surface. iOS-only labeling keeps v2 tight. Add web when a labeler asks for it.
