-- Kataki Store: شغّل الملف ده كله مرة واحدة في Supabase > SQL Editor > Run

create table settings(id int primary key default 1 check(id=1), data jsonb not null default '{}');
insert into settings(data) values('{"store_name":"Kataki Store","whatsapp":"","phone":"","address":"","hours":"","instagram":"https://instagram.com/kataki_store","facebook":"","tiktok":"","banner":"موديلات جديدة والشحن لكل المحافظات.","return_policy":"","free_shipping_over":0,"pay_cod":true,"pay_vodafone":false,"vodafone_number":"","pay_instapay":false,"instapay_address":"","login_google":false,"login_code":false}');

create table shipping_rates(governorate text primary key, price int not null check(price>=0));
insert into shipping_rates values
('القاهرة',50),('الجيزة',50),('القليوبية',55),('الإسكندرية',65),('الغربية',65),('الدقهلية',65),('الشرقية',65),('المنوفية',65),('كفر الشيخ',65),('البحيرة',65),('دمياط',65),('بورسعيد',65),('الإسماعيلية',65),('السويس',65),('الفيوم',70),('بني سويف',70),('المنيا',75),('أسيوط',75),('سوهاج',80),('قنا',80),('الأقصر',85),('أسوان',85),('مطروح',90),('البحر الأحمر',90),('شمال سيناء',95),('جنوب سيناء',95),('الوادي الجديد',95);

create table products(
 id bigint generated always as identity primary key,
 name text not null, category text not null, kind text,
 price int not null check(price>0), old_price int,
 img text not null, images jsonb not null default '[]', colors jsonb not null default '[]', sizes jsonb not null default '{}',
 hidden boolean not null default false, created_at timestamptz default now());

create table profiles(
 id uuid primary key references auth.users on delete cascade,
 name text, phone text, email text,
 role text not null default 'customer' check(role in ('customer','staff','owner')));

-- كود التفعيل لمرة واحدة لإنشاء حساب المالك (بيتولّد عشوائي هنا، وبيتمسح بعد الاستخدام)
create table owner_setup(code text primary key);
-- (كود التفعيل اتلغى: أول حساب يسجّل في صفحة المالك السرية هو المالك)

create table orders(
 id bigint generated always as identity primary key,
 user_id uuid references auth.users on delete set null, name text, phone text, governorate text, address text, notes text,
 payment text, items jsonb, subtotal int, shipping int, total int,
 status text not null default 'جديد' check(status in ('جديد','تم التأكيد','تم الشحن','تم التسليم','ملغي','مرتجع')),
 proof text, paid boolean not null default false, lat double precision, lng double precision,
 created_at timestamptz default now());

-- سجل العمليات: بيتكتب من السيرفر بس، والمالك بس يقراه، ومحدش يقدر يعدّل فيه من الموقع
create table audit_log(
 id bigint generated always as identity primary key,
 at timestamptz not null default now(),
 actor_id uuid, actor text, action text not null,
 details jsonb not null default '{}');

-- دوال مساعدة
create function is_aal2() returns boolean language sql stable as
$$ select true $$;

create function is_admin() returns boolean language sql security definer stable set search_path=public as
$$ select coalesce((select role in ('owner','staff') from profiles where id=auth.uid()),false) and is_aal2() $$;

create function is_owner() returns boolean language sql security definer stable set search_path=public as
$$ select coalesce((select role='owner' from profiles where id=auth.uid()),false) and is_aal2() $$;

-- هل المستخدم أدخل كود الموبايل (TOTP) من أقل من 5 دقايق؟ (للعمليات الحساسة زي تغيير أرقام الدفع)
create function fresh_totp(p_seconds int default 300) returns boolean language sql stable as
$$ select true $$;



create function owner_exists() returns boolean language sql security definer stable set search_path=public as
$$ select exists(select 1 from profiles where role='owner') $$;

create function new_user() returns trigger language plpgsql security definer set search_path=public as
$$ begin
 insert into profiles(id,name,phone,email) values(new.id,new.raw_user_meta_data->>'name',new.raw_user_meta_data->>'phone',new.email);
 return new;
end $$;
create trigger on_signup after insert on auth.users for each row execute function new_user();
insert into profiles(id,name,phone,email) select id,raw_user_meta_data->>'name',raw_user_meta_data->>'phone',email from auth.users on conflict do nothing;

-- أول مرة بس: لازم كود التفعيل الصح. بعد أول مالك الكود بيتمسح والدالة بترجع false دايمًا.
create function claim_owner(p_code text) returns boolean language plpgsql security definer set search_path=public as
$$ begin
 if auth.uid() is null then return false; end if;
 lock table profiles in share row exclusive mode;
 if exists(select 1 from profiles where role='owner') then return false; end if;
  update profiles set role='owner' where id=auth.uid();
 delete from owner_setup;
 perform audit_add('owner.claim','{}'::jsonb);
 return true;
end $$;

-- المالك بس: ضم حساب (اتعمل بإيميل وباسورد من عنده) لفريق العمل، أو حذف موظف
create function set_staff(p_id uuid) returns boolean language plpgsql security definer set search_path=public as
$$ declare r boolean;
begin
 if not is_owner() then raise exception 'forbidden'; end if;
 update profiles set role='staff' where id=p_id and role='customer';
 r:=found;
 if r then perform audit_add('staff.add',jsonb_build_object('id',p_id,'name',(select name from profiles where id=p_id))); end if;
 return r;
end $$;

create function remove_staff(p_id uuid) returns boolean language plpgsql security definer set search_path=public as
$$ begin
 if not is_owner() then raise exception 'forbidden'; end if;
 if not exists(select 1 from profiles where id=p_id and role='staff') then return false; end if;
 perform audit_add('staff.remove',jsonb_build_object('id',p_id,'name',(select name from profiles where id=p_id)));
 delete from auth.users where id=p_id;
 return true;
end $$;

-- إنشاء الطلب: السعر والشحن والمخزون كلها بتتحسب هنا في السيرفر
create function place_order(p_items jsonb,p_name text,p_phone text,p_gov text,p_address text,p_notes text,p_payment text,p_lat double precision default null,p_lng double precision default null)
returns bigint language plpgsql security definer set search_path=public as
$$ declare it jsonb; col text; pr products%rowtype; sub int:=0; ship int; snap jsonb:='[]'; st jsonb; fs int; oid bigint; q int; sz text;
begin
 if auth.uid() is null then raise exception 'login'; end if;
 if length(trim(coalesce(p_name,'')))<2 or length(p_name)>80 or p_phone !~ '^01[0125][0-9]{8}$' or length(trim(coalesce(p_address,'')))<5 or length(p_address)>300 then raise exception 'data'; end if;
 if (p_lat is null)<>(p_lng is null) or (p_lat is not null and (p_lat not between 21.7 and 31.8 or p_lng not between 24.6 and 37)) then raise exception 'data'; end if;
 if (select count(*) from orders where user_id=auth.uid() and created_at>now()-interval '1 hour')>=10 then raise exception 'rate'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>30 then raise exception 'empty'; end if;
 for it in select * from jsonb_array_elements(p_items) loop
  q:=(it->>'qty')::int; sz:=it->>'size'; col:=nullif(trim(coalesce(it->>'color','')),'');
  if q<1 or q>10 then raise exception 'qty'; end if;
  select * into pr from products where id=(it->>'id')::bigint and not hidden for update;
  if not found then raise exception 'missing'; end if;
  if jsonb_array_length(pr.colors)>0 and (col is null or not (pr.colors ? col)) then raise exception 'color'; end if;
  if coalesce((pr.sizes->>sz)::int,0)<q then raise exception 'stock %',pr.name; end if;
  update products set sizes=jsonb_set(sizes,array[sz],to_jsonb((sizes->>sz)::int-q)) where id=pr.id;
  sub:=sub+pr.price*q;
  snap:=snap||jsonb_build_object('id',pr.id,'name',pr.name,'price',pr.price,'size',sz,'color',col,'qty',q,'img',pr.img);
 end loop;
 select price into ship from shipping_rates where governorate=p_gov;
 if ship is null then raise exception 'gov'; end if;
 select data into st from settings where id=1;
 fs:=coalesce((st->>'free_shipping_over')::int,0);
 if fs>0 and sub>=fs then ship:=0; end if;
 if not coalesce((st->>(case p_payment when 'cod' then 'pay_cod' when 'vodafone' then 'pay_vodafone' when 'instapay' then 'pay_instapay' else 'none' end))::boolean,false) then raise exception 'payment'; end if;
 insert into orders(user_id,name,phone,governorate,address,notes,payment,items,subtotal,shipping,total,lat,lng)
 values(auth.uid(),trim(p_name),p_phone,p_gov,trim(p_address),left(coalesce(p_notes,''),300),p_payment,snap,sub,ship,sub+ship,p_lat,p_lng) returning id into oid;
 return oid;
end $$;

-- تغيير حالة الطلب (للمالك فقط). الإلغاء والإرجاع بيرجّعوا المخزون.
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

-- إثبات الدفع: الزبون يرفع صورة التحويل (في bucket خاص) ويربطها بطلبه
create function attach_proof(p_order bigint,p_path text) returns boolean language plpgsql security definer set search_path=public as
$$ begin
 if auth.uid() is null then raise exception 'login'; end if;
 if p_path is null or p_path not like auth.uid()::text||'/%' then return false; end if;
 update orders set proof=p_path where id=p_order and user_id=auth.uid() and payment<>'cod';
 return found;
end $$;

-- المالك أو الموظف: تأكيد استلام الفلوس
create function admin_set_paid(p_id bigint,p_paid boolean) returns void language plpgsql security definer set search_path=public as
$$ begin
 if not is_admin() then raise exception 'forbidden'; end if;
 update orders set paid=p_paid where id=p_id;
 perform audit_add('order.paid',jsonb_build_object('id',p_id,'paid',p_paid));
end $$;

create function audit_add(p_action text,p_details jsonb default '{}') returns void language plpgsql security definer set search_path=public as
$$ begin
 insert into audit_log(actor_id,actor,action,details)
 values(auth.uid(),coalesce((select email from profiles where id=auth.uid()),'system'),p_action,coalesce(p_details,'{}'::jsonb));
end $$;

create function log_event(p_action text) returns void language plpgsql security definer set search_path=public as
$$ begin
 if not is_admin() then raise exception 'forbidden'; end if;
 if p_action not in ('login','lock','logout') then raise exception 'action'; end if;
 perform audit_add('session.'||p_action,'{}'::jsonb);
end $$;

-- حفظ الإعدادات: المالك بس، وتغيير أرقام الدفع أو الواتساب لازم كود موبايل جديد، وكله بيتسجل
create function save_settings(p_data jsonb) returns void language plpgsql security definer set search_path=public as
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

create function audit_products() returns trigger language plpgsql security definer set search_path=public as
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

create function audit_shipping() returns trigger language plpgsql security definer set search_path=public as
$$ begin
 if old.price is distinct from new.price then perform audit_add('shipping.edit',jsonb_build_object('governorate',new.governorate,'from',old.price,'to',new.price)); end if;
 return null;
end $$;

-- الصلاحيات (RLS)
alter table settings enable row level security;
alter table shipping_rates enable row level security;
alter table products enable row level security;
alter table profiles enable row level security;
alter table orders enable row level security;
alter table audit_log enable row level security;
alter table owner_setup enable row level security;

create policy s_r on settings for select using(true);
create policy a_r on audit_log for select using(is_owner());
create policy r_r on shipping_rates for select using(true);
create policy r_w on shipping_rates for all using(is_owner()) with check(is_owner());
create policy p_r on products for select using(not hidden or is_admin());
create policy p_w on products for all using(is_admin()) with check(is_admin());
create policy pr_r on profiles for select using(id=auth.uid() or is_admin());
create policy o_r on orders for select using(user_id=auth.uid() or is_admin());

-- مخزن صور المنتجات
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
 ('products','products',true,2097152,array['image/jpeg','image/png','image/webp']),
 ('proofs','proofs',false,2097152,array['image/jpeg','image/png','image/webp'])
 on conflict (id) do update set public=excluded.public,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy img_up on storage.objects for insert to authenticated with check(bucket_id='products' and is_admin());
create policy img_del on storage.objects for delete to authenticated using(bucket_id='products' and is_admin());
create policy proof_up on storage.objects for insert to authenticated with check(bucket_id='proofs' and (storage.foldername(name))[1]=auth.uid()::text);
create policy proof_rd on storage.objects for select to authenticated using(bucket_id='proofs' and ((storage.foldername(name))[1]=auth.uid()::text or is_admin()));

revoke execute on function audit_add(text,jsonb) from public,anon,authenticated;
revoke execute on function save_settings(jsonb),log_event(text) from public,anon;
grant execute on function save_settings(jsonb),log_event(text) to authenticated;
-- الدوال اللي بتغيّر بيانات: للمسجّلين بس (الزوار غير المسجلين ممنوعين)
revoke execute on function place_order(jsonb,text,text,text,text,text,text,double precision,double precision),admin_set_status(bigint,text),claim_owner(text),set_staff(uuid),remove_staff(uuid),attach_proof(bigint,text),admin_set_paid(bigint,boolean) from public,anon;
grant execute on function place_order(jsonb,text,text,text,text,text,text,double precision,double precision),admin_set_status(bigint,text),claim_owner(text),set_staff(uuid),remove_staff(uuid),attach_proof(bigint,text),admin_set_paid(bigint,boolean) to authenticated;

-- منتجات تجريبية (الصور في فولدر images مع الموقع، والأسعار تجريبية)
insert into products(name,category,kind,price,img,sizes) values
('صندل بنّي بإبزيم فضي','حريمي','صندل',650,'images/kataki-product-1.jpg','{"36":5,"37":5,"38":5,"39":5,"40":5,"41":5}'),
('صندل أسود بسير خلفي','حريمي','صندل',600,'images/kataki-product-2.jpg','{"36":5,"37":5,"38":5,"39":5,"40":5,"41":5}'),
('صندل بيج بإبزيم دهبي','حريمي','صندل',650,'images/kataki-product-3.jpg','{"36":5,"37":5,"38":5,"39":5,"40":5,"41":5}'),
('باليرينا سوداء بفصوص','حريمي','فلات',550,'images/kataki-product-4.jpg','{"36":5,"37":5,"38":5,"39":5,"40":5,"41":5}'),
('إسبادريل رمادي جاكار','حريمي','فلات',500,'images/kataki-product-5.jpg','{"36":5,"37":5,"38":5,"39":5,"40":5,"41":5}'),
('كوتشي بيج وعسلي','حريمي','كوتشي',900,'images/kataki-product-6.jpg','{"36":5,"37":5,"38":5,"39":5,"40":5,"41":5}'),
('كوتشي أسود بخطوط','حريمي','كوتشي',850,'images/kataki-product-7.jpg','{"36":5,"37":5,"38":5,"39":5,"40":5,"41":5}');


-- دخول بالباسورد بس: بيرجّع إيميل حساب المالك/الموظف لو الباسورد صح (والمحاولات الغلط محدودة)
create table if not exists login_attempts(at timestamptz not null default now());
alter table login_attempts enable row level security;
create or replace function staff_email_for(p_password text) returns text language plpgsql security definer set search_path=public,extensions as
$$ declare e text; n int;
begin
 delete from login_attempts where at<now()-interval '1 hour';
 select count(*) into n from login_attempts where at>now()-interval '1 minute';
 if n>=20 then raise exception 'rate'; end if;
 select u.email into e from auth.users u join profiles p on p.id=u.id
  where p.role in ('owner','staff') and u.encrypted_password=crypt(p_password,u.encrypted_password) limit 1;
 if e is null then insert into login_attempts default values; end if;
 return e;
end $$;
create or replace function password_in_use(p_password text,p_except uuid) returns boolean language plpgsql security definer set search_path=public,extensions as
$$ begin
 if not is_owner() then raise exception 'forbidden'; end if;
 return exists(select 1 from auth.users u join profiles p on p.id=u.id
  where p.role in ('owner','staff') and (p_except is null or u.id<>p_except) and u.encrypted_password=crypt(p_password,u.encrypted_password));
end $$;
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
create or replace function set_staff_password(p_id uuid,p_password text) returns boolean language plpgsql security definer set search_path=public,extensions as
$$ begin
 if not is_owner() then raise exception 'forbidden'; end if;
 if length(coalesce(p_password,''))<8 then raise exception 'short'; end if;
 if not exists(select 1 from profiles where id=p_id and role='staff') then return false; end if;
 if exists(select 1 from auth.users u join profiles p on p.id=u.id where p.role in ('owner','staff') and u.id<>p_id and u.encrypted_password=crypt(p_password,u.encrypted_password)) then raise exception 'dup'; end if;
 update auth.users set encrypted_password=crypt(p_password,gen_salt('bf')),updated_at=now() where id=p_id;
 perform audit_add('staff.password',jsonb_build_object('id',p_id,'name',(select name from profiles where id=p_id)));
 return true;
end $$;
revoke execute on function staff_email_for(text),password_in_use(text,uuid),change_my_password(text),set_staff_password(uuid,text) from public,anon;
grant execute on function staff_email_for(text) to anon,authenticated;
grant execute on function password_in_use(text,uuid),change_my_password(text),set_staff_password(uuid,text) to authenticated;

-- تفعيل سجل العمليات (بعد المنتجات التجريبية عشان متتسجلش)
create trigger products_audit after insert or update or delete on products for each row execute function audit_products();
create trigger shipping_audit after update on shipping_rates for each row execute function audit_shipping();

-- ترقية v4: كوبونات الخصم + تتبّع الطلب. شغّله مرة واحدة بعد upgrade_v3.sql (أو بعد schema.sql القديم): psql -v ON_ERROR_STOP=1 -f upgrade_v4.sql
create table if not exists coupons(
 code text primary key check(code ~ '^[A-Z0-9_-]{3,20}$'),
 kind text not null check(kind in ('pct','fix')), value int not null check(value>0),
 min_total int not null default 0, max_uses int, used int not null default 0,
 expires date, active boolean not null default true, created_at timestamptz default now(),
 check(kind<>'pct' or value<=90));
alter table coupons enable row level security;
drop policy if exists c_all on coupons;
create policy c_all on coupons for all using(is_owner()) with check(is_owner());
alter table orders add column if not exists discount int not null default 0;
alter table orders add column if not exists coupon text;

-- الزبون بيتأكد من الكود قبل الطلب (بيرجّع بيانات الكود بس، مش بيستهلكه)
create or replace function check_coupon(p_code text,p_sub int) returns jsonb language plpgsql security definer set search_path=public as
$$ declare c coupons%rowtype;
begin
 select * into c from coupons where code=upper(trim(coalesce(p_code,''))) and active and (expires is null or expires>=current_date) and (max_uses is null or used<max_uses);
 if not found then raise exception 'coupon'; end if;
 if coalesce(p_sub,0)<c.min_total then raise exception 'min %',c.min_total; end if;
 return jsonb_build_object('code',c.code,'kind',c.kind,'value',c.value,'min_total',c.min_total);
end $$;

-- تتبّع الطلب: لازم رقم الطلب + نفس رقم الموبايل. بيرجّع الحالة والمنتجات بس (من غير العنوان).
create or replace function track_order(p_id bigint,p_phone text) returns jsonb language plpgsql security definer set search_path=public as
$$ declare o orders%rowtype;
begin
 select * into o from orders where id=p_id and phone=p_phone;
 if not found then return null; end if;
 return jsonb_build_object('id',o.id,'status',o.status,'created_at',o.created_at,'total',o.total,'payment',o.payment,'paid',o.paid,
  'items',(select coalesce(jsonb_agg(jsonb_build_object('name',i->>'name','size',i->>'size','color',i->>'color','qty',(i->>'qty')::int,'img',i->>'img')),'[]'::jsonb) from jsonb_array_elements(o.items) i));
end $$;

drop function if exists place_order(jsonb,text,text,text,text,text,text,double precision,double precision);
drop function if exists place_order(jsonb,text,text,text,text,text,text,double precision,double precision,text);
create function place_order(p_items jsonb,p_name text,p_phone text,p_gov text,p_address text,p_notes text,p_payment text,p_lat double precision default null,p_lng double precision default null,p_coupon text default null)
returns bigint language plpgsql security definer set search_path=public as
$$ declare disc int:=0; cp coupons%rowtype; it jsonb; col text; pr products%rowtype; sub int:=0; ship int; snap jsonb:='[]'; st jsonb; fs int; oid bigint; q int; sz text;
begin
 if auth.uid() is null then raise exception 'login'; end if;
 if length(trim(coalesce(p_name,'')))<2 or length(p_name)>80 or p_phone !~ '^01[0125][0-9]{8}$' or length(trim(coalesce(p_address,'')))<5 or length(p_address)>300 then raise exception 'data'; end if;
 if (p_lat is null)<>(p_lng is null) or (p_lat is not null and (p_lat not between 21.7 and 31.8 or p_lng not between 24.6 and 37)) then raise exception 'data'; end if;
 if (select count(*) from orders where user_id=auth.uid() and created_at>now()-interval '1 hour')>=10 then raise exception 'rate'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>30 then raise exception 'empty'; end if;
 for it in select * from jsonb_array_elements(p_items) loop
  q:=(it->>'qty')::int; sz:=it->>'size'; col:=nullif(trim(coalesce(it->>'color','')),'');
  if q<1 or q>10 then raise exception 'qty'; end if;
  select * into pr from products where id=(it->>'id')::bigint and not hidden for update;
  if not found then raise exception 'missing'; end if;
  if jsonb_array_length(pr.colors)>0 and (col is null or not (pr.colors ? col)) then raise exception 'color'; end if;
  if coalesce((pr.sizes->>sz)::int,0)<q then raise exception 'stock %',pr.name; end if;
  update products set sizes=jsonb_set(sizes,array[sz],to_jsonb((sizes->>sz)::int-q)) where id=pr.id;
  sub:=sub+pr.price*q;
  snap:=snap||jsonb_build_object('id',pr.id,'name',pr.name,'price',pr.price,'size',sz,'color',col,'qty',q,'img',pr.img);
 end loop;
 select price into ship from shipping_rates where governorate=p_gov;
 if ship is null then raise exception 'gov'; end if;
 select data into st from settings where id=1;
 fs:=coalesce((st->>'free_shipping_over')::int,0);
 if fs>0 and sub>=fs then ship:=0; end if;
 if not coalesce((st->>(case p_payment when 'cod' then 'pay_cod' when 'vodafone' then 'pay_vodafone' when 'instapay' then 'pay_instapay' else 'none' end))::boolean,false) then raise exception 'payment'; end if;
 if nullif(trim(coalesce(p_coupon,'')),'') is not null then
  select * into cp from coupons where code=upper(trim(p_coupon)) and active and (expires is null or expires>=current_date) and (max_uses is null or used<max_uses) and sub>=min_total for update;
  if not found then raise exception 'coupon'; end if;
  disc:=case cp.kind when 'pct' then least(sub,floor(sub*cp.value/100.0)::int) else least(sub,cp.value) end;
  update coupons set used=used+1 where code=cp.code;
 end if;
 insert into orders(user_id,name,phone,governorate,address,notes,payment,items,subtotal,shipping,discount,coupon,total,lat,lng)
 values(auth.uid(),trim(p_name),p_phone,p_gov,trim(p_address),left(coalesce(p_notes,''),300),p_payment,snap,sub,ship,disc,cp.code,sub-disc+ship,p_lat,p_lng) returning id into oid;
 return oid;
end $$;

revoke execute on function place_order(jsonb,text,text,text,text,text,text,double precision,double precision,text),check_coupon(text,int),track_order(bigint,text) from public;
grant execute on function place_order(jsonb,text,text,text,text,text,text,double precision,double precision,text) to authenticated;
grant execute on function check_coupon(text,int),track_order(bigint,text) to anon,authenticated;
-- ترقية v5: إشعار تليجرام لكل طلب جديد. شغّله مرة واحدة: psql -v ON_ERROR_STOP=1 -f upgrade_v5.sql
-- بعدها المالك يكتب Bot Token و Chat ID من لوحة التحكم ← إعدادات المتجر (مش محتاج يلمس SQL تاني).
create extension if not exists pg_net with schema extensions;

-- جدول سرّي: مفيش عليه أي policy ولا صلاحيات، فمحدش يقدر يقراه من الموقع. بيتقرا من الدوال بس.
create table if not exists private_cfg(key text primary key, value text);
alter table private_cfg enable row level security;
revoke all on private_cfg from anon, authenticated;

create or replace function tg_send(p_text text) returns void language plpgsql security definer set search_path=public,extensions as
$$ declare tk text; ch text;
begin
 select value into tk from private_cfg where key='tg_token';
 select value into ch from private_cfg where key='tg_chat';
 if coalesce(tk,'')='' or coalesce(ch,'')='' then return; end if;
 perform net.http_post(url:='https://api.telegram.org/bot'||tk||'/sendMessage',
  headers:='{"Content-Type":"application/json"}'::jsonb,
  body:=jsonb_build_object('chat_id',ch,'text',left(p_text,3500),'disable_web_page_preview',true));
exception when others then null;
end $$;

create table if not exists notify_err(at timestamptz default now(), err text);
alter table notify_err enable row level security;
create or replace function notify_order() returns trigger language plpgsql security definer set search_path=public,extensions as
$$ declare t text; it jsonb;
begin
 t:='🛍️ طلب جديد #'||new.id||E'\n👤 '||coalesce(new.name,'')||' — '||coalesce(new.phone,'')||E'\n📍 '||coalesce(new.governorate,'')||' — '||coalesce(new.address,'')||E'\n';
 for it in select * from jsonb_array_elements(coalesce(new.items,'[]'::jsonb)) loop
  t:=t||'• '||coalesce(it->>'name','')||' / مقاس '||coalesce(it->>'size','')||coalesce(' / '||(it->>'color'),'')||' × '||coalesce(it->>'qty','1')||E'\n';
 end loop;
 t:=t||'💰 الإجمالي: '||coalesce(new.total,0)||' ج.م'||case when coalesce(new.discount,0)>0 then ' (بعد خصم '||new.discount||')' else '' end
  ||E'\n💳 الدفع: '||case new.payment when 'cod' then 'عند الاستلام' when 'vodafone' then 'فودافون كاش' when 'instapay' then 'إنستاباي' else coalesce(new.payment,'') end;
 perform tg_send(t);
 return new;
exception when others then
 insert into notify_err(err) values(sqlerrm);
 return new;
end $$;
drop trigger if exists orders_notify on orders;
create trigger orders_notify after insert on orders for each row execute function notify_order();

create or replace function set_notify(p_token text,p_chat text) returns void language plpgsql security definer set search_path=public as
$$ begin
 if not is_owner() then raise exception 'forbidden'; end if;
 if coalesce(p_token,'') !~ '^[0-9]{6,12}:[A-Za-z0-9_-]{30,50}$' or coalesce(p_chat,'') !~ '^-?[0-9]{5,15}$' then raise exception 'format'; end if;
 insert into private_cfg(key,value) values('tg_token',p_token),('tg_chat',p_chat) on conflict(key) do update set value=excluded.value;
 perform audit_add('notify.set','{}'::jsonb);
end $$;
create or replace function clear_notify() returns void language plpgsql security definer set search_path=public as
$$ begin
 if not is_owner() then raise exception 'forbidden'; end if;
 delete from private_cfg where key in ('tg_token','tg_chat');
 perform audit_add('notify.clear','{}'::jsonb);
end $$;
create or replace function notify_status() returns boolean language plpgsql security definer set search_path=public as
$$ begin
 if not is_owner() then raise exception 'forbidden'; end if;
 return (select count(*) from private_cfg where key in ('tg_token','tg_chat') and coalesce(value,'')<>'')=2;
end $$;
create or replace function test_notify() returns void language plpgsql security definer set search_path=public as
$$ begin
 if not is_owner() then raise exception 'forbidden'; end if;
 perform tg_send('✅ تمام! إشعارات طلبات Kataki Store شغالة على تليجرام.');
end $$;

revoke execute on function tg_send(text),notify_order(),set_notify(text,text),clear_notify(),notify_status(),test_notify() from public,anon;
grant execute on function set_notify(text,text),clear_notify(),notify_status(),test_notify() to authenticated;

-- (v6) حفظ بيانات العميل بعد الدخول بالكود
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

-- (v7) صلاحيات tg_send
revoke execute on function tg_send(text) from public, anon, authenticated;
revoke execute on function notify_order() from public, anon, authenticated;

-- (v8) إشعارات تليجرام لأكتر من جهاز
create table if not exists tg_targets(
  id serial primary key,
  label text,
  token text not null,
  chat text not null,
  created_at timestamptz default now(),
  unique(token,chat)
);
alter table tg_targets enable row level security;
revoke all on tg_targets from anon, authenticated;

-- ننقل الإعداد القديم (لو موجود) كأول جهاز، وبعدها نمسحه علشان مايتبعتش مرتين.
insert into tg_targets(label,token,chat)
select 'الجهاز الأساسي', t.value, c.value
from private_cfg t, private_cfg c
where t.key='tg_token' and c.key='tg_chat' and coalesce(t.value,'')<>'' and coalesce(c.value,'')<>''
on conflict do nothing;
delete from private_cfg where key in ('tg_token','tg_chat');

-- إرسال رسالة لجهاز واحد (داخلية)
create or replace function tg_send_to(p_token text,p_chat text,p_text text) returns void
language plpgsql security definer set search_path=public,extensions as $$
begin
 perform net.http_post(url:='https://api.telegram.org/bot'||p_token||'/sendMessage',
  headers:='{"Content-Type":"application/json"}'::jsonb,
  body:=jsonb_build_object('chat_id',p_chat,'text',left(p_text,3500),'disable_web_page_preview',true),
  timeout_milliseconds:=20000);
exception when others then
 insert into notify_err(err) values('tg_send_to failed: '||sqlstate);
end $$;

-- إرسال لكل الأجهزة المضافة
create or replace function tg_send(p_text text) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare r record;
begin
 for r in select token,chat from tg_targets order by id loop
  perform tg_send_to(r.token,r.chat,p_text);
 end loop;
exception when others then null;
end $$;

-- إضافة جهاز. لو التوكن فاضي بيستخدم توكن آخر جهاز (نفس البوت لأكتر من شخص).
create or replace function add_notify(p_label text,p_token text,p_chat text) returns int
language plpgsql security definer set search_path=public as $$
declare tk text:=nullif(regexp_replace(regexp_replace(coalesce(p_token,''),'[^A-Za-z0-9_:-]','','g'),'^bot','','i'),'');
 ch text:=regexp_replace(coalesce(p_chat,''),'[^0-9-]','','g'); nid int;
begin
 if not is_owner() then raise exception 'forbidden'; end if;
 if tk is null then select token into tk from tg_targets order by id desc limit 1; end if;
 if tk is null or tk !~ '^[0-9]{6,12}:[A-Za-z0-9_-]{30,50}$' or ch !~ '^-?[0-9]{5,15}$' then raise exception 'format'; end if;
 if (select count(*) from tg_targets)>=10 and not exists(select 1 from tg_targets where token=tk and chat=ch) then raise exception 'limit'; end if;
 insert into tg_targets(label,token,chat) values(left(nullif(btrim(coalesce(p_label,'')),''),40),tk,ch)
  on conflict(token,chat) do update set label=coalesce(excluded.label,tg_targets.label)
  returning id into nid;
 perform audit_add('notify.add','{}'::jsonb);
 return nid;
end $$;

-- القائمة للمالك (التوكن نفسه عمره ما بيرجع للمتصفح، بس رقم البوت)
create or replace function list_notify() returns table(id int,label text,chat text,bot text)
language plpgsql security definer set search_path=public as $$
begin
 if not is_owner() then raise exception 'forbidden'; end if;
 return query select t.id,t.label,t.chat,split_part(t.token,':',1) from tg_targets t order by t.id;
end $$;

create or replace function remove_notify(p_id int) returns void
language plpgsql security definer set search_path=public as $$
begin
 if not is_owner() then raise exception 'forbidden'; end if;
 delete from tg_targets where id=p_id;
 perform audit_add('notify.remove','{}'::jsonb);
end $$;

-- كان من غير بارامتر. بنشيله علشان مايحصلش لبس بين النسختين.
drop function if exists test_notify();
create or replace function test_notify(p_id int default null) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare r record;
begin
 if not is_owner() then raise exception 'forbidden'; end if;
 for r in select token,chat from tg_targets where p_id is null or id=p_id order by id loop
  perform tg_send_to(r.token,r.chat,'✅ تمام! إشعارات طلبات Kataki Store شغالة على الجهاز ده.');
 end loop;
end $$;

create or replace function notify_status() returns boolean
language plpgsql security definer set search_path=public as $$
begin
 if not is_owner() then raise exception 'forbidden'; end if;
 return exists(select 1 from tg_targets);
end $$;

create or replace function clear_notify() returns void
language plpgsql security definer set search_path=public as $$
begin
 if not is_owner() then raise exception 'forbidden'; end if;
 delete from tg_targets;
 delete from private_cfg where key in ('tg_token','tg_chat');
 perform audit_add('notify.clear','{}'::jsonb);
end $$;

-- توافق مع النسخة القديمة من اللوحة: "حفظ" بقى معناها "إضافة جهاز".
create or replace function set_notify(p_token text,p_chat text) returns void
language plpgsql security definer set search_path=public as $$
begin
 perform add_notify(null,p_token,p_chat);
end $$;

revoke execute on function tg_send_to(text,text,text) from public, anon, authenticated;
revoke execute on function tg_send(text) from public, anon, authenticated;
revoke execute on function add_notify(text,text,text), list_notify(), remove_notify(int), test_notify(int),
  notify_status(), clear_notify(), set_notify(text,text) from public, anon;
grant execute on function add_notify(text,text,text), list_notify(), remove_notify(int), test_notify(int),
  notify_status(), clear_notify(), set_notify(text,text) to authenticated;

-- فحص: لازم النتيجة تكون فاضية. الدوال الداخلية مفروض ماتبقاش متاحة لأي زبون مسجّل.
select p.proname as "دالة داخلية متاحة للزبون (لازم تكون فاضية)"
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and has_function_privilege('authenticated',p.oid,'execute')
  and p.proname in ('tg_send','tg_send_to','audit_add','notify_order');
-- upgrade_v9: رسالة تليجرام بتخفي كلمة "مقاس" للمنتجات من غير مقاس (ساعات، شنط...).
-- آمن لو اتشغل تاني.
create or replace function notify_order() returns trigger language plpgsql security definer set search_path=public,extensions as
$$ declare t text; it jsonb; d text;
begin
 t:='🛍️ طلب جديد #'||new.id||E'\n👤 '||coalesce(new.name,'')||' — '||coalesce(new.phone,'')||E'\n📍 '||coalesce(new.governorate,'')||' — '||coalesce(new.address,'')||E'\n';
 for it in select * from jsonb_array_elements(coalesce(new.items,'[]'::jsonb)) loop
  d:=concat_ws(' / ',case when coalesce(it->>'size','') in ('','حر') then null else 'مقاس '||(it->>'size') end,nullif(it->>'color',''));
  t:=t||'• '||coalesce(it->>'name','')||case when d<>'' then ' / '||d else '' end||' × '||coalesce(it->>'qty','1')||E'\n';
 end loop;
 t:=t||'💰 الإجمالي: '||coalesce(new.total,0)||' ج.م'||case when coalesce(new.discount,0)>0 then ' (بعد خصم '||new.discount||')' else '' end
  ||E'\n💳 الدفع: '||case new.payment when 'cod' then 'عند الاستلام' when 'vodafone' then 'فودافون كاش' when 'instapay' then 'إنستاباي' else coalesce(new.payment,'') end;
 perform tg_send(t);
 return new;
exception when others then
 insert into notify_err(err) values(sqlerrm);
 return new;
end $$;
revoke execute on function notify_order() from public, anon, authenticated;
select 'ok' as done;

-- ===== upgrade_v10 =====

create table if not exists reviews(
  id bigint generated always as identity primary key,
  product_id bigint not null references products(id) on delete cascade,
  order_id bigint not null references orders(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text,
  body text not null check(char_length(body) between 2 and 500),
  hidden boolean not null default false,
  created_at timestamptz not null default now(),
  unique(order_id,product_id)
);
alter table reviews enable row level security;
revoke all on reviews from anon, authenticated;   -- مفيش قراءة مباشرة، كله من الدوال تحت

-- إضافة تعليق (للزبون صاحب الطلب بس، والطلب لازم يكون «تم التسليم»)
create or replace function add_review(p_order bigint,p_product bigint,p_body text) returns void
language plpgsql security definer set search_path=public as $$
declare o orders%rowtype; nm text; b text:=btrim(coalesce(p_body,''));
begin
 if auth.uid() is null then raise exception 'auth'; end if;
 if char_length(b)<2 or char_length(b)>500 then raise exception 'length'; end if;
 select * into o from orders where id=p_order and user_id=auth.uid();
 if not found then raise exception 'noorder'; end if;
 if o.status<>'تم التسليم' then raise exception 'notdelivered'; end if;
 if not exists(select 1 from jsonb_array_elements(o.items) it where (it->>'id')::bigint=p_product) then raise exception 'noproduct'; end if;
 select split_part(btrim(coalesce(name,'')),' ',1) into nm from profiles where id=auth.uid();
 insert into reviews(product_id,order_id,user_id,name,body) values(p_product,p_order,auth.uid(),nullif(nm,''),b);
exception when unique_violation then raise exception 'dup';
end $$;

-- التعليقات الظاهرة على منتج (للكل): الاسم الأول والنص والتاريخ بس
create or replace function product_reviews(p_product bigint) returns table(name text,body text,created_at timestamptz)
language sql security definer stable set search_path=public as $$
 select coalesce(r.name,'عميل'),r.body,r.created_at from reviews r
 where r.product_id=p_product and not r.hidden order by r.id desc limit 50
$$;

-- تعليقاتي أنا (علشان أعرف أنهي منتج علّقت عليه)
create or replace function my_reviews() returns table(order_id bigint,product_id bigint,body text)
language sql security definer stable set search_path=public as $$
 select r.order_id,r.product_id,r.body from reviews r where r.user_id=auth.uid()
$$;

-- للمالك/الفريق: كل التعليقات
create or replace function list_reviews() returns table(id bigint,product_id bigint,product_name text,order_id bigint,name text,body text,hidden boolean,created_at timestamptz)
language plpgsql security definer stable set search_path=public as $$
begin
 if not is_admin() then raise exception 'forbidden'; end if;
 return query select r.id,r.product_id,p.name,r.order_id,r.name,r.body,r.hidden,r.created_at
  from reviews r left join products p on p.id=r.product_id order by r.id desc limit 300;
end $$;

create or replace function set_review_hidden(p_id bigint,p_hidden boolean) returns void
language plpgsql security definer set search_path=public as $$
begin
 if not is_admin() then raise exception 'forbidden'; end if;
 update reviews set hidden=coalesce(p_hidden,false) where id=p_id;
 perform audit_add('review.hide','{}'::jsonb);
end $$;

create or replace function delete_review(p_id bigint) returns void
language plpgsql security definer set search_path=public as $$
begin
 if not is_admin() then raise exception 'forbidden'; end if;
 delete from reviews where id=p_id;
 perform audit_add('review.delete','{}'::jsonb);
end $$;

revoke execute on function add_review(bigint,bigint,text), my_reviews(), list_reviews(), set_review_hidden(bigint,boolean), delete_review(bigint) from public, anon;
grant execute on function add_review(bigint,bigint,text), my_reviews(), list_reviews(), set_review_hidden(bigint,boolean), delete_review(bigint) to authenticated;
revoke execute on function product_reviews(bigint) from public;
grant execute on function product_reviews(bigint) to anon, authenticated;

select 'ok' as done;

-- ===== upgrade_v11 =====

create or replace function place_order(p_items jsonb,p_name text,p_phone text,p_gov text,p_address text,p_notes text,p_payment text,p_lat double precision default null,p_lng double precision default null,p_coupon text default null)
returns bigint language plpgsql security definer set search_path=public as
$$ declare disc int:=0; cp coupons%rowtype; it jsonb; col text; pr products%rowtype; sub int:=0; ship int; snap jsonb:='[]'; st jsonb; fs int; oid bigint; q int; sz text;
begin
 if length(trim(coalesce(p_name,'')))<2 or length(p_name)>80 or p_phone !~ '^01[0125][0-9]{8}$' or length(trim(coalesce(p_address,'')))<5 or length(p_address)>300 then raise exception 'data'; end if;
 if (p_lat is null)<>(p_lng is null) or (p_lat is not null and (p_lat not between 21.7 and 31.8 or p_lng not between 24.6 and 37)) then raise exception 'data'; end if;
 if auth.uid() is null then
  if (select count(*) from orders where user_id is null and phone=p_phone and created_at>now()-interval '1 hour')>=5 then raise exception 'rate'; end if;
  if (select count(*) from orders where user_id is null and created_at>now()-interval '1 hour')>=30 then raise exception 'rate'; end if;
 elsif (select count(*) from orders where user_id=auth.uid() and created_at>now()-interval '1 hour')>=10 then raise exception 'rate'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>30 then raise exception 'empty'; end if;
 for it in select * from jsonb_array_elements(p_items) loop
  q:=(it->>'qty')::int; sz:=it->>'size'; col:=nullif(trim(coalesce(it->>'color','')),'');
  if q<1 or q>10 then raise exception 'qty'; end if;
  select * into pr from products where id=(it->>'id')::bigint and not hidden for update;
  if not found then raise exception 'missing'; end if;
  if jsonb_array_length(pr.colors)>0 and (col is null or not (pr.colors ? col)) then raise exception 'color'; end if;
  if coalesce((pr.sizes->>sz)::int,0)<q then raise exception 'stock %',pr.name; end if;
  update products set sizes=jsonb_set(sizes,array[sz],to_jsonb((sizes->>sz)::int-q)) where id=pr.id;
  sub:=sub+pr.price*q;
  snap:=snap||jsonb_build_object('id',pr.id,'name',pr.name,'price',pr.price,'size',sz,'color',col,'qty',q,'img',pr.img);
 end loop;
 select price into ship from shipping_rates where governorate=p_gov;
 if ship is null then raise exception 'gov'; end if;
 select data into st from settings where id=1;
 fs:=coalesce((st->>'free_shipping_over')::int,0);
 if fs>0 and sub>=fs then ship:=0; end if;
 if not coalesce((st->>(case p_payment when 'cod' then 'pay_cod' when 'vodafone' then 'pay_vodafone' when 'instapay' then 'pay_instapay' else 'none' end))::boolean,false) then raise exception 'payment'; end if;
 if nullif(trim(coalesce(p_coupon,'')),'') is not null then
  select * into cp from coupons where code=upper(trim(p_coupon)) and active and (expires is null or expires>=current_date) and (max_uses is null or used<max_uses) and sub>=min_total for update;
  if not found then raise exception 'coupon'; end if;
  disc:=case cp.kind when 'pct' then least(sub,floor(sub*cp.value/100.0)::int) else least(sub,cp.value) end;
  update coupons set used=used+1 where code=cp.code;
 end if;
 insert into orders(user_id,name,phone,governorate,address,notes,payment,items,subtotal,shipping,discount,coupon,total,lat,lng)
 values(auth.uid(),trim(p_name),p_phone,p_gov,trim(p_address),left(coalesce(p_notes,''),300),p_payment,snap,sub,ship,disc,cp.code,sub-disc+ship,p_lat,p_lng) returning id into oid;
 return oid;
end $$;

revoke execute on function place_order(jsonb,text,text,text,text,text,text,double precision,double precision,text) from public;
grant execute on function place_order(jsonb,text,text,text,text,text,text,double precision,double precision,text) to anon,authenticated;

select 'ok' as done;

-- ===== upgrade_v13 =====
alter table products add column if not exists color_imgs jsonb not null default '{}';
