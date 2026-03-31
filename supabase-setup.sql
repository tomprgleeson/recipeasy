-- Recipeasy – Supabase schema setup
-- Safe to run on a fresh project or as a re-run on an existing one.
-- On fresh projects, app_data is created with the correct schema from the start.
-- On existing projects with the old unscoped schema, the migration block below
-- detects the missing household_id column, truncates stale unscoped rows, and
-- applies the structural changes. Subsequent re-runs are fully no-ops.

-- ── 1. Households ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS households (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz DEFAULT now()
);

-- ── 2. Household members ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS household_members (
  user_id      uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  household_id uuid REFERENCES households(id)  ON DELETE CASCADE,
  PRIMARY KEY (user_id, household_id)
);

-- ── 3. app_data ───────────────────────────────────────────────────────────────
-- Fresh install: create the table with the correct schema straight away.
CREATE TABLE IF NOT EXISTS app_data (
  household_id uuid REFERENCES households(id) ON DELETE CASCADE,
  key          text,
  data         jsonb,
  PRIMARY KEY (household_id, key)
);

-- Upgrade path: only runs when household_id column is absent (i.e. the old
-- single-key schema is in place). Truncates unscoped rows, adds the column,
-- resets the primary key, and enforces NOT NULL. Safe to re-run — the whole
-- block is skipped once household_id exists.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'app_data' AND column_name = 'household_id'
  ) THEN
    TRUNCATE app_data;
    ALTER TABLE app_data
      ADD COLUMN household_id uuid REFERENCES households(id) ON DELETE CASCADE;
    ALTER TABLE app_data DROP CONSTRAINT IF EXISTS app_data_pkey;
    ALTER TABLE app_data ADD PRIMARY KEY (household_id, key);
    ALTER TABLE app_data ALTER COLUMN household_id SET NOT NULL;
  END IF;
END $$;

-- ── 4. Row Level Security ─────────────────────────────────────────────────────
ALTER TABLE app_data          ENABLE ROW LEVEL SECURITY;
ALTER TABLE households        ENABLE ROW LEVEL SECURITY;
ALTER TABLE household_members ENABLE ROW LEVEL SECURITY;

-- app_data: full access for household members only
DROP POLICY IF EXISTS "Household members access data" ON app_data;
CREATE POLICY "Household members access data" ON app_data FOR ALL
  USING (
    household_id IN (
      SELECT household_id FROM household_members WHERE user_id = auth.uid()
    )
  )
  WITH CHECK (
    household_id IN (
      SELECT household_id FROM household_members WHERE user_id = auth.uid()
    )
  );

-- household_members: users can read their own membership rows
DROP POLICY IF EXISTS "Users see own memberships" ON household_members;
CREATE POLICY "Users see own memberships" ON household_members FOR SELECT
  USING (user_id = auth.uid());

-- household_members: authenticated users can add themselves to a household
DROP POLICY IF EXISTS "Users can join households" ON household_members;
CREATE POLICY "Users can join households" ON household_members FOR INSERT
  WITH CHECK (user_id = auth.uid());

-- households: members can read their own household
DROP POLICY IF EXISTS "Members see their household" ON households;
CREATE POLICY "Members see their household" ON households FOR SELECT
  USING (
    id IN (
      SELECT household_id FROM household_members WHERE user_id = auth.uid()
    )
  );

-- ── 5. Household creation function ───────────────────────────────────────────
-- Creates a household and immediately adds the calling user as a member in one
-- atomic transaction. Runs as SECURITY DEFINER so it bypasses RLS on the
-- households table — no INSERT policy on households is needed.
CREATE OR REPLACE FUNCTION create_household()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  new_id uuid;
BEGIN
  INSERT INTO households DEFAULT VALUES RETURNING id INTO new_id;
  INSERT INTO household_members (user_id, household_id)
    VALUES (auth.uid(), new_id);
  RETURN new_id;
END;
$$;
