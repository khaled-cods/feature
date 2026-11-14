-- upgrade_v8: إشعارات تليجرام لأكتر من جهاز.
-- قبل كده كان التوكن والـ Chat ID بيتخزنوا مرة واحدة، فأي إضافة جديدة كانت بتمسح القديمة.
-- دلوقتي كل جهاز صف في جدول tg_targets، وكل طلب جديد بيتبعت لكلهم.
-- شغّله مرة واحدة في Supabase SQL Editor. آمن لو اتشغل تاني.

create table if not exists notify_err(at timestamptz default now(), err text);
alter table notify_err enable row level security;

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
