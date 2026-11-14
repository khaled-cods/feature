-- ترقية v6: تسجيل الدخول بكود على الإيميل (من غير باسورد) + حفظ الاسم والموبايل بعد أول دخول.
-- شغّله مرة واحدة: psql -v ON_ERROR_STOP=1 -f upgrade_v6.sql
create or replace function set_my_profile(p_name text, p_phone text) returns void
language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then raise exception 'not signed in'; end if;
 p_name:=btrim(coalesce(p_name,'')); p_phone:=btrim(coalesce(p_phone,''));
 if char_length(p_name)<2 or char_length(p_name)>60 then raise exception 'bad name'; end if;
 if p_phone !~ '^01[0125][0-9]{8}$' then raise exception 'bad phone'; end if;
 update profiles set name=p_name, phone=p_phone where id=auth.uid();
end $$;
revoke all on function set_my_profile(text,text) from public, anon;
grant execute on function set_my_profile(text,text) to authenticated;
