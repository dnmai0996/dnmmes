-- TEST DATABASE ONLY. Never run in a real Supabase project.
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE SCHEMA auth;
CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
GRANT USAGE ON SCHEMA auth,public TO anon,authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon,authenticated;
