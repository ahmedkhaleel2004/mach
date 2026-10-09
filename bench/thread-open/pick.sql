-- Chooses the conversations the thread-open benchmark opens, by shape only (sizes and counts).
-- Prints `shape<TAB>account<TAB>thread id` lines; run.sh saves them inside the working copy and never shows them.
.mode tabs
create temp table shape as
  select accountId, threadId, count(*) n,
         sum(coalesce(length(cast(bodyHTML as blob)), 0)) html,
         sum(coalesce(length(cast(bodyHTML as blob)), 0) + coalesce(length(cast(bodyText as blob)), 0)) bytes
    from message where id not like 'local-%' group by accountId, threadId;
-- A newsletter of about 20 KB and one of about 150 KB (one message each).
select 'news20', accountId, threadId from shape where n = 1 order by abs(html - 20000), threadId limit 1;
select 'news150', accountId, threadId from shape where n = 1 order by abs(html - 150000), threadId limit 1;
-- Another large newsletter, with its remote pictures swapped (in this throwaway copy only) for a small built-in one
-- and their width and height taken off, so pictures really arrive while it is open and each one moves the page.
-- A benchmark never fetches anything from the network.
create temp table pictured as select accountId, threadId from shape where n = 1 order by abs(html - 150000), threadId limit 1 offset 1;
update message set bodyHTML = replace(replace(replace(bodyHTML, ' width="120" height="80"', ''),
    'src="https://', 'src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==#'),
    'src="http://', 'src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==#')
  where (accountId, threadId) in (select accountId, threadId from pictured);
select 'images', accountId, threadId from pictured;
-- A short one-message mail from a person: plain text if the mailbox has any, about 1.5 KB.
select 'plain1', accountId, threadId from shape where n = 1 and bytes > 200 order by html > 0, abs(bytes - 1500), threadId limit 1;
-- Long conversations: the ones nearest 60 and 200 messages, and the one with the most bytes of all.
select 'thread60', accountId, threadId from shape order by abs(n - 60), bytes desc, threadId limit 1;
select 'thread200', accountId, threadId from shape order by abs(n - 200), bytes desc, threadId limit 1;
select 'heaviest', accountId, threadId from shape order by bytes desc, threadId limit 1;
-- For the memory run: the 50 largest one-message newsletters.
select 'memory', accountId, threadId from shape where n = 1 order by html desc, threadId limit 50;
