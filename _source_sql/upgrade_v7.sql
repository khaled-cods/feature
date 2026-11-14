-- ترقية v7: إصلاحات من فحص المشروع. شغّله مرة واحدة في SQL Editor (بعد ما تراجعه).
-- 1) أي زبون مسجّل كان يقدر يشغّل tg_send ويبعت رسالة لتليجرام المالك. دلوقتي محدش يقدر غير الدوال الداخلية.
revoke execute on function tg_send(text) from public, anon, authenticated;
revoke execute on function notify_order() from public, anon, authenticated;

-- 2) لما الطلب يرجع من "ملغي/مرتجع" لأي حالة نشطة، المخزون لازم يتخصم تاني (كان بيزيد بالغلط).
create or replace function admin_set_status(p_id bigint,p_status text) returns void language plpgsql security definer set search_path=public as
$$ declare o orders%rowtype; it jsonb; cur int;
begin
 if not is_admin() then raise exception 'forbidden'; end if;
 if p_status not in ('جديد','تم التأكيد','تم الشحن','تم التسليم','ملغي','مرتجع') then raise exception 'status'; end if;
 select * into o from orders where id=p_id for update;
 if not found then raise exception 'missing'; end if;
 if p_status in ('ملغي','مرتجع') and o.status not in ('ملغي','مرتجع') then
  for it in select * from jsonb_array_elements(o.items) loop
   update products set sizes=jsonb_set(sizes,array[it->>'size'],to_jsonb(coalesce((sizes->>(it->>'size'))::int,0)+(it->>'qty')::int),true) where id=(it->>'id')::bigint;
  end loop;
 elsif p_status not in ('ملغي','مرتجع') and o.status in ('ملغي','مرتجع') then
  for it in select * from jsonb_array_elements(o.items) loop
   select coalesce((sizes->>(it->>'size'))::int,0) into cur from products where id=(it->>'id')::bigint for update;
   if cur < (it->>'qty')::int then raise exception 'stock: %',coalesce(it->>'name',it->>'id'); end if;
   update products set sizes=jsonb_set(sizes,array[it->>'size'],to_jsonb(cur-(it->>'qty')::int),true) where id=(it->>'id')::bigint;
  end loop;
 end if;
 update orders set status=p_status where id=p_id;
 perform audit_add('order.status',jsonb_build_object('id',p_id,'from',o.status,'to',p_status));
end $$;

-- 3) change_my_password: حد للمحاولات (كان ممكن موظف يجرّب باسوردات لحد ما يطلع "dup" ويعرف باسورد المالك).
create or replace function change_my_password(p_password text) returns boolean language plpgsql security definer set search_path=public,extensions as
$$ declare n int;
begin
 if not is_admin() then raise exception 'forbidden'; end if;
 if length(coalesce(p_password,''))<8 then raise exception 'short'; end if;
 select count(*) into n from login_attempts where at>now()-interval '1 minute';
 if n>=20 then raise exception 'rate'; end if;
 if exists(select 1 from auth.users u join profiles p on p.id=u.id where p.role in ('owner','staff') and u.id<>auth.uid() and u.encrypted_password=crypt(p_password,u.encrypted_password)) then
  insert into login_attempts default values;
  return false; -- ماينفعش raise هنا: الاستثناء كان هيلغي تسجيل المحاولة
 end if;
 update auth.users set encrypted_password=crypt(p_password,gen_salt('bf')),updated_at=now() where id=auth.uid();
 perform audit_add('password.change','{}'::jsonb);
 return true;
end $$;

-- 4) فحص: لازم النتيجة تكون فاضية من دوال داخلية (tg_send / audit_add). الدوال العامة زي place_order و track_order عادي تظهر.
select p.proname as "دالة متاحة للزبون المسجل"
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and has_function_privilege('authenticated',p.oid,'execute')
  and p.proname in ('tg_send','audit_add','notify_order');
