-- 0009: Add 1h cache write pricing column to model_price and token column to request_log

ALTER TABLE model_price
    ADD COLUMN IF NOT EXISTS cache_write_1h_per_1k DOUBLE NULL;

-- Auto-populate for existing Anthropic rows (1h TTL = 1.6 × 5m rate)
UPDATE model_price
SET    cache_write_1h_per_1k = cache_write_per_1k * 1.6
WHERE  provider = 'anthropic'
  AND  cache_write_per_1k IS NOT NULL
  AND  cache_write_1h_per_1k IS NULL;

ALTER TABLE request_log
    ADD COLUMN IF NOT EXISTS cache_creation_1h_tokens BIGINT NOT NULL DEFAULT 0;
