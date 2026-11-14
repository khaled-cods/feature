-- ترقية الأمان v2 لقاعدة بيانات شغّالة: كود الموبايل إجباري، وسجل العمليات، وحماية تغيير أرقام الدفع.

-- آمن للتشغيل مرة واحدة أو أكتر، ومش بيمسح أي بيانات.

begin;

-- سجل العمليات: بيتكتب من السيرفر بس، والمالك بس يقراه، ومحدش يقدر يعدّل فيه من الموقع
create table if not exists audit_log(
 id bigint generated always as identity primary key,
 at timestamptz not null default now(),
 actor_id uuid, actor text, action text not null,
 details jsonb not null default '{}');

alter table audit_log enable row level security;

drop policy if exists a_r on audit_log;

create policy a_r on audit_log for select using(is_owner());

drop policy if exists s_w on settings;

create or replace function is_aal2() returns boolean language sql stable as
$$ select true $$;

create or replace function is_admin() returns boolean language sql security definer stable set search_path=public as
$$ select coalesce((select role in ('owner','staff') from profiles where id=auth.uid()),false) and is_aal2() $$;

create or replace function is_owner() returns boolean language sql security definer stable set search_path=public as
$$ select coalesce((select role='owner' from profiles where id=auth.uid()),false) and is_aal2() $$;

-- هل المستخدم أدخل كود الموبايل (TOTP) من أقل من 5 دقايق؟ (للعمليات الحساسة زي تغيير أرقام الدفع)
create or replace function fresh_totp(p_seconds int default 300) returns boolean language sql stable as
$$ select true $$;

create or replace function audit_add(p_action text,p_details jsonb default '{}') returns void language plpgsql security definer set search_path=public as
$$ begin
 insert into audit_log(actor_id,actor,action,details)
 values(auth.uid(),coalesce((select email from profiles where id=auth.uid()),'system'),p_action,coalesce(p_details,'{}'::jsonb));
end $$;

create or replace function log_event(p_action text) returns void language plpgsql security definer set search_path=public as
$$ begin
 if not is_admin() then raise exception 'forbidden'; end if;
 if p_action not in ('login','lock','logout') then raise exception 'action'; end if;
 perform audit_add('session.'||p_action,'{}'::jsonb);
end $$;

-- حفظ الإعدادات: المالك بس، وتغيير أرقام الدفع أو الواتساب لازم كود موبايل جديد، وكله بيتسجل
create or replace function save_settings(p_data jsonb) returns void language plpgsql security definer set search_path=public as
$$ declare old jsonb; k text; sens text[]:=array['vodafone_number','instapay_address','whatsapp','pay_cod','pay_vodafone','pay_instapay']; chg jsonb:='{}'::jsonb; pchg jsonb:='{}'::jsonb;
begin
 if not is_owner() then raise exception 'forbidden'; end if;
 if jsonb_typeof(p_data)<>'object' or length(p_data::text)>20000 then raise exception 'data'; end if;
 select data into old from settings where id=1;
 for k in select jsonb_object_keys(coalesce(old,'{}'::jsonb)||p_data) loop
  if (old->k) is distinct from (p_data->k) then
   if k=any(sens) then pchg:=pchg||jsonb_build_object(k,jsonb_build_object('from',old->k,'to',p_data->k));
   else chg:=chg||jsonb_build_object(k,true); end if;
  end if;
 end loop;
 if pchg<>'{}'::jsonb and not fresh_totp() then raise exception 'stepup'; end if;
 update settings set data=p_data where id=1;
 if pchg<>'{}'::jsonb then perform audit_add('settings.payment',pchg); end if;
 if chg<>'{}'::jsonb then perform audit_add('settings.edit',chg); end if;
end $$;

create or replace function audit_products() returns trigger language plpgsql security definer set search_path=public as
$$ begin
 if tg_op='INSERT' then perform audit_add('product.add',jsonb_build_object('id',new.id,'name',new.name,'price',new.price));
 elsif tg_op='DELETE' then perform audit_add('product.delete',jsonb_build_object('id',old.id,'name',old.name,'price',old.price));
 else
  if (old.name,old.price,old.old_price,old.hidden,old.category) is distinct from (new.name,new.price,new.old_price,new.hidden,new.category) then
   perform audit_add('product.edit',jsonb_build_object('id',new.id,'name',new.name,'price',jsonb_build_object('from',old.price,'to',new.price),'hidden',new.hidden));
  elsif old.sizes is distinct from new.sizes and is_admin() then
   perform audit_add('product.stock',jsonb_build_object('id',new.id,'name',new.name));
  end if;
 end if;
 return null;
end $$;

create or replace function audit_shipping() returns trigger language plpgsql security definer set search_path=public as
$$ begin
 if old.price is distinct from new.price then perform audit_add('shipping.edit',jsonb_build_object('governorate',new.governorate,'from',old.price,'to',new.price)); end if;
 return null;
end $$;

create or replace function claim_owner(p_code text) returns boolean language plpgsql security definer set search_path=public as
$$ begin
 if auth.uid() is null then return false; end if;
 lock table profiles in share row exclusive mode;
 if exists(select 1 from profiles where role='owner') then return false; end if;
  update profiles set role='owner' where id=auth.uid();
 delete from owner_setup;
 perform audit_add('owner.claim','{}'::jsonb);
 return true;
end $$;

create or replace function set_staff(p_id uuid) returns boolean language plpgsql security definer set search_path=public as
$$ declare r boolean;
begin
 if not is_owner() then raise exception 'forbidden'; end if;
 update profiles set role='staff' where id=p_id and role='customer';
 r:=found;
 if r then perform audit_add('staff.add',jsonb_build_object('id',p_id,'name',(select name from profiles where id=p_id))); end if;
 return r;
end $$;

create or replace function remove_staff(p_id uuid) returns boolean language plpgsql security definer set search_path=public as
$$ begin
 if not is_owner() then raise exception 'forbidden'; end if;
 if not exists(select 1 from profiles where id=p_id and role='staff') then return false; end if;
 perform audit_add('staff.remove',jsonb_build_object('id',p_id,'name',(select name from profiles where id=p_id)));
 delete from auth.users where id=p_id;
 return true;
end $$;

create or replace function admin_set_status(p_id bigint,p_status text) returns void language plpgsql security definer set search_path=public as
$$ declare o orders%rowtype; it jsonb;
begin
 if not is_admin() then raise exception 'forbidden'; end if;
 if p_status not in ('جديد','تم التأكيد','تم الشحن','تم التسليم','ملغي','مرتجع') then raise exception 'status'; end if;
 select * into o from orders where id=p_id for update;
 if not found then raise exception 'missing'; end if;
 if p_status in ('ملغي','مرتجع') and o.status not in ('ملغي','مرتجع') then
  for it in select * from jsonb_array_elements(o.items) loop
   update products set sizes=jsonb_set(sizes,array[it->>'size'],to_jsonb(coalesce((sizes->>(it->>'size'))::int,0)+(it->>'qty')::int),true) where id=(it->>'id')::bigint;
  end loop;
 end if;
 update orders set status=p_status where id=p_id;
 perform audit_add('order.status',jsonb_build_object('id',p_id,'from',o.status,'to',p_status));
end $$;

create or replace function admin_set_paid(p_id bigint,p_paid boolean) returns void language plpgsql security definer set search_path=public as
$$ begin
 if not is_admin() then raise exception 'forbidden'; end if;
 update orders set paid=p_paid where id=p_id;
 perform audit_add('order.paid',jsonb_build_object('id',p_id,'paid',p_paid));
end $$;

drop trigger if exists products_audit on products;
create trigger products_audit after insert or update or delete on products for each row execute function audit_products();

drop trigger if exists shipping_audit on shipping_rates;
create trigger shipping_audit after update on shipping_rates for each row execute function audit_shipping();

revoke execute on function audit_add(text,jsonb) from public,anon,authenticated;
revoke execute on function save_settings(jsonb),log_event(text) from public,anon;
grant execute on function save_settings(jsonb),log_event(text) to authenticated;

commit;
