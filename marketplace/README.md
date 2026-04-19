# snor-oh marketplace

Anonymous gallery for `.snoroh` and `.animime` mascot packages.
Stack: Next.js 15 · Supabase (Postgres + Storage) · Upstash Redis (rate limit) · Vercel.

## Setup

### 1. Supabase

Create a free Supabase project, then:

1. **SQL** — run `supabase/migrations/0001_init.sql` in the SQL editor.
2. **Storage** — create a bucket:
   - Name: `packages`
   - Public: **yes**
   - File size limit: `2 MiB`
   - Allowed MIME types: `application/json`
3. Grab `Project URL`, `anon public` key, and `service_role` key from **Project Settings → API**.

### 2. Upstash Redis

Create a free Redis database at [upstash.com](https://upstash.com/). Copy the REST URL and token.

### 3. Environment

Copy `.env.example` to `.env.local` and fill in:

```
NEXT_PUBLIC_SUPABASE_URL=...
NEXT_PUBLIC_SUPABASE_ANON_KEY=...
SUPABASE_SERVICE_ROLE_KEY=...
UPSTASH_REDIS_REST_URL=...
UPSTASH_REDIS_REST_TOKEN=...
ADMIN_TOKEN=$(openssl rand -hex 32)
IP_HASH_SALT=$(openssl rand -hex 16)
```

### 4. Run

```bash
npm install
npm run dev
# http://localhost:3000
```

### 5. Deploy to Vercel

```bash
vercel link     # first time, inside marketplace/
vercel env pull .env.local
vercel --prod
```

Set the same env vars in Vercel project settings.

## API

- `POST /api/upload` — multipart form, fields: `file` (required), `filename`, `creator`. Rate limit: 5/day/IP.
- `GET /api/packages?cursor=<iso>` — paginated list, newest first, 24 per page.
- `GET /api/packages/:id/download` — streams the raw package. Rate limit: 100/day/IP.
- `DELETE /api/admin/packages/:id` — admin-only, requires `Authorization: Bearer $ADMIN_TOKEN`.

## Package format

Both `.snoroh` and `.animime` use the same JSON schema (see `lib/schema.ts`). The extension is branding only. The validator enforces:

- Version must be `1`.
- Name must be 1–80 chars.
- All 7 statuses present: `initializing`, `searching`, `idle`, `busy`, `service`, `disconnected`, `visiting`.
- Each sprite is valid base64 PNG, ≤ 1024px per side.
- Frame count 1–64 per status.
- Total file ≤ 2 MiB.

## Moderation

To delete a package:

```bash
curl -X DELETE \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://your-marketplace.vercel.app/api/admin/packages/<uuid>
```

## Roadmap

- [ ] In-app "Share to Marketplace" button (snor-oh mac app → POST /api/upload)
- [ ] Search / filter by creator
- [ ] Report/flag endpoint (anonymous)
