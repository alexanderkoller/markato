# Mermaid diagram families

Every Mermaid fence in this document should become a diagram. Check readable labels, complete arrows and legends, and absence of clipped content. The renderer is rusty-mermaid 0.2.0; this corpus tests representative syntax, not complete Mermaid.js compatibility.

## Flowchart

Decisions and joins.

```mermaid
flowchart LR
    Start[Open document] --> Parse{Valid syntax?}
    Parse -->|Yes| SVG[Render SVG]
    Parse -->|No| Error[Show source]
    SVG --> Preview[Preview]
    Error --> Preview
```

## Sequence

Messages, activation and notes.

```mermaid
sequenceDiagram
    participant Writer
    participant Parser
    participant Preview
    Writer->>Parser: Edit Mermaid
    activate Parser
    Parser->>Preview: SVG image
    deactivate Parser
    Note over Writer,Preview: No browser runtime
    Preview-->>Writer: Diagram ready
```

## State

Start, transitions and end.

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Parsing: edit
    Parsing --> Ready: success
    Parsing --> Error: failure
    Error --> Parsing: retry
    Ready --> [*]
```

## Class

Members and inheritance.

```mermaid
classDiagram
    class Document {
        +String source
        +render()
    }
    class MarkdownDocument
    Document <|-- MarkdownDocument
```

## Er

Entities and relationships.

```mermaid
erDiagram
    DOCUMENT ||--o{ DIAGRAM : contains
    DOCUMENT {
        int id
        string title
    }
    DIAGRAM {
        int id
        string source
    }
```

## Pie

Slices and legend.

```mermaid
pie title Document content
    "Prose" : 60
    "Diagrams" : 25
    "Math" : 15
```

## Mindmap

Indented hierarchy.

```mermaid
mindmap
  root((Markdown))
    Text
      Headings
      Lists
    Diagrams
      Flowcharts
      Sequences
```

## Gantt

Dates, sections and dependencies.

```mermaid
gantt
    title Renderer rollout
    dateFormat YYYY-MM-DD
    section Implementation
    Integrate :a1, 2026-10-12, 2d
    Validate :a2, after a1, 3d
```

## Timeline

Periods and events.

```mermaid
timeline
    title Rendering milestones
    2025 : Markdown
    2026 : Equations : Mermaid SVG
```

## Gitgraph

Branches and merge.

```mermaid
gitGraph
    commit
    branch feature
    checkout feature
    commit
    checkout main
    merge feature
```

## Xychart

Axes, bars and lines.

```mermaid
xychart-beta
    title "Render time"
    x-axis [small, medium, large]
    y-axis "ms" 0 --> 10
    bar [1, 3, 8]
    line [1, 2, 6]
```

## Sankey

Weighted flows.

```mermaid
sankey-beta
Source,Parser,30
Parser,SVG,25
Parser,Error,5
```

## Quadrant

Axes and points.

```mermaid
quadrantChart
    title Renderers
    x-axis Slow --> Fast
    y-axis Limited --> Broad
    quadrant-1 Target
    Native: [0.8, 0.7]
    Browser: [0.2, 0.9]
```

## Journey

Sections, scores and actors.

```mermaid
journey
    title Writing a diagram
    section Author
      Write source: 5: Writer
      Fix syntax: 3: Writer
    section Preview
      Read diagram: 5: Writer, Reader
```
