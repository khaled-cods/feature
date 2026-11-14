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
