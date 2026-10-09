-- How many conversations of each shape a mailbox holds. Numbers only: never selects subjects, senders or bodies.
--   sqlite3 <working-copy>/mail.sqlite < bench/thread-open/shapes.sql
select 'messages', count(*), 'with html', sum(bodyHTML is not null and bodyHTML <> ''), 'largest html', max(length(bodyHTML)) from message;
select 'threads with N messages', case when n >= 200 then '200+' when n >= 60 then '60-199' when n >= 10 then '10-59' when n >= 2 then '2-9' else '1' end as bucket,
       count(*), 'most', max(n), 'largest bytes', max(bytes)
  from (select count(*) n, sum(coalesce(length(bodyHTML), 0) + coalesce(length(bodyText), 0)) bytes from message group by accountId, threadId) group by bucket;
select 'html size', case when l >= 140000 then '140k+' when l >= 50000 then '50-140k' when l >= 15000 then '15-50k' when l > 0 then '<15k' else 'none' end as bucket, count(*)
  from (select coalesce(length(bodyHTML), 0) l from message) group by bucket;
select 'messages with cid images', count(*) from message where bodyHTML like '%cid:%';
select 'messages with remote images', count(*) from message where bodyHTML like '%<img%http%';
select 'accounts', count(*) from account;
