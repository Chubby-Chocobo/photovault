# Complete Workflow Examples

End-to-end pipeline examples for asset generation and analysis.

## Example 1: Hero Section (Complete Pipeline)

```bash
# 1. Generate hero image with design context
.claude/skills/.venv/bin/python3 .claude/skills/ai-multimodal/scripts/gemini_batch_process.py \
  --task generate \
  --prompt "Minimalist desert landscape, warm beige sand dunes,
  soft morning light, serene and spacious, muted earth tones
  (tan, cream, soft ochre), clean composition for text overlay,
  sophisticated travel aesthetic, 16:9 cinematic" \
  --output assets/hero-desert \
  --model imagen-4.0-generate-001 \
  --aspect-ratio 16:9

# 2. Evaluate aesthetic quality
.claude/skills/.venv/bin/python3 .claude/skills/ai-multimodal/scripts/gemini_batch_process.py \
  --files assets/hero-desert.png \
  --task analyze \
  --prompt "Rate this image 1-10 for: visual appeal, color harmony,
  suitability for overlaying white text, professional quality.
  List any improvements needed." \
  --output assets/hero-evaluation.md \
  --model gemini-2.5-flash

# 3. If score ≥ 7/10, optimize for web
.claude/skills/.venv/bin/python3 .claude/skills/ai-multimodal/scripts/media_optimizer.py \
  --input assets/hero-desert.png \
  --output assets/hero-desktop.webp \
  --quality 85

# 4. Generate mobile variant (9:16)
.claude/skills/.venv/bin/python3 .claude/skills/ai-multimodal/scripts/gemini_batch_process.py \
  --task generate \
  --prompt "Minimalist desert landscape, warm beige sand dunes,
  soft morning light, serene and spacious, muted earth tones
  (tan, cream, soft ochre), clean composition for text overlay,
  sophisticated travel aesthetic, 9:16 portrait" \
  --output assets/hero-mobile \
  --model imagen-4.0-generate-001 \
  --aspect-ratio 9:16

# 5. Optimize mobile variant
.claude/skills/.venv/bin/python3 .claude/skills/ai-multimodal/scripts/media_optimizer.py \
  --input assets/hero-mobile.png \
  --output assets/hero-mobile.webp \
  --quality 85
```

## Example 2: Extract, Generate, Analyze Loop

```bash
# 1. Extract design guidelines from inspiration
.claude/skills/.venv/bin/python3 .claude/skills/ai-multimodal/scripts/gemini_batch_process.py \
  --files docs/inspiration/competitor-hero.png \
  --task analyze \
  --prompt "[use extraction prompt from extraction-prompts.md]" \
  --output docs/design/design-system/competitor-analysis.md \
  --model gemini-2.5-flash

# 2. Generate asset based on extracted guidelines
# (Review competitor-analysis.md for color palette, aesthetic)
.claude/skills/.venv/bin/python3 .claude/skills/ai-multimodal/scripts/gemini_batch_process.py \
  --task generate \
  --prompt "[craft prompt using extracted aesthetic and colors]" \
  --output assets/our-hero \
  --model imagen-4.0-generate-001 \
  --aspect-ratio 16:9

# 3. Analyze our generated asset
.claude/skills/.venv/bin/python3 .claude/skills/ai-multimodal/scripts/gemini_batch_process.py \
  --files assets/our-hero.png \
  --task analyze \
  --prompt "Compare to competitor design. Rate differentiation (1-10).
  Are we too similar or successfully distinct?" \
  --output assets/differentiation-analysis.md \
  --model gemini-2.5-flash

# 4. Extract colors from our final asset for CSS
.claude/skills/.venv/bin/python3 .claude/skills/ai-multimodal/scripts/gemini_batch_process.py \
  --files assets/our-hero.png \
  --task analyze \
  --prompt "[use color extraction prompt from visual-analysis-overview.md]" \
  --output assets/color-palette.md \
  --model gemini-2.5-flash
```

## Example 3: A/B Test Assets

```bash
# Generate 2 design directions
.claude/skills/.venv/bin/python3 .claude/skills/ai-multimodal/scripts/gemini_batch_process.py \
  --task generate \
  --prompt "Minimalist approach: [prompt]" \
  --output assets/variant-a \
  --model imagen-4.0-fast-generate-001 \
  --aspect-ratio 16:9

.claude/skills/.venv/bin/python3 .claude/skills/ai-multimodal/scripts/gemini_batch_process.py \
  --task generate \
  --prompt "Bold approach: [prompt]" \
  --output assets/variant-b \
  --model imagen-4.0-fast-generate-001 \
  --aspect-ratio 16:9

# Compare variants
.claude/skills/.venv/bin/python3 .claude/skills/ai-multimodal/scripts/gemini_batch_process.py \
  --files assets/variant-a.png assets/variant-b.png \
  --task analyze \
  --prompt "A/B comparison for [target audience]:
  1. Attention capture
  2. Brand alignment
  3. Conversion potential
  Recommend which to test." \
  --output assets/ab-comparison.md \
  --model gemini-2.5-flash

# Generate production version of winner
.claude/skills/.venv/bin/python3 .claude/skills/ai-multimodal/scripts/gemini_batch_process.py \
  --task generate \
  --prompt "[winning approach prompt]" \
  --output assets/final-hero \
  --model imagen-4.0-generate-001 \
  --aspect-ratio 16:9
```

## Batch Analysis for Rapid Iteration

```bash
# Generate 3 variations with fast model
for i in {1..3}; do
  .claude/skills/.venv/bin/python3 .claude/skills/ai-multimodal/scripts/gemini_batch_process.py \
    --task generate \
    --prompt "[prompt with variation-$i twist]" \
    --output assets/var-$i \
    --model imagen-4.0-fast-generate-001 \
    --aspect-ratio 16:9
done

# Batch analyze all variations
.claude/skills/.venv/bin/python3 .claude/skills/ai-multimodal/scripts/gemini_batch_process.py \
  --files assets/var-*.png \
  --task analyze \
  --prompt "Rank these variations 1-3 with scores. Identify winner." \
  --output assets/batch-analysis.md \
  --model gemini-2.5-flash
```
