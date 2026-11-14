-- ترقية لقاعدة شغّالة: يلغي كود الموبايل وكود التفعيل. شغّله مرة واحدة: psql -v ON_ERROR_STOP=1 -f upgrade_v3.sql
create or replace function is_aal2() returns boolean language sql stable as $$ select true $$;
create or replace function fresh_totp(p_seconds int default 300) returns boolean language sql stable as $$ select true $$;
create or replace function claim_owner(p_code text) returns boolean language plpgsql security definer set search_path=public as
$$ begin
 if auth.uid() is null then return false; end if;
 lock table profiles in share row exclusive mode;
 if exists(select 1 from profiles where role='owner') then return false; end if;
 update profiles set role='owner' where id=auth.uid();
 perform audit_add('owner.claim','{}'::jsonb);
 return true;
end $$;

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
$$ begin
 if not is_admin() then raise exception 'forbidden'; end if;
 if length(coalesce(p_password,''))<8 then raise exception 'short'; end if;
 if exists(select 1 from auth.users u join profiles p on p.id=u.id where p.role in ('owner','staff') and u.id<>auth.uid() and u.encrypted_password=crypt(p_password,u.encrypted_password)) then raise exception 'dup'; end if;
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

-- ألوان وصور إضافية للمنتجات
alter table products add column if not exists images jsonb not null default '[]';
alter table products add column if not exists colors jsonb not null default '[]';
create or replace function place_order(p_items jsonb,p_name text,p_phone text,p_gov text,p_address text,p_notes text,p_payment text,p_lat double precision default null,p_lng double precision default null)
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
