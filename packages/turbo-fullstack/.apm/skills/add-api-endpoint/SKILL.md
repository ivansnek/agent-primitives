---
name: add-api-endpoint
description: Use when adding or modifying any NestJS API endpoint in apps/api — @ZodRoute + ZodValidationPipe recipe, Zod schema placement in the shared validators package (@<scope>/shared), response typing, and the OpenAPI gate CI runs on every route.
---

# Adding a New API Endpoint

> Paths below are the conventional Turbo layout, and named helpers are examples. Where this repo's `CLAUDE.md`/`AGENTS.md` names a different layout or overrides a rule here, the repo wins.

Every new or modified endpoint in `apps/api` follows this pattern. When the repo has an OpenAPI gate (e.g. `pnpm --filter @<scope>/api openapi:gate`), a handler that skips it fails the build.

## Adding a new API endpoint (NON-NEGOTIABLE)

**1. Author the Zod schema in the shared package (`@<scope>/shared`)** — add request and response schemas to `packages/shared/src/validators/[domain].ts`. Add `.describe("…")` to each field so the generated API docs explain it.

**2. Apply `@ZodRoute()` and `ZodValidationPipe` in the controller** (the repo's route-documentation decorator and validation pipe; names below are the usual ones):

```ts
import { ZodRoute } from "../../common/openapi/decorators";
import { ZodValidationPipe } from "../../common/pipes/zod-validation.pipe";
import { myCreateSchema, myResponseSchema, type MyCreateInput, type MyResponse } from "@<scope>/shared";

@Post()
@HttpCode(201)
@Roles("admin")
@ZodRoute({
  request: { body: myCreateSchema },
  response: { 201: myResponseSchema },
})
async create(
  @Body(new ZodValidationPipe(myCreateSchema)) body: MyCreateInput,
  @CurrentUser() user: AuthUser, // the repo's auth-context decorator, if it has one
): Promise<MyResponse> {
  return this.service.create(body, user);
  // body is already validated — do NOT call myCreateSchema.parse(body) again
}
```

**3. Verify locally before pushing** (use the repo's own script names):

```bash
pnpm --filter @<scope>/api openapi:gate     # if the repo has the gate: must exit 0
pnpm --filter @<scope>/api typecheck        # must pass
```

**Red-flag checklist for new backend endpoints (reject at review):**
- `@Body() body: unknown` or `@Query() query: unknown` in a new handler — use `ZodValidationPipe` instead.
- Inline `schema.parse(body)` inside a controller handler — the pipe handles this. (An auth controller that must `safeParse` to avoid leaking validation detail is the usual documented exception.)
- `Promise<unknown>` return type on a controller handler — infer from the Zod response schema.
- Missing `@ZodRoute()` decorator on a handler — the OpenAPI gate fails the build on merge.
- Zod schemas defined inline in a controller file — schemas live in `packages/shared/src/validators/`.
