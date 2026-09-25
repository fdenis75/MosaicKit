# codebase-analysis-docs/assets

Supporting material for [`../CODEBASE_KNOWLEDGE.md`](../CODEBASE_KNOWLEDGE.md).

| File | What it shows | Referenced in |
|---|---|---|
| `feature-map.mmd` | Feature (F1–F13) interaction map | §1.7 |
| `component-map.mmd` | Layers and main collaborations | §2.2 |
| `mosaic-pipeline.mmd` | Mosaic generation flowchart | §1.7, §2.3 |
| `mosaic-sequence.mmd` | Mosaic sequence (coordinator → generator → GPU → commit) | §2.3 |
| `preview-sequence.mmd` | Preview sequence (retry → compose → export → commit) | §2.4 |
| `cancellation-model.mmd` | How cancellation reaches the work | §2.7 |
| `output-publication-strategy.mmd` | Proposed destination-aware publication (local / remote / iCloud) | §F12 |
| `model-schema.mmd` | Codable model graph (the persisted "schema") | §5.3 |
| `doc_check.py` | Link/table/fence checks + re-hash of every file anchor | §6.3 |

Render `.mmd` files with any Mermaid viewer (GitHub renders the inline copies in the main document).
