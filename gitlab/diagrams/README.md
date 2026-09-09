# Documentation diagrams

The operator guides embed the SVG files here as ordinary Markdown images, so
readers do not need a Mermaid-enabled preview. Each SVG has a matching editable
`.mmd` source. Keep both versions together when changing the architecture.

The diagrams use Mermaid 10-compatible syntax and plain SVG text labels. To
regenerate one with Mermaid CLI installed:

```bash
mmdc -i gitlab/diagrams/workflow.mmd -o gitlab/diagrams/workflow.svg \
  -c gitlab/diagrams/config.json -b white
```

Render every changed source and inspect the SVG at a readable size before
committing. Sequence message labels must not contain bare semicolons: Mermaid
treats them as statement separators. See the
[Mermaid sequence syntax](https://mermaid.js.org/syntax/sequenceDiagram.html).
