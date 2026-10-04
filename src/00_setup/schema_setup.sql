-- Create the public_health catalog
CREATE CATALOG IF NOT EXISTS public_health;

-- Create Bronze, Silver, Gold, and Quality  Schemas for public_health
CREATE SCHEMA IF NOT EXISTS public_health.bronze;

CREATE SCHEMA IF NOT EXISTS public_health.silver;

CREATE SCHEMA IF NOT EXISTS public_health.gold;

CREATE SCHEMA IF NOT EXISTS public_health.quality;
