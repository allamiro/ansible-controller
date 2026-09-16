# Controller documentation diagrams

Each SVG has an editable Mermaid source with the same name. Keep source and render together when updating a diagram. The SVG files use plain text labels so readers do not need Mermaid support.

| Source | Purpose |
|---|---|
| [controller-overview.mmd](controller-overview.mmd) | Compact direct-versus-mesh overview for the main README. Arrows show work flow. |
| [controller-mounts.mmd](controller-mounts.mmd) | Host directories, container paths, and mount access modes. |
| [mesh-topology.mmd](mesh-topology.mmd) | Control host, both ingress endpoints, target networks, and outbound connection initiation. |
| [mesh-enrollment.mmd](mesh-enrollment.mmd) | Certificate requests, offline CA signing, and node enrollment. |

Rendered with Mermaid CLI 10.9.1. From the repository root, with `mmdc` installed:

```bash
for diagram in assets/diagrams/*.mmd; do
  mmdc -i "$diagram" -o "${diagram%.mmd}.svg" \
    -c assets/diagrams/config.json -b white
done
```

Inspect each SVG at normal reading size before committing. Update accessibility titles/descriptions with the diagram, and keep connection-initiation arrows distinct from job-delivery arrows. The [GitLab diagrams](../../gitlab/diagrams/README.md) document that optional integration separately.
