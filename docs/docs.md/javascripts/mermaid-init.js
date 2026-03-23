/**
 * mermaid-init.js — configure Mermaid before Material for MkDocs initialises it.
 *
 * Material for MkDocs merges window.mermaidConfig into the mermaid.initialize()
 * call.  Setting wrappingWidth here tells Mermaid's layout engine to pre-wrap
 * node labels at 150 px, so it allocates correctly-sized node boxes instead of
 * producing boxes that are too narrow for the rendered text.
 */
window.mermaidConfig = {
  flowchart: { wrappingWidth: 150 },
  sequence:  {}
};
