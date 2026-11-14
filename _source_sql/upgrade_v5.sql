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
