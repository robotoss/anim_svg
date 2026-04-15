# brain/ — the brain of the `anim_svg` project

A living knowledge base. Not "just because", but so that anyone coming into
the project (including your future self) can understand within 5 minutes:
**what already exists, what's next, why it was decided this way**.

## What's where

| File | About | How often to update |
|---|---|---|
| [`feature_map.md`](feature_map.md) | SVG feature → Lottie field → status table | On every PR that changes feature coverage |
| [`knowledge.md`](knowledge.md) | Links to specs, articles, reference implementations | As new sources are found |
| [`glossary.md`](glossary.md) | SMIL/Lottie/thorvg terms | When a new term appears in the code |
| [`adr.md`](adr.md) | Architecture Decision Records | On every architectural decision — before implementation |

## Rules

1. **brain/ does not replace README.md**. README is the public face, brain is the internal kitchen.
2. **Every "why" goes into an ADR**. If the answer to "why this way" is not in the code or in
   brain/adr.md — the decision is undocumented and will be forgotten.
3. **feature_map is updated in the same PR that changes the feature**. Otherwise the table lies.
4. **Do not clean sprint.md**. Past sprints remain as a log — at the end of the file.
