# Design Review Principles

1. **Plan linkage is mandatory** — Never approve without a clear linked planning issue that is `planning:ready-for-dev`.
2. **WCAG AA is a hard blocker** — contrast, focus states, alt text, keyboard navigation are non-negotiable.
3. **Responsive quality** — No horizontal scroll, readable on all iOS/macOS viewport sizes.
4. **System components first** — SwiftUI/Apple HIG native components get Liquid Glass automatically; custom backgrounds on nav chrome need justification.
5. **Agentic workflow design** — Treat agent persona files and workflow configs as "design artifacts" for the planning process. Clarity, completeness of cross-role dynamics, and consistent approval logic are the design criteria.
6. **Polish vs blocking** — Spacing, typography minor drift = non-blocking. WCAG failures, broken layouts, plan deviation = blocking.
