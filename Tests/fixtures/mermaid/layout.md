# Mermaid layout and surrounding Markdown

A **bold** paragraph with $x^2$ before the first diagram.

```mermaid
flowchart TD
    A[MARKATO_MERMAID_START] --> B[MARKATO_MERMAID_END]
```

## Repeated diagrams

The next two images have identical arrow marker names internally. Both must show complete arrowheads.

```mermaid
flowchart LR
    A[Same] --> B[Diagram]
```

```mermaid
flowchart LR
    A[Same] --> B[Diagram]
```

## Wide diagram

Resize the window: the whole image should scale down proportionally without changing its aspect ratio.

```mermaid
flowchart LR
    A[Start] --> B[Decode] --> C[Parse] --> D[Layout] --> E[Render] --> F[Encode] --> G[Measure] --> H[Present] --> I[Finish]
```

## Nested diagram

> A diagram inside a quote:
>
> ```mermaid
> sequenceDiagram
>     Alice->>Bob: Quoted message
>     Bob-->>Alice: Reply
> ```

1. A list item containing a diagram:

   ```mermaid
   graph TD
       List --> Diagram
   ```

## Alternative fences and info strings

~~~mermaid title="Extra info is ignored"
graph LR
    Tilde --> Fence
~~~

## Unicode, escaped labels and multiline text

```mermaid
flowchart TD
    A["Grüße 😀"] --> B["A & B < C"]
    B --> C["Line one<br/>Line two"]
```

## Ordinary code stays code

```swift
let diagram = "graph TD; A --> B"
```

```mermaid-example
graph TD
    A --> B
```

| Feature | Result |
| --- | --- |
| Mermaid | SVG image |
| Math | KaTeX |

$$
a^2 + b^2 = c^2
$$

End of layout fixture. This paragraph must remain visible after diagrams render.
