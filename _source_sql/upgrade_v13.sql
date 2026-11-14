-- upgrade_v13: صورة خاصة لكل لون (اختياري). آمن لو اتشغل تاني.
alter table products add column if not exists color_imgs jsonb not null default '{}';
select 'ok' as done;
