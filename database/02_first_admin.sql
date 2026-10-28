-- 01_schema.sql 실행 → Authentication / Users에서 계정 생성 → 이 파일 실행
-- 아래 작은따옴표 안의 이메일 한 곳만 실제 관리자 이메일로 바꾸세요.
-- 비밀번호/OTP/Secret key를 이 SQL에 입력하지 마세요.
DO $$
DECLARE
  admin_email text := 'dnmai0996@gmail.com';
  admin_id uuid;
BEGIN
  IF admin_email = '관리자이메일입력' THEN RAISE EXCEPTION '관리자 이메일을 먼저 입력하세요.'; END IF;
  SELECT id INTO admin_id FROM auth.users WHERE lower(email)=lower(trim(admin_email));
  IF admin_id IS NULL THEN RAISE EXCEPTION 'Authentication / Users에 이 이메일의 계정을 먼저 생성하세요.'; END IF;
  UPDATE public.dnm_portal_profiles SET role='admin',active=true WHERE id=admin_id;
  IF NOT FOUND THEN RAISE EXCEPTION '01_schema.sql을 먼저 실행하세요.'; END IF;
  RAISE NOTICE '관리자 활성화 완료: %',admin_email;
END;
$$;
