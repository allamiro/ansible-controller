# Documentation diagrams

The operator guides embed the SVG files here as ordinary Markdown images, so
readers do not need a Mermaid-enabled preview. Each SVG has a matching editable
`.mmd` source. Keep both versions together when changing the architecture.

The diagrams use Mermaid 10-compatible syntax and plain SVG text labels. To
regenerate one with Mermaid CLI installed:

```bash
for diagram in gitlab/diagrams/*.mmd; do
  mmdc -i "$diagram" -o "${diagram%.mmd}.svg" \
    -c gitlab/diagrams/config.json -b white
done
```

| Diagram | Case |
|---|---|
| [Workflow](workflow.svg) | Review, optional separate sync release, receipt verification, manual execution. Applies to mesh and the reusable template. |
| [Lifecycle](lifecycle.svg) | Platform preparation versus repeatable automation project changes. |
| [Rollout](rollout.svg) | Canary verification, wider batches and recovery decisions. |
| [Standalone](standalone.svg) | Bootstrap seed's single manual fetch-and-run route. |
| [Mesh](mesh.svg) | Separate sync and execution, outbound connections and result return. |
| [Components](components.svg) | GitLab, Runner, controller and node responsibilities. |
| [Retries](retries.svg) | Replay, pre-submit admission retry and unresolved outcomes. |

Render every changed source and inspect the SVG at a readable size before
committing. Sequence message labels must not contain bare semicolons: Mermaid
treats them as statement separators. See the
[Mermaid sequence syntax](https://mermaid.js.org/syntax/sequenceDiagram.html).
