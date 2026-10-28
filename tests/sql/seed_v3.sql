-- Disposable CI users, not real credentials.
INSERT INTO auth.users(id,email) VALUES
('11111111-1111-4111-8111-111111111111','admin@example.invalid'),
('22222222-2222-4222-8222-222222222222','approver@example.invalid'),
('33333333-3333-4333-8333-333333333333','worker@example.invalid'),
('44444444-4444-4444-8444-444444444444','viewer@example.invalid');
UPDATE public.dnm_portal_profiles SET active=true,display_name=split_part(email,'@',1),role=CASE WHEN email LIKE 'viewer%' THEN 'viewer' WHEN email LIKE 'worker%' THEN 'member' ELSE 'admin' END;
INSERT INTO public.dnm_portal_products(code,name) VALUES('LEGACY-V3','이전 버전 보존 시험품');
INSERT INTO public.dnm_portal_notes(title,body,owner_id) VALUES('v3 보존','기존 메모 유지','11111111-1111-4111-8111-111111111111');
