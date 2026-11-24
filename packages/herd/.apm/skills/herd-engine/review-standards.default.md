# Herd review standards — thermo-nuclear code quality

Adapted from `cursor/plugins` → `cursor-team-kit/skills/thermo-nuclear-code-quality-review`
(https://github.com/cursor/plugins/blob/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md).
This is the engine's default review standard, used when a repo configures none of its own
(`.claude/herd.config.json` → `reviewStandards`). This file is the review standard for every
herd review stage. Your brief (`review-N.brief.md`) owns the mechanics — what to apply, what
to defer, how to verify, what to commit. This file owns the *bar*.

An unusually strict review focused on implementation quality, maintainability, abstraction
quality, and codebase health. Be **ambitious** about structure. Do not merely identify local
cleanup opportunities. Actively search for "code judo" moves: restructurings that preserve
behavior while making the implementation dramatically simpler, smaller, more direct, and more
elegant.

## Core prompt

> Perform a deep code quality audit of the reviewed range.
> Rethink how to structure / implement the changes to meaningfully improve code quality without
> impacting behavior.
> Work to improve abstractions, modularity, reduce spaghetti code, improve succinctness and
> legibility.
> Be ambitious: if there is a clear path to improving the implementation that involves
> restructuring some of the codebase, go for it.
> Be extremely thorough and rigorous. Measure twice, cut once.

## Non-negotiable standards

0. **Be ambitious about structural simplification.**
   - Do not stop at "this could be a bit cleaner."
   - Look for opportunities to reframe the change so whole branches, helpers, modes,
     conditionals, or layers disappear entirely.
   - Prefer the solution that makes the code feel inevitable in hindsight.
   - Assume there is often a "code judo" move available: a re-organization that uses the
     existing architecture more effectively and makes the change dramatically simpler.
   - If you see a path to delete complexity rather than rearrange it, push hard for that path.

1. **Do not let a change push a file from under 1k lines to over 1k lines without a very strong reason.**
   - Treat this as a strong code-quality smell by default.
   - Prefer extracting helpers, subcomponents, modules, or local abstractions instead of
     letting a file sprawl past 1000 lines.
   - If the diff crosses that threshold, decompose it.
   - Only waive this if there is a compelling structural reason and the resulting file is
     still clearly organized.

2. **Do not allow random spaghetti growth in existing code.**
   - Be highly suspicious of new ad-hoc conditionals, scattered special cases, or one-off
     branches inserted into unrelated flows.
   - "Weird if statements in random places" is a design problem, not a stylistic nit.
   - Prefer pushing the logic into a dedicated abstraction, helper, state machine, policy
     object, or separate module instead of tangling an existing path.
   - Call out changes that make the surrounding code harder to reason about, even if they
     technically work.

3. **Bias toward cleaning the design, not just accepting working code.**
   - If behavior can stay the same while the structure becomes meaningfully cleaner, take the
     cleaner version.
   - Do not rubber-stamp "it works" implementations that leave the codebase messier.
   - Strongly prefer simplifications that remove moving pieces altogether over refactors that
     merely spread the same complexity around.

4. **Prefer direct, boring, maintainable code over hacky or magical code.**
   - Treat brittle, ad-hoc, or "magic" behavior as a code-quality problem.
   - Be skeptical of generic mechanisms that hide simple data-shape assumptions.
   - Flag thin abstractions, identity wrappers, or pass-through helpers that add indirection
     without buying clarity.

5. **Push hard on type and boundary cleanliness when they affect maintainability.**
   - Question unnecessary optionality, `unknown`, `any`, or cast-heavy code when a clearer
     type boundary could exist.
   - Prefer explicit typed models or shared contracts over loosely-shaped ad-hoc objects.
   - If a branch relies on a silent fallback to paper over an unclear invariant, make the
     boundary explicit instead.

6. **Keep logic in the canonical layer and reuse existing helpers.**
   - Call out feature logic leaking into shared paths, and implementation details leaking
     through APIs.
   - Prefer existing canonical utilities/helpers over bespoke one-offs.
   - Push code toward the right package, service, or module instead of normalizing
     architectural drift.

7. **Treat unnecessary sequential orchestration and non-atomic updates as design smells when the cleaner structure is obvious.**
   - If independent work is serialized for no good reason, ask whether the flow should run in
     parallel instead.
   - If related updates can leave state half-applied, push for a more atomic structure.
   - Do not over-index on micro-optimizations, but do flag avoidable orchestration complexity
     that makes the implementation more brittle.

## Primary review questions

For every meaningful change, ask:

- Is there a "code judo" move that would make this dramatically simpler?
- Can this change be reframed so fewer concepts, branches, or helper layers are needed?
- Does this improve or worsen the local architecture?
- Did the diff add branching complexity where a better abstraction should exist?
- Did a previously cohesive module become more coupled, more stateful, or harder to scan?
- Is this logic living in the right file and layer?
- Did this change enlarge a file or component past a healthy size boundary?
- Are there repeated conditionals that signal a missing model or missing helper?
- Is the implementation direct and legible, or does it rely on special cases and incidental
  control flow?
- Is this abstraction actually earning its keep, or is it just a wrapper?
- Did the diff introduce casts, optionality, or ad-hoc object shapes that obscure the real
  invariant?
- Is this orchestration more sequential or less atomic than it needs to be?

## Flag aggressively

- A complicated implementation where a cleaner reframing could delete whole categories of
  complexity.
- Refactors that move code around but fail to reduce the number of concepts a reader must
  hold in their head.
- A file crossing 1000 lines because of this range, especially if the new code could be
  split out.
- New conditionals bolted onto unrelated code paths.
- One-off booleans, nullable modes, or flags that complicate existing control flow.
- Feature-specific logic leaking into general-purpose modules.
- Generic "magic" handling that hides simple structure.
- Thin wrappers or identity abstractions that add indirection without simplifying anything.
- Unnecessary casts, `any`, `unknown`, or optional params that muddy the real contract.
- Copy-pasted logic instead of extracted helpers.
- Narrow edge-case handling implemented in the middle of an already busy function.
- Refactors that technically pass tests but make the code less modular or less readable.
- "Temporary" branching that is likely to become permanent debt.
- Bespoke helpers where the codebase already has a canonical utility for the job.
- Logic added in the wrong layer/package when it should live somewhere more central.
- Sequential async flow where obviously independent work could stay simpler in parallel.
- Partial-update logic that leaves state less atomic than necessary.

## Preferred remedies

- Delete a whole layer of indirection rather than polishing it.
- Reframe the state model so conditionals disappear instead of getting centralized.
- Change the ownership boundary so the feature becomes a natural extension of an existing
  abstraction.
- Turn special-case logic into a simpler default flow with fewer exceptions.
- Extract a helper or pure function.
- Split a large file into smaller focused modules.
- Move feature-specific logic behind a dedicated abstraction.
- Replace condition chains with a typed model or explicit dispatcher.
- Separate orchestration from business logic.
- Collapse duplicate branches into a single clearer flow.
- Delete wrappers that do not meaningfully clarify the API.
- Reuse the existing canonical helper instead of introducing a near-duplicate.
- Make type boundaries more explicit so the control flow gets simpler.
- Move the logic to the package/module/layer that already owns the concept.
- Parallelize independent work when that also simplifies the orchestration.
- Restructure related updates into a more atomic flow when partial state would be harder to
  reason about.

Do not settle for "maybe rename this" when the real issue is structural. Do not settle for a
merely cleaner version of the same messy idea when a much simpler idea is plausible.

## Tone

Direct, serious, demanding. Not rude, but never soften a major maintainability issue into a
mild suggestion. If the code makes the codebase messier, say so. If the implementation missed
an opportunity for a dramatic simplification, say that too.

## Priority order

1. Structural code-quality regressions
2. Missed opportunities for dramatic simplification / code-judo restructuring
3. Spaghetti / branching complexity increases
4. Boundary / abstraction / type-contract problems
5. File-size and decomposition concerns
6. Modularity and abstraction issues
7. Legibility and maintainability concerns

Do not flood the review with low-value nits when larger structural issues exist. Prefer a
small number of high-conviction findings over a long list of cosmetic notes.

## Bar

Never call a range clean merely because behavior seems correct. The bar is:

- no clear structural regression
- no obvious missed opportunity to make the implementation dramatically simpler
- no unjustified file-size explosion
- no obvious spaghetti growth from special-case branching
- no obviously hacky or magical abstraction
- no unnecessary wrapper/cast/optionality churn obscuring the real design
- no architecture-boundary leak or avoidable canonical-helper duplication
- no missed obvious decomposition that would materially improve maintainability

Presumptive blockers unless there is a clear justification:

- the range preserves a lot of incidental complexity when a plausible code-judo move would
  delete it
- the range pushes a file from below 1000 lines to above 1000 lines
- the range adds ad-hoc branching that makes an existing flow more tangled
- the range solves a local problem by scattering feature checks across shared code
- the range adds an unnecessary abstraction, wrapper, or cast-heavy contract
- the range duplicates an existing helper or puts logic in the wrong layer
