# Compositor Domain Context

## Glossary

- **Smart Object Source**: The embedded original pixels shared by one or more Smart Object instances. Replacing the source updates every linked instance.
- **Smart Object Instance**: A layer that references a Smart Object Source while keeping its own placement, frame, and optional warp.
- **Frame**: The instance's retained placement boundary. It remains stable when the Smart Object Source is replaced and may be represented by either a rectangle or a four-corner quadrilateral.
- **Content Fit**: The uniform, centered scaling of a Smart Object Source inside its Frame. The source is contained without changing its aspect ratio; any unused frame area stays transparent.
