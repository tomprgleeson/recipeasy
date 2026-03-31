-- Recipeasy – Supabase schema setup
-- Run this once in the Supabase SQL Editor for a fresh project.
-- If upgrading from the old single-table (unscoped) schema, run the
-- "Modify app_data" block after the two CREATE TABLE statements.

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

-- ── 3. Modify app_data (skip if setting up from scratch) ─────────────────────
-- WARNING: TRUNCATE drops all existing app_data rows.
-- Export a backup from the app before running this block.
TRUNCATE app_data;
ALTER TABLE app_data
  ADD COLUMN IF NOT EXISTS household_id uuid REFERENCES households(id) ON DELETE CASCADE;
ALTER TABLE app_data DROP CONSTRAINT IF EXISTS app_data_pkey;
ALTER TABLE app_data ADD PRIMARY KEY (household_id, key);
ALTER TABLE app_data ALTER COLUMN household_id SET NOT NULL;

-- ── 4. Row Level Security ─────────────────────────────────────────────────────
ALTER TABLE app_data         ENABLE ROW LEVEL SECURITY;
ALTER TABLE households       ENABLE ROW LEVEL SECURITY;
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

-- households: any authenticated user can create a household
-- Note: auth.uid() IS NOT NULL is the reliable check; avoid auth.role().
DROP POLICY IF EXISTS "Authenticated users can create households" ON households;
CREATE POLICY "Authenticated users can create households" ON households FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);
