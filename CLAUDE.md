# PhishSight Development Rules

## Project Structure

PhishSight is a multi-tenant SaaS phishing email analysis platform. The monorepo contains 5 projects:

```
PhishSight/
├── phishsight-app-backend/   # Express.js + Prisma API (TypeScript)
├── phishsight-app/           # Next.js 14 App Router dashboard (TypeScript)
├── phishsight-site/          # Next.js 14 marketing site (TypeScript)
├── phishsight-extention/     # Chrome extension (TypeScript)
├── dev-deploy/               # Development docker-compose + env templates
├── prod-deploy/              # Production docker-compose + env templates
└── deployment-setup.sh       # Repo cloning/pulling script
```

Each sub-project has its own `package.json`, `tsconfig.json`, and git history. Run commands from within the specific project directory.

---

## Backend (`phishsight-app-backend`)

### Architecture

```
src/
├── api/routes/          # Express route handlers (thin controllers)
│   ├── admin.routes.ts  # Super admin dashboard (stats, user/tenant CRUD, maintenance)
│   ├── auth.routes.ts   # Login, register, Google OAuth, token refresh
│   ├── billing.routes.ts # Paddle checkout, subscription management
│   ├── paddle-webhook.routes.ts # Paddle webhook event handlers
│   ├── tenant.routes.ts # Tenant CRUD, member management
│   └── usage.routes.ts  # Usage tracking, upgrade options
├── api/middlewares/      # Auth, RBAC, rate limiting, validation, tenant resolution
├── core/                # Domain logic
│   ├── auth/            # JWT, sessions, MFA, Google OAuth, API keys
│   ├── billing/         # Paddle integration, plan limits, usage tracking
│   │   ├── paddle.service.ts  # Paddle SDK wrapper (customers, subscriptions, webhooks)
│   │   └── plan.service.ts    # Plan limits, display names, feature flags
│   └── tenant/          # Multi-tenant CRUD, invitations
├── services/            # Feature services
│   ├── phishing/        # Analysis engine, queue, enrichment
│   ├── pdf/             # Report generation (Puppeteer)
│   └── scheduled/       # Cron-like jobs
│       └── trial-expiry.service.ts  # Auto-downgrades expired trials to FREE
├── infrastructure/      # External integrations
│   ├── database/        # Prisma client singleton
│   ├── email/           # Notification service + templates
│   │   └── templates/
│   │       ├── auth.templates.ts          # Welcome, verification, password reset, MFA
│   │       └── subscription.templates.ts  # Subscription activated/cancelled/past due/trial expiring
│   ├── cache/           # Redis wrapper
│   └── storage/         # S3 file storage
└── shared/              # Errors, utils, logger
```

### Key Patterns

**Route -> Middleware -> Service -> Prisma**
Routes are thin. Business logic lives in services. Never put DB queries in route handlers.

```typescript
// Route handler pattern
router.patch('/:userId', requireRole(['TENANT_ADMIN']), async (req, res) => {
  const result = await tenantService.updateMemberRole(req.params.tenantId, req.params.userId, req.body.role);
  res.json(result);
});
```

**Singleton Services**: Services are instantiated once and exported as module-level singletons:
```typescript
class TenantService { ... }
export const tenantService = new TenantService();
```

**Error Handling**: Use `AppError` with `ErrorCode` enum. Never throw raw Error objects from services.

**Prisma Model Naming**: Prisma uses camelCase for model access. Model `PhishingAnalysis` -> `prisma.phishingAnalysis`. Model `TenantUser` -> `prisma.tenantUser` (NOT `prisma.tenantMember`).

**Database**: Single Prisma client from `src/infrastructure/database/prisma.ts`. Always import from there:
```typescript
import { prisma } from '../../infrastructure/database/prisma';
```

### Multi-Tenant Data Isolation (CRITICAL)

Every database query that touches tenant-scoped data MUST include `tenantId` in the WHERE clause. Never return data across tenants. The middleware extracts `tenantId` from the authenticated user's JWT and attaches it to `req.tenantId`.

Models that are tenant-scoped: `PhishingAnalysis`, `TenantUser`, `ApiKey`, `UsageRecord`, `AuditLog`, `TenantInvitation`.

### Tenant Soft-Delete (CRITICAL)

Tenants use soft-delete. The `Tenant` model has `isDeleted` (Boolean, default false) and `deletedAt` (DateTime, nullable) fields.

**Every tenant query** must include `isDeleted: false` in the WHERE clause to exclude archived tenants, including:
- Tenant resolution middleware (`tenant.middleware.ts`)
- Admin stats endpoint (`GET /admin/stats`)
- Admin tenant listing (`GET /admin/tenants` — unless `showArchived` param is set)
- Any aggregate queries (counts, groupBy)

Deletion flow: Soft-delete (archive) -> Restore OR Permanent delete (actual cascade delete with `?confirm=true`).

### Paddle Billing Integration

**Backend env vars** (NOT `NEXT_PUBLIC_` — these are server-side):
- `PADDLE_API_KEY` — Server-side API key for Paddle SDK
- `PADDLE_CLIENT_TOKEN` — Client token passed to frontend via `/billing/checkout-config` endpoint
- `PADDLE_WEBHOOK_SECRET` — For verifying webhook signatures
- `PADDLE_ENVIRONMENT` — `sandbox` or `production`
- `PADDLE_PRICE_STARTER_MONTHLY`, `PADDLE_PRICE_STARTER_ANNUAL`, etc. — Price IDs

**Checkout flow**: Frontend calls `GET /billing/checkout-config` to get the client token + prices, then opens Paddle.js checkout overlay client-side. Paddle sends webhook events to `POST /webhooks/paddle` which updates tenant subscription status.

**Customer conflict handling**: `paddle.service.ts` handles the case where a Paddle customer already exists for an email by catching the conflict error and looking up the existing customer.

### Plan Limits (CRITICAL)

Plan limits are defined in `src/core/billing/plan.service.ts` in the `PLAN_LIMITS` constant:

| Plan         | maxUsers | maxAnalysesPerMonth |
|--------------|----------|---------------------|
| FREE         | 1        | 30                  |
| STARTER      | 1        | 100                 |
| PROFESSIONAL | 10       | 300                 |
| ENTERPRISE   | -1       | -1 (unlimited)      |

When creating tenants, ALWAYS use `getPlanLimits(plan)` to set `maxUsers` and `maxAnalysesPerMonth` explicitly. Never rely on Prisma schema defaults. This was a past bug.

### Trial System

- Trials are activated via URL params: `?plan=starter&trial=true` or `?plan=professional&trial=true`
- Duration: 14 days
- Tenant fields: `trialPlan`, `trialEndsAt`, `status: TRIAL`
- Trial activation works for both new registrations and existing Google OAuth users returning with trial params
- `trial-expiry.service.ts` runs periodically to downgrade expired trials to FREE
- Admin can manage trial dates via tenant edit modal

### Adding a New API Route

1. Create route file in `src/api/routes/` following existing patterns
2. Register in `src/api/routes/index.ts`
3. Add validation schemas (Zod) alongside the route
4. Apply appropriate middleware: `authenticate`, `requireRole()`, `requireTenant()`
5. Add rate limiting if public-facing

### Adding Email Templates

1. Create template function in `src/infrastructure/email/templates/` (returns `{ subject, html }`)
2. Export from `src/infrastructure/email/templates/index.ts`
3. Add send method in `src/infrastructure/email/notification.service.ts`
4. Call from business logic with try/catch (email failures should not break the main flow)

### Database Migrations

1. Modify `prisma/schema.prisma`
2. Run `npx prisma migrate dev --name descriptive_name` locally
3. Migrations auto-apply in production via `docker-entrypoint.sh` (`npx prisma migrate deploy`)
4. After schema changes, always run `npx prisma generate`

### RBAC Roles (highest to lowest)

- `SUPER_ADMIN` — Platform-wide admin (single user per deployment). Cannot be assigned via admin UI.
- `TENANT_ADMIN` — Manages their tenant (members, settings, billing)
- `ANALYST` — Can run analyses, view results
- `VIEWER` — Read-only access to analyses

Check roles with `requireRole(['TENANT_ADMIN', 'SUPER_ADMIN'])` middleware.

**Role escalation guard**: The admin user create/update endpoints reject attempts to set role to `SUPER_ADMIN`.

### Auth Patterns

- JWT access tokens (short-lived, 15m default) + refresh tokens (7d, stored in Redis + httpOnly cookie)
- API keys use `ps_live_` prefix, stored hashed in DB
- Chrome extension receives refresh token in JSON body (not cookie) via `X-Client-Type: extension` header
- Google OAuth stores refresh token in Redis (critical -- was a past bug when missing)

### Admin Dashboard Features

The super admin dashboard (`/admin/*`) provides:
- **Stats**: Real-time metrics with month-over-month trends, billing breakdown (paying/trial/free tenants)
- **User management**: Create (with optional welcome email), edit (role/status), delete (with orphan tenant detection + cascade), 2FA reset (with email notification)
- **Tenant management**: View details (including Paddle billing info), edit limits, trial management, owner reassignment, soft-delete (archive/restore/permanent delete)
- **Audit logs**: User changes logged with before/after diffs, webhook events logged
- **Maintenance cleanup**: Cleans audit logs, temp files, orphaned API keys, revoked keys, expired invitations

---

## Frontend App (`phishsight-app`)

### Architecture

```
app/
├── (auth)/              # Login, register, forgot-password (no sidebar)
├── (dashboard)/         # Main app with sidebar layout
│   └── dashboard/
│       ├── analyze/     # File upload + analysis
│       ├── history/     # Analysis history + detail view ([id] dynamic route)
│       ├── team/        # Team member management
│       ├── settings/    # User preferences + billing/subscription management
│       ├── api-keys/    # API key management
│       ├── tenants/     # Tenant settings + billing ([id]/settings dynamic route)
│       └── admin/       # Super admin panel
│           ├── page.tsx         # Overview with real trend metrics + billing card
│           ├── users/           # User CRUD with safety guards
│           ├── tenants/         # Tenant management with soft-delete UI
│           ├── billing/         # Revenue & subscription overview
│           ├── leads/           # Sales inquiry management
│           ├── configurations/  # Global settings
│           ├── audit-logs/      # Activity & security logs
│           ├── performance/     # System metrics
│           └── system/          # Health & maintenance cleanup
├── providers.tsx        # QueryClient, GoogleOAuthProvider, TooltipProvider
├── layout.tsx           # Root layout (Paddle.js script tag)
└── middleware.ts        # Auth redirect middleware

components/
├── auth/
│   └── google-login-button.tsx  # Extracted for SSR-safe dynamic import
├── trial-banner.tsx     # Shows trial status + upgrade CTA in dashboard
├── payment-banner.tsx   # Subscription management banner
└── ui/                  # shadcn/ui components

lib/
├── api.ts              # API client singleton with auto token refresh
├── store.ts            # Zustand auth store (login, googleLogin with trial params)
├── paddle.ts           # Paddle.js client-side initialization + checkout overlay
└── utils.ts            # Utilities (cn, formatters)
```

### Key Patterns

**API Client**: Singleton in `lib/api.ts`. Uses `ApiClient` class with automatic token refresh. All API calls go through `api.methodName()`. Never use raw `fetch()` for backend calls.

```typescript
import { api } from '@/lib/api';
const data = await api.getAnalyses(page, limit);
```

**State Management**: Zustand store in `lib/store.ts` for auth state (`useAuthStore`) and UI state. The `googleLogin` method accepts optional `plan` and `trial` params for trial activation.

**Components**: shadcn/ui (Radix UI + Tailwind). Import from `@/components/ui/`. Follow existing component patterns.

**Route Groups**: `(auth)` and `(dashboard)` are Next.js route groups with different layouts. Auth pages have no sidebar. Dashboard pages have the sidebar + header + trial/payment banners.

### Google OAuth SSR Fix (CRITICAL)

The `useGoogleLogin` hook from `@react-oauth/google` crashes during Next.js static prerendering because `GoogleOAuthProvider` context isn't available at build time.

**Solution**: The Google login button is extracted into `components/auth/google-login-button.tsx` and imported with `next/dynamic` + `ssr: false` in both login and register pages:

```typescript
const GoogleLoginButton = dynamic(
  () => import("@/components/auth/google-login-button").then(mod => ({ default: mod.GoogleLoginButton })),
  { ssr: false }
);
```

**Never** call `useGoogleLogin()` directly in a page component. Always use the dynamically imported `GoogleLoginButton`.

### Adding a Dashboard Page

1. Create directory under `app/(dashboard)/dashboard/your-page/`
2. Add `page.tsx` (use `"use client"` for interactive pages)
3. Add navigation link in sidebar component if needed
4. Use existing patterns: toast for success/error, Dialog for modals, DropdownMenu for actions

### Build-Time Environment Variables

`NEXT_PUBLIC_*` variables are baked in at build time. If you change them, you MUST rebuild the Docker image. Key ones:
- `NEXT_PUBLIC_API_URL` — Backend API URL (internal Docker DNS: `http://api:3001`)
- `NEXT_PUBLIC_TURNSTILE_SITEKEY` — Cloudflare bot protection
- `NEXT_PUBLIC_GOOGLE_CLIENT_ID` — Google OAuth

**Important**: These must be declared as `ARG` + `ENV` in the Dockerfile builder stage. If a `NEXT_PUBLIC_*` var is missing from the Dockerfile, it will be empty in the built bundle even if set at runtime.

**Paddle client token** is NOT a `NEXT_PUBLIC_` build-time var on the frontend. It's fetched at runtime from the backend's `GET /billing/checkout-config` endpoint.

---

## Marketing Site (`phishsight-site`)

### Architecture

Same Next.js 14 App Router structure. Key directories:

```
app/
├── email-security/      # Free domain security scanner
├── tools/               # Individual SPF/DKIM/DMARC checkers
├── platform/            # Product features page
├── case-studies/        # Audience-specific case studies (MSSPs, SOC teams, security teams)
├── about/               # About page
├── contact/             # Contact form
└── sitemap.ts           # Dynamic sitemap generation

components/home/
├── hero-section.tsx     # Landing hero with trial CTAs
├── pricing-section.tsx  # Pricing cards with trial signup links
└── cta-section.tsx      # Call-to-action sections
```

**SEO**: All metadata defined in `lib/seo.ts` (`pageMetadata` object + JSON-LD generators). Every new page needs: metadata in layout.tsx, canonical URL, breadcrumb JSON-LD, sitemap entry.

**Components**: Shared with marketing patterns -- framer-motion for animations, custom components (not shadcn).

**Trial CTAs**: Pricing section links to `app.phishsight.ai/register?plan=starter&trial=true` and `?plan=professional&trial=true`.

---

## Chrome Extension (`phishsight-extention`)

TypeScript Chrome extension. Communicates with backend API using API keys or JWT tokens. Note the directory name typo (`extention` not `extension`) -- do not rename as it would break deployment references.

---

## Deployment

### Docker (Production)

- `prod-deploy/docker-compose.yml` — Orchestrates postgres, redis, api, app services
- `dev-deploy/docker-compose.yml` — Development environment with all services
- Traefik reverse proxy handles SSL termination and routing (external network `traefik-frontend`)
- API and App services are NOT exposed directly -- Traefik routes to them

### CACHEBUST Pattern (CRITICAL)

The backend Dockerfile uses `ARG CACHEBUST=1` before `COPY . .` to invalidate Docker layer cache for source code. Always pass a unique value when deploying:

```bash
CACHEBUST=$(date +%s) docker compose up --build -d
```

In Dokploy, set `CACHEBUST` as a build arg in the environment configuration.

### Docker Entrypoint Safety

`scripts/docker-entrypoint.sh` runs on every container start:
1. Waits for PostgreSQL and Redis
2. Runs `npx prisma generate` (ensures client matches schema)
3. Runs `npx prisma migrate deploy` (applies pending migrations)
4. Optionally seeds the database (`RUN_SEED=true`)
5. Starts the app

### Deployment Platform

Production uses **Dokploy** (not raw docker-compose) for app and API services. Dokploy pulls commits, builds, and deploys. PostgreSQL and Redis run via docker-compose separately.

---

## Development Workflow

### Before Committing

1. Run TypeScript check: `./node_modules/.bin/tsc --noEmit` in the modified project
2. Run build: `npm run build` to catch any build errors
3. Never commit `.env` files, credentials, or API keys

### TypeScript

- Strict mode enabled in all projects
- Use proper types -- avoid `any` except for Prisma JSON fields (`notificationPreferences as any`)
- Zod for runtime validation of API inputs

### Git Conventions

- Backend and frontend are separate git repos (each sub-directory is its own repo)
- Commit from within the specific project directory
- Use descriptive commit messages explaining the "why"
- Group commits by feature/function, not by file
- Do NOT include "Co-Authored-By" lines in commit messages

---

## Common Pitfalls (Past Bugs)

1. **Prisma model name**: The join table for users and tenants is `TenantUser` (`prisma.tenantUser`), NOT `TenantMember`. This has caused runtime errors.

2. **Prisma defaults vs plan limits**: Never trust DB schema defaults for plan-related fields. Always set explicitly using `PLAN_LIMITS`.

3. **Docker layer caching**: Source code changes may not take effect if Docker caches the layer. Always use CACHEBUST for deployments.

4. **Missing `prisma generate`**: After schema changes, the Prisma client must be regenerated. The entrypoint handles this in production, but run it manually in development.

5. **Token refresh for extension**: Chrome extensions cannot read httpOnly cookies. The `/auth/refresh` endpoint returns the refresh token in the JSON body when `X-Client-Type: extension` header is present.

6. **Google OAuth refresh token**: Must be stored in Redis via `storeRefreshToken()` after Google login. Missing this causes 401 on token refresh.

7. **Tenant-scoped queries**: Every query on tenant data MUST filter by `tenantId`. Missing this leaks data across tenants.

8. **Soft-deleted tenants**: Every tenant query MUST include `isDeleted: false`. Missing this shows archived tenants or lets archived tenant members access the dashboard.

9. **Email notification failures**: Always wrap email sending in try/catch. Email failures should never break the main business flow.

10. **GoogleOAuthProvider SSR**: Never use `useGoogleLogin()` directly in page components. Use the dynamically imported `GoogleLoginButton` component with `ssr: false`.

11. **Paddle customer email conflicts**: When creating Paddle customers, the email may already exist from a previous failed checkout. The `getOrCreateCustomer` method catches this and looks up the existing customer.

12. **`NEXT_PUBLIC_` vars in Docker**: These are baked at build time. They must be declared as `ARG` + `ENV` in the Dockerfile's builder stage before `RUN npm run build`. Setting them only at runtime has no effect.

13. **`zoxide` in shell**: This development environment has `zoxide` installed which intercepts the `cd` command. Use `builtin cd` or `SHELL=/bin/bash bash -c 'cd /path && command'` when running shell commands.

14. **SUPER_ADMIN role escalation**: The admin UI and backend both guard against creating or promoting users to SUPER_ADMIN role. Only the initial seed creates SUPER_ADMIN users.

---

## Session Continuity (IMPORTANT)

**When compacting or summarizing a conversation**, always update this `CLAUDE.md` file with any new knowledge gained during the session -- new features implemented, new pitfalls discovered, architecture changes, new env vars, new files/patterns, etc. This ensures the next chat starts with full up-to-date context of the project.
