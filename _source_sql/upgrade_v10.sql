-- upgrade_v10: تعليقات الزباين على المنتجات.
-- الزبون يقدر يكتب تعليق على منتج بس لو طلبه حالته «تم التسليم»، وتعليق واحد لكل منتج في كل طلب.
-- المالك/الفريق بيشوفوا التعليقات في الإعدادات وبيقدروا يخفوها أو يمسحوها.
-- شغّله مرة واحدة في Supabase SQL Editor. آمن لو اتشغل تاني.

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
