-- upgrade_v14: سجل إشعارات الطلبات + إعادة محاولة تلقائية.
-- كل طلب جديد بيتسجل له صف لكل جهاز تليجرام (رقم الطلب، الجهاز، الحالة، عدد المحاولات).
-- لو الإرسال فشل (مثلاً أول طلب بعد فترة سكون)، بيتعاد تلقائياً لحد 4 مرات.
-- آمن لو اتشغل تاني. مفيش حاجة هنا بتمس الطلبات أو المنتجات الموجودة.

create table if not exists order_notifications(
  id bigint generated always as identity primary key,
  order_id bigint not null,
  target_id int,
  label text,
  msg text not null,
  status text not null default 'pending' check(status in ('pending','sent','failed')),
  attempts int not null default 0,
  request_id bigint,
  last_error text,
  last_try timestamptz,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index if not exists order_notifications_order_idx on order_notifications(order_id);
create index if not exists order_notifications_pending_idx on order_notifications(status) where status='pending';
alter table order_notifications enable row level security;
revoke all on order_notifications from anon, authenticated;

-- محاولة إرسال واحدة (داخلية)
create or replace function tg_try(p_id bigint) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare r order_notifications%rowtype; t tg_targets%rowtype; rid bigint;
begin
 select * into r from order_notifications where id=p_id for update;
 if not found then return; end if;
 select * into t from tg_targets where id=r.target_id;
 if not found then
  update order_notifications set status='failed',last_error='الجهاز اتحذف' where id=p_id;
  return;
 end if;
 rid:=net.http_post(url:='https://api.telegram.org/bot'||t.token||'/sendMessage',
  headers:='{"Content-Type":"application/json"}'::jsonb,
  body:=jsonb_build_object('chat_id',t.chat,'text',left(r.msg,3500),'disable_web_page_preview',true),
  timeout_milliseconds:=15000);
 update order_notifications set request_id=rid,attempts=attempts+1,last_try=now(),status='pending' where id=p_id;
exception when others then
 update order_notifications set attempts=attempts+1,last_try=now(),last_error=left('خطأ إرسال '||sqlstate,200) where id=p_id;
end $$;

-- إرسال رسالة طلب لكل الأجهزة + تسجيلها
create or replace function tg_dispatch(p_order bigint,p_text text) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare r record; nid bigint; n int:=0;
begin
 for r in select id,label from tg_targets order by id loop
  insert into order_notifications(order_id,target_id,label,msg) values(p_order,r.id,r.label,p_text) returning id into nid;
  perform tg_try(nid);
  n:=n+1;
 end loop;
 if n=0 then
  insert into order_notifications(order_id,msg,status,last_error) values(p_order,p_text,'failed','مفيش أجهزة تليجرام مضافة');
 end if;
end $$;

-- الفاحص: بيشوف نتيجة كل إرسال وبيعيد اللي فشل (كل دقيقة)
create or replace function notify_sweep() returns void
language plpgsql security definer set search_path=public,extensions as $$
declare r record; h record;
begin
 for r in select * from order_notifications where status='pending' order by id limit 100 loop
  if r.request_id is null then
   if r.attempts<4 then perform tg_try(r.id); else update order_notifications set status='failed' where id=r.id; end if;
   continue;
  end if;
  select status_code,left(coalesce(content,''),120) as body,error_msg,timed_out into h from net._http_response where id=r.request_id;
  if found then
   if h.status_code=200 then
    update order_notifications set status='sent',sent_at=now(),last_error=null where id=r.id;
   elsif h.status_code in (400,401,403,404) then
    update order_notifications set status='failed',last_error='تليجرام رفض ('||h.status_code||'): '||h.body where id=r.id;
   elsif r.attempts<4 then
    update order_notifications set last_error=coalesce('HTTP '||h.status_code,h.error_msg,'timeout') where id=r.id;
    perform tg_try(r.id);
   else
    update order_notifications set status='failed',last_error=coalesce('HTTP '||h.status_code,h.error_msg,'timeout') where id=r.id;
   end if;
  elsif r.last_try is not null and r.last_try<now()-interval '2 minutes' then
   if r.attempts<4 then
    update order_notifications set last_error='مفيش رد من تليجرام' where id=r.id;
    perform tg_try(r.id);
   else
    update order_notifications set status='failed',last_error='مفيش رد من تليجرام' where id=r.id;
   end if;
  end if;
 end loop;
 delete from order_notifications where created_at<now()-interval '90 days';
exception when others then
 insert into notify_err(err) values('sweep: '||sqlstate);
end $$;

-- الطلب الجديد بيتبعت عن طريق tg_dispatch (نفس نص الرسالة القديم)
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
 perform tg_dispatch(new.id,t);
 return new;
exception when others then
 insert into notify_err(err) values(sqlerrm);
 return new;
end $$;

-- عرض السجل للمالك فقط (صف لكل طلب)
create or replace function list_order_notifs(p_limit int default 50) returns table(
  order_id bigint, at timestamptz, devices int, sent int, failed int, pending int, detail jsonb)
language plpgsql security definer set search_path=public as $$
begin
 if not is_owner() then raise exception 'forbidden'; end if;
 return query
 select n.order_id,min(n.created_at),count(*)::int,
  (count(*) filter(where n.status='sent'))::int,(count(*) filter(where n.status='failed'))::int,(count(*) filter(where n.status='pending'))::int,
  jsonb_agg(jsonb_build_object('label',coalesce(n.label,'جهاز'),'status',n.status,'attempts',n.attempts,'error',n.last_error) order by n.id)
 from order_notifications n group by n.order_id order by min(n.created_at) desc limit greatest(1,least(coalesce(p_limit,50),200));
end $$;

-- إعادة إرسال يدوي لطلب فشل إشعاره
create or replace function retry_order_notif(p_order bigint) returns void
language plpgsql security definer set search_path=public,extensions as $$
declare r record;
begin
 if not is_owner() then raise exception 'forbidden'; end if;
 for r in select id from order_notifications where order_id=p_order and status<>'sent' loop
  update order_notifications set status='pending',attempts=0,last_error=null where id=r.id;
  perform tg_try(r.id);
 end loop;
end $$;

revoke execute on function tg_try(bigint),tg_dispatch(bigint,text),notify_sweep(),notify_order() from public,anon,authenticated;
-- السجل بيتشاف من لوحة Supabase بس (Table Editor / SQL). مفيش وصول من الموقع.
revoke execute on function list_order_notifs(int),retry_order_notif(bigint) from public,anon,authenticated;

-- تشغيل الفاحص كل دقيقة
create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname='order_notify_sweep';
select cron.schedule('order_notify_sweep','* * * * *','select public.notify_sweep()');

select 'ok' as done;
