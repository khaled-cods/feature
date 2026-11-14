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
